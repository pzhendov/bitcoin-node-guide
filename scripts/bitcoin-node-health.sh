#!/usr/bin/env bash

# Bitcoin Core node health monitor.
# Exit codes:
#   0 = healthy
#   1 = warning
#   2 = critical

set -u

PATH=/usr/local/bin:/usr/bin:/bin

BITCOIN_CLI="${BITCOIN_CLI:-/usr/local/bin/bitcoin-cli}"
JQ="${JQ:-/usr/bin/jq}"
CHRONYC="${CHRONYC:-/usr/bin/chronyc}"
SYSTEMCTL="${SYSTEMCTL:-/usr/bin/systemctl}"
DATADIR="${BITCOIN_DATADIR:-/home/ubuntu/.bitcoin}"

MAX_BLOCK_GAP="${MAX_BLOCK_GAP:-6}"
WARN_TIME_OFFSET="${WARN_TIME_OFFSET:-10}"
CRIT_TIME_OFFSET="${CRIT_TIME_OFFSET:-60}"
WARN_DISK_FREE_PERCENT="${WARN_DISK_FREE_PERCENT:-20}"
CRIT_DISK_FREE_PERCENT="${CRIT_DISK_FREE_PERCENT:-10}"
WARN_MEMORY_MIB="${WARN_MEMORY_MIB:-512}"
CRIT_MEMORY_MIB="${CRIT_MEMORY_MIB:-256}"

warning_count=0
critical_count=0

timestamp() {
    date --utc '+%Y-%m-%dT%H:%M:%SZ'
}

log_ok() {
    printf '%s [OK] %s\n' "$(timestamp)" "$1"
}

log_warning() {
    warning_count=$((warning_count + 1))
    printf '%s [WARNING] %s\n' "$(timestamp)" "$1"
}

log_critical() {
    critical_count=$((critical_count + 1))
    printf '%s [CRITICAL] %s\n' "$(timestamp)" "$1"
}

finish() {
    local status
    local exit_code

    if (( critical_count > 0 )); then
        status="CRITICAL"
        exit_code=2
    elif (( warning_count > 0 )); then
        status="WARNING"
        exit_code=1
    else
        status="HEALTHY"
        exit_code=0
    fi

    printf '%s [SUMMARY] status=%s warnings=%d critical=%d\n' \
        "$(timestamp)" \
        "$status" \
        "$warning_count" \
        "$critical_count"

    exit "$exit_code"
}

require_executable() {
    if [[ ! -x "$1" ]]; then
        log_critical "Required executable not found: $1"
    fi
}

require_executable "$BITCOIN_CLI"
require_executable "$JQ"
require_executable "$CHRONYC"
require_executable "$SYSTEMCTL"

if (( critical_count > 0 )); then
    finish
fi

if "$SYSTEMCTL" is-active --quiet bitcoind.service; then
    log_ok "bitcoind.service is active"
else
    log_critical "bitcoind.service is not active"
    finish
fi

blockchain_json="$(
    "$BITCOIN_CLI" \
        -datadir="$DATADIR" \
        getblockchaininfo 2>/dev/null
)"

if [[ -z "$blockchain_json" ]]; then
    log_critical "Bitcoin Core blockchain RPC did not return data"
    finish
fi

chain_fields="$(
    "$JQ" -er \
        '[
            .blocks,
            .headers,
            .verificationprogress,
            .initialblockdownload,
            .pruned,
            .pruneheight,
            .size_on_disk
        ] | @tsv' \
        <<<"$blockchain_json"
)"

if [[ -z "$chain_fields" ]]; then
    log_critical "Unable to parse blockchain information"
    finish
fi

IFS=$'\t' read -r \
    blocks \
    headers \
    verification_progress \
    initial_block_download \
    pruned \
    prune_height \
    size_on_disk \
    <<<"$chain_fields"

block_gap=$((headers - blocks))

if (( block_gap < 0 )); then
    block_gap=0
fi

progress_percent="$(
    awk -v progress="$verification_progress" \
        'BEGIN { printf "%.4f", progress * 100 }'
)"

if [[ "$initial_block_download" == "false" ]]; then
    log_ok "Initial block download is complete"
else
    log_warning "Initial block download is still active"
fi

if (( block_gap <= MAX_BLOCK_GAP )); then
    log_ok "Blockchain is current: blocks=$blocks headers=$headers gap=$block_gap progress=${progress_percent}%"
else
    log_warning "Blockchain is behind: blocks=$blocks headers=$headers gap=$block_gap progress=${progress_percent}%"
fi

if [[ "$pruned" == "true" ]]; then
    size_on_disk_gib="$(
        awk -v bytes="$size_on_disk" \
            'BEGIN { printf "%.2f", bytes / 1073741824 }'
    )"

    log_ok "Pruning is active: prune_height=$prune_height size=${size_on_disk_gib}GiB"
else
    log_warning "Pruning is not active"
fi

network_json="$(
    "$BITCOIN_CLI" \
        -datadir="$DATADIR" \
        getnetworkinfo 2>/dev/null
)"

if [[ -z "$network_json" ]]; then
    log_critical "Bitcoin Core network RPC did not return data"
    finish
fi

network_fields="$(
    "$JQ" -er \
        '[
            .networkactive,
            .connections,
            .connections_in,
            .connections_out,
            .timeoffset
        ] | @tsv' \
        <<<"$network_json"
)"

if [[ -z "$network_fields" ]]; then
    log_critical "Unable to parse network information"
    finish
fi

IFS=$'\t' read -r \
    network_active \
    connections \
    connections_in \
    connections_out \
    time_offset \
    <<<"$network_fields"

if [[ "$network_active" == "true" ]]; then
    log_ok "Bitcoin network activity is enabled"
else
    log_critical "Bitcoin network activity is disabled"
fi

if (( connections_out > 0 )); then
    log_ok "Peers connected: total=$connections inbound=$connections_in outbound=$connections_out"
else
    log_warning "No outbound Bitcoin peers are connected"
fi

absolute_time_offset="${time_offset#-}"

if (( absolute_time_offset >= CRIT_TIME_OFFSET )); then
    log_critical "Bitcoin time offset is ${time_offset}s"
elif (( absolute_time_offset >= WARN_TIME_OFFSET )); then
    log_warning "Bitcoin time offset is ${time_offset}s"
else
    log_ok "Bitcoin time offset is ${time_offset}s"
fi

chrony_output="$("$CHRONYC" -N tracking 2>/dev/null)"

if [[ -n "$chrony_output" ]]; then
    leap_status="$(
        awk -F ':' '
            /^Leap status/ {
                value=$2
                gsub(/^[ \t]+|[ \t]+$/, "", value)
                print value
            }
        ' <<<"$chrony_output"
    )"

    chrony_offset="$(
        awk -F ':' '
            /^System time/ {
                value=$2
                gsub(/^[ \t]+/, "", value)
                split(value, fields, /[ \t]+/)
                print fields[1]
            }
        ' <<<"$chrony_output"
    )"

    if [[ "$leap_status" == "Normal" ]]; then
        log_ok "Chrony leap status is Normal"
    else
        log_warning "Chrony leap status is '${leap_status:-unknown}'"
    fi

    if [[ -n "$chrony_offset" ]]; then
        if awk -v offset="$chrony_offset" \
            'BEGIN { exit !(offset <= 1.0) }'
        then
            log_ok "Chrony system offset is ${chrony_offset}s"
        else
            log_warning "Chrony system offset is ${chrony_offset}s"
        fi
    else
        log_warning "Unable to read the Chrony system offset"
    fi
else
    log_warning "Chrony tracking information is unavailable"
fi

disk_used_percent="$(
    df -P "$DATADIR" |
        awk 'NR == 2 {
            gsub(/%/, "", $5)
            print $5
        }'
)"

if [[ -n "$disk_used_percent" ]]; then
    disk_free_percent=$((100 - disk_used_percent))

    if (( disk_free_percent <= CRIT_DISK_FREE_PERCENT )); then
        log_critical "Disk space is critically low: ${disk_free_percent}% free"
    elif (( disk_free_percent <= WARN_DISK_FREE_PERCENT )); then
        log_warning "Disk space is low: ${disk_free_percent}% free"
    else
        log_ok "Disk space is sufficient: ${disk_free_percent}% free"
    fi
else
    log_critical "Unable to determine available disk space"
fi

memory_available_mib="$(
    awk '
        /^MemAvailable:/ {
            printf "%.0f", $2 / 1024
        }
    ' /proc/meminfo
)"

if [[ -n "$memory_available_mib" ]]; then
    if (( memory_available_mib <= CRIT_MEMORY_MIB )); then
        log_critical "Available memory is critically low: ${memory_available_mib}MiB"
    elif (( memory_available_mib <= WARN_MEMORY_MIB )); then
        log_warning "Available memory is low: ${memory_available_mib}MiB"
    else
        log_ok "Available memory is sufficient: ${memory_available_mib}MiB"
    fi
else
    log_critical "Unable to determine available memory"
fi

finish
