#!/usr/bin/env bash

# Run the Bitcoin node health check, store its report and dispatch alerts.

set -u

PATH=/usr/local/bin:/usr/bin:/bin
umask 077

HEALTH_SCRIPT="${HEALTH_SCRIPT:-/usr/local/bin/bitcoin-node-health}"
ALERT_SCRIPT="${ALERT_SCRIPT:-/usr/local/bin/bitcoin-node-telegram-alert}"
RUNTIME_DIR="${HEALTH_RUNTIME_DIR:-/run/bitcoin-node-health}"
REPORT_FILE="${RUNTIME_DIR}/latest-report.log"

timestamp() {
    date --utc '+%Y-%m-%dT%H:%M:%SZ'
}

if [[ -x "$HEALTH_SCRIPT" ]]; then
    health_report="$("$HEALTH_SCRIPT" 2>&1)"
    health_exit_code=$?
else
    health_exit_code=2
    health_report="$(
        printf '%s\n' \
            "$(timestamp) [CRITICAL] Health script is unavailable: $HEALTH_SCRIPT" \
            "$(timestamp) [SUMMARY] status=CRITICAL warnings=0 critical=1"
    )"
fi

printf '%s\n' "$health_report"

if [[ ! -d "$RUNTIME_DIR" || ! -w "$RUNTIME_DIR" ]]; then
    printf '%s [ALERT-ERROR] Runtime directory is unavailable: %s\n' \
        "$(timestamp)" \
        "$RUNTIME_DIR" >&2

    exit "$health_exit_code"
fi

if ! printf '%s\n' "$health_report" >"$REPORT_FILE"; then
    printf '%s [ALERT-ERROR] Unable to write health report: %s\n' \
        "$(timestamp)" \
        "$REPORT_FILE" >&2

    exit "$health_exit_code"
fi

if [[ -x "$ALERT_SCRIPT" ]]; then
    if ! "$ALERT_SCRIPT" "$health_exit_code" "$REPORT_FILE"; then
        printf '%s [ALERT-ERROR] Alert dispatcher failed\n' \
            "$(timestamp)" >&2
    fi
else
    printf '%s [ALERT-ERROR] Alert dispatcher is unavailable: %s\n' \
        "$(timestamp)" \
        "$ALERT_SCRIPT" >&2
fi

exit "$health_exit_code"
