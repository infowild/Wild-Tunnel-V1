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
TUN2SOCKS_VERSION="v2.7.0"

# Paths
CORE_DIR="/usr/local/bin/wild-xray"
CONF_DIR="/etc/wild-tunnel"
SERVICE="wild-tunnel"
FWD_SERVICE="wild-forward"

# Local port-forwarding (Xray engine) settings
SOCKS_PORT="10808"            # local-only SOCKS inbound that tun2socks feeds
TUN_NAME="wildtun0"           # TUN device created on the local (Iran) side
TUN_ADDR="198.18.0.1"         # address assigned to the TUN device
TUN_CIDR="15"                 # 198.18.0.0/15 (RFC 2544 benchmarking range)
SENTINEL_IP="198.18.0.2"      # DNAT target routed into the TUN (ignored by remote)

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
# NOTE: dest MUST be a TLS1.3 site with a SMALL (ECDSA) certificate chain.
# Large RSA chains (e.g. www.microsoft.com from some regions) overflow REALITY's
# handshake buffer and cause "handshake did not complete successfully".
REALITY_DEST="dl.google.com:443"
REALITY_SNI="dl.google.com"
REALITY_PRIVATE=""
REALITY_PUBLIC=""
REALITY_SHORTID=""
REALITY_FINGERPRINT="chrome"
# VLESS Encryption material
VLESS_DECRYPTION="none"
VLESS_ENCRYPTION="none"

die() { echo -e "${RED}Error: $1${NC}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Interactive navigation helpers (step-by-step Back with "0")
# ---------------------------------------------------------------------------
BACK_RC=10   # a step returns this when the user pressed 0 (Back)
SKIP_RC=20   # a step returns this when it does not apply in the current context

# Big symbolic banner shown at the top of the main menu.
show_banner() {
    clear 2>/dev/null
    echo -e "${GREEN}"
    cat <<'BANNER'
 ##     ## #### ##       ########     ######## ##     ## ##    ## ##    ## ######## ##
 ##     ##  ##  ##       ##     ##       ##    ##     ## ###   ## ###   ## ##       ##
 ##     ##  ##  ##       ##     ##       ##    ##     ## ####  ## ####  ## ##       ##
 ##  #  ##  ##  ##       ##     ##       ##    ##     ## ## ## ## ## ## ## ######   ##
 ## ### ##  ##  ##       ##     ##       ##    ##     ## ##  #### ##  #### ##       ##
 ####  ###  ##  ##       ##     ##       ##    ##     ## ##   ### ##   ### ##       ##
 ###   ## #### ######## ########        ##     #######  ##    ## ##    ## ######## ########
BANNER
    echo -e "            W I L D   T U N N E L   -   V 1${NC}"
    echo
}

# run_steps step1 step2 ... : run an ordered list of input steps that support
# step-by-step Back. A step returns 0 (advance), BACK_RC (go back one step) or
# SKIP_RC (not applicable -> keep moving in the current direction). If the user
# backs out before the first step, run_steps returns BACK_RC (caller shows menu).
run_steps() {
    local -a __steps=("$@")
    local __i=0 __dir=1 __rc
    while (( __i >= 0 && __i < ${#__steps[@]} )); do
        "${__steps[__i]}"; __rc=$?
        if   (( __rc == BACK_RC )); then __dir=-1; (( __i-- ))
        elif (( __rc == SKIP_RC )); then (( __i += __dir ))
        else __dir=1; (( __i++ )); fi
    done
    (( __i < 0 )) && return $BACK_RC
    return 0
}

hint_back() { echo -e "${YELLOW}(enter 0 to go Back)${NC}"; }

# ---------------------------------------------------------------------------
# Prerequisites & helpers
# ---------------------------------------------------------------------------

ensure_prerequisites() {
    echo -e "${GREEN}Updating package lists and installing prerequisites...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q || die "apt-get update failed"
    apt-get install -y unzip uuid-runtime jq openssl wget curl ca-certificates iproute2 iptables cron \
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

install_tun2socks() {
    # Already present (e.g. during an edit/apply): keep the pinned binary.
    [ -x "$CORE_DIR/tun2socks" ] && return 0
    echo -e "${GREEN}Installing tun2socks (${TUN2SOCKS_VERSION})...${NC}"
    mkdir -p "$CORE_DIR"
    wget -qO /tmp/tun2socks.zip "https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_VERSION}/tun2socks-linux-amd64.zip" \
        || die "Failed to download tun2socks"
    unzip -qo /tmp/tun2socks.zip -d "$CORE_DIR/" || die "Failed to extract tun2socks"
    rm -f /tmp/tun2socks.zip
    # The archive ships the binary as tun2socks-linux-amd64; normalise the name.
    [ -f "$CORE_DIR/tun2socks-linux-amd64" ] && mv -f "$CORE_DIR/tun2socks-linux-amd64" "$CORE_DIR/tun2socks"
    chmod +x "$CORE_DIR/tun2socks"
    [ -x "$CORE_DIR/tun2socks" ] || die "tun2socks binary is missing after installation"
}

install_core() {
    if [[ "$ENGINE" == "hysteria" ]]; then
        install_hysteria
    else
        install_xray
    fi
}

# Like install_core but skips the download when the needed binary already
# exists. Used by the edit/apply path so editing a port does not re-download.
ensure_core() {
    mkdir -p "$CORE_DIR" "$CONF_DIR"
    if [[ "$ENGINE" == "hysteria" ]]; then
        [ -x "$CORE_DIR/hysteria" ] || install_hysteria
    else
        [ -x "$CORE_DIR/xray" ] || install_xray
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
FWD_SERVICE="wild-forward"
CRON_TAG="# wild-tunnel-restart"

has_forward() { [ -f /etc/systemd/system/${FWD_SERVICE}.service ]; }

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
    1) systemctl status "$SERVICE" --no-pager
       has_forward && { echo; systemctl status "$FWD_SERVICE" --no-pager; } ;;
    2) systemctl restart "$SERVICE"; has_forward && systemctl restart "$FWD_SERVICE"
       echo -e "${GREEN}Restarted.${NC}" ;;
    3) systemctl stop "$SERVICE"; has_forward && systemctl stop "$FWD_SERVICE"
       echo -e "${GREEN}Stopped.${NC}" ;;
    4) systemctl start "$SERVICE"; has_forward && systemctl start "$FWD_SERVICE"
       echo -e "${GREEN}Started.${NC}" ;;
    5) journalctl -u "$SERVICE" -f ;;
    6) cat "$CONF_DIR"/config.* 2>/dev/null || echo -e "${RED}No config found.${NC}" ;;
    7) schedule_restart ;;
    8) remove_cron && echo -e "${GREEN}Scheduled restart removed.${NC}" ;;
    9) systemctl stop "$FWD_SERVICE" 2>/dev/null
       systemctl disable "$FWD_SERVICE" 2>/dev/null
       [ -f "$CONF_DIR/forward-down.sh" ] && bash "$CONF_DIR/forward-down.sh" 2>/dev/null
       rm -f /etc/systemd/system/${FWD_SERVICE}.service
       systemctl stop "$SERVICE" 2>/dev/null
       systemctl disable "$SERVICE" 2>/dev/null
       remove_cron
       rm -f /etc/systemd/system/${SERVICE}.service
       rm -f /etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh
       rm -rf "$CORE_DIR" "$CONF_DIR"
       systemctl daemon-reload
       systemctl reset-failed "$SERVICE" 2>/dev/null
       systemctl reset-failed "$FWD_SERVICE" 2>/dev/null
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
    echo "0) Back"
    read -p "Cipher [1-7, 0=Back]: " ss_opt

    local keylen=""
    case $ss_opt in
        0) return $BACK_RC;;
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
    return 0
}

prompt_vmess_security() {
    echo -e "${GREEN}Select VMESS Encryption (security):${NC}"
    echo "1) auto"
    echo "2) aes-128-gcm"
    echo "3) chacha20-poly1305"
    echo "4) none"
    echo "5) zero"
    echo "0) Back"
    read -p "Security [1-5, 0=Back]: " sec_opt
    case $sec_opt in
        0) return $BACK_RC;;
        1) VMESS_SECURITY="auto";;
        2) VMESS_SECURITY="aes-128-gcm";;
        3) VMESS_SECURITY="chacha20-poly1305";;
        4) VMESS_SECURITY="none";;
        5) VMESS_SECURITY="zero";;
        *) VMESS_SECURITY="auto"; echo "Defaulting to auto";;
    esac
    return 0
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
    echo "0) Back"
    read -p "Transmission [1-5, 0=Back]: " net_opt
    case $net_opt in
        0) return $BACK_RC;;
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
    return 0
}

prompt_security_choice() {
    echo -e "${GREEN}Select Security:${NC}"
    echo "1) none"
    echo "2) tls"
    echo "3) reality"
    echo "0) Back"
    read -p "Security [1-3, 0=Back]: " sopt
    case $sopt in
        0) return $BACK_RC;;
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
    return 0
}

prompt_vless_encryption() {
    read -p "Enable VLESS Encryption (post-quantum ML-KEM)? (y/n) [n] (0=Back): " ve
    [ "$ve" = "0" ] && return $BACK_RC
    if [[ "$ve" == "y" || "$ve" == "Y" ]]; then
        VLESS_ENC="on"
        FLOW=""   # do not combine Vision flow with VLESS Encryption
    else
        VLESS_ENC="off"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Key generation (run on the REMOTE, needs the installed xray binary)
# ---------------------------------------------------------------------------

# Interactive part (asks for dest + SNI). Back-aware.
prompt_reality_dest() {
    echo -e "${YELLOW}Tip: REALITY dest must use TLS1.3 with a SMALL cert (ECDSA). Good: dl.google.com, www.cloudflare.com. Avoid big RSA chains like www.microsoft.com.${NC}"
    read -p "REALITY dest (camouflage site) [Default: dl.google.com:443] (0=Back): " REALITY_DEST
    [ "$REALITY_DEST" = "0" ] && return $BACK_RC
    REALITY_DEST=${REALITY_DEST:-dl.google.com:443}
    read -p "REALITY serverName/SNI [Default: dl.google.com] (0=Back): " REALITY_SNI
    [ "$REALITY_SNI" = "0" ] && return $BACK_RC
    REALITY_SNI=${REALITY_SNI:-dl.google.com}
    return 0
}

# Generation part (runs after install, needs the installed xray binary).
make_reality_keys() {
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
# Certificate generation (TLS)
# ---------------------------------------------------------------------------

# Interactive part (asks for a real cert + domain). Back-aware.
prompt_tls_domain() {
    echo -e "${GREEN}Do you want to get a REAL SSL certificate using Let's Encrypt? (y/n)${NC}"
    echo "Note: You must have a domain pointing to this server's IP, and port 80 must be free."
    read -p "Choice (y/n) [n] (0=Back): " USE_REAL_SSL
    [ "$USE_REAL_SSL" = "0" ] && return $BACK_RC
    if [[ "$USE_REAL_SSL" == "y" || "$USE_REAL_SSL" == "Y" ]]; then
        read -p "Enter your Domain Name (e.g., sub.domain.com) (0=Back): " DOMAIN
        [ "$DOMAIN" = "0" ] && return $BACK_RC
    fi
    return 0
}

# Generation part (runs after install, no prompts). Uses USE_REAL_SSL/DOMAIN.
make_certs() {
    if [[ "$USE_REAL_SSL" == "y" || "$USE_REAL_SSL" == "Y" ]]; then
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
        make_certs
        create_remote_hysteria
        return
    fi

    # Security material for stream-capable protocols. Existing material is
    # reused (important for edits: regenerating REALITY keys would break the
    # already-configured local side). Material is (re)generated only when it is
    # missing, or when an edit explicitly cleared it to request a refresh.
    if is_stream_protocol; then
        if [[ "$SECURITY" == "tls" ]]; then
            make_certs
        elif [[ "$SECURITY" == "reality" ]]; then
            [ -z "$REALITY_PRIVATE" ] && make_reality_keys
            [ -z "$REALITY_SHORTID" ] && REALITY_SHORTID=$(openssl rand -hex 8)
        fi
        if [[ "$PROTOCOL" == "vless" && "$VLESS_ENC" == "on" ]]; then
            { [ -z "$VLESS_DECRYPTION" ] || [ "$VLESS_DECRYPTION" == "none" ]; } && gen_vless_enc
        fi
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
  "outbounds": [ { "protocol": "freedom", "settings": { "redirect": "127.0.0.1:0" } } ]
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

    IFS=',' read -ra PORT_ARRAY <<< "$FORWARD_PORTS"
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
    # All interactive input (forward ports + client-side security material) has
    # already been collected by the step-based flow before install; here we only
    # write the configuration.
    if [[ "$ENGINE" == "hysteria" ]]; then
        create_local_hysteria
        return
    fi

    local settings stream
    settings=$(local_settings)
    if is_stream_protocol; then
        stream=$(stream_json local)
    else
        stream="\"network\": \"tcp\", \"security\": \"none\""
    fi

    # A local-only SOCKS inbound is the entry point that tun2socks feeds; its
    # traffic flows out through the encrypted tunnel outbound below.
    cat <<EOF > "$CONF_DIR/config.json"
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": true },
      "sniffing": { "enabled": false }
    }
  ],
  "outbounds": [
    {
      "protocol": "$PROTOCOL",
      "settings": { $settings },
      "streamSettings": { $stream }
    }
  ]
}
EOF

    install_tun2socks
    write_forward_scripts
}

# Generate the up/down scripts that build the TUN device + iptables rules so the
# chosen ports are forwarded through the tunnel (system-level, no dokodemo-door).
write_forward_scripts() {
    local ports_line=""
    IFS=',' read -ra PORT_ARRAY <<< "$FORWARD_PORTS"
    for port in "${PORT_ARRAY[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        [ -z "$port" ] && continue
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
            || die "Invalid forward port: $port"
        check_port "$port"
        ports_line="$ports_line $port"
    done
    ports_line="${ports_line# }"
    [ -n "$ports_line" ] || die "No valid forward ports provided"

    cat <<EOF > "$CONF_DIR/forward-up.sh"
#!/bin/bash
# Auto-generated by Wild Tunnel installer. Brings up the forwarding TUN + rules.
TUN="$TUN_NAME"
TUN_CIDR_ADDR="$TUN_ADDR/$TUN_CIDR"
SENTINEL="$SENTINEL_IP"
PORTS=($ports_line)
EOF
    cat <<'EOF' >> "$CONF_DIR/forward-up.sh"
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1

if ! ip link show "$TUN" >/dev/null 2>&1; then
    ip tuntap add mode tun dev "$TUN"
fi
ip addr replace "$TUN_CIDR_ADDR" dev "$TUN"
ip link set dev "$TUN" up

ensure() { local t="$1" c="$2"; shift 2; iptables -t "$t" -C "$c" "$@" 2>/dev/null || iptables -t "$t" -A "$c" "$@"; }

for p in "${PORTS[@]}"; do
    ensure nat PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "$SENTINEL:$p" -m comment --comment wild-tunnel
    ensure nat PREROUTING -p udp --dport "$p" -j DNAT --to-destination "$SENTINEL:$p" -m comment --comment wild-tunnel
done
ensure nat POSTROUTING -o "$TUN" -j MASQUERADE -m comment --comment wild-tunnel
ensure filter FORWARD -o "$TUN" -j ACCEPT -m comment --comment wild-tunnel
ensure filter FORWARD -i "$TUN" -j ACCEPT -m comment --comment wild-tunnel
EOF
    chmod +x "$CONF_DIR/forward-up.sh"

    cat <<EOF > "$CONF_DIR/forward-down.sh"
#!/bin/bash
# Auto-generated by Wild Tunnel installer. Tears down the forwarding TUN + rules.
TUN="$TUN_NAME"
SENTINEL="$SENTINEL_IP"
PORTS=($ports_line)
EOF
    cat <<'EOF' >> "$CONF_DIR/forward-down.sh"
for p in "${PORTS[@]}"; do
    iptables -t nat -D PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "$SENTINEL:$p" -m comment --comment wild-tunnel 2>/dev/null
    iptables -t nat -D PREROUTING -p udp --dport "$p" -j DNAT --to-destination "$SENTINEL:$p" -m comment --comment wild-tunnel 2>/dev/null
done
iptables -t nat -D POSTROUTING -o "$TUN" -j MASQUERADE -m comment --comment wild-tunnel 2>/dev/null
iptables -D FORWARD -o "$TUN" -j ACCEPT -m comment --comment wild-tunnel 2>/dev/null
iptables -D FORWARD -i "$TUN" -j ACCEPT -m comment --comment wild-tunnel 2>/dev/null
ip link set dev "$TUN" down 2>/dev/null
ip link del "$TUN" 2>/dev/null
EOF
    chmod +x "$CONF_DIR/forward-down.sh"
}

# Install + start the tun2socks service that pumps the TUN device into the SOCKS
# inbound (which is chained to the encrypted tunnel outbound).
setup_forward_service() {
    echo -e "${GREEN}Setting up port-forwarding service (${FWD_SERVICE})...${NC}"
    cat <<EOF > /etc/systemd/system/${FWD_SERVICE}.service
[Unit]
Description=Wild Tunnel Port Forwarder
After=network.target ${SERVICE}.service
Requires=${SERVICE}.service

[Service]
Type=simple
ExecStartPre=/bin/bash $CONF_DIR/forward-up.sh
ExecStart=$CORE_DIR/tun2socks --device $TUN_NAME --proxy socks5://127.0.0.1:$SOCKS_PORT --loglevel warning
ExecStopPost=/bin/bash $CONF_DIR/forward-down.sh
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$FWD_SERVICE"
    systemctl restart "$FWD_SERVICE"
    echo -e "${GREEN}Port forwarder started.${NC}"
    systemctl status "$FWD_SERVICE" --no-pager | head -n 10
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
# Input steps (support step-by-step Back with "0")
# ---------------------------------------------------------------------------

# Reset all per-run selections so a previous run (or a backed-out run) never
# leaks stale values into the next installation.
reset_state() {
    ENGINE="xray"; PROTOCOL=""; NETWORK="tcp"; SECURITY="none"; FLOW=""
    VLESS_ENC="off"; VLESS_ENCRYPTION="none"; VLESS_DECRYPTION="none"
    UUID=""; PASSWORD=""; OBFS_PASS=""; SS_METHOD=""; VMESS_SECURITY="auto"
    WS_PATH="/"; HTTP_HOST=""; GRPC_SERVICE="grpc"; HTTP_PATH="/"
    REALITY_DEST=""; REALITY_SNI=""; REALITY_PUBLIC=""; REALITY_PRIVATE=""
    REALITY_SHORTID=""; REALITY_FINGERPRINT="chrome"
    USE_REAL_SSL=""; DOMAIN=""; LOCAL_SERVER_NAME=""; LOCAL_ALLOW_INSECURE="true"
    FORWARD_PORTS=""; REMOTE_IP=""; TUNNEL_PORT=""
}

# Persist every selection so the configuration can be edited later. This is the
# single source of truth the "Edit Configuration" menu reads from.
save_state() {
    mkdir -p "$CONF_DIR"
    cat > "$CONF_DIR/wild.conf" <<EOF
ROLE="$ROLE"
ENGINE="$ENGINE"
PROTOCOL="$PROTOCOL"
TUNNEL_PORT="$TUNNEL_PORT"
REMOTE_IP="$REMOTE_IP"
UUID="$UUID"
PASSWORD="$PASSWORD"
OBFS_PASS="$OBFS_PASS"
SS_METHOD="$SS_METHOD"
VMESS_SECURITY="$VMESS_SECURITY"
NETWORK="$NETWORK"
WS_PATH="$WS_PATH"
HTTP_HOST="$HTTP_HOST"
GRPC_SERVICE="$GRPC_SERVICE"
HTTP_PATH="$HTTP_PATH"
SECURITY="$SECURITY"
FLOW="$FLOW"
VLESS_ENC="$VLESS_ENC"
VLESS_ENCRYPTION="$VLESS_ENCRYPTION"
VLESS_DECRYPTION="$VLESS_DECRYPTION"
REALITY_DEST="$REALITY_DEST"
REALITY_SNI="$REALITY_SNI"
REALITY_PUBLIC="$REALITY_PUBLIC"
REALITY_PRIVATE="$REALITY_PRIVATE"
REALITY_SHORTID="$REALITY_SHORTID"
REALITY_FINGERPRINT="$REALITY_FINGERPRINT"
USE_REAL_SSL="$USE_REAL_SSL"
DOMAIN="$DOMAIN"
CERT_FILE="$CERT_FILE"
KEY_FILE="$KEY_FILE"
SERVER_NAME="$SERVER_NAME"
ALLOW_INSECURE="$ALLOW_INSECURE"
LOCAL_SERVER_NAME="$LOCAL_SERVER_NAME"
LOCAL_ALLOW_INSECURE="$LOCAL_ALLOW_INSECURE"
FORWARD_PORTS="$FORWARD_PORTS"
EOF
    chmod 600 "$CONF_DIR/wild.conf" 2>/dev/null || true
}

# Load a previously saved configuration into the current shell. Returns 1 when
# no saved state exists (e.g. installed with an older version, or not installed).
load_state() {
    [ -f "$CONF_DIR/wild.conf" ] || return 1
    # shellcheck disable=SC1090
    . "$CONF_DIR/wild.conf"
    return 0
}

step_tunnel_port() {
    hint_back
    while true; do
        read -p "Enter Tunnel Port (1-65535): " TUNNEL_PORT
        [ "$TUNNEL_PORT" = "0" ] && return $BACK_RC
        if [[ "$TUNNEL_PORT" =~ ^[0-9]+$ ]] && [ "$TUNNEL_PORT" -ge 1 ] && [ "$TUNNEL_PORT" -le 65535 ]; then
            break
        fi
        echo -e "${RED}Invalid port. Enter a number between 1 and 65535 (or 0 to go back).${NC}"
    done
    return 0
}

lstep_remote_ip() {
    hint_back
    while true; do
        read -p "Enter Remote Server IP: " REMOTE_IP
        [ "$REMOTE_IP" = "0" ] && return $BACK_RC
        [ -n "$REMOTE_IP" ] && break
        echo -e "${RED}Remote IP cannot be empty (or 0 to go back).${NC}"
    done
    return 0
}

sstep_protocol() {
    echo -e "${GREEN}Select Tunnel Protocol:${NC}"
    echo "1) VLESS (TCP)"
    echo "2) VMESS (TCP)"
    echo "3) Trojan (TCP)"
    echo "4) Shadowsocks (TCP/UDP, selectable cipher)"
    echo "5) Socks (TCP/UDP)"
    echo "6) Hysteria 2 (UDP, with Obfuscation)"
    echo "0) Back"
    read -p "Protocol [1-6, 0=Back]: " proto_opt
    case $proto_opt in
        0) return $BACK_RC;;
        1) PROTOCOL="vless"; ENGINE="xray";;
        2) PROTOCOL="vmess"; ENGINE="xray";;
        3) PROTOCOL="trojan"; ENGINE="xray";;
        4) PROTOCOL="shadowsocks"; ENGINE="xray";;
        5) PROTOCOL="socks"; ENGINE="xray";;
        6) PROTOCOL="hysteria2"; ENGINE="hysteria";;
        *) PROTOCOL="vless"; ENGINE="xray"; echo "Defaulting to vless";;
    esac
    return 0
}

sstep_creds() {
    case "$PROTOCOL" in
        vless|vmess)
            read -p "Enter UUID [Leave blank to auto-generate] (0=Back): " UUID
            [ "$UUID" = "0" ] && return $BACK_RC
            [ -z "$UUID" ] && { UUID=$(generate_uuid); echo "Generated UUID: $UUID"; }
            [[ "$PROTOCOL" == "vmess" ]] && { prompt_vmess_security || return $BACK_RC; }
            ;;
        shadowsocks)
            prompt_ss_method || return $BACK_RC
            ;;
        trojan|socks|hysteria2)
            read -p "Enter Password [Leave blank to auto-generate] (0=Back): " PASSWORD
            [ "$PASSWORD" = "0" ] && return $BACK_RC
            [ -z "$PASSWORD" ] && { PASSWORD=$(generate_password); echo "Generated Password: $PASSWORD"; }
            if [[ "$PROTOCOL" == "hysteria2" ]]; then
                read -p "Enter Obfuscation Password [Leave blank to auto-generate]: " OBFS_PASS
                [ -z "$OBFS_PASS" ] && { OBFS_PASS=$(generate_password); echo "Generated Obfuscation Password: $OBFS_PASS"; }
            fi
            ;;
    esac
    return 0
}

sstep_transmission() {
    is_stream_protocol || return $SKIP_RC
    prompt_transmission
}

sstep_security() {
    is_stream_protocol || return $SKIP_RC
    prompt_security_choice
}

sstep_vlessenc() {
    is_stream_protocol || return $SKIP_RC
    [[ "$PROTOCOL" == "vless" ]] || return $SKIP_RC
    prompt_vless_encryption
}

# Remote-side security material (dest/SNI for REALITY, or real-cert domain).
rstep_secmaterial() {
    if [[ "$ENGINE" == "hysteria" ]]; then
        prompt_tls_domain; return $?
    fi
    is_stream_protocol || return $SKIP_RC
    if [[ "$SECURITY" == "tls" ]]; then
        prompt_tls_domain; return $?
    elif [[ "$SECURITY" == "reality" ]]; then
        prompt_reality_dest; return $?
    fi
    return $SKIP_RC
}

# Client-side domain (TLS) prompt used by the local side.
prompt_remote_domain() {
    read -p "Does the Remote Server use a REAL Domain Name for TLS? (y/n) (0=Back): " HAS_REAL_DOMAIN
    [ "$HAS_REAL_DOMAIN" = "0" ] && return $BACK_RC
    if [[ "$HAS_REAL_DOMAIN" == "y" || "$HAS_REAL_DOMAIN" == "Y" ]]; then
        read -p "Enter the Domain Name (0=Back): " LOCAL_SERVER_NAME
        [ "$LOCAL_SERVER_NAME" = "0" ] && return $BACK_RC
        LOCAL_ALLOW_INSECURE="false"
    else
        LOCAL_SERVER_NAME="bing.com"
        LOCAL_ALLOW_INSECURE="true"
    fi
    return 0
}

# Client-side REALITY material (must match the remote's output).
prompt_client_reality() {
    read -p "Enter REALITY serverName/SNI (same as remote) (0=Back): " REALITY_SNI
    [ "$REALITY_SNI" = "0" ] && return $BACK_RC
    read -p "Enter REALITY Public Key (from remote) (0=Back): " REALITY_PUBLIC
    [ "$REALITY_PUBLIC" = "0" ] && return $BACK_RC
    read -p "Enter REALITY shortId (from remote) (0=Back): " REALITY_SHORTID
    [ "$REALITY_SHORTID" = "0" ] && return $BACK_RC
    read -p "Enter uTLS fingerprint [Default: chrome]: " REALITY_FINGERPRINT
    REALITY_FINGERPRINT=${REALITY_FINGERPRINT:-chrome}
    return 0
}

# Local-side security material (TLS domain / REALITY material / VLESS enc str).
lstep_client_material() {
    if [[ "$ENGINE" == "hysteria" ]]; then
        prompt_remote_domain; return $?
    fi
    is_stream_protocol || return $SKIP_RC
    local any=0
    if [[ "$SECURITY" == "tls" ]]; then
        prompt_remote_domain || return $BACK_RC; any=1
    elif [[ "$SECURITY" == "reality" ]]; then
        prompt_client_reality || return $BACK_RC; any=1
    fi
    if [[ "$PROTOCOL" == "vless" && "$VLESS_ENC" == "on" ]]; then
        read -p "Enter VLESS Encryption string (from remote) (0=Back): " VLESS_ENCRYPTION
        [ "$VLESS_ENCRYPTION" = "0" ] && return $BACK_RC
        any=1
    fi
    [ "$any" -eq 0 ] && return $SKIP_RC
    return 0
}

lstep_forward_ports() {
    hint_back
    while true; do
        read -p "Enter ports to forward (comma separated, e.g., 2053,8443): " FORWARD_PORTS
        [ "$FORWARD_PORTS" = "0" ] && return $BACK_RC
        [ -n "$FORWARD_PORTS" ] && break
        echo -e "${RED}You must enter at least one port (or 0 to go back).${NC}"
    done
    return 0
}

# ---------------------------------------------------------------------------
# Top-level actions
# ---------------------------------------------------------------------------

do_remote_setup() {
    ROLE="remote"; reset_state
    echo -e "${GREEN}--- Remote Server Setup ---${NC}"
    echo "This installer is self-contained and does not touch the Sanaei/3x-ui panel."
    ensure_prerequisites
    if ! run_steps step_tunnel_port sstep_protocol sstep_creds \
                    sstep_transmission sstep_security sstep_vlessenc rstep_secmaterial; then
        echo -e "${YELLOW}Setup cancelled - returning to main menu.${NC}"
        return
    fi
    check_port "$TUNNEL_PORT"
    install_core
    create_remote_config
    setup_service
    save_state
    print_remote_summary
}

do_local_setup() {
    ROLE="local"; reset_state
    echo -e "${GREEN}--- Local Server Setup ---${NC}"
    echo "This installer is self-contained and does not touch the Sanaei/3x-ui panel."
    ensure_prerequisites
    if ! run_steps lstep_remote_ip step_tunnel_port sstep_protocol sstep_creds \
                    sstep_transmission sstep_security sstep_vlessenc \
                    lstep_client_material lstep_forward_ports; then
        echo -e "${YELLOW}Setup cancelled - returning to main menu.${NC}"
        return
    fi
    install_core
    create_local_config
    setup_service
    [[ "$ENGINE" == "xray" ]] && setup_forward_service
    save_state
}

# ---------------------------------------------------------------------------
# Edit configuration (role-aware: different fields on Iran vs Foreign side)
# ---------------------------------------------------------------------------

# Generic "keep-or-change" text field. Shows the current value; Enter keeps it,
# 0 cancels (returns 1), anything else overwrites the variable named in $1.
edit_field() {
    local __v="$1" __label="$2" __cur __in
    __cur="${!__v}"
    read -p "$__label [current: ${__cur:-<empty>}] (Enter=keep, 0=cancel): " __in
    [ "$__in" = "0" ] && return 1
    [ -n "$__in" ] && printf -v "$__v" '%s' "$__in"
    return 0
}

edit_tunnel_port() {
    local new
    while true; do
        read -p "Tunnel Port [current: $TUNNEL_PORT] (Enter=keep, 0=cancel): " new
        [ "$new" = "0" ] && return 1
        [ -z "$new" ] && return 0
        if [[ "$new" =~ ^[0-9]+$ ]] && [ "$new" -ge 1 ] && [ "$new" -le 65535 ]; then
            TUNNEL_PORT="$new"; check_port "$TUNNEL_PORT"; return 0
        fi
        echo -e "${RED}Invalid port. Enter 1-65535.${NC}"
    done
}

edit_remote_ip()     { edit_field REMOTE_IP "Remote Server IP"; }
edit_forward_ports() { edit_field FORWARD_PORTS "Forward Ports (comma separated)"; }

# Credentials, with keep-on-Enter semantics (unlike the install steps which
# auto-generate on blank input).
edit_credentials() {
    case "$PROTOCOL" in
        vless|vmess)
            edit_field UUID "UUID" || return 1
            [[ "$PROTOCOL" == "vmess" ]] && { prompt_vmess_security || return 1; }
            ;;
        shadowsocks)
            prompt_ss_method || return 1
            ;;
        trojan|socks|hysteria2)
            edit_field PASSWORD "Password" || return 1
            [[ "$PROTOCOL" == "hysteria2" ]] && { edit_field OBFS_PASS "Obfuscation Password" || return 1; }
            ;;
    esac
    return 0
}

# Transmission edit also re-derives the Vision flow (only valid for VLESS over
# raw TCP with tls/reality and without VLESS Encryption).
edit_transmission() {
    prompt_transmission
    if [[ "$PROTOCOL" == "vless" && "$NETWORK" == "tcp" \
          && ( "$SECURITY" == "tls" || "$SECURITY" == "reality" ) && "$VLESS_ENC" != "on" ]]; then
        FLOW="xtls-rprx-vision"
    else
        FLOW=""
    fi
    return 0
}

edit_reality_dest() {
    edit_field REALITY_DEST "REALITY dest (host:port)" || return 1
    edit_field REALITY_SNI  "REALITY serverName/SNI"   || return 1
    return 0
}

edit_tls_domain_remote() {
    local ans
    read -p "Use a REAL Let's Encrypt certificate? (y/n) [current: ${USE_REAL_SSL:-n}] (0=cancel): " ans
    [ "$ans" = "0" ] && return 1
    [ -n "$ans" ] && USE_REAL_SSL="$ans"
    if [[ "$USE_REAL_SSL" == "y" || "$USE_REAL_SSL" == "Y" ]]; then
        edit_field DOMAIN "Domain Name" || return 1
    fi
    return 0
}

edit_client_reality() {
    edit_field REALITY_SNI         "REALITY serverName/SNI (from remote)" || return 1
    edit_field REALITY_PUBLIC      "REALITY Public Key (from remote)"     || return 1
    edit_field REALITY_SHORTID     "REALITY shortId (from remote)"        || return 1
    edit_field REALITY_FINGERPRINT "uTLS fingerprint"                     || return 1
    return 0
}

edit_remote_domain_local() {
    local ans
    read -p "Does the Remote use a REAL Domain for TLS? (y/n) [current insecure=$LOCAL_ALLOW_INSECURE] (0=cancel): " ans
    [ "$ans" = "0" ] && return 1
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        edit_field LOCAL_SERVER_NAME "Domain Name" || return 1
        LOCAL_ALLOW_INSECURE="false"
    elif [[ "$ans" == "n" || "$ans" == "N" ]]; then
        LOCAL_SERVER_NAME="bing.com"; LOCAL_ALLOW_INSECURE="true"
    fi
    return 0
}

edit_vless_enc_string() { edit_field VLESS_ENCRYPTION "VLESS Encryption string (from remote)"; }

show_config_brief() {
    echo -e "${YELLOW}Current:  role=$ROLE  protocol=$PROTOCOL  port=$TUNNEL_PORT  security=${SECURITY:-none}  network=${NETWORK:-tcp}${NC}"
    [[ "$ROLE" == "local" ]] && \
        echo -e "${YELLOW}          remote_ip=$REMOTE_IP  forward_ports=$FORWARD_PORTS${NC}"
}

apply_remote() {
    echo -e "${GREEN}Applying changes on the Foreign (remote) server...${NC}"
    ensure_core
    create_remote_config
    setup_service
    save_state
    print_remote_summary
}

apply_local() {
    echo -e "${GREEN}Applying changes on the Iran (local) server...${NC}"
    ensure_core
    create_local_config
    setup_service
    if [[ "$ENGINE" == "xray" ]]; then
        setup_forward_service
    else
        systemctl stop "$FWD_SERVICE" 2>/dev/null
        systemctl disable "$FWD_SERVICE" 2>/dev/null
        [ -f "$CONF_DIR/forward-down.sh" ] && bash "$CONF_DIR/forward-down.sh" 2>/dev/null
    fi
    save_state
    echo -e "${GREEN}Local configuration updated.${NC}"
}

# Confirm before discarding unapplied edits. Returns 0 when it is OK to leave.
confirm_discard() {
    local d
    [ "$1" -eq 0 ] && return 0
    read -p "You have unapplied changes. Discard them and go back? (y/n): " d
    [[ "$d" == "y" || "$d" == "Y" ]]
}

# --- Foreign (remote) side: no forward ports, no remote IP -----------------
edit_remote() {
    local dirty=0 e
    while true; do
        echo
        echo -e "${GREEN}--- Edit Foreign (Remote) Configuration ---${NC}"
        show_config_brief
        echo "1) Tunnel Port"
        echo "2) Protocol (re-configure protocol + credentials + transmission + security)"
        echo "3) Credentials"
        is_stream_protocol && echo "4) Transmission (network)"
        is_stream_protocol && echo "5) Security (+ material)"
        [[ "$SECURITY" == "reality" ]] && echo "6) REALITY dest / SNI"
        [[ "$SECURITY" == "reality" ]] && echo "7) Regenerate REALITY keypair"
        { [[ "$SECURITY" == "tls" ]] || [[ "$ENGINE" == "hysteria" ]]; } && echo "8) TLS certificate / domain"
        echo -e "${GREEN}a) Apply changes (regenerate config + restart)${NC}"
        echo "0) Back to main menu"
        read -p "Select: " e
        case "$e" in
            1) edit_tunnel_port && dirty=1 ;;
            2) run_steps sstep_protocol sstep_creds sstep_transmission sstep_security rstep_secmaterial; dirty=1 ;;
            3) edit_credentials && dirty=1 ;;
            4) if is_stream_protocol; then edit_transmission; dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
            5) if is_stream_protocol; then run_steps sstep_security rstep_secmaterial; dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
            6) if [[ "$SECURITY" == "reality" ]]; then edit_reality_dest && dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
            7) if [[ "$SECURITY" == "reality" ]]; then REALITY_PRIVATE=""; REALITY_PUBLIC=""; echo -e "${YELLOW}A fresh keypair will be generated on Apply (update the Iran side afterwards).${NC}"; dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
            8) if [[ "$SECURITY" == "tls" || "$ENGINE" == "hysteria" ]]; then edit_tls_domain_remote && dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
            a|A) apply_remote; dirty=0 ;;
            0) confirm_discard "$dirty" && return ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

# --- Iran (local) side: has remote IP + forward ports, client-side material -
edit_local() {
    local dirty=0 e
    while true; do
        echo
        echo -e "${GREEN}--- Edit Iran (Local) Configuration ---${NC}"
        show_config_brief
        echo "1) Remote Server IP"
        echo "2) Tunnel Port"
        echo "3) Protocol (re-configure protocol + credentials + transmission + security)"
        echo "4) Credentials"
        is_stream_protocol && echo "5) Transmission (network)"
        is_stream_protocol && echo "6) Security (+ client material)"
        [[ "$SECURITY" == "reality" ]] && echo "7) REALITY client material (SNI / PublicKey / shortId / fingerprint)"
        { [[ "$SECURITY" == "tls" ]] || [[ "$ENGINE" == "hysteria" ]]; } && echo "8) Remote TLS domain"
        [[ "$PROTOCOL" == "vless" && "$VLESS_ENC" == "on" ]] && echo "9) VLESS Encryption string"
        echo "10) Forward Ports"
        echo -e "${GREEN}a) Apply changes (regenerate config + restart)${NC}"
        echo "0) Back to main menu"
        read -p "Select: " e
        case "$e" in
            1) edit_remote_ip && dirty=1 ;;
            2) edit_tunnel_port && dirty=1 ;;
            3) run_steps sstep_protocol sstep_creds sstep_transmission sstep_security sstep_vlessenc lstep_client_material; dirty=1 ;;
            4) edit_credentials && dirty=1 ;;
            5) if is_stream_protocol; then edit_transmission; dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
            6) if is_stream_protocol; then run_steps sstep_security sstep_vlessenc lstep_client_material; dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
            7) if [[ "$SECURITY" == "reality" ]]; then edit_client_reality && dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
            8) if [[ "$SECURITY" == "tls" || "$ENGINE" == "hysteria" ]]; then edit_remote_domain_local && dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
            9) if [[ "$PROTOCOL" == "vless" && "$VLESS_ENC" == "on" ]]; then edit_vless_enc_string && dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
            10) edit_forward_ports && dirty=1 ;;
            a|A) apply_local; dirty=0 ;;
            0) confirm_discard "$dirty" && return ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
    done
}

do_edit() {
    if ! load_state; then
        echo -e "${RED}No saved configuration found at $CONF_DIR/wild.conf.${NC}"
        echo "Editing is available only for tunnels installed with this version."
        echo "Please reinstall once (option 1 or 2); afterwards editing will work."
        return
    fi
    case "$ROLE" in
        remote) edit_remote ;;
        local)  edit_local ;;
        *) echo -e "${RED}Saved state has an unknown role ('$ROLE'). Cannot edit.${NC}" ;;
    esac
}

do_uninstall() {
    echo -e "${RED}Uninstalling Wild Tunnel...${NC}"
    systemctl stop "$FWD_SERVICE" 2>/dev/null
    systemctl disable "$FWD_SERVICE" 2>/dev/null
    [ -f "$CONF_DIR/forward-down.sh" ] && bash "$CONF_DIR/forward-down.sh" 2>/dev/null
    rm -f /etc/systemd/system/${FWD_SERVICE}.service
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
    systemctl reset-failed "$FWD_SERVICE" 2>/dev/null
    echo -e "${GREEN}Uninstallation complete.${NC}"
    echo "Note: the Sanaei/3x-ui panel (if installed) was not touched."
}

# ---------------------------------------------------------------------------
# Main menu (loops until Exit)
# ---------------------------------------------------------------------------

main_menu() {
    while true; do
        show_banner
        echo "1) Install Remote Server (Foreign - Receiver)"
        echo "2) Install Local Server (Iran - Forwarder)"
        echo "3) Edit Configuration"
        echo "4) Uninstall Wild Tunnel"
        echo "5) Exit"
        read -p "Select an option [1-5]: " role_option
        case "$role_option" in
            1) do_remote_setup ;;
            2) do_local_setup ;;
            3) do_edit ;;
            4) do_uninstall ;;
            5) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid option selected.${NC}" ;;
        esac
        echo
        read -p "Press Enter to return to the main menu..." _
    done
}

main_menu
