#!/usr/bin/env bash

# Read-only deep integrity verification for Bitcoin blockchain backups.
#
# Exit codes:
#   0 = HEALTHY
#   1 = WARNING
#   2 = CRITICAL
#
# Backup archives, checksum files and manifests are never modified or deleted.
# Successful verification receipts are written to a separate state directory.
#
# The dollar expressions in AWK programs belong to AWK, not Bash.
# shellcheck disable=SC2016

set -u
set -o pipefail

PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
umask 077

AWK="${AWK:-/usr/bin/awk}"
DATE="${DATE:-/bin/date}"
MKDIR="${MKDIR:-/bin/mkdir}"
MKTEMP="${MKTEMP:-/usr/bin/mktemp}"
MV="${MV:-/bin/mv}"
SHASUM="${SHASUM:-/usr/bin/shasum}"
SORT="${SORT:-/usr/bin/sort}"
STAT="${STAT:-/usr/bin/stat}"
ZSTD="${ZSTD:-}"

if [[ -z "$ZSTD" ]]; then
    ZSTD="$(command -v zstd 2>/dev/null || true)"
fi

LOCAL_DIRECTORY="${HOME}/bitcoin-node-backups"
EXTERNAL_DIRECTORY="/Volumes/Backup_8TB/bitcoin-node-backups"
RECEIPT_DIRECTORY="${HOME}/Library/Application Support/bitcoin-node-guide/deep-integrity"

DRY_RUN=false
NEWEST_ONLY=false
REQUIRE_EXTERNAL=false

warnings=0
critical=0
verified_count=0
planned_count=0

timestamp() {
    "$DATE" -u '+%Y-%m-%dT%H:%M:%SZ'
}

report_ok() {
    printf '%s [DEEP-AUDIT] [OK] %s\n' "$(timestamp)" "$1"
}

report_info() {
    printf '%s [DEEP-AUDIT] [INFO] %s\n' "$(timestamp)" "$1"
}

report_warning() {
    warnings=$((warnings + 1))
    printf '%s [DEEP-AUDIT] [WARNING] %s\n' "$(timestamp)" "$1"
}

report_critical() {
    critical=$((critical + 1))
    printf '%s [DEEP-AUDIT] [CRITICAL] %s\n' "$(timestamp)" "$1"
}

usage() {
    cat <<'EOF'
Usage:
  macos-bitcoin-node-backup-deep-audit [options]

Options:
  --local-directory PATH      Local backup directory
  --external-directory PATH   External backup directory
  --receipt-directory PATH    Separate verification-receipt directory
  --newest-only               Verify only the newest local backup
  --require-external          Warn when the external drive is not mounted
  --dry-run                   Validate metadata without hashing or testing archives
  --help                      Show this help

Default behavior:
  - Deeply verify every complete local backup set
  - Deeply verify the newest external copy when the drive is mounted
  - Treat a disconnected external drive as informational
  - Never modify or delete backup artifacts
EOF
}

require_value() {
    option_name="$1"
    remaining_count="$2"

    if (( remaining_count < 2 )); then
        printf 'Missing value for %s\n' "$option_name" >&2
        usage >&2
        exit 2
    fi
}

print_summary_and_exit() {
    if (( critical > 0 )); then
        final_status="CRITICAL"
        exit_code=2
    elif (( warnings > 0 )); then
        final_status="WARNING"
        exit_code=1
    else
        final_status="HEALTHY"
        exit_code=0
    fi

    if [[ "$DRY_RUN" == "true" ]]; then
        audit_mode="DRY_RUN"
    else
        audit_mode="DEEP"
    fi

    printf '%s [DEEP-AUDIT] [SUMMARY] status=%s mode=%s verified=%d planned=%d warnings=%d critical=%d\n' \
        "$(timestamp)" \
        "$final_status" \
        "$audit_mode" \
        "$verified_count" \
        "$planned_count" \
        "$warnings" \
        "$critical"

    exit "$exit_code"
}

require_executable() {
    executable_path="$1"

    if [[ ! -x "$executable_path" ]]; then
        report_critical "Required executable not found: $executable_path"
        print_summary_and_exit
    fi
}

read_expected_sha() {
    checksum_path="$1"

    "$AWK" 'NR == 1 { print $1; exit }' "$checksum_path"
}

write_receipt() {
    archive_path="$1"
    location_name="$2"
    expected_sha="$3"
    archive_bytes="$4"

    archive_name="${archive_path##*/}"
    receipt_base="${archive_name%.tar.zst}.${location_name}.deep-integrity.txt"
    receipt_path="${RECEIPT_DIRECTORY}/${receipt_base}"

    if ! "$MKDIR" -p "$RECEIPT_DIRECTORY"; then
        report_critical "Unable to create receipt directory: $RECEIPT_DIRECTORY"
        return 1
    fi

    if ! temporary_receipt="$(
        "$MKTEMP" "${RECEIPT_DIRECTORY}/.deep-integrity.XXXXXX"
    )"; then
        report_critical "Unable to create temporary verification receipt"
        return 1
    fi

    if ! {
        printf 'verification_status=HEALTHY\n'
        printf 'verified_at_utc=%s\n' "$(timestamp)"
        printf 'location=%s\n' "$location_name"
        printf 'archive_name=%s\n' "$archive_name"
        printf 'archive_path=%s\n' "$archive_path"
        printf 'archive_size_bytes=%s\n' "$archive_bytes"
        printf 'sha256=%s\n' "$expected_sha"
        printf 'sha256_check=passed\n'
        printf 'zstd_test=passed\n'
    } >"$temporary_receipt"
    then
        report_critical "Unable to write verification receipt"
        /bin/rm -f "$temporary_receipt"
        return 1
    fi

    if ! /bin/chmod 600 "$temporary_receipt"; then
        report_critical "Unable to protect verification receipt"
        /bin/rm -f "$temporary_receipt"
        return 1
    fi

    if ! "$MV" -f "$temporary_receipt" "$receipt_path"; then
        report_critical "Unable to finalize verification receipt: $receipt_path"
        /bin/rm -f "$temporary_receipt"
        return 1
    fi

    report_ok "Verification receipt recorded: $receipt_path"
    return 0
}

verify_archive() {
    archive_path="$1"
    location_name="$2"
    comparison_sha="${3:-}"

    archive_name="${archive_path##*/}"
    checksum_path="${archive_path}.sha256"
    manifest_path="${archive_path%.tar.zst}.manifest.txt"

    if [[ ! -f "$archive_path" ]]; then
        report_critical "Archive does not exist: $archive_path"
        return
    fi

    if [[ ! -f "$checksum_path" ]]; then
        report_critical "Archive has no checksum file: $archive_path"
        return
    fi

    if [[ ! -f "$manifest_path" ]]; then
        report_critical "Archive has no manifest file: $archive_path"
        return
    fi

    expected_sha="$(read_expected_sha "$checksum_path")"

    if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
        report_critical "Checksum file has an invalid SHA-256 value: $checksum_path"
        return
    fi

    if [[ -n "$comparison_sha" && "$expected_sha" != "$comparison_sha" ]]; then
        report_critical "Recorded checksum differs from the trusted local checksum: $archive_path"
        return
    fi

    archive_bytes="$("$STAT" -f '%z' "$archive_path")"

    if [[ ! "$archive_bytes" =~ ^[1-9][0-9]*$ ]]; then
        report_critical "Archive is empty or has an invalid size: $archive_path"
        return
    fi

    archive_gib="$(
        "$AWK" -v bytes="$archive_bytes" \
            'BEGIN { printf "%.2f", bytes / 1073741824 }'
    )"

    planned_count=$((planned_count + 1))

    if [[ "$DRY_RUN" == "true" ]]; then
        report_info "Would deeply verify ${location_name} archive: name=${archive_name} size=${archive_gib}GiB"
        return
    fi

    report_info "Calculating SHA-256: location=${location_name} name=${archive_name} size=${archive_gib}GiB"

    if ! actual_sha="$(
        "$SHASUM" -a 256 "$archive_path" |
            "$AWK" 'NR == 1 { print $1; exit }'
    )"; then
        report_critical "Unable to calculate SHA-256: $archive_path"
        return
    fi

    if [[ "$actual_sha" != "$expected_sha" ]]; then
        report_critical "SHA-256 mismatch: $archive_path"
        return
    fi

    report_ok "SHA-256 verified: location=${location_name} name=${archive_name}"

    report_info "Testing Zstandard stream: location=${location_name} name=${archive_name}"

    if ! "$ZSTD" --test "$archive_path" >/dev/null 2>&1; then
        report_critical "Zstandard integrity test failed: $archive_path"
        return
    fi

    report_ok "Zstandard stream verified: location=${location_name} name=${archive_name}"

    verified_count=$((verified_count + 1))

    write_receipt \
        "$archive_path" \
        "$location_name" \
        "$expected_sha" \
        "$archive_bytes"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local-directory)
            require_value "$1" "$#"
            LOCAL_DIRECTORY="$2"
            shift 2
            ;;
        --external-directory)
            require_value "$1" "$#"
            EXTERNAL_DIRECTORY="$2"
            shift 2
            ;;
        --receipt-directory)
            require_value "$1" "$#"
            RECEIPT_DIRECTORY="$2"
            shift 2
            ;;
        --newest-only)
            NEWEST_ONLY=true
            shift
            ;;
        --require-external)
            REQUIRE_EXTERNAL=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

for executable in \
    "$AWK" \
    "$DATE" \
    "$MKDIR" \
    "$MKTEMP" \
    "$MV" \
    "$SHASUM" \
    "$SORT" \
    "$STAT" \
    "$ZSTD"
do
    require_executable "$executable"
done

if [[ ! -d "$LOCAL_DIRECTORY" ]]; then
    report_critical "Local backup directory does not exist: $LOCAL_DIRECTORY"
    print_summary_and_exit
fi

if [[ ! -r "$LOCAL_DIRECTORY" ]]; then
    report_critical "Local backup directory is not readable: $LOCAL_DIRECTORY"
    print_summary_and_exit
fi

report_ok "Local backup directory is readable: $LOCAL_DIRECTORY"

shopt -s nullglob

for partial_path in \
    "$LOCAL_DIRECTORY"/bitcoin-node-pruned-*.partial
do
    report_critical "Incomplete artifact found: $partial_path"
done

for checksum_path in \
    "$LOCAL_DIRECTORY"/bitcoin-node-pruned-*.tar.zst.sha256
do
    related_archive="${checksum_path%.sha256}"

    if [[ ! -f "$related_archive" ]]; then
        report_critical "Checksum has no matching archive: $checksum_path"
    fi
done

for manifest_path in \
    "$LOCAL_DIRECTORY"/bitcoin-node-pruned-*.manifest.txt
do
    related_archive="${manifest_path%.manifest.txt}.tar.zst"

    if [[ ! -f "$related_archive" ]]; then
        report_critical "Manifest has no matching archive: $manifest_path"
    fi
done

inventory_file="$("$MKTEMP" "${TMPDIR:-/tmp}/bitcoin-deep-audit.XXXXXX")"

# Invoked indirectly by trap.
# shellcheck disable=SC2329

cleanup() {
    /bin/rm -f "$inventory_file"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

for archive_path in \
    "$LOCAL_DIRECTORY"/bitcoin-node-pruned-*.tar.zst
do
    archive_name="${archive_path##*/}"

    if [[ "$archive_name" =~ ^bitcoin-node-pruned-([0-9]+)-([0-9]{4}-[0-9]{2}-[0-9]{2})\.tar\.zst$ ]]; then
        block_height="${BASH_REMATCH[1]}"

        printf '%020d\t%s\n' \
            "$block_height" \
            "$archive_path" \
            >>"$inventory_file"
    else
        report_critical "Unexpected archive name: $archive_path"
    fi
done

"$SORT" -r "$inventory_file" -o "$inventory_file"

local_archives=()
local_archive_count=0

while IFS=$'\t' read -r _ archive_path; do
    if [[ -n "$archive_path" ]]; then
        local_archives+=("$archive_path")
        local_archive_count=$((local_archive_count + 1))
    fi
done <"$inventory_file"

if (( local_archive_count == 0 )); then
    report_critical "No local backup archives were found"
    print_summary_and_exit
fi

newest_local_archive="${local_archives[0]}"
newest_local_checksum="${newest_local_archive}.sha256"

if [[ -f "$newest_local_checksum" ]]; then
    newest_local_sha="$(read_expected_sha "$newest_local_checksum")"
else
    newest_local_sha=""
fi

if [[ "$NEWEST_ONLY" == "true" ]]; then
    report_info "Local verification scope: newest backup only"
    verify_archive "$newest_local_archive" "local"
else
    report_info "Local verification scope: all retained backups"

    for archive_path in "${local_archives[@]}"; do
        verify_archive "$archive_path" "local"
    done
fi

external_parent="${EXTERNAL_DIRECTORY%/*}"

if [[ -d "$EXTERNAL_DIRECTORY" ]]; then
    report_ok "External backup directory is mounted: $EXTERNAL_DIRECTORY"

    external_archive="${EXTERNAL_DIRECTORY}/${newest_local_archive##*/}"
    external_checksum="${external_archive}.sha256"
    external_manifest="${external_archive%.tar.zst}.manifest.txt"
    external_complete=true

    for external_path in \
        "$external_archive" \
        "$external_checksum" \
        "$external_manifest"
    do
        if [[ ! -f "$external_path" ]]; then
            report_warning "Newest local backup artifact is missing externally: $external_path"
            external_complete=false
        fi
    done

    if [[ "$external_complete" == "true" ]]; then
        verify_archive \
            "$external_archive" \
            "external" \
            "$newest_local_sha"
    fi
elif [[ -d "$external_parent" ]]; then
    report_warning "External volume is mounted but backup directory is missing: $EXTERNAL_DIRECTORY"
elif [[ "$REQUIRE_EXTERNAL" == "true" ]]; then
    report_warning "Required external backup volume is not mounted: $external_parent"
else
    report_info "External backup volume is not mounted; optional deep verification skipped"
fi

print_summary_and_exit
