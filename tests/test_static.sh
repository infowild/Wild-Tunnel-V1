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

for NETWORK in tcp ws grpc http httpupgrade; do
    for SECURITY in none tls reality; do
        printf '{%s}\n' "$(stream_json remote)" | assert_json
        printf '{%s}\n' "$(stream_json local)" | assert_json
    done
done

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

echo "All static and configuration-builder tests passed."