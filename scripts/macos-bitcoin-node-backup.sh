#!/usr/bin/env bash

# Safely coordinate a cold pruned-blockchain backup from macOS.
#
# Exit codes:
#   0 = preflight passed or backup completed
#   1 = invalid command usage
#   2 = preflight, backup, verification, or recovery failed

# The dollar expressions in AWK programs belong to AWK, not Bash.
# shellcheck disable=SC2016,SC2317,SC2329

set -u
set -o pipefail

PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin
umask 077

MULTIPASS="${MULTIPASS:-/usr/local/bin/multipass}"
AWK="${AWK:-/usr/bin/awk}"
DF="${DF:-/bin/df}"

VM_NAME="bitcoin-node"
DESTINATION="${HOME}/bitcoin-node-backups"
MODE=""
EXECUTION_CONFIRMED=false

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
    printf '%s [BACKUP] %s\n' "$(timestamp)" "$1"
}

fail() {
    log "ERROR: $1" >&2
    exit 2
}

usage() {
    cat <<'EOF'
Usage:
  macos-bitcoin-node-backup --dry-run [options]
  macos-bitcoin-node-backup --execute [options]

Options:
  --dry-run              Perform read-only preflight checks
  --execute              Run the backup after all safety checks pass
  --confirm-cold-backup  Confirm the intentional service interruption

Execution stops Bitcoin Core temporarily, creates and verifies the archive,
transfers it to macOS, and restores production services.
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
        --confirm-cold-backup)
            EXECUTION_CONFIRMED=true
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
        --vm)
            if [[ $# -lt 2 ]]; then
                printf 'Missing value for --vm\n' >&2
                usage >&2
                exit 1
            fi

            VM_NAME="$2"
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

if [[ "$MODE" == "--execute" ]] && [[ "$EXECUTION_CONFIRMED" != "true" ]]; then
    printf 'Execution requires --confirm-cold-backup.\n' >&2
    exit 1
fi

require_executable "$MULTIPASS"
require_executable "$AWK"
require_executable "$DF"

for host_executable in \
    /usr/bin/caffeinate \
    /usr/bin/grep \
    /usr/bin/head \
    /usr/bin/sed \
    /usr/bin/shasum \
    /usr/bin/tail \
    /usr/bin/tee \
    /usr/bin/wc
do
    require_executable "$host_executable"
done

if [[ ! -d "$DESTINATION" ]]; then
    fail "Destination directory does not exist: $DESTINATION"
fi

if [[ ! -w "$DESTINATION" ]]; then
    fail "Destination directory is not writable: $DESTINATION"
fi

log "Destination directory is available: $DESTINATION"

if ! vm_info="$("$MULTIPASS" info "$VM_NAME" 2>/dev/null)"; then
    fail "Multipass VM does not exist or cannot be inspected: $VM_NAME"
fi

vm_state="$(
    printf '%s\n' "$vm_info" |
        "$AWK" -F ': *' '$1 == "State" { print $2; exit }'
)"

if [[ "$vm_state" != "Running" ]]; then
    fail "Multipass VM is not running: $VM_NAME state=$vm_state"
fi

log "Multipass VM is running: $VM_NAME"

if ! guest_missing="$(
    "$MULTIPASS" exec -n "$VM_NAME" -- sh -c '
        for tool in bitcoin-cli jq systemctl chronyc tar zstd sha256sum du df; do
            if ! command -v "$tool" >/dev/null 2>&1; then
                printf "%s\n" "$tool"
            fi
        done
    '
)"; then
    fail "Unable to inspect required tools inside VM: $VM_NAME"
fi

if [[ -n "$guest_missing" ]]; then
    fail "Required VM tools are missing: $guest_missing"
fi

log "All required VM tools are available"

for unit in \
    bitcoind.service \
    bitcoin-node-health.timer \
    bitcoin-node-clock-recovery.timer
do
    if ! "$MULTIPASS" exec -n "$VM_NAME" -- \
        systemctl is-active --quiet "$unit"
    then
        fail "Required VM unit is not active: $unit"
    fi

    log "VM unit is active: $unit"
done

if ! chain_summary="$(
    "$MULTIPASS" exec -n "$VM_NAME" -- sh -c '
        bitcoin-cli getblockchaininfo |
            jq -r "[
                .blocks,
                .headers,
                .verificationprogress,
                .initialblockdownload,
                .pruned,
                (.warnings | length),
                .bestblockhash,
                .pruneheight,
                .size_on_disk
            ] | @tsv"
    '
)"; then
    fail "Unable to read Bitcoin blockchain information"
fi

IFS=$'\t' read -r \
    blocks \
    headers \
    verification_progress \
    initial_block_download \
    pruned \
    warning_count \
    best_block_hash \
    prune_height \
    size_on_disk_bytes \
    <<< "$chain_summary"

if [[ ! "$best_block_hash" =~ ^[0-9a-f]{64}$ ]]; then
    fail "Bitcoin returned an invalid best block hash"
fi

if [[ ! "$prune_height" =~ ^[0-9]+$ ]]; then
    fail "Bitcoin returned an invalid prune height: $prune_height"
fi

if [[ ! "$size_on_disk_bytes" =~ ^[0-9]+$ ]]; then
    fail "Bitcoin returned an invalid on-disk size: $size_on_disk_bytes"
fi

if [[ ! "$blocks" =~ ^[0-9]+$ ]]; then
    fail "Bitcoin returned an invalid block height: $blocks"
fi

if [[ ! "$headers" =~ ^[0-9]+$ ]]; then
    fail "Bitcoin returned an invalid header height: $headers"
fi

if [[ "$blocks" != "$headers" ]]; then
    fail "Blockchain is not current: blocks=$blocks headers=$headers"
fi

if [[ "$initial_block_download" != "false" ]]; then
    fail "Initial block download is not complete"
fi

if [[ "$pruned" != "true" ]]; then
    fail "Bitcoin node is not operating in pruned mode"
fi

if [[ "$warning_count" != "0" ]]; then
    fail "Bitcoin Core reports warnings: count=$warning_count"
fi

log "Blockchain is healthy: blocks=$blocks headers=$headers progress=$verification_progress"

if ! network_summary="$(
    "$MULTIPASS" exec -n "$VM_NAME" -- sh -c '
        bitcoin-cli getnetworkinfo |
            jq -r "[
                .networkactive,
                .connections,
                .timeoffset
            ] | @tsv"
    '
)"; then
    fail "Unable to read Bitcoin network information"
fi

IFS=$'\t' read -r \
    network_active \
    connections \
    time_offset \
    <<< "$network_summary"

if [[ "$network_active" != "true" ]]; then
    fail "Bitcoin network activity is disabled"
fi

if [[ ! "$connections" =~ ^[0-9]+$ ]] || (( connections < 1 )); then
    fail "Bitcoin node has no peer connections"
fi

if [[ ! "$time_offset" =~ ^-?[0-9]+$ ]]; then
    fail "Bitcoin returned an invalid time offset: $time_offset"
fi

absolute_time_offset="${time_offset#-}"

if (( absolute_time_offset > 60 )); then
    fail "Bitcoin time offset is unsafe: ${time_offset}s"
fi

log "Bitcoin network is healthy: peers=$connections time_offset=${time_offset}s"

if ! chrony_tracking="$(
    "$MULTIPASS" exec -n "$VM_NAME" -- chronyc -N tracking
)"; then
    fail "Unable to read Chrony tracking information"
fi

leap_status="$(
    printf '%s\n' "$chrony_tracking" |
        "$AWK" -F ':' '
            /Leap status/ {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                print $2
                exit
            }
        '
)"

if [[ "$leap_status" != "Normal" ]]; then
    fail "Chrony is not synchronized: leap_status=$leap_status"
fi

log "Chrony is synchronized: leap_status=$leap_status"

if ! source_usage="$(
    "$MULTIPASS" exec -n "$VM_NAME" -- sudo du -sk \
        /home/ubuntu/.bitcoin/blocks \
        /home/ubuntu/.bitcoin/chainstate
)"; then
    fail "Unable to calculate blockchain source size"
fi

source_kib="$(
    printf '%s\n' "$source_usage" |
        "$AWK" '{ total += $1 } END { print total }'
)"

if [[ ! "$source_kib" =~ ^[1-9][0-9]*$ ]]; then
    fail "Invalid blockchain source size: $source_kib"
fi

if ! guest_disk="$(
    "$MULTIPASS" exec -n "$VM_NAME" -- df -Pk /home/ubuntu/.bitcoin
)"; then
    fail "Unable to inspect free VM disk space"
fi

guest_free_kib="$(
    printf '%s\n' "$guest_disk" |
        "$AWK" 'NR == 2 { print $4 }'
)"

destination_free_kib="$(
    "$DF" -Pk "$DESTINATION" |
        "$AWK" 'NR == 2 { print $4 }'
)"

if [[ ! "$guest_free_kib" =~ ^[0-9]+$ ]]; then
    fail "Invalid free VM disk-space value: $guest_free_kib"
fi

if [[ ! "$destination_free_kib" =~ ^[0-9]+$ ]]; then
    fail "Invalid destination disk-space value: $destination_free_kib"
fi

required_guest_kib=$((source_kib + 5 * 1024 * 1024))
required_destination_kib=$source_kib

if (( guest_free_kib < required_guest_kib )); then
    fail "Insufficient VM disk space for a safe temporary archive"
fi

if (( destination_free_kib < required_destination_kib )); then
    fail "Insufficient destination disk space for the backup"
fi

source_gib="$(
    "$AWK" -v kib="$source_kib" \
        'BEGIN { printf "%.2f", kib / 1048576 }'
)"

guest_free_gib="$(
    "$AWK" -v kib="$guest_free_kib" \
        'BEGIN { printf "%.2f", kib / 1048576 }'
)"

destination_free_gib="$(
    "$AWK" -v kib="$destination_free_kib" \
        'BEGIN { printf "%.2f", kib / 1048576 }'
)"

log "Blockchain source size: ${source_gib}GiB"
log "VM free space is sufficient: ${guest_free_gib}GiB"
log "Destination free space is sufficient: ${destination_free_gib}GiB"

if [[ "$MODE" == "--dry-run" ]]; then
    log "Read-only preflight stage passed"
    log "No services were stopped and no backup files were created"
    exit 0
fi

script_directory="$(
    cd "$(/usr/bin/dirname "${BASH_SOURCE[0]}")" &&
        pwd
)"

guest_helper_source="${script_directory}/bitcoin-node-backup-create.sh"
guest_helper_installed="/usr/local/bin/bitcoin-node-backup-create"
guest_upload_path=""
host_partial_path=""
host_final_path=""
host_checksum_path=""
host_manifest_path=""
host_checksum_partial_path=""
host_manifest_partial_path=""
run_log_path=""
macos_monitor_was_loaded=false
backup_finalized=false

host_lock_directory="${TMPDIR:-/tmp}/bitcoin-node-backup-${UID}.lock"
launch_agent_domain="gui/$(/usr/bin/id -u)"
launch_agent_label="com.pzhendov.bitcoin-node-health-notify"
launch_agent_service="${launch_agent_domain}/${launch_agent_label}"
launch_agent_plist="${HOME}/Library/LaunchAgents/${launch_agent_label}.plist"

host_preparation_cleanup() {
    cleanup_status=$?

    trap - EXIT HUP INT TERM

    if [[ -n "$guest_upload_path" ]]; then
        "$MULTIPASS" exec -n "$VM_NAME" -- \
            rm -f -- "$guest_upload_path" \
            >/dev/null 2>&1 || true
    fi

    if (( cleanup_status != 0 )) && [[ "$backup_finalized" != "true" ]]; then
        for incomplete_path in \
            "$host_partial_path" \
            "$host_checksum_partial_path" \
            "$host_manifest_partial_path" \
            "$host_final_path" \
            "$host_checksum_path" \
            "$host_manifest_path"
        do
            if [[ -n "$incomplete_path" ]] && [[ -f "$incomplete_path" ]]; then
                if /bin/rm -f -- "$incomplete_path"; then
                    log "Removed incomplete Mac-side artifact: $incomplete_path"
                else
                    log "ERROR: Unable to remove incomplete Mac-side artifact: $incomplete_path" >&2
                    cleanup_status=2
                fi
            fi
        done
    fi

    if [[ -n "$run_log_path" ]] && [[ -f "$run_log_path" ]]; then
        /bin/rm -f -- "$run_log_path" || cleanup_status=2
    fi

    if [[ "$macos_monitor_was_loaded" == "true" ]]; then
        log "Restoring macOS notification monitor"

        if ! /bin/launchctl bootstrap \
            "$launch_agent_domain" \
            "$launch_agent_plist"
        then
            log "ERROR: Unable to bootstrap macOS notification monitor" >&2
            cleanup_status=2
        fi

        if ! /bin/launchctl enable "$launch_agent_service"; then
            log "ERROR: Unable to enable macOS notification monitor" >&2
            cleanup_status=2
        fi

        if ! /bin/launchctl kickstart -k "$launch_agent_service"; then
            log "ERROR: Unable to start macOS notification monitor" >&2
            cleanup_status=2
        fi
    fi

    /bin/rm -f -- "${host_lock_directory}/pid" \
        >/dev/null 2>&1 || true

    /bin/rmdir -- "$host_lock_directory" \
        >/dev/null 2>&1 || true

    exit "$cleanup_status"
}

if [[ ! -f "$guest_helper_source" ]]; then
    fail "VM-side backup helper does not exist: $guest_helper_source"
fi

if [[ ! -x "$guest_helper_source" ]]; then
    fail "VM-side backup helper is not executable: $guest_helper_source"
fi

if ! /bin/mkdir -- "$host_lock_directory"; then
    fail "Another host-side backup may already be running: $host_lock_directory"
fi

printf '%s\n' "$$" >"${host_lock_directory}/pid"

trap host_preparation_cleanup EXIT
trap 'exit 2' HUP INT TERM

archive_date="$(/bin/date -u '+%Y-%m-%d')"
archive_stem="bitcoin-node-pruned-${blocks}-${archive_date}"
guest_archive_name="${archive_stem}.tar.zst.partial"

host_partial_path="${DESTINATION}/${archive_stem}.tar.zst.partial"
host_final_path="${DESTINATION}/${archive_stem}.tar.zst"
host_checksum_path="${DESTINATION}/${archive_stem}.tar.zst.sha256"
host_manifest_path="${DESTINATION}/${archive_stem}.manifest.txt"
host_checksum_partial_path="${host_checksum_path}.partial"
host_manifest_partial_path="${host_manifest_path}.partial"

for candidate_path in \
    "$host_partial_path" \
    "$host_final_path" \
    "$host_checksum_path" \
    "$host_manifest_path" \
    "$host_checksum_partial_path" \
    "$host_manifest_partial_path"
do
    if [[ -e "$candidate_path" ]]; then
        fail "Refusing to overwrite an existing backup file: $candidate_path"
    fi
done

guest_upload_path="/home/ubuntu/.bitcoin-node-backup-create-${$}.upload"

log "Transferring VM-side backup helper"

if ! "$MULTIPASS" transfer \
    "$guest_helper_source" \
    "${VM_NAME}:${guest_upload_path}"
then
    fail "Unable to transfer VM-side backup helper"
fi

if ! "$MULTIPASS" exec -n "$VM_NAME" -- \
    bash -n "$guest_upload_path"
then
    fail "Transferred VM-side helper failed Bash syntax validation"
fi

local_helper_sha="$(
    /usr/bin/shasum -a 256 "$guest_helper_source" |
        "$AWK" '{ print $1 }'
)"

guest_helper_sha="$(
    "$MULTIPASS" exec -n "$VM_NAME" -- \
        sha256sum "$guest_upload_path" |
        "$AWK" '{ print $1 }'
)"

if [[ "$local_helper_sha" != "$guest_helper_sha" ]]; then
    fail "VM-side helper checksum does not match the repository copy"
fi

log "VM-side helper checksum verified: $local_helper_sha"

if ! "$MULTIPASS" exec -n "$VM_NAME" -- sudo install \
    -o root \
    -g root \
    -m 0755 \
    "$guest_upload_path" \
    "$guest_helper_installed"
then
    fail "Unable to install VM-side backup helper"
fi

if ! "$MULTIPASS" exec -n "$VM_NAME" -- \
    rm -f -- "$guest_upload_path"
then
    fail "Unable to remove transferred helper upload"
fi

guest_upload_path=""

if ! "$MULTIPASS" exec -n "$VM_NAME" -- sudo \
    "$guest_helper_installed" \
    --dry-run \
    --archive-name "$guest_archive_name"
then
    fail "Installed VM-side helper failed its dry-run"
fi

log "Host preparation and installed-helper dry-run passed"

if /bin/launchctl print "$launch_agent_service" \
    >/dev/null 2>&1
then
    log "Pausing macOS notification monitor"

    if ! /bin/launchctl bootout "$launch_agent_service"; then
        fail "Unable to pause macOS notification monitor"
    fi

    macos_monitor_was_loaded=true
else
    log "macOS notification monitor is not loaded; continuing"
fi

log "Planned archive: ${archive_stem}.tar.zst"

run_log_path="${TMPDIR:-/tmp}/bitcoin-node-backup-${UID}-${$}.log"

log "Creating and verifying the cold archive inside the VM"

if ! /usr/bin/caffeinate -i \
    "$MULTIPASS" exec -n "$VM_NAME" -- sudo \
        "$guest_helper_installed" \
        --execute \
        --archive-name "$guest_archive_name" |
    /usr/bin/tee "$run_log_path"
then
    fail "VM-side archive creation failed"
fi

backup_result="$({
    /usr/bin/grep '^BACKUP_RESULT ' "$run_log_path" || true
} | /usr/bin/tail -n 1)"

guest_archive_path="$({
    printf '%s\n' "$backup_result" |
        /usr/bin/sed -n \
            's/^BACKUP_RESULT archive_path=\([^ ]*\) sha256=[0-9a-f]\{64\}$/\1/p'
})"

guest_checksum="$({
    printf '%s\n' "$backup_result" |
        /usr/bin/sed -n \
            's/^BACKUP_RESULT archive_path=[^ ]* sha256=\([0-9a-f]\{64\}\)$/\1/p'
})"

expected_guest_archive_path="/home/ubuntu/${guest_archive_name}"

if [[ "$guest_archive_path" != "$expected_guest_archive_path" ]]; then
    fail "VM helper returned an unexpected archive path: $guest_archive_path"
fi

if [[ ! "$guest_checksum" =~ ^[0-9a-f]{64}$ ]]; then
    fail "VM helper returned an invalid SHA-256 checksum"
fi

log "VM archive verified: sha256=$guest_checksum"
log "Transferring verified archive to macOS"

if ! /usr/bin/caffeinate -i \
    "$MULTIPASS" transfer \
        "${VM_NAME}:${guest_archive_path}" \
        "$host_partial_path"
then
    fail "Unable to transfer the verified archive to macOS"
fi

if [[ ! -s "$host_partial_path" ]]; then
    fail "Transferred archive is missing or empty"
fi

host_checksum="$({
    /usr/bin/shasum -a 256 "$host_partial_path" |
        "$AWK" '{ print $1 }'
})"

if [[ "$host_checksum" != "$guest_checksum" ]]; then
    fail "Mac-side checksum does not match the VM-side checksum"
fi

archive_size_bytes="$({
    /usr/bin/wc -c <"$host_partial_path" |
        "$AWK" '{ print $1 }'
})"

if [[ ! "$archive_size_bytes" =~ ^[1-9][0-9]*$ ]]; then
    fail "Unable to determine the transferred archive size"
fi

log "Mac-side checksum verified: $host_checksum"

printf '%s  %s\n' \
    "$host_checksum" \
    "${host_final_path##*/}" \
    >"$host_checksum_partial_path" ||
    fail "Unable to create the checksum file"

created_utc="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"

if ! /usr/bin/tee "$host_manifest_partial_path" >/dev/null <<EOF
Bitcoin Node Pruned Blockchain Backup Manifest

Backup file:
${host_final_path##*/}

Checksum file:
${host_checksum_path##*/}

Created (UTC):
$created_utc

Compressed size:
$archive_size_bytes bytes

SHA-256:
$host_checksum

Source environment:
- Multipass VM: $VM_NAME
- Pruned Bitcoin mainnet node
- Wallet data excluded

Blockchain state:
- Blocks: $blocks
- Headers: $headers
- Best block hash: $best_block_hash
- Verification progress: $verification_progress
- Initial block download: $initial_block_download
- Pruned: $pruned
- Prune height: $prune_height
- Bitcoin size_on_disk: $size_on_disk_bytes bytes
- Peers at preflight: $connections
- Bitcoin time offset at preflight: ${time_offset}s
- Chrony leap status at preflight: $leap_status

Included:
- blocks/
- chainstate/

Explicitly excluded:
- wallets/
- wallet.dat
- private keys and seed phrases
- .cookie and bitcoin.conf
- RPC and Telegram credentials
- logs, peer data and mempool data
- systemd and Chrony configuration

Security classification:
This archive contains public Bitcoin blockchain validation data only. It is not a wallet backup and cannot recover private keys or funds.

Creation method:
Bitcoin Core was stopped cleanly inside the VM. The archive was created with tar and zstd, tested with zstd, transferred to macOS, and verified against the VM-side SHA-256 checksum.
EOF
then
    fail "Unable to create the backup manifest"
fi

if ! /bin/chmod 0600 \
    "$host_partial_path" \
    "$host_checksum_partial_path" \
    "$host_manifest_partial_path"
then
    fail "Unable to protect Mac-side backup artifacts"
fi

if ! /bin/mv "$host_partial_path" "$host_final_path"; then
    fail "Unable to finalize the backup archive"
fi

if ! /bin/mv "$host_checksum_partial_path" "$host_checksum_path"; then
    fail "Unable to finalize the checksum file"
fi

if ! /bin/mv "$host_manifest_partial_path" "$host_manifest_path"; then
    fail "Unable to finalize the backup manifest"
fi

backup_finalized=true

log "Removing the verified temporary archive from the VM"

if ! "$MULTIPASS" exec -n "$VM_NAME" -- sudo \
    rm -f -- "$guest_archive_path"
then
    fail "Backup completed, but the temporary VM archive could not be removed"
fi

for unit in \
    bitcoind.service \
    bitcoin-node-health.timer \
    bitcoin-node-clock-recovery.timer
do
    if ! "$MULTIPASS" exec -n "$VM_NAME" -- \
        systemctl is-active --quiet "$unit"
    then
        fail "Backup completed, but a required VM unit is not active: $unit"
    fi
done

log "Backup completed successfully"
log "Archive: $host_final_path"
log "Checksum: $host_checksum_path"
log "Manifest: $host_manifest_path"
exit 0
