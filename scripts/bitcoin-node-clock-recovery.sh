#!/usr/bin/env bash

# Recover a Bitcoin node from severe VM clock drift.
# Exit codes:
#   0 = healthy, recovered, or safely skipped
#   2 = recovery failed and operator attention is required

set -u

PATH=/usr/local/bin:/usr/bin:/bin
umask 077

BITCOIN_CLI="${BITCOIN_CLI:-/usr/local/bin/bitcoin-cli}"
JQ="${JQ:-/usr/bin/jq}"
SYSTEMCTL="${SYSTEMCTL:-/usr/bin/systemctl}"
CHRONYC="${CHRONYC:-/usr/bin/chronyc}"
AWK="${AWK:-/usr/bin/awk}"
FLOCK="${FLOCK:-/usr/bin/flock}"
SLEEP="${SLEEP:-/usr/bin/sleep}"
RM="${RM:-/usr/bin/rm}"

DATADIR="${BITCOIN_DATADIR:-/home/ubuntu/.bitcoin}"
LOCK_FILE="${CLOCK_RECOVERY_LOCK_FILE:-/run/bitcoin-node-clock-recovery/recovery.lock}"
STATE_FILE="${CLOCK_RECOVERY_STATE_FILE:-/var/lib/bitcoin-node-clock-recovery/recovery-required}"

RECOVERY_THRESHOLD_SECONDS="${RECOVERY_THRESHOLD_SECONDS:-60}"
SOURCE_ATTEMPTS="${SOURCE_ATTEMPTS:-30}"
SOURCE_WAIT_SECONDS="${SOURCE_WAIT_SECONDS:-2}"

timestamp() {
    date --utc '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
    printf '%s [CLOCK-RECOVERY] %s\n' "$(timestamp)" "$1"
}

fail() {
    log "CRITICAL: $1"
    exit 2
}

require_executable() {
    if [[ ! -x "$1" ]]; then
        fail "Required executable not found: $1"
    fi
}

for executable in \
    "$BITCOIN_CLI" \
    "$JQ" \
    "$SYSTEMCTL" \
    "$CHRONYC" \
    "$AWK" \
    "$FLOCK" \
    "$SLEEP" \
    "$RM"
do
    require_executable "$executable"
done

if [[ ! "$RECOVERY_THRESHOLD_SECONDS" =~ ^[0-9]+$ ]]; then
    fail "RECOVERY_THRESHOLD_SECONDS must be a non-negative integer"
fi

if [[ ! "$SOURCE_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
    fail "SOURCE_ATTEMPTS must be a positive integer"
fi

if [[ ! "$SOURCE_WAIT_SECONDS" =~ ^[1-9][0-9]*$ ]]; then
    fail "SOURCE_WAIT_SECONDS must be a positive integer"
fi

if ! exec 9>"$LOCK_FILE"; then
    fail "Unable to open lock file: $LOCK_FILE"
fi

if ! "$FLOCK" --nonblock 9; then
    log "Another clock-recovery check is already running; skipping"
    exit 0
fi

recovery_pending=false

if [[ -f "$STATE_FILE" ]]; then
    recovery_pending=true
    log "Unfinished clock recovery detected; resuming"
fi

if "$SYSTEMCTL" is-active --quiet bitcoind.service; then
    bitcoin_active=true
else
    bitcoin_active=false
fi

if [[ "$recovery_pending" != "true" ]]; then
    if [[ "$bitcoin_active" != "true" ]]; then
        log "bitcoind.service is not active and no recovery is pending; automatic recovery skipped"
        exit 0
    fi

    if ! time_offset="$(
        "$BITCOIN_CLI" \
            -datadir="$DATADIR" \
            getnetworkinfo 2>/dev/null |
            "$JQ" -er '.timeoffset'
    )"; then
        log "Bitcoin network RPC is not ready; automatic recovery skipped"
        exit 0
    fi

    if [[ ! "$time_offset" =~ ^-?[0-9]+$ ]]; then
        fail "Bitcoin returned an invalid time offset: $time_offset"
    fi

    absolute_time_offset="${time_offset#-}"

    if (( absolute_time_offset < RECOVERY_THRESHOLD_SECONDS )); then
        log "Clock is healthy: Bitcoin time offset is ${time_offset}s"
        exit 0
    fi

    log "Severe Bitcoin time offset detected: ${time_offset}s"

    if ! printf '%s\n' "recovery-required" >"$STATE_FILE"; then
        fail "Unable to record pending recovery state"
    fi

    recovery_pending=true
fi

if [[ "$bitcoin_active" == "true" ]]; then
    log "Stopping Bitcoin Core before correcting the system clock"

    if ! "$SYSTEMCTL" stop bitcoind.service; then
        fail "Unable to stop bitcoind.service"
    fi

    if "$SYSTEMCTL" is-active --quiet bitcoind.service; then
        fail "bitcoind.service remained active after the stop request"
    fi

    log "Bitcoin Core stopped cleanly"
else
    log "Bitcoin Core remains stopped while clock recovery resumes"
fi

log "Restarting Chrony to discard stale measurements"

if ! "$SYSTEMCTL" restart chrony.service; then
    fail "Unable to restart chrony.service; Bitcoin Core remains stopped"
fi

burst_requested=false
burst_error=""

for ((attempt = 1; attempt <= SOURCE_ATTEMPTS; attempt++)); do
    if burst_output="$("$CHRONYC" burst 4/4 2>&1)"; then
        burst_requested=true
        break
    fi

    burst_error="$burst_output"
    "$SLEEP" "$SOURCE_WAIT_SECONDS"
done

if [[ "$burst_requested" != "true" ]]; then
    fail "Unable to request fresh Chrony samples; last response: ${burst_error:-no output}; Bitcoin Core remains stopped"
fi

log "Fresh Chrony samples requested"

source_selected=false

for ((attempt = 1; attempt <= SOURCE_ATTEMPTS; attempt++)); do
# The dollar expression belongs to AWK, not Bash.
# shellcheck disable=SC2016
    if "$CHRONYC" -N sources 2>/dev/null |
        "$AWK" '$1 ~ /^\^\*/ { found = 1 } END { exit !found }'
    then
        source_selected=true
        break
    fi

    "$SLEEP" "$SOURCE_WAIT_SECONDS"
done

if [[ "$source_selected" != "true" ]]; then
    fail "Chrony has no selected time source; Bitcoin Core remains stopped"
fi

log "Chrony selected a fresh time source"

if ! "$CHRONYC" makestep >/dev/null 2>&1; then
    fail "Chrony could not step the clock; Bitcoin Core remains stopped"
fi

if ! "$CHRONYC" waitsync 30 0.1 0.0 1 >/dev/null 2>&1; then
    fail "Chrony did not synchronize within the allowed time; Bitcoin Core remains stopped"
fi

chrony_tracking="$("$CHRONYC" -N tracking 2>/dev/null)"
# The dollar expression belongs to AWK, not Bash.
# shellcheck disable=SC2016
leap_status="$(
    "$AWK" -F ':' '
        /^Leap status/ {
            value = $2
            gsub(/^[ \t]+|[ \t]+$/, "", value)
            print value
        }
    ' <<<"$chrony_tracking"
)"
# The dollar expression belongs to AWK, not Bash.
# shellcheck disable=SC2016
system_offset="$(
    "$AWK" -F ':' '
        /^System time/ {
            value = $2
            gsub(/^[ \t]+/, "", value)
            split(value, fields, /[ \t]+/)
            print fields[1]
        }
    ' <<<"$chrony_tracking"
)"

if [[ "$leap_status" != "Normal" ]]; then
    fail "Chrony leap status is '${leap_status:-unknown}'; Bitcoin Core remains stopped"
fi

if [[ -z "$system_offset" ]]; then
    fail "Unable to read the Chrony system offset; Bitcoin Core remains stopped"
fi

if ! "$AWK" -v offset="$system_offset" \
    'BEGIN { if (offset < 0) offset = -offset; exit !(offset <= 0.1) }'
then
    fail "Chrony system offset is ${system_offset}s; Bitcoin Core remains stopped"
fi

log "Clock recovery verified: Chrony offset=${system_offset}s"
log "Starting Bitcoin Core"

if ! "$SYSTEMCTL" start bitcoind.service; then
    fail "Clock recovered, but bitcoind.service could not be started"
fi

if ! "$SYSTEMCTL" is-active --quiet bitcoind.service; then
    fail "Clock recovered, but bitcoind.service is not active"
fi

if ! "$RM" --force "$STATE_FILE"; then
    fail "Bitcoin Core is active, but the pending recovery state could not be cleared"
fi

log "Recovery completed successfully; bitcoind.service is active"
exit 0
