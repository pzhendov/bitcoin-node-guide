#!/usr/bin/env bash

# Safely report and retain local Bitcoin blockchain backups on macOS.
#
# Exit codes:
#   0 = inventory completed or confirmed retention completed
#   1 = invalid command usage
#   2 = verification or retention safety check failed
#
# The dollar expressions in AWK programs belong to AWK, not Bash.
# shellcheck disable=SC2016,SC2317,SC2329

set -u
set -o pipefail

PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
umask 077

AWK="${AWK:-/usr/bin/awk}"
DF="${DF:-/bin/df}"
FIND="${FIND:-/usr/bin/find}"
RM="${RM:-/bin/rm}"
SHASUM="${SHASUM:-/usr/bin/shasum}"
SORT="${SORT:-/usr/bin/sort}"
STAT="${STAT:-/usr/bin/stat}"

DESTINATION="${HOME}/bitcoin-node-backups"
KEEP_COUNT=2
MODE=""
DELETE_CONFIRMED=false

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
    printf '%s [RETENTION] %s\n' "$(timestamp)" "$1"
}

fail() {
    log "ERROR: $1" >&2
    exit 2
}

usage() {
    cat <<'EOF'
Usage:
  macos-bitcoin-node-backup-retention --dry-run [options]
  macos-bitcoin-node-backup-retention --execute --confirm-retention-delete [options]

Options:
  --dry-run                  Verify and report retention decisions without deletion
  --execute                  Delete only verified backup sets beyond the keep count
  --confirm-retention-delete Confirm intentional deletion during --execute
  --destination PATH         Backup directory
  --keep COUNT               Number of newest complete backups to protect; minimum 2
  --help                     Show this help

A complete backup set contains:

  bitcoin-node-pruned-BLOCK-DATE.tar.zst
  bitcoin-node-pruned-BLOCK-DATE.tar.zst.sha256
  bitcoin-node-pruned-BLOCK-DATE.manifest.txt

The newest protected sets are selected by Bitcoin block height. Incomplete,
unverified or unexpected backup sets are never deleted automatically.
EOF
}

require_executable() {
    if [[ ! -x "$1" ]]; then
        fail "Required executable not found: $1"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|--execute)
            if [[ -n "$MODE" ]]; then
                printf 'Choose only one mode: --dry-run or --execute\n' >&2
                exit 1
            fi

            MODE="$1"
            shift
            ;;
        --confirm-retention-delete)
            DELETE_CONFIRMED=true
            shift
            ;;
        --destination)
            if [[ $# -lt 2 ]]; then
                printf 'Missing value for --destination\n' >&2
                usage >&2
                exit 1
            fi

            DESTINATION="$2"
            shift 2
            ;;
        --keep)
            if [[ $# -lt 2 ]]; then
                printf 'Missing value for --keep\n' >&2
                usage >&2
                exit 1
            fi

            KEEP_COUNT="$2"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$MODE" ]]; then
    printf 'Choose one mode: --dry-run or --execute\n' >&2
    usage >&2
    exit 1
fi

if [[ ! "$KEEP_COUNT" =~ ^[0-9]+$ ]] || (( KEEP_COUNT < 2 )); then
    printf 'The --keep value must be an integer of at least 2.\n' >&2
    exit 1
fi

if [[ "$MODE" == "--execute" ]] &&
    [[ "$DELETE_CONFIRMED" != "true" ]]
then
    printf 'Execution requires --confirm-retention-delete.\n' >&2
    exit 1
fi

for executable in \
    "$AWK" \
    "$DF" \
    "$FIND" \
    "$RM" \
    "$SHASUM" \
    "$SORT" \
    "$STAT"
do
    require_executable "$executable"
done

if [[ ! -d "$DESTINATION" ]]; then
    fail "Backup directory does not exist: $DESTINATION"
fi

if [[ ! -r "$DESTINATION" ]]; then
    fail "Backup directory is not readable: $DESTINATION"
fi

if [[ "$MODE" == "--execute" ]] && [[ ! -w "$DESTINATION" ]]; then
    fail "Backup directory is not writable: $DESTINATION"
fi

inventory_file="${TMPDIR:-/tmp}/bitcoin-backup-retention-${UID}-${$}.inventory"
lock_directory="${TMPDIR:-/tmp}/bitcoin-backup-retention-${UID}.lock"
lock_acquired=false

cleanup() {
    cleanup_status=$?

    trap - EXIT HUP INT TERM

    "$RM" -f -- "$inventory_file" >/dev/null 2>&1 || true

    if [[ "$lock_acquired" == "true" ]]; then
        /bin/rmdir -- "$lock_directory" >/dev/null 2>&1 || true
    fi

    exit "$cleanup_status"
}

trap cleanup EXIT
trap 'exit 2' HUP INT TERM

if [[ "$MODE" == "--execute" ]]; then
    if ! /bin/mkdir -- "$lock_directory"; then
        fail "Another retention execution may already be running: $lock_directory"
    fi

    lock_acquired=true
fi

log "Backup directory is available: $DESTINATION"
log "Retention policy: keep newest $KEEP_COUNT complete backup sets"

shopt -s nullglob

archive_paths=(
    "$DESTINATION"/bitcoin-node-pruned-*.tar.zst
)

partial_paths=(
    "$DESTINATION"/bitcoin-node-pruned-*.partial
)

checksum_paths=(
    "$DESTINATION"/bitcoin-node-pruned-*.tar.zst.sha256
)

manifest_paths=(
    "$DESTINATION"/bitcoin-node-pruned-*.manifest.txt
)

if (( ${#partial_paths[@]} > 0 )); then
    for partial_path in "${partial_paths[@]}"; do
        log "UNSAFE: incomplete artifact found: $partial_path"
    done

    fail "Incomplete backup artifacts require manual inspection"
fi

incomplete_sets=false

for checksum_path in "${checksum_paths[@]}"; do
    related_archive="${checksum_path%.sha256}"

    if [[ ! -f "$related_archive" ]]; then
        log "UNSAFE: checksum has no archive: $checksum_path"
        incomplete_sets=true
    fi
done

for manifest_path in "${manifest_paths[@]}"; do
    related_archive="${manifest_path%.manifest.txt}.tar.zst"

    if [[ ! -f "$related_archive" ]]; then
        log "UNSAFE: manifest has no archive: $manifest_path"
        incomplete_sets=true
    fi
done

if [[ "$incomplete_sets" == "true" ]]; then
    fail "Incomplete backup sets require manual inspection"
fi

unexpected_archive_names=false

for archive_path in "${archive_paths[@]}"; do
    archive_name="${archive_path##*/}"

    if [[ ! "$archive_name" =~ ^bitcoin-node-pruned-([0-9]+)-([0-9]{4}-[0-9]{2}-[0-9]{2})\.tar\.zst$ ]]; then
        log "UNSAFE: unexpected archive name: $archive_path"
        unexpected_archive_names=true
    fi
done

if [[ "$unexpected_archive_names" == "true" ]]; then
    fail "Unexpected archive names require manual inspection"
fi

{
    for archive_path in "${archive_paths[@]}"; do
        archive_name="${archive_path##*/}"
        [[ "$archive_name" =~ ^bitcoin-node-pruned-([0-9]+)-([0-9]{4}-[0-9]{2}-[0-9]{2})\.tar\.zst$ ]]

        block_height="${BASH_REMATCH[1]}"
        backup_date="${BASH_REMATCH[2]}"

        printf '%020d\t%s\t%s\n' \
            "$block_height" \
            "$backup_date" \
            "$archive_path"
    done
} |
    "$SORT" -r >"$inventory_file"

complete_count=0
protected_count=0
candidate_count=0
candidate_total_bytes=0

candidate_archives=()
candidate_checksums=()
candidate_manifests=()
candidate_blocks=()
candidate_dates=()
candidate_sizes=()

while IFS=$'\t' read -r \
    padded_block_height \
    backup_date \
    archive_path
do
    if [[ -z "$archive_path" ]]; then
        continue
    fi

    block_height="$((10#$padded_block_height))"
    checksum_path="${archive_path}.sha256"
    manifest_path="${archive_path%.tar.zst}.manifest.txt"

    if [[ ! -f "$checksum_path" ]]; then
        fail "Archive has no checksum file: $archive_path"
    fi

    if [[ ! -f "$manifest_path" ]]; then
        fail "Archive has no manifest file: $archive_path"
    fi

    expected_sha="$(
        "$AWK" 'NR == 1 { print $1; exit }' "$checksum_path"
    )"

    if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
        fail "Checksum file contains an invalid SHA-256 value: $checksum_path"
    fi

    actual_sha="$(
        "$SHASUM" -a 256 "$archive_path" |
            "$AWK" '{ print $1 }'
    )"

    if [[ "$actual_sha" != "$expected_sha" ]]; then
        fail "Archive checksum verification failed: $archive_path"
    fi

    archive_bytes="$("$STAT" -f '%z' "$archive_path")"

    if [[ ! "$archive_bytes" =~ ^[1-9][0-9]*$ ]]; then
        fail "Unable to determine archive size: $archive_path"
    fi

    archive_gib="$(
        "$AWK" -v bytes="$archive_bytes" \
            'BEGIN { printf "%.2f", bytes / 1073741824 }'
    )"

    complete_count=$((complete_count + 1))

    if (( complete_count <= KEEP_COUNT )); then
        protected_count=$((protected_count + 1))

        log "PROTECT: block=$block_height date=$backup_date size=${archive_gib}GiB"
    else
        candidate_count=$((candidate_count + 1))
        candidate_total_bytes=$((candidate_total_bytes + archive_bytes))

        candidate_archives+=("$archive_path")
        candidate_checksums+=("$checksum_path")
        candidate_manifests+=("$manifest_path")
        candidate_blocks+=("$block_height")
        candidate_dates+=("$backup_date")
        candidate_sizes+=("$archive_gib")

        log "CANDIDATE: block=$block_height date=$backup_date size=${archive_gib}GiB"
    fi
done <"$inventory_file"

free_kib="$(
    "$DF" -Pk "$DESTINATION" |
        "$AWK" 'NR == 2 { print $4 }'
)"

if [[ ! "$free_kib" =~ ^[0-9]+$ ]]; then
    fail "Unable to determine destination free space"
fi

free_gib="$(
    "$AWK" -v kib="$free_kib" \
        'BEGIN { printf "%.2f", kib / 1048576 }'
)"

candidate_total_gib="$(
    "$AWK" -v bytes="$candidate_total_bytes" \
        'BEGIN { printf "%.2f", bytes / 1073741824 }'
)"

log "Summary: complete=$complete_count protected=$protected_count candidates=$candidate_count"
log "Destination free space: ${free_gib}GiB"
log "Potential reclaimed space: ${candidate_total_gib}GiB"

if (( complete_count == 0 )); then
    log "No complete backup sets were found"
    exit 0
fi

if (( candidate_count == 0 )); then
    log "Retention policy already satisfied; no files selected"
    exit 0
fi

if [[ "$MODE" == "--dry-run" ]]; then
    log "Dry-run completed; no files were deleted"
    exit 0
fi

log "Confirmed deletion of $candidate_count verified backup set(s)"

candidate_index=0

while (( candidate_index < candidate_count )); do
    archive_path="${candidate_archives[$candidate_index]}"
    checksum_path="${candidate_checksums[$candidate_index]}"
    manifest_path="${candidate_manifests[$candidate_index]}"
    block_height="${candidate_blocks[$candidate_index]}"
    backup_date="${candidate_dates[$candidate_index]}"
    archive_gib="${candidate_sizes[$candidate_index]}"

    for required_path in \
        "$archive_path" \
        "$checksum_path" \
        "$manifest_path"
    do
        if [[ ! -f "$required_path" ]]; then
            fail "Candidate changed before deletion: $required_path"
        fi
    done

    if ! "$RM" -- \
        "$archive_path" \
        "$checksum_path" \
        "$manifest_path"
    then
        fail "Unable to delete backup set for block $block_height"
    fi

    log "DELETED: block=$block_height date=$backup_date size=${archive_gib}GiB"

    candidate_index=$((candidate_index + 1))
done

log "Retention completed successfully"
log "Deleted backup sets: $candidate_count"
log "Approximate space reclaimed: ${candidate_total_gib}GiB"
