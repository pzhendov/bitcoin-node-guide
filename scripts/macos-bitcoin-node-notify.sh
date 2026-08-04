#!/usr/bin/env bash

# Check the Multipass Bitcoin node and display macOS notifications when its
# health state changes.

set -u

PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin

INSTANCE_NAME="${BITCOIN_NODE_INSTANCE:-bitcoin-node}"
HEALTH_SCRIPT="${BITCOIN_HEALTH_SCRIPT:-/usr/local/bin/bitcoin-node-health}"

STATE_DIR="${HOME}/Library/Application Support/bitcoin-node-guide"
STATE_FILE="${STATE_DIR}/macos-last-state"

LOG_DIR="${HOME}/Library/Logs"
LOG_FILE="${LOG_DIR}/bitcoin-node-health-notify.log"

mkdir -p "$STATE_DIR" "$LOG_DIR"
chmod 700 "$STATE_DIR"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"

exec >>"$LOG_FILE" 2>&1

timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log_message() {
    printf '%s [MACOS-MONITOR] %s\n' "$(timestamp)" "$1"
}

find_multipass() {
    local candidate

    for candidate in \
        "${MULTIPASS:-}" \
        /usr/local/bin/multipass \
        /opt/homebrew/bin/multipass
    do
        if [[ -n "$candidate" && -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

display_notification() {
    local title="$1"
    local message="$2"

    if /usr/bin/osascript \
        -e 'on run argv' \
        -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
        -e 'end run' \
        "$title" \
        "$message" \
        >/dev/null
    then
        return 0
    fi

    log_message "Unable to display the macOS notification"
    return 1
}

write_state() {
    local state="$1"
    local temporary_file

    if ! temporary_file="$(mktemp "${STATE_DIR}/macos-last-state.XXXXXX")"; then
        log_message "Unable to create a temporary state file"
        return 1
    fi

    if ! printf '%s\n' "$state" >"$temporary_file"; then
        rm -f "$temporary_file"
        log_message "Unable to write the state file"
        return 1
    fi

    chmod 600 "$temporary_file"

    if ! mv -f "$temporary_file" "$STATE_FILE"; then
        rm -f "$temporary_file"
        log_message "Unable to replace the state file"
        return 1
    fi
}

if [[ "${1:-}" == "--test" ]]; then
    if display_notification \
        "Bitcoin Node Monitor" \
        "macOS notification delivery is working."
    then
        log_message "Test notification displayed"
        exit 0
    fi

    exit 1
fi

if multipass_binary="$(find_multipass)"; then
    health_report="$(
        "$multipass_binary" \
            exec "$INSTANCE_NAME" -- \
            "$HEALTH_SCRIPT" 2>&1
    )"

    command_exit_code=$?

    if ! grep -q '\[SUMMARY\].*status=' <<<"$health_report"; then
        log_message "Health summary missing; retrying Multipass check in 10 seconds"
        sleep 10

        health_report="$(
            "$multipass_binary" \
                exec "$INSTANCE_NAME" -- \
                "$HEALTH_SCRIPT" 2>&1
        )"

        command_exit_code=$?
    fi
else
    multipass_binary=""
    command_exit_code=127
    health_report="$(
        printf '%s\n' \
            "$(timestamp) [CRITICAL] Multipass executable was not found" \
            "$(timestamp) [SUMMARY] status=CRITICAL warnings=0 critical=1"
    )"
fi

case "$command_exit_code" in
    0)
        current_state="HEALTHY"
        ;;
    1)
        current_state="WARNING"
        ;;
    *)
        current_state="CRITICAL"
        ;;
esac

reported_state="$(
    printf '%s\n' "$health_report" |
        awk -F 'status=' '
            /\[SUMMARY\]/ {
                split($2, fields, /[[:space:]]+/)
                state=fields[1]
            }
            END {
                print state
            }
        '
)"

case "$reported_state" in
    HEALTHY|WARNING|CRITICAL)
        current_state="$reported_state"
        ;;
esac

previous_state=""

if [[ -r "$STATE_FILE" ]]; then
    previous_state="$(<"$STATE_FILE")"
fi

summary_line="$(
    printf '%s\n' "$health_report" |
        grep '\[SUMMARY\]' |
        tail -n 1 ||
        true
)"

problem_line="$(
    printf '%s\n' "$health_report" |
        grep -E '\[(WARNING|CRITICAL)\]' |
        head -n 1 ||
        true
)"

log_message "Check completed: state=${current_state} previous=${previous_state:-none}"

if [[ "$current_state" == "$previous_state" ]]; then
    log_message "State unchanged; no macOS notification displayed"
    exit 0
fi

if [[ -z "$previous_state" && "$current_state" == "HEALTHY" ]]; then
    if write_state "$current_state"; then
        log_message "Initial healthy state recorded; no notification displayed"
        exit 0
    fi

    exit 1
fi

if [[ "$current_state" == "HEALTHY" ]]; then
    notification_title="Bitcoin Node Recovered"
    notification_message="State changed from ${previous_state:-unknown} to HEALTHY."
else
    notification_title="Bitcoin Node ${current_state}"

    if [[ -n "$problem_line" ]]; then
        notification_message="$problem_line"
    elif [[ -n "$summary_line" ]]; then
        notification_message="$summary_line"
    else
        notification_message="The Bitcoin node health check returned ${current_state}."
    fi
fi

notification_message="${notification_message:0:500}"

if display_notification "$notification_title" "$notification_message"; then
    if write_state "$current_state"; then
        log_message "Notification displayed: ${previous_state:-none} -> ${current_state}"
        exit 0
    fi
fi

exit 1
