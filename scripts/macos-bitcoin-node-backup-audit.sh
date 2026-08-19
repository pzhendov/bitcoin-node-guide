#!/usr/bin/env bash

# Read-only freshness and completeness audit for Bitcoin backup sets on macOS.
#
# Exit codes:
#   0 = HEALTHY
#   1 = WARNING
#   2 = CRITICAL
#
# This script never creates, modifies, hashes, transfers, renames or deletes
# backup files.
#
# The dollar expressions in AWK programs belong to AWK, not Bash.
# shellcheck disable=SC2016

set -u
set -o pipefail

PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
umask 077

AWK="${AWK:-/usr/bin/awk}"
DATE="${DATE:-/bin/date}"
DF="${DF:-/bin/df}"
STAT="${STAT:-/usr/bin/stat}"

LOCAL_DIRECTORY="${HOME}/bitcoin-node-backups"
EXTERNAL_DIRECTORY="/Volumes/Backup_8TB/bitcoin-node-backups"

STALE_DAYS=7
CRITICAL_DAYS=14
MINIMUM_BACKUPS=2
WARNING_FREE_GIB=100
CRITICAL_FREE_GIB=50
REQUIRE_EXTERNAL=false

warnings=0
critical=0

timestamp() {
    "$DATE" -u '+%Y-%m-%dT%H:%M:%SZ'
}

report_ok() {
    printf '%s [BACKUP-AUDIT] [OK] %s\n' "$(timestamp)" "$1"
}

report_info() {
    printf '%s [BACKUP-AUDIT] [INFO] %s\n' "$(timestamp)" "$1"
}

report_warning() {
    warnings=$((warnings + 1))
    printf '%s [BACKUP-AUDIT] [WARNING] %s\n' "$(timestamp)" "$1"
}

report_critical() {
    critical=$((critical + 1))
    printf '%s [BACKUP-AUDIT] [CRITICAL] %s\n' "$(timestamp)" "$1"
}

usage() {
    cat <<'EOF'
Usage:
  macos-bitcoin-node-backup-audit [options]

Options:
  --local-directory PATH      Local backup directory
  --external-directory PATH   External backup directory
  --stale-days DAYS           Warning age for newest backup; default 7
  --critical-days DAYS        Critical age for newest backup; default 14
  --minimum-backups COUNT     Required complete local sets; default 2
  --warning-free-gib GIB      Low-space warning threshold; default 100
  --critical-free-gib GIB     Low-space critical threshold; default 50
  --require-external          Warn when the external volume is not mounted
  --help                      Show this help

This is a metadata-only audit. It does not calculate archive checksums.
EOF
}

require_executable() {
    if [[ ! -x "$1" ]]; then
        report_critical "Required executable not found: $1"
        print_summary_and_exit
    fi
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

validate_non_negative_integer() {
    value_name="$1"
    value="$2"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        printf '%s must be a non-negative integer: %s\n' \
            "$value_name" \
            "$value" \
            >&2
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

    printf '%s [BACKUP-AUDIT] [SUMMARY] status=%s warnings=%d critical=%d\n' \
        "$(timestamp)" \
        "$final_status" \
        "$warnings" \
        "$critical"

    exit "$exit_code"
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
        --stale-days)
            require_value "$1" "$#"
            STALE_DAYS="$2"
            shift 2
            ;;
        --critical-days)
            require_value "$1" "$#"
            CRITICAL_DAYS="$2"
            shift 2
            ;;
        --minimum-backups)
            require_value "$1" "$#"
            MINIMUM_BACKUPS="$2"
            shift 2
            ;;
        --warning-free-gib)
            require_value "$1" "$#"
            WARNING_FREE_GIB="$2"
            shift 2
            ;;
        --critical-free-gib)
            require_value "$1" "$#"
            CRITICAL_FREE_GIB="$2"
            shift 2
            ;;
        --require-external)
            REQUIRE_EXTERNAL=true
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

validate_non_negative_integer "STALE_DAYS" "$STALE_DAYS"
validate_non_negative_integer "CRITICAL_DAYS" "$CRITICAL_DAYS"
validate_non_negative_integer "MINIMUM_BACKUPS" "$MINIMUM_BACKUPS"
validate_non_negative_integer "WARNING_FREE_GIB" "$WARNING_FREE_GIB"
validate_non_negative_integer "CRITICAL_FREE_GIB" "$CRITICAL_FREE_GIB"

if (( MINIMUM_BACKUPS < 2 )); then
    printf 'MINIMUM_BACKUPS must be at least 2.\n' >&2
    exit 2
fi

if (( CRITICAL_DAYS <= STALE_DAYS )); then
    printf 'CRITICAL_DAYS must be greater than STALE_DAYS.\n' >&2
    exit 2
fi

if (( CRITICAL_FREE_GIB >= WARNING_FREE_GIB )); then
    printf 'CRITICAL_FREE_GIB must be lower than WARNING_FREE_GIB.\n' >&2
    exit 2
fi

for executable in \
    "$AWK" \
    "$DATE" \
    "$DF" \
    "$STAT"
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

archive_paths=(
    "$LOCAL_DIRECTORY"/bitcoin-node-pruned-*.tar.zst
)

checksum_paths=(
    "$LOCAL_DIRECTORY"/bitcoin-node-pruned-*.tar.zst.sha256
)

manifest_paths=(
    "$LOCAL_DIRECTORY"/bitcoin-node-pruned-*.manifest.txt
)

partial_paths=(
    "$LOCAL_DIRECTORY"/bitcoin-node-pruned-*.partial
)

if (( ${#partial_paths[@]} > 0 )); then
    for partial_path in "${partial_paths[@]}"; do
        report_critical "Incomplete artifact found: $partial_path"
    done
fi

for checksum_path in "${checksum_paths[@]}"; do
    related_archive="${checksum_path%.sha256}"

    if [[ ! -f "$related_archive" ]]; then
        report_critical "Checksum has no matching archive: $checksum_path"
    fi
done

for manifest_path in "${manifest_paths[@]}"; do
    related_archive="${manifest_path%.manifest.txt}.tar.zst"

    if [[ ! -f "$related_archive" ]]; then
        report_critical "Manifest has no matching archive: $manifest_path"
    fi
done

complete_count=0
newest_block=-1
newest_date=""
newest_epoch=0
newest_archive=""
newest_checksum=""
newest_manifest=""
newest_expected_sha=""

for archive_path in "${archive_paths[@]}"; do
    archive_name="${archive_path##*/}"

    if [[ ! "$archive_name" =~ ^bitcoin-node-pruned-([0-9]+)-([0-9]{4}-[0-9]{2}-[0-9]{2})\.tar\.zst$ ]]; then
        report_critical "Unexpected archive name: $archive_path"
        continue
    fi

    block_height="${BASH_REMATCH[1]}"
    backup_date="${BASH_REMATCH[2]}"
    checksum_path="${archive_path}.sha256"
    manifest_path="${archive_path%.tar.zst}.manifest.txt"

    if [[ ! -f "$checksum_path" ]]; then
        report_critical "Archive has no checksum file: $archive_path"
        continue
    fi

    if [[ ! -f "$manifest_path" ]]; then
        report_critical "Archive has no manifest file: $archive_path"
        continue
    fi

    expected_sha="$(
        "$AWK" 'NR == 1 { print $1; exit }' "$checksum_path"
    )"

    if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ]]; then
        report_critical "Checksum file has an invalid SHA-256 value: $checksum_path"
        continue
    fi

    archive_bytes="$("$STAT" -f '%z' "$archive_path")"

    if [[ ! "$archive_bytes" =~ ^[1-9][0-9]*$ ]]; then
        report_critical "Archive is empty or has an invalid size: $archive_path"
        continue
    fi

    if ! backup_epoch="$(
        "$DATE" -j -u -f '%Y-%m-%d' "$backup_date" '+%s' 2>/dev/null
    )"; then
        report_critical "Archive contains an invalid backup date: $archive_path"
        continue
    fi

    for protected_path in \
        "$archive_path" \
        "$checksum_path" \
        "$manifest_path"
    do
        file_permissions="$("$STAT" -f '%Lp' "$protected_path")"

        if [[ "$file_permissions" != "600" ]]; then
            report_warning "Backup artifact permissions are ${file_permissions}, expected 600: $protected_path"
        fi
    done

    complete_count=$((complete_count + 1))

    archive_gib="$(
        "$AWK" -v bytes="$archive_bytes" \
            'BEGIN { printf "%.2f", bytes / 1073741824 }'
    )"

    report_ok "Complete backup: block=$block_height date=$backup_date size=${archive_gib}GiB"

    if (( block_height > newest_block )); then
        newest_block="$block_height"
        newest_date="$backup_date"
        newest_epoch="$backup_epoch"
        newest_archive="$archive_path"
        newest_checksum="$checksum_path"
        newest_manifest="$manifest_path"
        newest_expected_sha="$expected_sha"
    fi
done

if (( complete_count == 0 )); then
    report_critical "No complete local backup sets were found"
else
    report_ok "Complete local backup sets: $complete_count"
fi

if (( complete_count < MINIMUM_BACKUPS )); then
    report_warning "Only $complete_count complete local backup set(s); minimum is $MINIMUM_BACKUPS"
fi

if (( complete_count > 0 )); then
    current_epoch="$("$DATE" -u '+%s')"

    if (( newest_epoch > current_epoch )); then
        report_critical "Newest backup date is in the future: $newest_date"
    else
        newest_age_days=$(((current_epoch - newest_epoch) / 86400))

        if (( newest_age_days >= CRITICAL_DAYS )); then
            report_critical "Newest backup is critically stale: block=$newest_block age=${newest_age_days}d"
        elif (( newest_age_days >= STALE_DAYS )); then
            report_warning "Newest backup is stale: block=$newest_block age=${newest_age_days}d"
        else
            report_ok "Newest backup is fresh: block=$newest_block age=${newest_age_days}d"
        fi
    fi
fi

local_free_kib="$(
    "$DF" -Pk "$LOCAL_DIRECTORY" |
        "$AWK" 'NR == 2 { print $4 }'
)"

if [[ ! "$local_free_kib" =~ ^[0-9]+$ ]]; then
    report_critical "Unable to determine local free disk space"
else
    local_free_gib=$((local_free_kib / 1048576))

    if (( local_free_gib < CRITICAL_FREE_GIB )); then
        report_critical "Local free space is critically low: ${local_free_gib}GiB"
    elif (( local_free_gib < WARNING_FREE_GIB )); then
        report_warning "Local free space is low: ${local_free_gib}GiB"
    else
        report_ok "Local free space is sufficient: ${local_free_gib}GiB"
    fi
fi

external_parent="${EXTERNAL_DIRECTORY%/*}"

if [[ -d "$EXTERNAL_DIRECTORY" ]]; then
    report_ok "External backup directory is mounted: $EXTERNAL_DIRECTORY"

    if (( complete_count > 0 )); then
        external_archive="${EXTERNAL_DIRECTORY}/${newest_archive##*/}"
        external_checksum="${EXTERNAL_DIRECTORY}/${newest_checksum##*/}"
        external_manifest="${EXTERNAL_DIRECTORY}/${newest_manifest##*/}"

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
            external_archive_bytes="$("$STAT" -f '%z' "$external_archive")"
            local_archive_bytes="$("$STAT" -f '%z' "$newest_archive")"

            external_expected_sha="$(
                "$AWK" 'NR == 1 { print $1; exit }' "$external_checksum"
            )"

            if [[ "$external_archive_bytes" != "$local_archive_bytes" ]]; then
                report_critical "External archive size differs from newest local archive"
            elif [[ "$external_expected_sha" != "$newest_expected_sha" ]]; then
                report_critical "External checksum record differs from newest local checksum"
            else
                report_ok "Newest local backup has a matching external copy: block=$newest_block"
            fi
        fi
    fi
elif [[ -d "$external_parent" ]]; then
    report_warning "External volume is mounted but backup directory is missing: $EXTERNAL_DIRECTORY"
elif [[ "$REQUIRE_EXTERNAL" == "true" ]]; then
    report_warning "Required external backup volume is not mounted: $external_parent"
else
    report_info "External backup volume is not mounted; optional check skipped"
fi

print_summary_and_exit
