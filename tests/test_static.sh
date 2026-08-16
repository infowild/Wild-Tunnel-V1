#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
INSTALLER="$ROOT/install.sh"
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

bash -n "$INSTALLER"
[[ $(tail -n 1 "$INSTALLER") == "main_menu" ]] || fail "installer entry point must remain the final line"
[[ $(grep -c '^main_menu()' "$INSTALLER") -eq 1 ]] || fail "main_menu must be defined exactly once"
[[ $(grep -c '^install_shortcut()' "$INSTALLER") -eq 1 ]] || fail "install_shortcut must be defined exactly once"
! grep -Eq '/tmp/(xray|tun2socks)\.(zip|tmp)' "$INSTALLER" || fail "fixed temporary download path found"
grep -q 'download_verified' "$INSTALLER" || fail "verified download helper is missing"
grep -q 'pinSHA256:' "$INSTALLER" || fail "Hysteria certificate pin is missing"
grep -q 'pinnedPeerCertSha256' "$INSTALLER" || fail "Xray certificate pin is missing"
grep -q -- '--tcp-rcvbuf $TUN_TCP_RCVBUF --tcp-auto-tuning' "$INSTALLER" ||
    fail "tun2socks upload receive-window tuning is missing"
grep -q 'txqueuelen "$TUN_TXQLEN"' "$INSTALLER" ||
    fail "TUN upload queue tuning is missing"
grep -q 'bbrProfile:' "$INSTALLER" || fail "Hysteria BBR profile is missing"
for helper in generate_uuid generate_password cert_sha256; do
    [[ $(grep -c "^$helper()" "$INSTALLER") -eq 1 ]] || fail "$helper must be defined exactly once"
done

# Load function definitions without executing the interactive entry point.
# shellcheck disable=SC1090
source <(sed '$d' "$INSTALLER")
[[ $(normalize_cert_pin '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff') == '00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF' ]] ||
    fail "certificate pin normalization failed"
[[ $(generate_password) =~ ^[0-9a-f]{16}$ ]] ||
    fail "generated password has an unexpected format"

CRON_FILE="$TEST_DIR/crontab"
printf '0 4 * * * systemctl restart wild-tunnel %s\n' "$CRON_TAG" > "$CRON_FILE"
crontab() {
    if [ "$1" = "-l" ]; then
        cat "$CRON_FILE"
    else
        cat > "$CRON_FILE"
    fi
}
remove_cron
! grep -qF "$CRON_TAG" "$CRON_FILE" || fail "tagged cron entry was not removed"

CONF_DIR="$TEST_DIR/certs"
mkdir -p "$CONF_DIR"
ENGINE='xray'
USE_REAL_SSL='n'
make_certs >/dev/null
openssl x509 -in "$CERT_FILE" -noout -text | grep -q 'CA:FALSE' ||
    fail "self-signed Xray certificate is not a leaf certificate"
[[ $(normalize_cert_pin "$CERT_SHA256") == "$CERT_SHA256" ]] ||
    fail "generated certificate fingerprint is not canonical"

# Production installs jq. The fallback keeps this test runnable on a minimal
# developer workstation while exercising the exact fragment builders.
if ! command -v jq >/dev/null 2>&1; then
    json_quote() {
        python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"
    }
fi

assert_json() {
    python3 -c 'import json, sys; json.load(sys.stdin)' >/dev/null
}

assert_xray_runs() {
    local config="$1" label="$2" log status
    log="$TEST_DIR/xray-${label}.log"
    [[ -n ${XRAY_TEST_BINARY:-} ]] || return 0
    set +e
    timeout 2 "$XRAY_TEST_BINARY" run -config "$config" >"$log" 2>&1
    status=$?
    set -e
    if [[ $status -ne 124 ]]; then
        cat "$log" >&2
        fail "Xray did not keep the $label configuration running"
    fi
}

UUID='00000000-0000-4000-8000-000000000001'
PASSWORD=$'p"ass\nword\\tail'
SS_METHOD='aes-256-gcm'
VMESS_SECURITY='auto'
VLESS_ENCRYPTION='none'
VLESS_DECRYPTION='none'
FLOW=''
REMOTE_IP='203.0.113.10'
TUNNEL_PORT='50000'
WS_PATH=$'/wild"tunnel'
HTTP_PATH='/wild'
HTTP_HOST='edge.example'
GRPC_SERVICE='wild-grpc'
CERT_FILE='/etc/wild-tunnel/cert.crt'
KEY_FILE='/etc/wild-tunnel/private.key'
LOCAL_SERVER_NAME='bing.com'
LOCAL_PINNED_SHA='0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
REALITY_DEST='dl.google.com:443'
REALITY_SNI='dl.google.com'
REALITY_PRIVATE='private-key'
REALITY_PUBLIC='public-key'
REALITY_SHORTID='0011223344556677'
REALITY_FINGERPRINT='chrome'

[[ $(normalize_port_spec '443, 2053, 3000-3002') == '443,2053,3000-3002' ]] ||
    fail "tunnel-port normalization failed"
mapfile -t EXPANDED_PORTS < <(expand_tunnel_ports '443,2053,3000-3002' 64)
[[ ${EXPANDED_PORTS[*]} == '443 2053 3000 3001 3002' ]] ||
    fail "tunnel-port expansion failed"
! validate_engine_port_spec xray '1-100' >/dev/null 2>&1 ||
    fail "Xray accepted more than 64 expanded tunnel ports"

for NETWORK in tcp ws grpc http httpupgrade; do
    for SECURITY in none tls reality; do
        printf '{%s}\n' "$(stream_json remote)" | assert_json
        printf '{%s}\n' "$(stream_json local)" | assert_json
    done
done

NETWORK='tcp'
SECURITY='tls'
USE_REAL_SSL='y'
[[ $(stream_json remote) == *'"rejectUnknownSni": true'* ]] ||
    fail "real-domain TLS does not reject unknown SNI"
USE_REAL_SSL='n'
[[ $(stream_json remote) != *'"rejectUnknownSni"'* ]] ||
    fail "self-signed TLS unexpectedly rejects unknown SNI"

TLS_PING_CORE="$TEST_DIR/tls-ping-core"
mkdir -p "$TLS_PING_CORE"
cat > "$TLS_PING_CORE/xray" <<'MOCK'
#!/bin/sh
[ "$1" = tls ] && [ "$2" = ping ] && [ "$3" = -ip ] && [ "$4" = 203.0.113.20 ] && [ "$5" = reality.example ] || exit 2
cat <<'OUTPUT'
Pinging with SNI
Handshake succeeded
TLS Version:                       TLS 1.3
TLS ping finished
OUTPUT
MOCK
chmod +x "$TLS_PING_CORE/xray"
CORE_DIR="$TLS_PING_CORE"
REALITY_DEST='203.0.113.20:443'
REALITY_SNI='reality.example'
validate_reality_target >/dev/null || fail "valid REALITY TLS target was rejected"
REALITY_DEST='dl.google.com:443'
REALITY_SNI='dl.google.com'

preferred_tcp_congestion() { printf '%s\n' bbr; }
NETWORK='tcp'
SECURITY='none'
[[ $(stream_json local) == *'"tcpcongestion": "bbr"'* ]] ||
    fail "local Xray stream does not select available BBR"
[[ $(stream_json remote) != *'"tcpcongestion"'* ]] ||
    fail "remote Xray stream unexpectedly overrides congestion control"

for PROTOCOL in vless vmess trojan shadowsocks socks; do
    SECURITY=none
    printf '{%s}\n' "$(remote_settings)" | assert_json
    printf '{%s}\n' "$(local_settings)" | assert_json
done

# A remote Xray receiver creates one inbound per tunnel port and preserves a
# direct-only health-check route for the local observatory.
MOCK_CORE="$TEST_DIR/mock-core"
mkdir -p "$MOCK_CORE"
if [[ -n ${XRAY_TEST_BINARY:-} ]]; then
    ln -s "$XRAY_TEST_BINARY" "$MOCK_CORE/xray"
else
    printf '#!/bin/sh\nexit 0\n' > "$MOCK_CORE/xray"
    chmod +x "$MOCK_CORE/xray"
fi
CORE_DIR="$MOCK_CORE"
CONF_DIR="$TEST_DIR/multi-remote"
mkdir -p "$CONF_DIR"
ROLE='remote'
ENGINE='xray'
PROTOCOL='vmess'
NETWORK='tcp'
SECURITY='none'
TUNNEL_PORTS='443,2053,8443'
TUNNEL_PORT='443'
check_port() { :; }
create_remote_config
[[ $(jq '.inbounds | length' "$CONF_DIR/config.json") -eq 3 ]] ||
    fail "remote multi-port inbound count is wrong"
jq -e '.routing.rules[] | select(.outboundTag == "health-direct")' "$CONF_DIR/config.json" >/dev/null ||
    fail "remote health-check bypass route is missing"

# A remote Hysteria receiver consumes the range natively and its ACL rewrites
# the forwarding sentinel to loopback while preserving the requested port.
CONF_DIR="$TEST_DIR/hysteria-remote"
mkdir -p "$CONF_DIR"
ENGINE='hysteria'
PROTOCOL='hysteria2'
TUNNEL_PORTS='32000-32002'
TUNNEL_PORT='32000'
PASSWORD='hy-password'
OBFS_PASS='hy-obfs'
USE_REAL_SSL='n'
CERT_FILE="$CONF_DIR/cert.crt"
KEY_FILE="$CONF_DIR/private.key"
SERVER_NAME='bing.com'
create_remote_config
grep -q 'listen: ":32000-32002"' "$CONF_DIR/config.yaml" ||
    fail "remote Hysteria port range was not generated"
grep -q '^direct(198.18.0.2, \*, 127.0.0.1)$' "$CONF_DIR/hysteria.acl" ||
    fail "remote Hysteria sentinel ACL is missing"
grep -q '^direct(connectivitycheck.gstatic.com, tcp/443)$' "$CONF_DIR/hysteria.acl" ||
    fail "remote Hysteria health-check ACL is missing"
grep -q '^reject(all)$' "$CONF_DIR/hysteria.acl" ||
    fail "remote Hysteria default-reject ACL is missing"
! grep -q '^direct(all)$' "$CONF_DIR/hysteria.acl" ||
    fail "remote Hysteria ACL still permits unrestricted direct access"
if [[ -n ${HYSTERIA_TEST_BINARY:-} ]]; then
    HYSTERIA_LOG="$TEST_DIR/hysteria-server.log"
    set +e
    timeout 2 env HYSTERIA_DISABLE_UPDATE_CHECK=1 "$HYSTERIA_TEST_BINARY" \
        server -c "$CONF_DIR/config.yaml" >"$HYSTERIA_LOG" 2>&1
    HYSTERIA_STATUS=$?
    set -e
    if [[ $HYSTERIA_STATUS -ne 124 ]]; then
        cat "$HYSTERIA_LOG" >&2
        fail "Hysteria rejected the generated multi-port server config or ACL"
    fi
fi

# Mixed Xray + Hysteria locations share one dispatcher. Hysteria uses its own
# loopback SOCKS client and native multi-port hopping.
CONF_DIR="$TEST_DIR/multi-local"
LOCATIONS_FILE="$CONF_DIR/locations.json"
LOCATIONS_DIR="$CONF_DIR/locations"
HYSTERIA_CLIENT_LIST="$CONF_DIR/hysteria-clients.list"
HYSTERIA_CLIENT_PREVIOUS="$CONF_DIR/hysteria-clients.previous"
mkdir -p "$CONF_DIR"
ROLE='local'
MULTI_MODE='on'
BALANCER_STRATEGY='leastLoad'
LOCATION_NAME='Xray-US'
ENGINE='xray'
PROTOCOL='vmess'
REMOTE_IP='203.0.113.10'
TUNNEL_PORTS='443,8443'
TUNNEL_PORT='443'
UUID='00000000-0000-4000-8000-000000000001'
NETWORK='tcp'
SECURITY='none'
FLOW=''
NODE_ONE=$(current_location_json 'loc1' "$LOCATION_NAME")
LOCATION_NAME='HY-DE'
ENGINE='hysteria'
PROTOCOL='hysteria2'
REMOTE_IP='198.51.100.20'
TUNNEL_PORTS='20000-20010'
TUNNEL_PORT='20000'
PASSWORD='hy-password'
OBFS_PASS='hy-obfs'
LOCAL_SERVER_NAME='hy.example'
LOCAL_ALLOW_INSECURE='false'
LOCAL_PINNED_SHA=''
HYSTERIA_BBR_PROFILE='standard'
NODE_TWO=$(current_location_json 'loc2' "$LOCATION_NAME")
jq -n --argjson one "$NODE_ONE" --argjson two "$NODE_TWO" \
    '{version:1, strategy:"leastLoad", nodes:[$one,$two]}' > "$LOCATIONS_FILE"
FORWARD_PORTS='23456,23457'
FORWARD_MODE='direct'
TUN_INSTALL_CALLS=0
TUN_SCRIPT_CALLS=0
install_tun2socks() { (( ++TUN_INSTALL_CALLS )); }
write_forward_scripts() { (( ++TUN_SCRIPT_CALLS )); }
create_multi_local_config
[[ $(jq '.outbounds | length' "$CONF_DIR/config.json") -eq 3 ]] ||
    fail "mixed multi-location outbound count is wrong"
[[ $(jq '.inbounds | length' "$CONF_DIR/config.json") -eq 2 ]] ||
    fail "direct mode did not create one inbound per forwarded port"
jq -e 'all(.inbounds[];
    .protocol == "dokodemo-door" and .settings.address == "198.18.0.2" and
    .settings.network == "tcp,udp")' "$CONF_DIR/config.json" >/dev/null ||
    fail "direct forwarding inbounds are invalid"
[[ $TUN_INSTALL_CALLS -eq 0 && $TUN_SCRIPT_CALLS -eq 0 ]] ||
    fail "direct mode unexpectedly prepared tun2socks"
assert_xray_runs "$CONF_DIR/config.json" 'direct'
[[ $(jq '.routing.balancers | length' "$CONF_DIR/config.json") -eq 2 ]] ||
    fail "TCP/UDP balancers were not both generated"
jq -e '.burstObservatory.subjectSelector == ["wild-node-"]' "$CONF_DIR/config.json" >/dev/null ||
    fail "multi-location observatory is missing"
grep -q 'server: "198.51.100.20:20000-20010"' "$LOCATIONS_DIR/loc-1.yaml" ||
    fail "Hysteria port-hopping address was not generated"
grep -q 'minHopInterval: 15s' "$LOCATIONS_DIR/loc-1.yaml" ||
    fail "Hysteria randomized port hopping is missing"
grep -q '^loc-1$' "$HYSTERIA_CLIENT_LIST" ||
    fail "Hysteria instance list is missing"

FORWARD_MODE='tun-legacy'
create_multi_local_config
jq -e '.inbounds == [{
    tag:"socks-in", listen:"127.0.0.1", port:10808, protocol:"socks",
    settings:{auth:"noauth",udp:true}, sniffing:{enabled:false}
}]' "$CONF_DIR/config.json" >/dev/null ||
    fail "tun-legacy SOCKS inbound is invalid"
[[ $TUN_INSTALL_CALLS -eq 1 && $TUN_SCRIPT_CALLS -eq 1 ]] ||
    fail "tun-legacy mode did not prepare tun2socks"
assert_xray_runs "$CONF_DIR/config.json" 'tun-legacy'
FORWARD_MODE='direct'
if [[ -n ${HYSTERIA_TEST_BINARY:-} ]]; then
    HYSTERIA_LOG="$TEST_DIR/hysteria-client.log"
    set +e
    timeout 2 env HYSTERIA_DISABLE_UPDATE_CHECK=1 "$HYSTERIA_TEST_BINARY" \
        client -c "$LOCATIONS_DIR/loc-1.yaml" >"$HYSTERIA_LOG" 2>&1
    HYSTERIA_STATUS=$?
    set -e
    if [[ $HYSTERIA_STATUS -ne 124 ]]; then
        cat "$HYSTERIA_LOG" >&2
        fail "Hysteria rejected the generated multi-location client config"
    fi
fi

# A single eligible tunnel path is routed directly. It must not create a
# periodic observatory or a health-dependent balancer.
CONF_DIR="$TEST_DIR/single-local"
LOCATIONS_FILE="$CONF_DIR/locations.json"
LOCATIONS_DIR="$CONF_DIR/locations"
HYSTERIA_CLIENT_LIST="$CONF_DIR/hysteria-clients.list"
HYSTERIA_CLIENT_PREVIOUS="$CONF_DIR/hysteria-clients.previous"
mkdir -p "$CONF_DIR"
ROLE='local'
LOCATION_NAME='Single-Xray'
ENGINE='xray'
PROTOCOL='vmess'
REMOTE_IP='203.0.113.30'
TUNNEL_PORTS='443'
TUNNEL_PORT='443'
UUID='00000000-0000-4000-8000-000000000001'
NETWORK='tcp'
SECURITY='none'
FLOW=''
NODE_SINGLE=$(current_location_json 'single' "$LOCATION_NAME")
jq -n --argjson node "$NODE_SINGLE" '{version:1, strategy:"leastLoad", nodes:[$node]}' > "$LOCATIONS_FILE"
FORWARD_PORTS='23458'
FORWARD_MODE='direct'
create_multi_local_config
jq -e '(.routing.balancers | length) == 0 and
       (has("burstObservatory") | not) and
       all(.routing.rules[]; has("outboundTag") and (has("balancerTag") | not))' \
    "$CONF_DIR/config.json" >/dev/null ||
    fail "single-path config still uses periodic health probing or a balancer"
assert_xray_runs "$CONF_DIR/config.json" 'single-path'

ENGINE='hysteria'
HYSTERIA_BBR_PROFILE='aggressive'
FORWARD_PORTS='23456'
OBFS_PASS='obfs-password'
LOCAL_ALLOW_INSECURE='true'
check_port() { :; }
HYSTERIA_CONFIG="$TEST_DIR/hysteria-client.yaml"
create_local_hysteria "$HYSTERIA_CONFIG"
grep -q 'bbrProfile: "aggressive"' "$HYSTERIA_CONFIG" ||
    fail "Hysteria aggressive upload profile was not generated"
if python3 -c 'import yaml' >/dev/null 2>&1; then
    validate_yaml_file "$HYSTERIA_CONFIG"
fi

CONF_DIR="$TEST_DIR"
reset_state
ROLE='local'
ENGINE='xray'
PROTOCOL='trojan'
SECURITY='tls'
EXPECTED_PASSWORD=$'state "quote"\nbackslash\\value'
PASSWORD="$EXPECTED_PASSWORD"
save_state
[[ $(stat -c '%a' "$CONF_DIR/wild.conf") == '600' ]] || fail "wild.conf mode is not 600"
PASSWORD='changed'
load_state
[[ "$PASSWORD" == "$EXPECTED_PASSWORD" ]] || fail "wild.conf did not safely round-trip a complex value"
[[ "$FORWARD_MODE" == 'direct' ]] || fail "direct forwarding mode did not round-trip through state"
sed -i '/^FORWARD_MODE=/d' "$CONF_DIR/wild.conf"
FORWARD_MODE='direct'
load_state
[[ "$FORWARD_MODE" == 'tun-legacy' ]] ||
    fail "pre-v2 state did not preserve legacy TUN forwarding"

echo "All static and configuration-builder tests passed."
