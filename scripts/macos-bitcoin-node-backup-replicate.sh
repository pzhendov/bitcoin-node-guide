#!/usr/bin/env bash

# Safely replicate the newest complete local Bitcoin blockchain backup to a
# removable external volume on macOS.
#
# Exit codes:
#   0 = dry-run passed, copy completed, or verified copy already exists
#   1 = invalid command usage
#   2 = verification or replication safety check failed
#
# The dollar expressions in AWK programs belong to AWK, not Bash.
# shellcheck disable=SC2016,SC2317,SC2329

set -u
set -o pipefail

PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
umask 077

AWK="${AWK:-/usr/bin/awk}"
CAFFEINATE="${CAFFEINATE:-/usr/bin/caffeinate}"
CMP="${CMP:-/usr/bin/cmp}"
DF="${DF:-/bin/df}"
MKDIR="${MKDIR:-/bin/mkdir}"
MV="${MV:-/bin/mv}"
RSYNC="${RSYNC:-/usr/bin/rsync}"
SHASUM="${SHASUM:-/usr/bin/shasum}"
SORT="${SORT:-/usr/bin/sort}"
STAT="${STAT:-/usr/bin/stat}"
SYNC="${SYNC:-/bin/sync}"

SOURCE_DIRECTORY="${HOME}/bitcoin-node-backups"
DESTINATION_DIRECTORY="/Volumes/Backup_8TB/bitcoin-node-backups"
MODE="--dry-run"
MODE_EXPLICIT=false
REPLICATION_CONFIRMED=false
MINIMUM_FREE_MARGIN_BYTES=$((1024 * 1024 * 1024))
ALLOW_NON_VOLUME_DESTINATION="${REPLICATION_ALLOW_NON_VOLUME_DESTINATION:-false}"

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
    printf '%s [REPLICATION] %s\n' "$(timestamp)" "$1"
}

fail() {
    log "ERROR: $1" >&2
    exit 2
}

usage() {
    cat <<'EOF'
Usage:
  macos-bitcoin-node-backup-replicate --dry-run [options]
  macos-bitcoin-node-backup-replicate --execute \
    --confirm-external-replication [options]

Options:
  --dry-run                       Verify and report without copying files
  --execute                       Replicate the newest complete backup set
  --confirm-external-replication  Confirm intentional external replication
  --source PATH                   Local backup directory
  --destination PATH              External backup directory
  --help                          Show this help

The command selects the newest complete local backup by Bitcoin block height.
It verifies the local SHA-256 checksum before any copy. Execution transfers to
.partial files, verifies the external SHA-256, and publishes the final names
only after verification. Existing files are never overwritten or deleted.
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
            if [[ "$MODE_EXPLICIT" == "true" ]]; then
                printf 'Choose only one mode: --dry-run or --execute\n' >&2
                exit 1
            fi

            MODE="$1"
            MODE_EXPLICIT=true
            shift
            ;;
        --confirm-external-replication)
            REPLICATION_CONFIRMED=true
            shift
            ;;
        --source)
            if [[ $# -lt 2 ]]; then
                printf 'Missing value for --source\n' >&2
                usage >&2
                exit 1
            fi

            SOURCE_DIRECTORY="$2"
            shift 2
            ;;
        --destination)
            if [[ $# -lt 2 ]]; then
                printf 'Missing value for --destination\n' >&2
                usage >&2
                exit 1
            fi

            DESTINATION_DIRECTORY="$2"
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

if [[ "$MODE" == "--execute" ]] &&
    [[ "$REPLICATION_CONFIRMED" != "true" ]]
then
    printf 'Execution requires --confirm-external-replication.\n' >&2
    exit 1
fi

for executable in \
    "$AWK" \
    "$CAFFEINATE" \
    "$CMP" \
    "$DF" \
    "$MKDIR" \
    "$MV" \
    "$RSYNC" \
    "$SHASUM" \
    "$SORT" \
    "$STAT" \
    "$SYNC"
do
    require_executable "$executable"
done

if [[ ! -d "$SOURCE_DIRECTORY" ]]; then
    fail "Local backup directory does not exist: $SOURCE_DIRECTORY"
fi

if [[ ! -r "$SOURCE_DIRECTORY" ]]; then
    fail "Local backup directory is not readable: $SOURCE_DIRECTORY"
fi

if [[ ! -d "$DESTINATION_DIRECTORY" ]]; then
    fail "External backup directory does not exist: $DESTINATION_DIRECTORY"
fi

if [[ ! -r "$DESTINATION_DIRECTORY" ]]; then
    fail "External backup directory is not readable: $DESTINATION_DIRECTORY"
fi

if [[ "$MODE" == "--execute" ]] &&
    [[ ! -w "$DESTINATION_DIRECTORY" ]]
then
    fail "External backup directory is not writable: $DESTINATION_DIRECTORY"
fi

SOURCE_DIRECTORY="$(cd "$SOURCE_DIRECTORY" && pwd -P)"
DESTINATION_DIRECTORY="$(cd "$DESTINATION_DIRECTORY" && pwd -P)"

if [[ "$SOURCE_DIRECTORY" == "$DESTINATION_DIRECTORY" ]]; then
    fail "Source and destination directories resolve to the same path"
fi

source_device="$($STAT -f '%d' "$SOURCE_DIRECTORY")"
destination_device="$($STAT -f '%d' "$DESTINATION_DIRECTORY")"

if [[ ! "$source_device" =~ ^[0-9]+$ ]] ||
    [[ ! "$destination_device" =~ ^[0-9]+$ ]]
then
    fail "Unable to identify source and destination filesystems"
fi

if [[ "$ALLOW_NON_VOLUME_DESTINATION" != "true" ]]; then
    if [[ "$DESTINATION_DIRECTORY" != /Volumes/* ]]; then
        fail "Destination is not on a mounted macOS external volume: $DESTINATION_DIRECTORY"
    fi

    if [[ "$source_device" == "$destination_device" ]]; then
        fail "Destination is on the same filesystem as the local backups"
    fi
fi

log "Local backup directory is available: $SOURCE_DIRECTORY"
log "External backup directory is available: $DESTINATION_DIRECTORY"

inventory_file="${TMPDIR:-/tmp}/bitcoin-backup-replication-${UID}-${$}.inventory"
lock_directory="${TMPDIR:-/tmp}/bitcoin-backup-replication-${UID}.lock"
lock_acquired=false

cleanup() {
    cleanup_status=$?

    trap - EXIT HUP INT TERM

    /bin/rm -f -- "$inventory_file" >/dev/null 2>&1 || true

    if [[ "$lock_acquired" == "true" ]]; then
        /bin/rmdir -- "$lock_directory" >/dev/null 2>&1 || true
    fi

    exit "$cleanup_status"
}

trap cleanup EXIT
trap 'exit 2' HUP INT TERM

if [[ "$MODE" == "--execute" ]]; then
    if ! "$MKDIR" -- "$lock_directory"; then
        fail "Another replication execution may already be running: $lock_directory"
    fi

    lock_acquired=true
fi

shopt -s nullglob

source_partial_paths=(
    "$SOURCE_DIRECTORY"/bitcoin-node-pruned-*.partial
)

destination_partial_paths=(
    "$DESTINATION_DIRECTORY"/bitcoin-node-pruned-*.partial
)

if (( ${#source_partial_paths[@]} > 0 )); then
    for partial_path in "${source_partial_paths[@]}"; do
        log "UNSAFE: incomplete local artifact found: $partial_path"
    done

    fail "Incomplete local artifacts require manual inspection"
fi

if (( ${#destination_partial_paths[@]} > 0 )); then
    for partial_path in "${destination_partial_paths[@]}"; do
        log "UNSAFE: incomplete external artifact found: $partial_path"
    done

    fail "Incomplete external artifacts require manual inspection"
fi

source_archive_paths=(
    "$SOURCE_DIRECTORY"/bitcoin-node-pruned-*.tar.zst
)

if (( ${#source_archive_paths[@]} == 0 )); then
    fail "No local backup archives were found"
fi

unexpected_archive_names=false

for archive_path in "${source_archive_paths[@]}"; do
    archive_name="${archive_path##*/}"

    if [[ ! "$archive_name" =~ ^bitcoin-node-pruned-([0-9]+)-([0-9]{4}-[0-9]{2}-[0-9]{2})\.tar\.zst$ ]]; then
        log "UNSAFE: unexpected local archive name: $archive_path"
        unexpected_archive_names=true
        continue
    fi

    block_height="${BASH_REMATCH[1]}"
    backup_date="${BASH_REMATCH[2]}"

    printf '%020d\t%s\t%s\n' \
        "$block_height" \
        "$backup_date" \
        "$archive_path" \
        >>"$inventory_file"
done

if [[ "$unexpected_archive_names" == "true" ]]; then
    fail "Unexpected local archive names require manual inspection"
fi

"$SORT" -r "$inventory_file" -o "$inventory_file"

IFS=$'\t' read -r \
    padded_block_height \
    backup_date \
    source_archive \
    <"$inventory_file"

if [[ -z "${source_archive:-}" ]]; then
    fail "Unable to select the newest local backup"
fi

block_height="$((10#$padded_block_height))"
source_checksum="${source_archive}.sha256"
source_manifest="${source_archive%.tar.zst}.manifest.txt"

for required_path in \
    "$source_archive" \
    "$source_checksum" \
    "$source_manifest"
do
    if [[ ! -f "$required_path" ]]; then
        fail "Newest local backup set is incomplete: $required_path"
    fi

    if [[ ! -r "$required_path" ]]; then
        fail "Newest local backup artifact is not readable: $required_path"
    fi
done

archive_name="${source_archive##*/}"
checksum_name="${source_checksum##*/}"
manifest_name="${source_manifest##*/}"

expected_sha="$($AWK 'NR == 1 { print $1; exit }' "$source_checksum")"
checksum_recorded_name="$($AWK 'NR == 1 { print $2; exit }' "$source_checksum")"

if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
    fail "Local checksum file contains an invalid SHA-256 value: $source_checksum"
fi

if [[ "$checksum_recorded_name" != "$archive_name" ]]; then
    fail "Local checksum file references an unexpected archive: $source_checksum"
fi

log "Calculating local SHA-256: $archive_name"

actual_local_sha="$($SHASUM -a 256 "$source_archive" | $AWK '{ print $1 }')"

if [[ "$actual_local_sha" != "$expected_sha" ]]; then
    fail "Local archive checksum verification failed: $source_archive"
fi

archive_bytes="$($STAT -f '%z' "$source_archive")"

if [[ ! "$archive_bytes" =~ ^[1-9][0-9]*$ ]]; then
    fail "Unable to determine local archive size: $source_archive"
fi

archive_gib="$($AWK -v bytes="$archive_bytes" \
    'BEGIN { printf "%.2f", bytes / 1073741824 }')"

log "Newest local backup verified: block=$block_height date=$backup_date size=${archive_gib}GiB"

destination_archive="${DESTINATION_DIRECTORY}/${archive_name}"
destination_checksum="${DESTINATION_DIRECTORY}/${checksum_name}"
destination_manifest="${DESTINATION_DIRECTORY}/${manifest_name}"

destination_archive_partial="${destination_archive}.partial"
destination_checksum_partial="${destination_checksum}.partial"
destination_manifest_partial="${destination_manifest}.partial"

existing_final_count=0

for final_path in \
    "$destination_archive" \
    "$destination_checksum" \
    "$destination_manifest"
do
    if [[ -e "$final_path" ]]; then
        existing_final_count=$((existing_final_count + 1))
    fi
done

if (( existing_final_count > 0 && existing_final_count < 3 )); then
    fail "External destination contains an incomplete final backup set for $archive_name"
fi

if (( existing_final_count == 3 )); then
    if ! "$CMP" -s "$source_checksum" "$destination_checksum"; then
        fail "Existing external checksum file differs; refusing overwrite: $destination_checksum"
    fi

    if ! "$CMP" -s "$source_manifest" "$destination_manifest"; then
        fail "Existing external manifest differs; refusing overwrite: $destination_manifest"
    fi

    log "Calculating SHA-256 for existing external copy: $archive_name"

    existing_external_sha="$($SHASUM -a 256 "$destination_archive" | $AWK '{ print $1 }')"

    if [[ "$existing_external_sha" != "$expected_sha" ]]; then
        fail "Existing external archive checksum failed; refusing overwrite: $destination_archive"
    fi

    log "External backup is already synchronized and verified: $archive_name"
    exit 0
fi

free_kib="$($DF -Pk "$DESTINATION_DIRECTORY" | $AWK 'NR == 2 { print $4 }')"

if [[ ! "$free_kib" =~ ^[0-9]+$ ]]; then
    fail "Unable to determine external free space"
fi

free_bytes=$((free_kib * 1024))
required_bytes=$((archive_bytes + MINIMUM_FREE_MARGIN_BYTES))
free_gib="$($AWK -v bytes="$free_bytes" \
    'BEGIN { printf "%.2f", bytes / 1073741824 }')"

if (( free_bytes < required_bytes )); then
    fail "External free space is insufficient: available=${free_gib}GiB required_archive=${archive_gib}GiB plus 1GiB margin"
fi

log "External free space is sufficient: ${free_gib}GiB"

if [[ "$MODE" == "--dry-run" ]]; then
    log "DRY-RUN: would replicate $archive_name"
    log "DRY-RUN: transfer would use .partial files and publish only after external SHA-256 verification"
    log "Dry-run completed; no files were created or modified"
    exit 0
fi

for planned_path in \
    "$destination_archive_partial" \
    "$destination_checksum_partial" \
    "$destination_manifest_partial" \
    "$destination_archive" \
    "$destination_checksum" \
    "$destination_manifest"
do
    if [[ -e "$planned_path" ]]; then
        fail "Destination path appeared before replication; refusing overwrite: $planned_path"
    fi
done

"$CAFFEINATE" -i -w "$$" >/dev/null 2>&1 &

log "Transferring archive to external .partial file"

if ! "$RSYNC" -a --progress --ignore-existing -- \
    "$source_archive" \
    "$destination_archive_partial"
then
    fail "Archive transfer failed; partial artifact retained for inspection"
fi

if ! "$RSYNC" -a --ignore-existing -- \
    "$source_checksum" \
    "$destination_checksum_partial"
then
    fail "Checksum transfer failed; partial artifacts retained for inspection"
fi

if ! "$RSYNC" -a --ignore-existing -- \
    "$source_manifest" \
    "$destination_manifest_partial"
then
    fail "Manifest transfer failed; partial artifacts retained for inspection"
fi

if ! "$CMP" -s "$source_checksum" "$destination_checksum_partial"; then
    fail "Transferred checksum file differs from source; partial artifacts retained"
fi

if ! "$CMP" -s "$source_manifest" "$destination_manifest_partial"; then
    fail "Transferred manifest differs from source; partial artifacts retained"
fi

transferred_bytes="$($STAT -f '%z' "$destination_archive_partial")"

if [[ "$transferred_bytes" != "$archive_bytes" ]]; then
    fail "Transferred archive size differs from source; partial artifacts retained"
fi

log "Calculating external SHA-256: $archive_name"

external_sha="$($SHASUM -a 256 "$destination_archive_partial" | $AWK '{ print $1 }')"

if [[ "$external_sha" != "$expected_sha" ]]; then
    fail "External archive checksum verification failed; partial artifacts retained"
fi

log "External SHA-256 verified: $external_sha"

for final_path in \
    "$destination_archive" \
    "$destination_checksum" \
    "$destination_manifest"
do
    if [[ -e "$final_path" ]]; then
        fail "Final destination appeared during verification; partial artifacts retained: $final_path"
    fi
done

if ! "$MV" -n -- "$destination_checksum_partial" "$destination_checksum"; then
    fail "Unable to publish external checksum; remaining artifacts retained"
fi

if ! "$MV" -n -- "$destination_manifest_partial" "$destination_manifest"; then
    fail "Unable to publish external manifest; remaining artifacts retained"
fi

if ! "$MV" -n -- "$destination_archive_partial" "$destination_archive"; then
    fail "Unable to publish external archive; remaining artifacts retained"
fi

for final_path in \
    "$destination_archive" \
    "$destination_checksum" \
    "$destination_manifest"
do
    if [[ ! -f "$final_path" ]]; then
        fail "Published external backup set is incomplete: $final_path"
    fi
done

"$SYNC"

log "External replication completed successfully"
log "Archive: $destination_archive"
log "Checksum: $destination_checksum"
log "Manifest: $destination_manifest"
log "SHA-256: $external_sha"
