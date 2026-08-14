#!/usr/bin/env bash

# Create and verify a cold pruned-blockchain archive inside the Bitcoin VM.
#
# Exit codes:
#   0 = dry-run passed or archive created and services restored
#   1 = invalid command usage
#   2 = backup or service recovery failed
#
# shellcheck disable=SC2016,SC2317,SC2329

set -u
set -o pipefail

PATH=/usr/local/bin:/usr/bin:/bin
umask 077

SYSTEMCTL="${SYSTEMCTL:-/usr/bin/systemctl}"
BITCOIN_CLI="${BITCOIN_CLI:-/usr/local/bin/bitcoin-cli}"
TAR="${TAR:-/usr/bin/tar}"
ZSTD="${ZSTD:-/usr/bin/zstd}"
SHA256SUM="${SHA256SUM:-/usr/bin/sha256sum}"
FLOCK="${FLOCK:-/usr/bin/flock}"
INSTALL="${INSTALL:-/usr/bin/install}"
TOUCH="${TOUCH:-/usr/bin/touch}"
RM="${RM:-/usr/bin/rm}"
TAIL="${TAIL:-/usr/bin/tail}"
GREP="${GREP:-/usr/bin/grep}"
AWK="${AWK:-/usr/bin/awk}"
CHOWN="${CHOWN:-/usr/bin/chown}"
CHMOD="${CHMOD:-/usr/bin/chmod}"

DATADIR="${BITCOIN_DATADIR:-/home/ubuntu/.bitcoin}"
OUTPUT_DIRECTORY="${BACKUP_OUTPUT_DIRECTORY:-/home/ubuntu}"
LOCK_FILE="${BACKUP_LOCK_FILE:-/run/lock/bitcoin-node-backup.lock}"
STATE_DIRECTORY="${BACKUP_STATE_DIRECTORY:-/var/lib/bitcoin-node-backup}"
STATE_FILE="${BACKUP_STATE_FILE:-${STATE_DIRECTORY}/backup-in-progress}"

MODE=""
ARCHIVE_NAME=""
ARCHIVE_PATH=""

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
    printf '%s [BACKUP-CREATE] %s\n' "$(timestamp)" "$1"
}

fail() {
    log "ERROR: $1" >&2
    exit 2
}

usage() {
    cat <<'EOF'
Usage:
  bitcoin-node-backup-create --dry-run --archive-name NAME
  bitcoin-node-backup-create --execute --archive-name NAME

Options:
  --dry-run             Validate requirements without changing services or files
  --execute             Create and verify the archive
  --archive-name NAME   Final guest filename ending in .tar.zst.partial
  --help                Show this help message
EOF
}

require_executable() {
    if [[ ! -x "$1" ]]; then
        fail "Required executable not found: $1"
    fi
}

restore_previous_interruption() {
    log "Unfinished backup state detected; restoring production services"

    if ! "$SYSTEMCTL" start bitcoind.service; then
        fail "Unable to restart bitcoind.service from unfinished backup state"
    fi

    if ! "$SYSTEMCTL" start \
        bitcoin-node-health.timer \
        bitcoin-node-clock-recovery.timer
    then
        fail "Unable to restart monitoring timers from unfinished backup state"
    fi

    if ! "$SYSTEMCTL" is-active --quiet bitcoind.service; then
        fail "bitcoind.service is not active after interrupted-backup recovery"
    fi

    if ! "$SYSTEMCTL" is-active --quiet bitcoin-node-health.timer; then
        fail "bitcoin-node-health.timer is not active after recovery"
    fi

    if ! "$SYSTEMCTL" is-active --quiet bitcoin-node-clock-recovery.timer; then
        fail "bitcoin-node-clock-recovery.timer is not active after recovery"
    fi

    if ! "$RM" --force "$STATE_FILE"; then
        fail "Services recovered, but the backup state marker could not be removed"
    fi

    fail "Previous interrupted backup was recovered; inspect partial files and run again"
}

cleanup() {
    initial_status=$?
    final_status=$initial_status

    trap - EXIT HUP INT TERM

    if (( initial_status != 0 )) && [[ -n "$ARCHIVE_PATH" ]] && [[ -f "$ARCHIVE_PATH" ]]; then
        if "$RM" --force -- "$ARCHIVE_PATH"; then
            log "Removed incomplete archive after failure"
        else
            log "ERROR: Unable to remove incomplete archive: $ARCHIVE_PATH" >&2
            final_status=2
        fi
    fi

    if [[ -f "$STATE_FILE" ]]; then
        log "Restoring Bitcoin Core and monitoring timers"

        if ! "$SYSTEMCTL" start bitcoind.service; then
            log "ERROR: Unable to restart bitcoind.service" >&2
            final_status=2
        fi

        if ! "$SYSTEMCTL" start \
            bitcoin-node-health.timer \
            bitcoin-node-clock-recovery.timer
        then
            log "ERROR: Unable to restart monitoring timers" >&2
            final_status=2
        fi

        if ! "$SYSTEMCTL" is-active --quiet bitcoind.service; then
            log "ERROR: bitcoind.service is not active after backup" >&2
            final_status=2
        fi

        if ! "$SYSTEMCTL" is-active --quiet bitcoin-node-health.timer; then
            log "ERROR: bitcoin-node-health.timer is not active after backup" >&2
            final_status=2
        fi

        if ! "$SYSTEMCTL" is-active --quiet bitcoin-node-clock-recovery.timer; then
            log "ERROR: bitcoin-node-clock-recovery.timer is not active after backup" >&2
            final_status=2
        fi

        if (( final_status == 0 )); then
            if ! "$RM" --force "$STATE_FILE"; then
                log "ERROR: Unable to remove completed backup state marker" >&2
                final_status=2
            fi
        fi
    fi

    if (( final_status == 0 )); then
        log "Production services restored successfully"
    else
        log "ERROR: Operator attention is required" >&2
    fi

    exit "$final_status"
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
        --archive-name)
            if [[ $# -lt 2 ]]; then
                printf 'Missing value for --archive-name\n' >&2
                exit 1
            fi

            ARCHIVE_NAME="$2"
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

if [[ -z "$MODE" ]] || [[ -z "$ARCHIVE_NAME" ]]; then
    usage >&2
    exit 1
fi

if [[ ! "$ARCHIVE_NAME" =~ ^bitcoin-node-pruned-[0-9]+-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.zst\.partial$ ]]; then
    printf 'Invalid archive name: %s\n' "$ARCHIVE_NAME" >&2
    exit 1
fi

ARCHIVE_PATH="${OUTPUT_DIRECTORY}/${ARCHIVE_NAME}"

if (( EUID != 0 )); then
    fail "This command must run as root"
fi

for executable in \
    "$SYSTEMCTL" \
    "$BITCOIN_CLI" \
    "$TAR" \
    "$ZSTD" \
    "$SHA256SUM" \
    "$FLOCK" \
    "$INSTALL" \
    "$TOUCH" \
    "$RM" \
    "$TAIL" \
    "$GREP" \
    "$AWK" \
    "$CHOWN" \
    "$CHMOD"
do
    require_executable "$executable"
done

if [[ ! -d "$DATADIR/blocks" ]]; then
    fail "Bitcoin blocks directory does not exist"
fi

if [[ ! -d "$DATADIR/chainstate" ]]; then
    fail "Bitcoin chainstate directory does not exist"
fi

if [[ -e "$ARCHIVE_PATH" ]]; then
    fail "Archive path already exists: $ARCHIVE_PATH"
fi

if [[ -f "$STATE_FILE" ]]; then
    if [[ "$MODE" == "--dry-run" ]]; then
        fail "An unfinished backup state marker exists: $STATE_FILE"
    fi

    restore_previous_interruption
fi

for unit in \
    bitcoind.service \
    bitcoin-node-health.timer \
    bitcoin-node-clock-recovery.timer
do
    if ! "$SYSTEMCTL" is-active --quiet "$unit"; then
        fail "Required unit is not active: $unit"
    fi
done

if [[ "$MODE" == "--dry-run" ]]; then
    log "VM-side dry-run passed: archive_path=$ARCHIVE_PATH"
    log "No services were stopped and no archive was created"
    exit 0
fi

if ! exec 9>"$LOCK_FILE"; then
    fail "Unable to open backup lock file: $LOCK_FILE"
fi

if ! "$FLOCK" --nonblock 9; then
    fail "Another VM-side backup is already running"
fi

if ! "$INSTALL" -d -m 0700 -o root -g root "$STATE_DIRECTORY"; then
    fail "Unable to create backup state directory"
fi

if ! "$TOUCH" "$STATE_FILE"; then
    fail "Unable to create backup state marker"
fi

trap cleanup EXIT
trap 'exit 2' HUP INT TERM

log "Pausing monitoring timers"

if ! "$SYSTEMCTL" stop \
    bitcoin-node-health.timer \
    bitcoin-node-clock-recovery.timer
then
    fail "Unable to stop monitoring timers"
fi

log "Stopping Bitcoin Core cleanly"

if ! "$SYSTEMCTL" stop bitcoind.service; then
    fail "Unable to stop bitcoind.service"
fi

if "$SYSTEMCTL" is-active --quiet bitcoind.service; then
    fail "bitcoind.service remained active after the stop request"
fi

if ! "$TAIL" -n 50 "$DATADIR/debug.log" |
    "$GREP" -q 'Shutdown done'
then
    fail "Bitcoin Core did not record a clean shutdown"
fi

log "Creating cold blockchain archive: $ARCHIVE_PATH"

if ! "$TAR" \
    --numeric-owner \
    -C "$DATADIR" \
    -cf - \
    blocks \
    chainstate |
    "$ZSTD" -T0 -3 -o "$ARCHIVE_PATH"
then
    fail "Archive creation failed"
fi

log "Testing compressed archive integrity"

if ! "$ZSTD" --test "$ARCHIVE_PATH"; then
    fail "Compressed archive integrity test failed"
fi

if ! checksum="$(
    "$SHA256SUM" "$ARCHIVE_PATH" |
        "$AWK" '{ print $1 }'
)"; then
    fail "Unable to calculate archive checksum"
fi

if [[ ! "$checksum" =~ ^[0-9a-f]{64}$ ]]; then
    fail "Invalid SHA-256 result: $checksum"
fi

if ! "$CHOWN" ubuntu:ubuntu "$ARCHIVE_PATH"; then
    fail "Unable to assign archive ownership to ubuntu"
fi

if ! "$CHMOD" 0600 "$ARCHIVE_PATH"; then
    fail "Unable to protect the guest archive"
fi

log "Archive creation and VM-side verification succeeded"
printf 'BACKUP_RESULT archive_path=%s sha256=%s\n' \
    "$ARCHIVE_PATH" \
    "$checksum"

exit 0
