#!/bin/bash
# Wild Tunnel v1 Installer Script
# Dynamic protocol tunnel over Xray-core (VLESS/VMESS/Trojan/Shadowsocks/SOCKS)
# plus native Hysteria2 (apernet/hysteria). Designed for Ubuntu/Debian.
#
# Everything this script installs lives under its own namespace
#   service : wild-tunnel      binaries : /usr/local/bin/wild-xray
#   config  : /etc/wild-tunnel command  : /usr/local/bin/wild
# so it never touches the Sanaei / 3x-ui panel (x-ui service,
# /usr/local/x-ui, /etc/x-ui, /usr/bin/x-ui). The only possible clash is a
# TCP/UDP port already used by the panel or another service, which the
# installer warns about before binding.

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Pinned core versions
XRAY_VERSION="v26.3.27"
HYSTERIA_VERSION="v2.9.3"

# Paths
CORE_DIR="/usr/local/bin/wild-xray"
CONF_DIR="/etc/wild-tunnel"
SERVICE="wild-tunnel"

# Runtime state
ENGINE="xray"                 # xray | hysteria
ROLE=""                       # remote | local
SS_METHOD="aes-256-gcm"       # Shadowsocks cipher
VMESS_SECURITY="auto"         # VMESS encryption
SECURITY="none"               # none | tls | reality  (vless/vmess/trojan)
NETWORK="tcp"                 # tcp | ws | grpc | http | httpupgrade
VLESS_ENC="off"               # on | off (VLESS post-quantum Encryption)
FLOW=""                       # xtls-rprx-vision when applicable
# Transport sub-settings
WS_PATH="/"
GRPC_SERVICE="grpc"
HTTP_PATH="/"
HTTP_HOST=""
# REALITY material
REALITY_DEST="www.microsoft.com:443"
REALITY_SNI="www.microsoft.com"
REALITY_PRIVATE=""
REALITY_PUBLIC=""
REALITY_SHORTID=""
REALITY_FINGERPRINT="chrome"
# VLESS Encryption material
VLESS_DECRYPTION="none"
VLESS_ENCRYPTION="none"

die() { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }

echo -e "${GREEN}Welcome to Wild Tunnel v1 Installer${NC}"
echo "1) Install Remote Server (Foreign - Receiver)"
echo "2) Install Local Server (Iran - Forwarder)"
echo "3) Uninstall Wild Tunnel"
read -p "Select an option [1-3]: " role_option

# ---------------------------------------------------------------------------
# Prerequisites & helpers
# ---------------------------------------------------------------------------

ensure_prerequisites() {
    echo -e "${GREEN}Updating package lists and installing prerequisites...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q || die "apt-get update failed"
    apt-get install -y unzip uuid-runtime jq openssl wget curl ca-certificates iproute2 cron \
        || die "Failed to install prerequisites"
    # Make sure the cron daemon is running so scheduled restarts work.
    systemctl enable --now cron >/dev/null 2>&1 || true
}

# Warn (do not fail) if a port we are about to bind is already in use, e.g. by
# the Sanaei/3x-ui panel (default web port 2053) or any other service.
check_port() {
    local p="$1"
    command -v ss >/dev/null 2>&1 || return 0
    if ss -ltnuH 2>/dev/null | awk '{print $5}' | sed 's/.*://' | grep -qx "$p"; then
        echo -e "${YELLOW}WARNING: port $p already appears to be in use on this server.${NC}"
        echo "  If the Sanaei/3x-ui panel (default 2053) or another service owns it,"
        echo "  pick a different port to avoid a conflict."
    fi
}

install_xray() {
    echo -e "${GREEN}Installing Xray core (${XRAY_VERSION})...${NC}"
    mkdir -p "$CORE_DIR" "$CONF_DIR"
    wget -qO /tmp/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" \
        || die "Failed to download Xray core"
    unzip -qo /tmp/xray.zip -d "$CORE_DIR/" || die "Failed to extract Xray core"
    rm -f /tmp/xray.zip
    chmod +x "$CORE_DIR/xray"
    [ -x "$CORE_DIR/xray" ] || die "Xray binary is missing after installation"
}

install_hysteria() {
    echo -e "${GREEN}Installing Hysteria2 core (${HYSTERIA_VERSION})...${NC}"
    mkdir -p "$CORE_DIR" "$CONF_DIR"
    wget -qO "$CORE_DIR/hysteria" "https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-amd64" \
        || die "Failed to download Hysteria2 core"
    chmod +x "$CORE_DIR/hysteria"
    [ -x "$CORE_DIR/hysteria" ] || die "Hysteria binary is missing after installation"
}

install_core() {
    if [[ "$ENGINE" == "hysteria" ]]; then
        install_hysteria
    else
        install_xray
    fi
}

setup_service() {
    echo -e "${GREEN}Setting up Systemd service...${NC}"
    local exec_cmd
    if [[ "$ENGINE" == "hysteria" ]]; then
        if [[ "$ROLE" == "remote" ]]; then
            exec_cmd="$CORE_DIR/hysteria server -c $CONF_DIR/config.yaml"
        else
            exec_cmd="$CORE_DIR/hysteria client -c $CONF_DIR/config.yaml"
        fi
    else
        exec_cmd="$CORE_DIR/xray run -config $CONF_DIR/config.json"
    fi

    # Generate the unit inline so the installer does not depend on its own CWD.
    cat <<EOF > /etc/systemd/system/${SERVICE}.service
[Unit]
Description=Wild Tunnel Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=$exec_cmd
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE"
    systemctl restart "$SERVICE"
    echo -e "${GREEN}Wild Tunnel started successfully!${NC}"
    systemctl status "$SERVICE" --no-pager | head -n 10
    install_shortcut
}

install_shortcut() {
    # Install the `wild` management command so the tunnel can be controlled
    # from anywhere after installation.
    cat <<'WILDCMD' > /usr/local/bin/wild
#!/bin/bash
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
CONF_DIR="/etc/wild-tunnel"
CORE_DIR="/usr/local/bin/wild-xray"
SERVICE="wild-tunnel"
CRON_TAG="# wild-tunnel-restart"

remove_cron() { crontab -l 2>/dev/null | grep -v "$CRON_TAG" | crontab - 2>/dev/null; }

schedule_restart() {
    echo "Schedule automatic restart:"
    echo "1) Every 6 hours"
    echo "2) Every 12 hours"
    echo "3) Every day at 04:00"
    echo "4) Custom cron expression"
    read -p "Choice [1-4]: " c
    local expr
    case $c in
        1) expr="0 */6 * * *" ;;
        2) expr="0 */12 * * *" ;;
        3) expr="0 4 * * *" ;;
        4) read -p "Enter cron expression (e.g. '0 */8 * * *'): " expr ;;
        *) echo -e "${RED}Invalid choice.${NC}"; return ;;
    esac
    [ -z "$expr" ] && { echo -e "${RED}Empty expression.${NC}"; return; }
    remove_cron
    ( crontab -l 2>/dev/null; echo "$expr systemctl restart $SERVICE $CRON_TAG" ) | crontab - \
        && echo -e "${GREEN}Scheduled: '$expr' -> restart $SERVICE${NC}"
}

echo -e "${GREEN}Wild Tunnel Management${NC}"
echo "1) Status"
echo "2) Restart (manual)"
echo "3) Stop"
echo "4) Start"
echo "5) Live logs"
echo "6) Show config"
echo "7) Schedule auto-restart (cron)"
echo "8) Remove scheduled restart"
echo "9) Uninstall"
read -p "Select [1-9]: " opt

case $opt in
    1) systemctl status "$SERVICE" --no-pager ;;
    2) systemctl restart "$SERVICE" && echo -e "${GREEN}Restarted.${NC}" ;;
    3) systemctl stop "$SERVICE" && echo -e "${GREEN}Stopped.${NC}" ;;
    4) systemctl start "$SERVICE" && echo -e "${GREEN}Started.${NC}" ;;
    5) journalctl -u "$SERVICE" -f ;;
    6) cat "$CONF_DIR"/config.* 2>/dev/null || echo -e "${RED}No config found.${NC}" ;;
    7) schedule_restart ;;
    8) remove_cron && echo -e "${GREEN}Scheduled restart removed.${NC}" ;;
    9) systemctl stop "$SERVICE" 2>/dev/null
       systemctl disable "$SERVICE" 2>/dev/null
       remove_cron
       rm -f /etc/systemd/system/${SERVICE}.service
       rm -f /etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh
       rm -rf "$CORE_DIR" "$CONF_DIR"
       systemctl daemon-reload
       systemctl reset-failed "$SERVICE" 2>/dev/null
       rm -f /usr/local/bin/wild
       echo -e "${GREEN}Uninstallation complete.${NC}" ;;
    *) echo -e "${RED}Invalid option.${NC}" ;;
esac
WILDCMD
    chmod +x /usr/local/bin/wild
    echo -e "${GREEN}Shortcut installed: run 'wild' to manage the tunnel.${NC}"
}

generate_uuid() { uuidgen; }
generate_password() { tr -dc A-Za-z0-9 </dev/urandom | head -c 16; }

# ---------------------------------------------------------------------------
# Credential / cipher prompts
# ---------------------------------------------------------------------------

# Shadowsocks cipher + matching credential. Classic AEAD ciphers accept any
# password; Shadowsocks-2022 ciphers require a Base64 PSK of an exact length,
# generated automatically.
prompt_ss_method() {
    echo -e "${GREEN}Select Shadowsocks Cipher:${NC}"
    echo "1) aes-256-gcm                    (classic)"
    echo "2) aes-128-gcm                    (classic)"
    echo "3) chacha20-ietf-poly1305         (classic)"
    echo "4) xchacha20-ietf-poly1305        (classic)"
    echo "5) 2022-blake3-aes-256-gcm        (SS2022)"
    echo "6) 2022-blake3-aes-128-gcm        (SS2022)"
    echo "7) 2022-blake3-chacha20-poly1305  (SS2022)"
    read -p "Cipher [1-7]: " ss_opt

    local keylen=""
    case $ss_opt in
        1) SS_METHOD="aes-256-gcm";;
        2) SS_METHOD="aes-128-gcm";;
        3) SS_METHOD="chacha20-ietf-poly1305";;
        4) SS_METHOD="xchacha20-ietf-poly1305";;
        5) SS_METHOD="2022-blake3-aes-256-gcm"; keylen=32;;
        6) SS_METHOD="2022-blake3-aes-128-gcm"; keylen=16;;
        7) SS_METHOD="2022-blake3-chacha20-poly1305"; keylen=32;;
        *) SS_METHOD="aes-256-gcm"; echo "Defaulting to aes-256-gcm";;
    esac

    if [ -n "$keylen" ]; then
        read -p "Enter Base64 PSK for $SS_METHOD [Leave blank to auto-generate]: " PASSWORD
        if [ -z "$PASSWORD" ]; then
            PASSWORD=$(openssl rand -base64 "$keylen")
            echo "Generated PSK: $PASSWORD"
        fi
    else
        read -p "Enter Password [Leave blank to auto-generate]: " PASSWORD
        if [ -z "$PASSWORD" ]; then
            PASSWORD=$(generate_password)
            echo "Generated Password: $PASSWORD"
        fi
    fi
}

prompt_vmess_security() {
    echo -e "${GREEN}Select VMESS Encryption (security):${NC}"
    echo "1) auto"
    echo "2) aes-128-gcm"
    echo "3) chacha20-poly1305"
    echo "4) none"
    echo "5) zero"
    read -p "Security [1-5]: " sec_opt
    case $sec_opt in
        1) VMESS_SECURITY="auto";;
        2) VMESS_SECURITY="aes-128-gcm";;
        3) VMESS_SECURITY="chacha20-poly1305";;
        4) VMESS_SECURITY="none";;
        5) VMESS_SECURITY="zero";;
        *) VMESS_SECURITY="auto"; echo "Defaulting to auto";;
    esac
}

# ---------------------------------------------------------------------------
# Transmission (network) + Security (TLS/REALITY) prompts
# ---------------------------------------------------------------------------

prompt_transmission() {
    echo -e "${GREEN}Select Transmission (network):${NC}"
    echo "1) tcp"
    echo "2) ws (WebSocket)"
    echo "3) grpc"
    echo "4) http (HTTP/2)"
    echo "5) httpupgrade"
    read -p "Transmission [1-5]: " net_opt
    case $net_opt in
        1) NETWORK="tcp";;
        2) NETWORK="ws";;
        3) NETWORK="grpc";;
        4) NETWORK="http";;
        5) NETWORK="httpupgrade";;
        *) NETWORK="tcp"; echo "Defaulting to tcp";;
    esac

    case $NETWORK in
        ws|httpupgrade)
            read -p "Path [Default: /]: " WS_PATH; WS_PATH=${WS_PATH:-/}
            read -p "Host header [optional, blank to skip]: " HTTP_HOST
            ;;
        grpc)
            read -p "gRPC serviceName [Default: grpc]: " GRPC_SERVICE; GRPC_SERVICE=${GRPC_SERVICE:-grpc}
            ;;
        http)
            read -p "Path [Default: /]: " HTTP_PATH; HTTP_PATH=${HTTP_PATH:-/}
            read -p "Host [optional, blank to skip]: " HTTP_HOST
            ;;
    esac
}

prompt_security_choice() {
    echo -e "${GREEN}Select Security:${NC}"
    echo "1) none"
    echo "2) tls"
    echo "3) reality"
    read -p "Security [1-3]: " sopt
    case $sopt in
        1) SECURITY="none";;
        2) SECURITY="tls";;
        3) SECURITY="reality";;
        *) SECURITY="none"; echo "Defaulting to none";;
    esac

    if [[ "$SECURITY" == "none" && ( "$NETWORK" == "http" || "$NETWORK" == "grpc" ) ]]; then
        echo -e "${YELLOW}Note: '$NETWORK' transmission normally needs tls or reality; 'none' may fail to connect.${NC}"
    fi

    # XTLS Vision only applies to VLESS over raw TCP with a TLS-like security
    # layer, and is mutually exclusive with VLESS Encryption (set later).
    if [[ "$PROTOCOL" == "vless" && "$NETWORK" == "tcp" && ( "$SECURITY" == "tls" || "$SECURITY" == "reality" ) ]]; then
        FLOW="xtls-rprx-vision"
    else
        FLOW=""
    fi
}

prompt_vless_encryption() {
    read -p "Enable VLESS Encryption (post-quantum ML-KEM)? (y/n) [n]: " ve
    if [[ "$ve" == "y" || "$ve" == "Y" ]]; then
        VLESS_ENC="on"
        FLOW=""   # do not combine Vision flow with VLESS Encryption
    else
        VLESS_ENC="off"
    fi
}

# ---------------------------------------------------------------------------
# Key generation (run on the REMOTE, needs the installed xray binary)
# ---------------------------------------------------------------------------

gen_reality_keys() {
    read -p "REALITY dest (camouflage site) [Default: www.microsoft.com:443]: " REALITY_DEST
    REALITY_DEST=${REALITY_DEST:-www.microsoft.com:443}
    read -p "REALITY serverName/SNI [Default: www.microsoft.com]: " REALITY_SNI
    REALITY_SNI=${REALITY_SNI:-www.microsoft.com}

    local out
    out=$("$CORE_DIR/xray" x25519) || die "xray x25519 failed"
    echo -e "${YELLOW}----- xray x25519 output (copy manually if parsing fails) -----${NC}"
    echo "$out"
    echo -e "${YELLOW}--------------------------------------------------------------${NC}"
    REALITY_PRIVATE=$(echo "$out" | grep -i 'private' | head -1 | awk -F: '{print $2}' | tr -d ' ')
    REALITY_PUBLIC=$(echo "$out" | grep -iE 'public|password' | head -1 | awk -F: '{print $2}' | tr -d ' ')
    REALITY_SHORTID=$(openssl rand -hex 8)
    [ -n "$REALITY_PRIVATE" ] || die "Could not parse REALITY private key (see output above)"
    [ -n "$REALITY_PUBLIC" ]  || die "Could not parse REALITY public key (see output above)"
}

gen_vless_enc() {
    local out
    out=$("$CORE_DIR/xray" vlessenc) || die "xray vlessenc failed"
    echo -e "${YELLOW}----- xray vlessenc output (copy manually if parsing fails) -----${NC}"
    echo "$out"
    echo -e "${YELLOW}----------------------------------------------------------------${NC}"
    VLESS_DECRYPTION=$(echo "$out" | grep -o '"decryption"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"decryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    VLESS_ENCRYPTION=$(echo "$out" | grep -o '"encryption"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"encryption"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
    [ -n "$VLESS_DECRYPTION" ] || die "Could not parse VLESS decryption (see output above)"
    [ -n "$VLESS_ENCRYPTION" ] || die "Could not parse VLESS encryption (see output above)"
}

# ---------------------------------------------------------------------------
# JSON fragment builders
# ---------------------------------------------------------------------------

# streamSettings inner JSON. $1 = remote|local
stream_json() {
    local role="$1"
    local parts=()
    parts+=("\"network\": \"$NETWORK\"")

    case "$NETWORK" in
        ws)
            local ws="\"path\": \"$WS_PATH\""
            [ -n "$HTTP_HOST" ] && ws="$ws, \"headers\": { \"Host\": \"$HTTP_HOST\" }"
            parts+=("\"wsSettings\": { $ws }")
            ;;
        httpupgrade)
            local hu="\"path\": \"$WS_PATH\""
            [ -n "$HTTP_HOST" ] && hu="$hu, \"host\": \"$HTTP_HOST\""
            parts+=("\"httpupgradeSettings\": { $hu }")
            ;;
        grpc)
            parts+=("\"grpcSettings\": { \"serviceName\": \"$GRPC_SERVICE\" }")
            ;;
        http)
            local h="\"path\": \"$HTTP_PATH\""
            [ -n "$HTTP_HOST" ] && h="$h, \"host\": [ \"$HTTP_HOST\" ]"
            parts+=("\"httpSettings\": { $h }")
            ;;
    esac

    case "$SECURITY" in
        tls)
            parts+=("\"security\": \"tls\"")
            if [[ "$role" == "remote" ]]; then
                parts+=("\"tlsSettings\": { \"certificates\": [ { \"certificateFile\": \"$CERT_FILE\", \"keyFile\": \"$KEY_FILE\" } ] }")
            else
                parts+=("\"tlsSettings\": { \"serverName\": \"$LOCAL_SERVER_NAME\", \"allowInsecure\": $LOCAL_ALLOW_INSECURE }")
            fi
            ;;
        reality)
            parts+=("\"security\": \"reality\"")
            if [[ "$role" == "remote" ]]; then
                parts+=("\"realitySettings\": { \"show\": false, \"dest\": \"$REALITY_DEST\", \"serverNames\": [ \"$REALITY_SNI\" ], \"privateKey\": \"$REALITY_PRIVATE\", \"shortIds\": [ \"$REALITY_SHORTID\" ] }")
            else
                parts+=("\"realitySettings\": { \"serverName\": \"$REALITY_SNI\", \"fingerprint\": \"$REALITY_FINGERPRINT\", \"publicKey\": \"$REALITY_PUBLIC\", \"shortId\": \"$REALITY_SHORTID\" }")
            fi
            ;;
        *)
            parts+=("\"security\": \"none\"")
            ;;
    esac

    local IFS=","
    echo "${parts[*]}"
}

# Inbound settings JSON for the REMOTE (receiver).
remote_settings() {
    case "$PROTOCOL" in
        vless)
            local client="\"id\": \"$UUID\", \"level\": 0"
            [ -n "$FLOW" ] && client="$client, \"flow\": \"$FLOW\""
            echo "\"clients\": [ { $client } ], \"decryption\": \"$VLESS_DECRYPTION\""
            ;;
        vmess)
            echo "\"clients\": [ { \"id\": \"$UUID\", \"alterId\": 0 } ]"
            ;;
        trojan)
            echo "\"clients\": [ { \"password\": \"$PASSWORD\" } ]"
            ;;
        shadowsocks)
            echo "\"method\": \"$SS_METHOD\", \"password\": \"$PASSWORD\", \"network\": \"tcp,udp\""
            ;;
        socks)
            echo "\"auth\": \"password\", \"accounts\": [ { \"user\": \"tunnel\", \"pass\": \"$PASSWORD\" } ], \"udp\": true"
            ;;
    esac
}

# Outbound settings JSON for the LOCAL (forwarder).
local_settings() {
    case "$PROTOCOL" in
        vless)
            local user="\"id\": \"$UUID\", \"encryption\": \"$VLESS_ENCRYPTION\", \"level\": 0"
            [ -n "$FLOW" ] && user="$user, \"flow\": \"$FLOW\""
            echo "\"vnext\": [ { \"address\": \"$REMOTE_IP\", \"port\": $TUNNEL_PORT, \"users\": [ { $user } ] } ]"
            ;;
        vmess)
            echo "\"vnext\": [ { \"address\": \"$REMOTE_IP\", \"port\": $TUNNEL_PORT, \"users\": [ { \"id\": \"$UUID\", \"security\": \"$VMESS_SECURITY\", \"level\": 0 } ] } ]"
            ;;
        trojan)
            echo "\"servers\": [ { \"address\": \"$REMOTE_IP\", \"port\": $TUNNEL_PORT, \"password\": \"$PASSWORD\" } ]"
            ;;
        shadowsocks)
            echo "\"servers\": [ { \"address\": \"$REMOTE_IP\", \"port\": $TUNNEL_PORT, \"password\": \"$PASSWORD\", \"method\": \"$SS_METHOD\" } ]"
            ;;
        socks)
            echo "\"servers\": [ { \"address\": \"$REMOTE_IP\", \"port\": $TUNNEL_PORT, \"users\": [ { \"user\": \"tunnel\", \"pass\": \"$PASSWORD\" } ] } ]"
            ;;
    esac
}

is_stream_protocol() {
    [[ "$PROTOCOL" == "vless" || "$PROTOCOL" == "vmess" || "$PROTOCOL" == "trojan" ]]
}

# ---------------------------------------------------------------------------
# Protocol prompt
# ---------------------------------------------------------------------------

prompt_protocol_info() {
    echo -e "${GREEN}Select Tunnel Protocol:${NC}"
    echo "1) VLESS (TCP)"
    echo "2) VMESS (TCP)"
    echo "3) Trojan (TCP)"
    echo "4) Shadowsocks (TCP/UDP, selectable cipher)"
    echo "5) Socks (TCP/UDP)"
    echo "6) Hysteria 2 (UDP, with Obfuscation)"
    read -p "Protocol [1-6]: " proto_opt

    case $proto_opt in
        1) PROTOCOL="vless";;
        2) PROTOCOL="vmess";;
        3) PROTOCOL="trojan";;
        4) PROTOCOL="shadowsocks";;
        5) PROTOCOL="socks";;
        6) PROTOCOL="hysteria2"; ENGINE="hysteria";;
        *) PROTOCOL="vless"; echo "Defaulting to vless";;
    esac

    # Credentials
    if [[ "$PROTOCOL" == "vless" || "$PROTOCOL" == "vmess" ]]; then
        read -p "Enter UUID [Leave blank to auto-generate]: " UUID
        if [ -z "$UUID" ]; then
            UUID=$(generate_uuid)
            echo "Generated UUID: $UUID"
        fi
        [[ "$PROTOCOL" == "vmess" ]] && prompt_vmess_security
    elif [[ "$PROTOCOL" == "shadowsocks" ]]; then
        prompt_ss_method
    elif [[ "$PROTOCOL" == "trojan" || "$PROTOCOL" == "socks" || "$PROTOCOL" == "hysteria2" ]]; then
        read -p "Enter Password [Leave blank to auto-generate]: " PASSWORD
        if [ -z "$PASSWORD" ]; then
            PASSWORD=$(generate_password)
            echo "Generated Password: $PASSWORD"
        fi
        if [[ "$PROTOCOL" == "hysteria2" ]]; then
            read -p "Enter Obfuscation Password [Leave blank to auto-generate]: " OBFS_PASS
            if [ -z "$OBFS_PASS" ]; then
                OBFS_PASS=$(generate_password)
                echo "Generated Obfuscation Password: $OBFS_PASS"
            fi
        fi
    fi

    # Transmission + Security layer (VLESS/VMESS/Trojan only)
    if is_stream_protocol; then
        prompt_transmission
        prompt_security_choice
        [[ "$PROTOCOL" == "vless" ]] && prompt_vless_encryption
    fi
}

# ---------------------------------------------------------------------------
# Certificate generation (TLS)
# ---------------------------------------------------------------------------

generate_certs() {
    echo -e "${GREEN}Do you want to get a REAL SSL certificate using Let's Encrypt? (y/n)${NC}"
    echo "Note: You must have a domain pointing to this server's IP, and port 80 must be free."
    read -p "Choice: " USE_REAL_SSL

    if [[ "$USE_REAL_SSL" == "y" || "$USE_REAL_SSL" == "Y" ]]; then
        read -p "Enter your Domain Name (e.g., sub.domain.com): " DOMAIN
        echo -e "${GREEN}Installing Certbot...${NC}"
        apt-get update -q && apt-get install -y certbot || die "Failed to install certbot"
        check_port 80
        certbot certonly --standalone -d "$DOMAIN" --non-interactive --agree-tos -m "admin@$DOMAIN" \
            || die "Certbot failed to issue a certificate for $DOMAIN"

        CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        KEY_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        SERVER_NAME="$DOMAIN"
        ALLOW_INSECURE="false"

        # Reload the tunnel after every automatic certificate renewal.
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat <<'HOOK' > /etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh
#!/bin/bash
systemctl restart wild-tunnel
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh
    else
        echo -e "${GREEN}Generating self-signed certificates...${NC}"
        openssl ecparam -genkey -name prime256v1 -out "$CONF_DIR/private.key" \
            || die "Failed to generate private key"
        openssl req -new -x509 -days 3650 -key "$CONF_DIR/private.key" -out "$CONF_DIR/cert.crt" -subj "/CN=bing.com" >/dev/null 2>&1 \
            || die "Failed to generate self-signed certificate"
        CERT_FILE="$CONF_DIR/cert.crt"
        KEY_FILE="$CONF_DIR/private.key"
        SERVER_NAME="bing.com"
        ALLOW_INSECURE="true"
    fi
}

# ---------------------------------------------------------------------------
# Config generation
# ---------------------------------------------------------------------------

create_remote_hysteria() {
    cat <<EOF > "$CONF_DIR/config.yaml"
listen: :$TUNNEL_PORT

tls:
  cert: $CERT_FILE
  key: $KEY_FILE

auth:
  type: password
  password: $PASSWORD

obfs:
  type: salamander
  salamander:
    password: $OBFS_PASS
EOF
}

create_remote_config() {
    if [[ "$ENGINE" == "hysteria" ]]; then
        generate_certs
        create_remote_hysteria
        return
    fi

    # Security material for stream-capable protocols
    if is_stream_protocol; then
        if [[ "$SECURITY" == "tls" ]]; then
            generate_certs
        elif [[ "$SECURITY" == "reality" ]]; then
            gen_reality_keys
        fi
        [[ "$PROTOCOL" == "vless" && "$VLESS_ENC" == "on" ]] && gen_vless_enc
    fi

    local settings stream
    settings=$(remote_settings)
    if is_stream_protocol; then
        stream=$(stream_json remote)
    else
        stream="\"network\": \"tcp\", \"security\": \"none\""
    fi

    cat <<EOF > "$CONF_DIR/config.json"
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $TUNNEL_PORT,
      "listen": "0.0.0.0",
      "protocol": "$PROTOCOL",
      "settings": { $settings },
      "streamSettings": { $stream },
      "sniffing": { "enabled": false }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "settings": {} } ]
}
EOF
}

create_local_hysteria() {
    local sni="${LOCAL_SERVER_NAME:-bing.com}"
    local insecure="${LOCAL_ALLOW_INSECURE:-true}"

    cat <<EOF > "$CONF_DIR/config.yaml"
server: $REMOTE_IP:$TUNNEL_PORT

auth: $PASSWORD

tls:
  sni: $sni
  insecure: $insecure

obfs:
  type: salamander
  salamander:
    password: $OBFS_PASS

tcpForwarding:
EOF

    IFS=',' read -ra PORT_ARRAY <<< "$TUNNEL_PORTS"
    for port in "${PORT_ARRAY[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        [ -z "$port" ] && continue
        check_port "$port"
        cat <<EOF >> "$CONF_DIR/config.yaml"
  - listen: 0.0.0.0:$port
    remote: 127.0.0.1:$port
EOF
    done

    echo "" >> "$CONF_DIR/config.yaml"
    echo "udpForwarding:" >> "$CONF_DIR/config.yaml"
    for port in "${PORT_ARRAY[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        [ -z "$port" ] && continue
        cat <<EOF >> "$CONF_DIR/config.yaml"
  - listen: 0.0.0.0:$port
    remote: 127.0.0.1:$port
EOF
    done
}

create_local_config() {
    read -p "Enter ports to tunnel (comma separated, e.g., 2053,8443): " TUNNEL_PORTS

    if [[ "$ENGINE" == "hysteria" ]]; then
        read -p "Does the Remote Server use a REAL Domain Name for TLS? (y/n): " HAS_REAL_DOMAIN
        if [[ "$HAS_REAL_DOMAIN" == "y" || "$HAS_REAL_DOMAIN" == "Y" ]]; then
            read -p "Enter the Domain Name: " LOCAL_SERVER_NAME
            LOCAL_ALLOW_INSECURE="false"
        else
            LOCAL_SERVER_NAME="bing.com"
            LOCAL_ALLOW_INSECURE="true"
        fi
        create_local_hysteria
        return
    fi

    # Client-side security material (must match the remote's choices)
    if is_stream_protocol; then
        if [[ "$SECURITY" == "tls" ]]; then
            read -p "Does the Remote Server use a REAL Domain Name for TLS? (y/n): " HAS_REAL_DOMAIN
            if [[ "$HAS_REAL_DOMAIN" == "y" || "$HAS_REAL_DOMAIN" == "Y" ]]; then
                read -p "Enter the Domain Name: " LOCAL_SERVER_NAME
                LOCAL_ALLOW_INSECURE="false"
            else
                LOCAL_SERVER_NAME="bing.com"
                LOCAL_ALLOW_INSECURE="true"
            fi
        elif [[ "$SECURITY" == "reality" ]]; then
            read -p "Enter REALITY serverName/SNI (same as remote): " REALITY_SNI
            read -p "Enter REALITY Public Key (from remote): " REALITY_PUBLIC
            read -p "Enter REALITY shortId (from remote): " REALITY_SHORTID
            read -p "Enter uTLS fingerprint [Default: chrome]: " REALITY_FINGERPRINT
            REALITY_FINGERPRINT=${REALITY_FINGERPRINT:-chrome}
        fi
        if [[ "$PROTOCOL" == "vless" && "$VLESS_ENC" == "on" ]]; then
            read -p "Enter VLESS Encryption string (from remote): " VLESS_ENCRYPTION
        fi
    fi

    local settings stream
    settings=$(local_settings)
    if is_stream_protocol; then
        stream=$(stream_json local)
    else
        stream="\"network\": \"tcp\", \"security\": \"none\""
    fi

    cat <<EOF > "$CONF_DIR/config.json"
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "$PROTOCOL",
      "settings": { $settings },
      "streamSettings": { $stream }
    }
  ]
}
EOF

    IFS=',' read -ra PORT_ARRAY <<< "$TUNNEL_PORTS"
    for port in "${PORT_ARRAY[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        [ -z "$port" ] && continue
        check_port "$port"
        jq --argjson p "$port" '.inbounds += [{"port": $p, "listen": "0.0.0.0", "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1", "port": $p, "network": "tcp,udp"}, "sniffing": {"enabled": false}}]' \
            "$CONF_DIR/config.json" > "$CONF_DIR/config.tmp.json" \
            && mv "$CONF_DIR/config.tmp.json" "$CONF_DIR/config.json" \
            || die "Failed to add dokodemo-door inbound for port $port"
    done
}

print_remote_summary() {
    echo -e "${GREEN}Save these details for the Local Server setup:${NC}"
    echo "Tunnel Port: $TUNNEL_PORT"
    echo "Protocol: $PROTOCOL"
    [[ -n "$UUID" ]] && echo "UUID: $UUID"
    [[ -n "$PASSWORD" ]] && echo "Password: $PASSWORD"
    [[ "$PROTOCOL" == "shadowsocks" ]] && echo "Cipher (method): $SS_METHOD"
    [[ "$PROTOCOL" == "vmess" ]] && echo "VMESS Security: $VMESS_SECURITY"
    [[ -n "$OBFS_PASS" ]] && echo "Obfuscation: $OBFS_PASS"
    if is_stream_protocol; then
        echo "Transmission: $NETWORK"
        [[ "$NETWORK" == "ws" || "$NETWORK" == "httpupgrade" ]] && echo "  Path: $WS_PATH${HTTP_HOST:+  Host: $HTTP_HOST}"
        [[ "$NETWORK" == "grpc" ]] && echo "  gRPC serviceName: $GRPC_SERVICE"
        [[ "$NETWORK" == "http" ]] && echo "  Path: $HTTP_PATH${HTTP_HOST:+  Host: $HTTP_HOST}"
        echo "Security: $SECURITY"
        [[ -n "$FLOW" ]] && echo "Flow: $FLOW"
    fi
    [[ "$SECURITY" == "reality" ]] && {
        echo "REALITY dest: $REALITY_DEST"
        echo "REALITY SNI (serverName): $REALITY_SNI"
        echo "REALITY Public Key: $REALITY_PUBLIC"
        echo "REALITY shortId: $REALITY_SHORTID"
    }
    [[ "$SECURITY" == "tls" && "$ALLOW_INSECURE" == "false" ]] && echo "Domain/SNI: $SERVER_NAME"
    [[ "$VLESS_ENC" == "on" ]] && echo "VLESS Encryption: $VLESS_ENCRYPTION"
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------

if [ "$role_option" == "1" ]; then
    ROLE="remote"
    echo -e "${GREEN}--- Remote Server Setup ---${NC}"
    echo "This installer is self-contained and does not touch the Sanaei/3x-ui panel."
    ensure_prerequisites
    prompt_tunnel_port
    check_port "$TUNNEL_PORT"
    prompt_protocol_info
    install_core
    create_remote_config
    setup_service
    print_remote_summary

elif [ "$role_option" == "2" ]; then
    ROLE="local"
    echo -e "${GREEN}--- Local Server Setup ---${NC}"
    echo "This installer is self-contained and does not touch the Sanaei/3x-ui panel."
    ensure_prerequisites
    read -p "Enter Remote Server IP: " REMOTE_IP
    prompt_tunnel_port
    prompt_protocol_info
    install_core
    create_local_config
    setup_service

elif [ "$role_option" == "3" ]; then
    echo -e "${RED}Uninstalling Wild Tunnel...${NC}"
    systemctl stop "$SERVICE" 2>/dev/null
    systemctl disable "$SERVICE" 2>/dev/null
    crontab -l 2>/dev/null | grep -v '# wild-tunnel-restart' | crontab - 2>/dev/null
    rm -f /etc/systemd/system/${SERVICE}.service
    rm -f /etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh
    rm -rf "$CORE_DIR"
    rm -rf "$CONF_DIR"
    rm -f /usr/local/bin/wild
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" 2>/dev/null
    echo -e "${GREEN}Uninstallation complete.${NC}"
    echo "Note: the Sanaei/3x-ui panel (if installed) was not touched."
else
    echo -e "${RED}Invalid option selected.${NC}"
fi
