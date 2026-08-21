#!/usr/bin/env bash

# Configure a narrowly scoped Bitcoin Core RPC bridge for Sparrow Wallet.
#
# Exit codes:
#   0 = check, install, or rollback completed successfully
#   1 = invalid arguments or confirmation missing
#   2 = validation, installation, or rollback failed

set -u
set -o pipefail

PATH=/usr/local/bin:/usr/bin:/bin
umask 077

AWK="${AWK:-/usr/bin/awk}"
BITCOIN_CLI="${BITCOIN_CLI:-/usr/local/bin/bitcoin-cli}"
CP="${CP:-/usr/bin/cp}"
DATE="${DATE:-/usr/bin/date}"
GREP="${GREP:-/usr/bin/grep}"
INSTALL="${INSTALL:-/usr/bin/install}"
PYTHON3="${PYTHON3:-/usr/bin/python3}"
RM="${RM:-/usr/bin/rm}"
SED="${SED:-/usr/bin/sed}"
SLEEP="${SLEEP:-/usr/bin/sleep}"
SS="${SS:-/usr/bin/ss}"
STAT="${STAT:-/usr/bin/stat}"
SYSTEMCTL="${SYSTEMCTL:-/usr/bin/systemctl}"

DATADIR="${BITCOIN_DATADIR:-/home/ubuntu/.bitcoin}"
BITCOIN_CONF="${BITCOIN_CONF:-${DATADIR}/bitcoin.conf}"
RPC_INCLUDE="${SPARROW_RPC_INCLUDE:-${DATADIR}/sparrow-rpc.conf}"
RPC_CREDENTIALS="${SPARROW_RPC_CREDENTIALS:-/root/sparrow-rpc-credentials.txt}"
RPC_USER="${SPARROW_RPC_USER:-sparrow}"
RPC_PORT="${SPARROW_RPC_PORT:-8332}"

MODE=check
CONFIRM_INSTALL=false
CONFIRM_ROLLBACK=false
SERVER_IP=""
CLIENT_IP=""
RPCAUTH_TOOL=""
ROLLBACK_FILE=""

timestamp() {
    "$DATE" --utc '+%Y-%m-%dT%H:%M:%SZ'
}

log() {
    printf '%s [SPARROW-RPC] %s\n' "$(timestamp)" "$1"
}

fail() {
    log "ERROR: $1" >&2
    exit 2
}

usage() {
    cat <<'EOF'
Usage:
  bitcoin-node-sparrow-rpc-setup --check

  bitcoin-node-sparrow-rpc-setup \
    --install \
    --confirm-sparrow-rpc \
    --server-ip <bitcoin-vm-ip> \
    --client-ip <mac-bridge-ip> \
    --rpcauth-tool <path-to-rpcauth.py>

  bitcoin-node-sparrow-rpc-setup \
    --rollback <bitcoin.conf.backup> \
    --confirm-rollback

Modes:
  --check                Read-only validation; this is the default
  --install              Install the restricted Sparrow RPC bridge
  --rollback FILE        Restore bitcoin.conf from FILE and remove the bridge

Install confirmation:
  --confirm-sparrow-rpc  Required with --install

Rollback confirmation:
  --confirm-rollback     Required with --rollback

Install parameters:
  --server-ip IP         Bitcoin VM IPv4 address, for example 192.168.252.3
  --client-ip IP         Exact Mac bridge IPv4 address, for example 192.168.252.1
  --rpcauth-tool FILE    Official Bitcoin Core share/rpcauth/rpcauth.py

Security behavior:
  - Never prints the generated RPC password
  - Stores credentials only in a root-owned mode-0600 file
  - Allows RPC only from localhost and the exact client IPv4 address
  - Never binds RPC to 0.0.0.0
  - Restores the previous configuration if restart validation fails
EOF
}

require_executable() {
    if [[ ! -x "$1" ]]; then
        fail "Required executable not found: $1"
    fi
}

valid_ipv4() {
    local address="$1"
    local octet
    local old_ifs="$IFS"

    if [[ ! "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        return 1
    fi

    IFS='.' read -r -a octets <<<"$address"
    IFS="$old_ifs"

    for octet in "${octets[@]}"; do
        if (( 10#$octet < 0 || 10#$octet > 255 )); then
            return 1
        fi
    done
}

require_root() {
    if (( EUID != 0 )); then
        fail "This operation must run as root"
    fi
}

configuration_has_bridge() {
    "$GREP" -Eq '^[[:space:]]*includeconf[[:space:]]*=[[:space:]]*sparrow-rpc\.conf[[:space:]]*$' \
        "$BITCOIN_CONF" 2>/dev/null
}

verify_bridge_files() {
    local include_mode
    local include_owner
    local credentials_mode
    local credentials_owner

    if [[ ! -f "$BITCOIN_CONF" ]]; then
        fail "Bitcoin configuration not found: $BITCOIN_CONF"
    fi

    if [[ ! -f "$RPC_INCLUDE" ]]; then
        fail "Sparrow RPC include not found: $RPC_INCLUDE"
    fi

    if [[ ! -f "$RPC_CREDENTIALS" ]]; then
        fail "Sparrow RPC credentials not found: $RPC_CREDENTIALS"
    fi

    if ! configuration_has_bridge; then
        fail "bitcoin.conf does not include sparrow-rpc.conf"
    fi

    if ! "$GREP" -Eq '^[[:space:]]*disablewallet[[:space:]]*=[[:space:]]*0[[:space:]]*$' \
        "$BITCOIN_CONF"
    then
        fail "Bitcoin wallet subsystem is not enabled for Sparrow"
    fi

    if ! "$GREP" -Eq '^[[:space:]]*server[[:space:]]*=[[:space:]]*1[[:space:]]*$' \
        "$BITCOIN_CONF"
    then
        fail "Bitcoin RPC server is not enabled"
    fi

    if ! "$GREP" -Eq "^[[:space:]]*rpcauth[[:space:]]*=[[:space:]]*${RPC_USER}:" \
        "$RPC_INCLUDE"
    then
        fail "Dedicated rpcauth entry is missing for user: $RPC_USER"
    fi

    if "$GREP" -Eq '^[[:space:]]*rpc(password|user)[[:space:]]*=' \
        "$BITCOIN_CONF" "$RPC_INCLUDE"
    then
        fail "Plaintext rpcuser or rpcpassword directive detected"
    fi

    if "$GREP" -Eq '^[[:space:]]*rpcbind[[:space:]]*=[[:space:]]*0\.0\.0\.0' \
        "$BITCOIN_CONF" "$RPC_INCLUDE"
    then
        fail "Unsafe wildcard RPC bind detected"
    fi

    if [[ -n "$SERVER_IP" ]]; then
        if ! "$GREP" -Eq "^[[:space:]]*rpcbind[[:space:]]*=[[:space:]]*${SERVER_IP}[[:space:]]*$" \
            "$RPC_INCLUDE"
        then
            fail "Expected VM RPC bind is missing: $SERVER_IP"
        fi
    fi

    if [[ -n "$CLIENT_IP" ]]; then
        if ! "$GREP" -Eq "^[[:space:]]*rpcallowip[[:space:]]*=[[:space:]]*${CLIENT_IP}/32[[:space:]]*$" \
            "$RPC_INCLUDE"
        then
            fail "Expected exact client allow rule is missing: ${CLIENT_IP}/32"
        fi
    fi

    include_mode="$($STAT -c '%a' "$RPC_INCLUDE")"
    include_owner="$($STAT -c '%U:%G' "$RPC_INCLUDE")"
    credentials_mode="$($STAT -c '%a' "$RPC_CREDENTIALS")"
    credentials_owner="$($STAT -c '%U:%G' "$RPC_CREDENTIALS")"

    if [[ "$include_mode" != "600" || "$include_owner" != "ubuntu:ubuntu" ]]; then
        fail "Sparrow RPC include must be ubuntu:ubuntu mode 600"
    fi

    if [[ "$credentials_mode" != "600" || "$credentials_owner" != "root:root" ]]; then
        fail "Sparrow RPC credentials must be root:root mode 600"
    fi
}

verify_running_bridge() {
    local detected_server_ip="$SERVER_IP"

    verify_bridge_files

    if ! "$SYSTEMCTL" is-active --quiet bitcoind.service; then
        fail "bitcoind.service is not active"
    fi

    if ! "$BITCOIN_CLI" -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1; then
        fail "Bitcoin RPC is not ready"
    fi

    if [[ -z "$detected_server_ip" ]]; then
# The dollar expressions belong to AWK, not Bash.
# shellcheck disable=SC2016
        detected_server_ip="$($AWK -F '=' '
            /^[[:space:]]*rpcbind[[:space:]]*=/ {
                value = $2
                gsub(/[[:space:]]/, "", value)
                if (value != "127.0.0.1") {
                    print value
                    exit
                }
            }
        ' "$RPC_INCLUDE")"
    fi

    if [[ -z "$detected_server_ip" ]]; then
        fail "Unable to determine the VM RPC bind address"
    fi

    # The dollar expression belongs to AWK, not Bash.
    # shellcheck disable=SC2016
    if ! "$SS" -lnt |
        "$AWK" -v endpoint="${detected_server_ip}:${RPC_PORT}" \
            '$4 == endpoint { found = 1 } END { exit !found }'
    then
        fail "Bitcoin RPC is not listening on ${detected_server_ip}:${RPC_PORT}"
    fi

    # The dollar expression belongs to AWK, not Bash.
    # shellcheck disable=SC2016
    if "$SS" -lnt |
        "$AWK" -v port=":${RPC_PORT}" \
            '$4 == "0.0.0.0" port { found = 1 } END { exit !found }'
    then
        fail "Bitcoin RPC is listening on an unsafe wildcard address"
    fi

    log "Bridge validation passed"
    log "Bitcoin RPC listener is restricted to ${detected_server_ip}:${RPC_PORT}"
    log "Credential file is protected and its password was not displayed"
}

restore_configuration() {
    local backup_file="$1"

    log "Restoring previous Bitcoin configuration"
    "$SYSTEMCTL" stop bitcoind.service >/dev/null 2>&1 || true

    if ! "$CP" -p "$backup_file" "$BITCOIN_CONF"; then
        return 1
    fi

    "$RM" -f -- "$RPC_INCLUDE" "$RPC_CREDENTIALS"

    if ! "$SYSTEMCTL" start bitcoind.service; then
        return 1
    fi

    for ((attempt = 1; attempt <= 60; attempt++)); do
        if "$BITCOIN_CLI" -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1; then
            return 0
        fi

        "$SLEEP" 2
    done

    return 1
}

install_bridge() {
    local backup_file
    local config_temp
    local credentials_temp
    local include_temp
    local rpc_password
    local rpcauth_line
    local rpcauth_output
    local timestamp_suffix

    if [[ "$CONFIRM_INSTALL" != "true" ]]; then
        printf '%s\n' "Installation requires --confirm-sparrow-rpc." >&2
        exit 1
    fi

    if ! valid_ipv4 "$SERVER_IP"; then
        printf '%s\n' "Invalid --server-ip: $SERVER_IP" >&2
        exit 1
    fi

    if ! valid_ipv4 "$CLIENT_IP"; then
        printf '%s\n' "Invalid --client-ip: $CLIENT_IP" >&2
        exit 1
    fi

    if [[ "$SERVER_IP" == "0.0.0.0" || "$CLIENT_IP" == "0.0.0.0" ]]; then
        printf '%s\n' "Wildcard IPv4 addresses are not allowed." >&2
        exit 1
    fi

    require_root

    if [[ ! -f "$RPCAUTH_TOOL" ]]; then
        fail "Official rpcauth.py not found: $RPCAUTH_TOOL"
    fi

    if configuration_has_bridge; then
        log "Existing Sparrow RPC bridge detected; running validation only"
        verify_running_bridge
        return 0
    fi

    if [[ -e "$RPC_INCLUDE" || -e "$RPC_CREDENTIALS" ]]; then
        fail "Partial Sparrow RPC files require manual inspection"
    fi

    if [[ ! -f "$BITCOIN_CONF" ]]; then
        fail "Bitcoin configuration not found: $BITCOIN_CONF"
    fi

    if "$GREP" -Eq '^[[:space:]]*includeconf[[:space:]]*=[[:space:]]*sparrow-rpc\.conf' \
        "$BITCOIN_CONF"
    then
        fail "Unexpected existing Sparrow include directive"
    fi

    if "$GREP" -Eq '^[[:space:]]*rpc(password|user)[[:space:]]*=' "$BITCOIN_CONF"; then
        fail "Existing plaintext RPC credentials require manual inspection"
    fi

    timestamp_suffix="$($DATE --utc '+%Y%m%dT%H%M%SZ')"
    backup_file="${BITCOIN_CONF}.before-sparrow-${timestamp_suffix}"

    if ! "$CP" -p "$BITCOIN_CONF" "$backup_file"; then
        fail "Unable to create rollback file: $backup_file"
    fi

    config_temp="${BITCOIN_CONF}.sparrow.tmp"
    include_temp="${RPC_INCLUDE}.tmp"
    credentials_temp="${RPC_CREDENTIALS}.tmp"

    if ! rpcauth_output="$($PYTHON3 "$RPCAUTH_TOOL" "$RPC_USER" 2>/dev/null)"; then
        fail "Official rpcauth.py failed"
    fi

    rpcauth_line="$(
        printf '%s\n' "$rpcauth_output" |
            "$AWK" '/^rpcauth=/ { print; exit }'
    )"

    rpc_password="$(
        printf '%s\n' "$rpcauth_output" |
            "$AWK" 'found { print; exit } /^Your password:/ { found = 1 }'
    )"

    unset rpcauth_output

    if [[ ! "$rpcauth_line" =~ ^rpcauth=${RPC_USER}: ]] || [[ -z "$rpc_password" ]]; then
        restore_configuration "$backup_file" || true
        fail "Unable to parse rpcauth.py output"
    fi

    if ! "$SED" -E \
        -e 's/^[[:space:]]*disablewallet[[:space:]]*=.*/disablewallet=0/' \
        -e 's/^[[:space:]]*server[[:space:]]*=.*/server=1/' \
        "$BITCOIN_CONF" >"$config_temp"
    then
        unset rpc_password
        restore_configuration "$backup_file" || true
        fail "Unable to prepare Bitcoin configuration"
    fi

    if ! "$GREP" -Eq '^[[:space:]]*disablewallet[[:space:]]*=' "$config_temp"; then
        printf '\ndisablewallet=0\n' >>"$config_temp"
    fi

    if ! "$GREP" -Eq '^[[:space:]]*server[[:space:]]*=' "$config_temp"; then
        printf 'server=1\n' >>"$config_temp"
    fi

    printf '\n# Restricted Sparrow Wallet RPC bridge\nincludeconf=sparrow-rpc.conf\n' \
        >>"$config_temp"

    if ! printf '%s\n' \
        '# Dedicated Sparrow RPC bridge' \
        "$rpcauth_line" \
        '' \
        '[main]' \
        'rpcbind=127.0.0.1' \
        "rpcbind=${SERVER_IP}" \
        'rpcallowip=127.0.0.1' \
        "rpcallowip=${CLIENT_IP}/32" \
        >"$include_temp"
    then
        unset rpc_password
        restore_configuration "$backup_file" || true
        fail "Unable to prepare restricted RPC include"
    fi

    if ! printf '%s\n' \
        "Username: ${RPC_USER}" \
        'Your password:' \
        "$rpc_password" \
        >"$credentials_temp"
    then
        unset rpc_password
        restore_configuration "$backup_file" || true
        fail "Unable to prepare protected credential file"
    fi

    unset rpc_password

    if ! "$INSTALL" -o ubuntu -g ubuntu -m 0600 "$config_temp" "$BITCOIN_CONF" ||
        ! "$INSTALL" -o ubuntu -g ubuntu -m 0600 "$include_temp" "$RPC_INCLUDE" ||
        ! "$INSTALL" -o root -g root -m 0600 "$credentials_temp" "$RPC_CREDENTIALS"
    then
        "$RM" -f -- "$config_temp" "$include_temp" "$credentials_temp"
        restore_configuration "$backup_file" || true
        fail "Unable to install Sparrow RPC configuration"
    fi

    "$RM" -f -- "$config_temp" "$include_temp" "$credentials_temp"

    log "Restarting Bitcoin Core with the restricted Sparrow RPC bridge"

    if ! "$SYSTEMCTL" restart bitcoind.service; then
        restore_configuration "$backup_file" ||
            fail "Restart failed and automatic rollback also failed"
        fail "Bitcoin restart failed; previous configuration restored"
    fi

    for ((attempt = 1; attempt <= 60; attempt++)); do
        if "$BITCOIN_CLI" -datadir="$DATADIR" getblockchaininfo >/dev/null 2>&1; then
            break
        fi

        if (( attempt == 60 )); then
            restore_configuration "$backup_file" ||
                fail "RPC readiness failed and automatic rollback also failed"
            fail "Bitcoin RPC did not become ready; previous configuration restored"
        fi

        "$SLEEP" 2
    done

    if ! ( verify_running_bridge ); then
        restore_configuration "$backup_file" ||
            fail "Bridge validation failed and automatic rollback also failed"
        fail "Bridge validation failed; previous configuration restored"
    fi

    log "Sparrow RPC bridge installed successfully"
    log "Rollback file: $backup_file"
    log "Credentials: $RPC_CREDENTIALS"
    log "The RPC password was not displayed"
}

rollback_bridge() {
    if [[ "$CONFIRM_ROLLBACK" != "true" ]]; then
        printf '%s\n' "Rollback requires --confirm-rollback." >&2
        exit 1
    fi

    require_root

    if [[ ! -f "$ROLLBACK_FILE" ]]; then
        fail "Rollback file not found: $ROLLBACK_FILE"
    fi

    if ! restore_configuration "$ROLLBACK_FILE"; then
        fail "Rollback failed; operator attention is required"
    fi

    log "Rollback completed successfully"
    log "Bitcoin Core is active with the restored configuration"
}

while (( $# > 0 )); do
    case "$1" in
        --check)
            MODE=check
            shift
            ;;
        --install)
            MODE=install
            shift
            ;;
        --confirm-sparrow-rpc)
            CONFIRM_INSTALL=true
            shift
            ;;
        --server-ip)
            [[ $# -ge 2 ]] || { usage >&2; exit 1; }
            SERVER_IP="$2"
            shift 2
            ;;
        --client-ip)
            [[ $# -ge 2 ]] || { usage >&2; exit 1; }
            CLIENT_IP="$2"
            shift 2
            ;;
        --rpcauth-tool)
            [[ $# -ge 2 ]] || { usage >&2; exit 1; }
            RPCAUTH_TOOL="$2"
            shift 2
            ;;
        --rollback)
            [[ $# -ge 2 ]] || { usage >&2; exit 1; }
            MODE=rollback
            ROLLBACK_FILE="$2"
            shift 2
            ;;
        --confirm-rollback)
            CONFIRM_ROLLBACK=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

for executable in \
    "$AWK" \
    "$BITCOIN_CLI" \
    "$CP" \
    "$DATE" \
    "$GREP" \
    "$INSTALL" \
    "$PYTHON3" \
    "$RM" \
    "$SED" \
    "$SLEEP" \
    "$SS" \
    "$STAT" \
    "$SYSTEMCTL"
do
    require_executable "$executable"
done

case "$MODE" in
    check)
        require_root
        verify_running_bridge
        ;;
    install)
        if [[ -z "$SERVER_IP" || -z "$CLIENT_IP" || -z "$RPCAUTH_TOOL" ]]; then
            usage >&2
            exit 1
        fi
        install_bridge
        ;;
    rollback)
        rollback_bridge
        ;;
esac
