#!/usr/bin/env bash

# Send Bitcoin node health state changes to Telegram.
#
# Production usage:
#   bitcoin-node-telegram-alert EXIT_CODE REPORT_FILE
#
# Test usage:
#   bitcoin-node-telegram-alert --test WARNING

set -u

PATH=/usr/local/bin:/usr/bin:/bin

CURL="${CURL:-/usr/bin/curl}"
JQ="${JQ:-/usr/bin/jq}"
STATE_DIR="${ALERT_STATE_DIR:-/var/lib/bitcoin-node-health}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"

timestamp() {
    date --utc '+%Y-%m-%dT%H:%M:%SZ'
}

log_alert() {
    printf '%s [ALERT] %s\n' "$(timestamp)" "$1"
}

log_error() {
    printf '%s [ALERT-ERROR] %s\n' "$(timestamp)" "$1" >&2
}

send_telegram_message() {
    local message="$1"
    local response

    if [[ -z "$TELEGRAM_BOT_TOKEN" || -z "$TELEGRAM_CHAT_ID" ]]; then
        log_error "Telegram credentials are not configured"
        return 1
    fi

    if [[ ! -x "$CURL" ]]; then
        log_error "curl is not available at $CURL"
        return 1
    fi

    if [[ ! -x "$JQ" ]]; then
        log_error "jq is not available at $JQ"
        return 1
    fi

    message="${message:0:3900}"

    if ! response="$(
        "$CURL" \
            -fsS \
            --max-time 20 \
            -X POST \
            "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=${message}"
    )"; then
        log_error "Telegram API request failed"
        return 1
    fi

    if ! "$JQ" -e '.ok == true' >/dev/null 2>&1 <<<"$response"; then
        log_error "Telegram API did not accept the message"
        return 1
    fi

    return 0
}

write_state() {
    local state="$1"
    local temporary_file

    if [[ ! -d "$STATE_DIR" || ! -w "$STATE_DIR" ]]; then
        log_error "State directory is unavailable: $STATE_DIR"
        return 1
    fi

    if ! temporary_file="$(mktemp "${STATE_DIR}/last-state.XXXXXX")"; then
        log_error "Unable to create a temporary state file"
        return 1
    fi

    if ! printf '%s\n' "$state" >"$temporary_file"; then
        rm -f "$temporary_file"
        log_error "Unable to write the alert state"
        return 1
    fi

    if ! mv -f "$temporary_file" "${STATE_DIR}/last-state"; then
        rm -f "$temporary_file"
        log_error "Unable to replace the alert state"
        return 1
    fi
}

if [[ "${1:-}" == "--test" ]]; then
    test_status="${2:-WARNING}"

    test_message="$(
        printf '%s\n' \
            "Bitcoin node alert test" \
            "Host: $(hostname)" \
            "State: ${test_status}" \
            "UTC: $(timestamp)" \
            "Telegram alert delivery is working."
    )"

    if send_telegram_message "$test_message"; then
        log_alert "Telegram test message sent"
        exit 0
    fi

    exit 1
fi

if (( $# != 2 )); then
    log_error "Usage: $0 EXIT_CODE REPORT_FILE"
    exit 2
fi

health_exit_code="$1"
report_file="$2"

case "$health_exit_code" in
    0)
        current_state="HEALTHY"
        ;;
    1)
        current_state="WARNING"
        ;;
    2)
        current_state="CRITICAL"
        ;;
    *)
        current_state="UNKNOWN"
        ;;
esac

if [[ ! -r "$report_file" ]]; then
    log_error "Health report is unreadable: $report_file"
    exit 1
fi

previous_state=""

if [[ -r "${STATE_DIR}/last-state" ]]; then
    previous_state="$(<"${STATE_DIR}/last-state")"
fi

if [[ "$current_state" == "$previous_state" ]]; then
    log_alert "State remains ${current_state}; no Telegram message sent"
    exit 0
fi

if [[ -z "$previous_state" && "$current_state" == "HEALTHY" ]]; then
    if write_state "$current_state"; then
        log_alert "Initial healthy state recorded; no Telegram message sent"
        exit 0
    fi

    exit 1
fi

details="$(
    grep -E '\[(WARNING|CRITICAL|SUMMARY)\]' "$report_file" |
        tail -n 8 ||
        true
)"

if [[ "$current_state" == "HEALTHY" ]]; then
    title="Bitcoin node recovered"
else
    title="Bitcoin node alert"
fi

message="$(
    printf '%s\n' \
        "$title" \
        "Host: $(hostname)" \
        "Previous state: ${previous_state:-none}" \
        "Current state: ${current_state}" \
        "UTC: $(timestamp)"
)"

if [[ -n "$details" ]]; then
    message="${message}

${details}"
fi

if send_telegram_message "$message"; then
    if write_state "$current_state"; then
        log_alert "Telegram state-change message sent: ${previous_state:-none} -> ${current_state}"
        exit 0
    fi
fi

exit 1
