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

# Configurations contain credentials, certificate material and private keys.
# Keep every generated file private unless a broader mode is explicitly needed.
umask 077
set -o pipefail

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[1;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Pinned core versions
XRAY_VERSION="v26.3.27"
HYSTERIA_VERSION="v2.9.3"
TUN2SOCKS_VERSION="v2.7.0"
XRAY_SHA256="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
HYSTERIA_SHA256="66dbdb0608f25f3057b433afe975a9fc1af2ca8e512479e294988b3ef363d6c1"
TUN2SOCKS_SHA256="a612baa287a3b6de6221f74fd02b442a50888508227ecf51e1288a5ccbb77381"

# Paths
CORE_DIR="/usr/local/bin/wild-xray"
CONF_DIR="/etc/wild-tunnel"
SERVICE="wild-tunnel"
FWD_SERVICE="wild-forward"
CRON_TAG="# wild-tunnel-restart"
BBR_MODULE_FILE="/etc/modules-load.d/wild-tunnel-bbr.conf"

# Local port-forwarding (Xray engine) settings
SOCKS_PORT="10808"            # local-only SOCKS inbound that tun2socks feeds
TUN_NAME="wildtun0"           # TUN device created on the local (Iran) side
TUN_ADDR="198.18.0.1"         # address assigned to the TUN device
TUN_CIDR="15"                 # 198.18.0.0/15 (RFC 2544 benchmarking range)
SENTINEL_IP="198.18.0.2"      # DNAT target routed into the TUN (ignored by remote)
TUN_MTU="1500"               # explicit netstack MTU
TUN_TXQLEN="10000"          # absorb upload bursts before userspace drains the TUN
TUN_TCP_RCVBUF="4m"          # tun2socks upload-side receive window
HYSTERIA_BBR_PROFILE="aggressive" # local/client upload congestion profile

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

verify_sha256() {
    local file="$1" expected="$2" actual
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    [[ -n "$actual" && "$actual" == "$expected" ]] || {
        rm -f -- "$file"
        die "SHA-256 verification failed for a downloaded asset"
    }
}

download_verified() {
    local url="$1" expected="$2" output="$3"
    wget --https-only --timeout=30 --tries=3 -qO "$output" "$url" || {
        rm -f -- "$output"
        die "Failed to download $url"
    }
    verify_sha256 "$output" "$expected"
}

# ---------------------------------------------------------------------------
# Interactive navigation helpers (step-by-step Back with "0")
# ---------------------------------------------------------------------------
BACK_RC=10   # a step returns this when the user pressed 0 (Back)
SKIP_RC=20   # a step returns this when it does not apply in the current context

# Big symbolic banner shown at the top of every menu.
show_banner() {
    clear 2>/dev/null
    echo -e "${CYAN}"
    cat <<'BANNER'
   ██╗    ██╗██╗██╗     ██████╗
   ██║    ██║██║██║     ██╔══██╗
   ██║ █╗ ██║██║██║     ██║  ██║
   ██║███╗██║██║██║     ██║  ██║
   ╚███╔███╔╝██║███████╗██████╔╝
    ╚══╝╚══╝ ╚═╝╚══════╝╚═════╝
   ████████╗██╗   ██╗███╗   ██╗███╗   ██╗███████╗██╗
   ╚══██╔══╝██║   ██║████╗  ██║████╗  ██║██╔════╝██║
      ██║   ██║   ██║██╔██╗ ██║██╔██╗ ██║█████╗  ██║
      ██║   ██║   ██║██║╚██╗██║██║╚██╗██║██╔══╝  ██║
      ██║   ╚██████╔╝██║ ╚████║██║ ╚████║███████╗███████╗
      ╚═╝    ╚═════╝ ╚═╝  ╚═══╝╚═╝  ╚═══╝╚══════╝╚══════╝
BANNER
    echo -e "${NC}"
    echo -e "${BOLD}${YELLOW}        «  W I L D   T U N N E L   ·   V 1  »${NC}"
    echo -e "${GREEN}     GitHub: ${NC}${BOLD}https://github.com/infowild/Wild-Tunnel-V1${NC}"
    echo -e "${CYAN}   ────────────────────────────────────────────────────────${NC}"
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
    [[ $(id -u) -eq 0 ]] || die "Run this installer as root"
    [[ $(uname -m) == "x86_64" ]] || die "This release currently supports x86_64/amd64 only"
    command -v systemctl >/dev/null 2>&1 || die "systemd is required"
    command -v apt-get >/dev/null 2>&1 || die "Ubuntu/Debian with apt-get is required"
    echo -e "${GREEN}Updating package lists and installing prerequisites...${NC}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q || die "apt-get update failed"
    apt-get install -y unzip uuid-runtime jq openssl wget ca-certificates iproute2 iptables cron python3 python3-yaml \
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
    local archive extract_dir
    archive=$(mktemp) || die "Could not create a temporary download file"
    extract_dir=$(mktemp -d) || { rm -f -- "$archive"; die "Could not create a temporary extraction directory"; }
    mkdir -p "$CORE_DIR" "$CONF_DIR"
    download_verified "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" "$XRAY_SHA256" "$archive"
    unzip -qo "$archive" -d "$extract_dir/" || { rm -f -- "$archive"; rm -rf -- "$extract_dir"; die "Failed to extract Xray core"; }
    [ -f "$extract_dir/xray" ] || { rm -f -- "$archive"; rm -rf -- "$extract_dir"; die "Xray binary is missing from the release archive"; }
    install -m 0755 "$extract_dir/xray" "$CORE_DIR/xray" || { rm -f -- "$archive"; rm -rf -- "$extract_dir"; die "Failed to install Xray core"; }
    rm -f -- "$archive"
    rm -rf -- "$extract_dir"
    [ -x "$CORE_DIR/xray" ] || die "Xray binary is missing after installation"
}

install_hysteria() {
    echo -e "${GREEN}Installing Hysteria2 core (${HYSTERIA_VERSION})...${NC}"
    local binary
    binary=$(mktemp) || die "Could not create a temporary download file"
    mkdir -p "$CORE_DIR" "$CONF_DIR"
    download_verified "https://github.com/apernet/hysteria/releases/download/app/${HYSTERIA_VERSION}/hysteria-linux-amd64" "$HYSTERIA_SHA256" "$binary"
    install -m 0755 "$binary" "$CORE_DIR/hysteria" || { rm -f -- "$binary"; die "Failed to install Hysteria2 core"; }
    rm -f -- "$binary"
    [ -x "$CORE_DIR/hysteria" ] || die "Hysteria binary is missing after installation"
}

install_tun2socks() {
    # Already present (e.g. during an edit/apply): keep the verified pinned binary.
    [ -x "$CORE_DIR/tun2socks" ] && return 0
    local archive extract_dir source_binary
    archive=$(mktemp) || die "Could not create a temporary download file"
    extract_dir=$(mktemp -d) || { rm -f -- "$archive"; die "Could not create a temporary extraction directory"; }
    echo -e "${GREEN}Installing tun2socks (${TUN2SOCKS_VERSION})...${NC}"
    mkdir -p "$CORE_DIR"
    download_verified "https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_VERSION}/tun2socks-linux-amd64.zip" "$TUN2SOCKS_SHA256" "$archive"
    unzip -qo "$archive" -d "$extract_dir/" || { rm -f -- "$archive"; rm -rf -- "$extract_dir"; die "Failed to extract tun2socks"; }
    source_binary="$extract_dir/tun2socks-linux-amd64"
    [ -f "$source_binary" ] || { rm -f -- "$archive"; rm -rf -- "$extract_dir"; die "tun2socks binary is missing from the release archive"; }
    install -m 0755 "$source_binary" "$CORE_DIR/tun2socks" || { rm -f -- "$archive"; rm -rf -- "$extract_dir"; die "Failed to install tun2socks"; }
    rm -f -- "$archive"
    rm -rf -- "$extract_dir"
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
    local exec_cmd unit_tmp
    if [[ "$ENGINE" == "hysteria" ]]; then
        if [[ "$ROLE" == "remote" ]]; then
            exec_cmd="$CORE_DIR/hysteria server -c $CONF_DIR/config.yaml"
        else
            exec_cmd="$CORE_DIR/hysteria client -c $CONF_DIR/config.yaml"
        fi
    else
        exec_cmd="$CORE_DIR/xray run -config $CONF_DIR/config.json"
    fi

    unit_tmp=$(mktemp) || die "Could not create a temporary systemd unit"
    cat <<EOF > "$unit_tmp"
[Unit]
Description=Wild Tunnel Service
Documentation=https://github.com/infowild/Wild-Tunnel-V1
Wants=network-online.target
After=network-online.target nss-lookup.target

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$CONF_DIR
UMask=0077
ExecStart=$exec_cmd
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 "$unit_tmp" /etc/systemd/system/${SERVICE}.service || {
        rm -f -- "$unit_tmp"
        die "Failed to install systemd unit"
    }
    rm -f -- "$unit_tmp"

    systemctl daemon-reload || die "systemd daemon-reload failed"
    systemctl enable "$SERVICE" || die "Could not enable $SERVICE"
    if ! systemctl restart "$SERVICE" || ! systemctl is-active --quiet "$SERVICE"; then
        journalctl -u "$SERVICE" -n 30 --no-pager >&2
        die "$SERVICE failed to start"
    fi
    echo -e "${GREEN}Wild Tunnel started successfully!${NC}"
    systemctl status "$SERVICE" --no-pager | head -n 10
    install_shortcut
}

remove_cron() {
    local current
    current=$(crontab -l 2>/dev/null || true)
    { printf '%s\n' "$current" | grep -vF "$CRON_TAG" || true; } | crontab - || die "Could not update root crontab"
}

schedule_restart() {
    local choice expr current
    echo "Schedule automatic restart:"
    echo "1) Every 6 hours"
    echo "2) Every 12 hours"
    echo "3) Every day at 04:00"
    echo "4) Custom cron expression"
    read -p "Choice [1-4]: " choice
    case $choice in
        1) expr="0 */6 * * *" ;;
        2) expr="0 */12 * * *" ;;
        3) expr="0 4 * * *" ;;
        4) read -p "Enter cron expression: " expr ;;
        *) echo -e "${RED}Invalid choice.${NC}"; return 1 ;;
    esac
    [[ -n "$expr" && "$expr" =~ ^[0-9A-Za-z*/?,[:space:]-]+$ ]] || {
        echo -e "${RED}Invalid cron expression.${NC}"
        return 1
    }
    current=$(crontab -l 2>/dev/null || true)
    {
        printf '%s\n' "$current" | grep -vF "$CRON_TAG" || true
        printf '%s systemctl restart %s %s\n' "$expr" "$SERVICE" "$CRON_TAG"
    } | crontab - || die "Could not install restart schedule"
    echo -e "${GREEN}Scheduled: '$expr' -> restart $SERVICE${NC}"
}

install_shortcut() {
    # Build the installed manager from the functions in this exact verified
    # installer, so the wild command cannot drift from edit/install behavior.
    local manager_dir="/usr/local/lib/wild-tunnel"
    local manager="$manager_dir/manager.sh" manager_tmp wrapper_tmp var
    local -a manager_vars=(
        GREEN RED YELLOW CYAN BOLD NC
        XRAY_VERSION HYSTERIA_VERSION TUN2SOCKS_VERSION
        XRAY_SHA256 HYSTERIA_SHA256 TUN2SOCKS_SHA256
        CORE_DIR CONF_DIR SERVICE FWD_SERVICE CRON_TAG BBR_MODULE_FILE
        SOCKS_PORT TUN_NAME TUN_ADDR TUN_CIDR SENTINEL_IP
        TUN_MTU TUN_TXQLEN TUN_TCP_RCVBUF HYSTERIA_BBR_PROFILE
        BACK_RC SKIP_RC
    )
    mkdir -p "$manager_dir"
    chmod 700 "$manager_dir"
    manager_tmp=$(mktemp "$manager_dir/.manager.XXXXXX") || die "Could not create manager script"
    {
        echo '#!/bin/bash'
        echo 'umask 077'
        echo 'set -o pipefail'
        for var in "${manager_vars[@]}"; do
            printf '%s=%q\n' "$var" "${!var}"
        done
        declare -f
        echo
        echo 'main_menu'
    } > "$manager_tmp"
    install -m 0700 "$manager_tmp" "$manager" || {
        rm -f -- "$manager_tmp"
        die "Could not install management script"
    }
    rm -f -- "$manager_tmp"

    wrapper_tmp=$(mktemp) || die "Could not create command wrapper"
    cat <<'WILDCMD' > "$wrapper_tmp"
#!/bin/bash
exec /usr/local/lib/wild-tunnel/manager.sh "$@"
WILDCMD
    install -m 0755 "$wrapper_tmp" /usr/local/bin/wild || {
        rm -f -- "$wrapper_tmp"
        die "Could not install wild command"
    }
    rm -f -- "$wrapper_tmp"
    echo -e "${GREEN}Shortcut installed: run 'wild' to manage or edit the tunnel.${NC}"
}

generate_uuid() {
    uuidgen
}

generate_password() {
    # Exactly 16 printable hexadecimal characters, without a truncating pipeline
    # that would fail under pipefail because of SIGPIPE.
    openssl rand -hex 8
}

cert_sha256() {
    # OpenSSL's colon-separated form is accepted by both Xray and Hysteria.
    openssl x509 -noout -fingerprint -sha256 -in "$1" 2>/dev/null |
        sed 's/.*=//'
}

normalize_cert_pin() {
    local compact="${1//:/}" output=""
    [[ "$compact" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    compact="${compact^^}"
    while [ -n "$compact" ]; do
        output="${output:+$output:}${compact:0:2}"
        compact="${compact:2}"
    done
    printf '%s\n' "$output"
}

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
    while true; do
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
            *) echo -e "${RED}Invalid choice.${NC}"; continue;;
        esac

        # Xray's compatibility matrix does not support REALITY over WebSocket
        # or HTTPUpgrade. Refuse the combination before any config is written.
        if [[ "$SECURITY" == "reality" && ( "$NETWORK" == "ws" || "$NETWORK" == "httpupgrade" ) ]]; then
            echo -e "${RED}REALITY is not supported with $NETWORK. Choose TLS, or go back and select tcp/grpc.${NC}"
            continue
        fi
        break
    done

    if [[ "$SECURITY" == "none" && ( "$NETWORK" == "http" || "$NETWORK" == "grpc" ) ]]; then
        echo -e "${YELLOW}Note: '$NETWORK' transmission normally needs tls or reality; 'none' may fail to connect.${NC}"
    fi

    if [[ "$SECURITY" == "none" ]]; then
        echo -e "${YELLOW}Warning: without tls/reality the tunnel is fingerprintable; Iran's DPI drops its return traffic. REALITY is recommended.${NC}"
    elif [[ "$PROTOCOL" == "shadowsocks" || "$PROTOCOL" == "socks" ]]; then
        echo -e "${YELLOW}Note: with tls/reality, $PROTOCOL forwards TCP only; local UDP is disabled to prevent an unmasked native-UDP leak.${NC}"
    fi

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

remove_xray_bbr() {
    rm -f -- "$BBR_MODULE_FILE"
}

configure_xray_bbr() {
    local tmp available
    command -v modprobe >/dev/null 2>&1 || return 0
    modprobe tcp_bbr >/dev/null 2>&1 || { remove_xray_bbr; return 0; }
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    if [[ " $available " != *" bbr "* ]]; then
        remove_xray_bbr
        return 0
    fi
    tmp=$(mktemp) || die "Could not create temporary BBR module configuration"
    printf '%s\n' tcp_bbr > "$tmp"
    install -m 0644 "$tmp" "$BBR_MODULE_FILE" || {
        rm -f -- "$tmp"
        die "Could not persist the BBR kernel module"
    }
    rm -f -- "$tmp"
}

preferred_tcp_congestion() {
    local available
    available=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)
    [[ " $available " == *" bbr "* ]] && printf '%s\n' bbr
}

# streamSettings inner JSON. $1 = remote|local
stream_json() {
    local role="$1"
    local parts=()
    parts+=("\"network\": $(json_quote "$NETWORK")")

    case "$NETWORK" in
        ws)
            local ws="\"path\": $(json_quote "$WS_PATH")"
            [ -n "$HTTP_HOST" ] && ws="$ws, \"headers\": { \"Host\": $(json_quote "$HTTP_HOST") }"
            parts+=("\"wsSettings\": { $ws }")
            ;;
        httpupgrade)
            local hu="\"path\": $(json_quote "$WS_PATH")"
            [ -n "$HTTP_HOST" ] && hu="$hu, \"host\": $(json_quote "$HTTP_HOST")"
            parts+=("\"httpupgradeSettings\": { $hu }")
            ;;
        grpc)
            parts+=("\"grpcSettings\": { \"serviceName\": $(json_quote "$GRPC_SERVICE") }")
            ;;
        http)
            local http="\"path\": $(json_quote "$HTTP_PATH")"
            [ -n "$HTTP_HOST" ] && http="$http, \"host\": [ $(json_quote "$HTTP_HOST") ]"
            parts+=("\"httpSettings\": { $http }")
            ;;
    esac

    # Apply BBR only to the local outbound tunnel socket when supported.
    # This targets upload without changing the host-wide congestion controller.
    if [[ "$role" == "local" ]]; then
        local tcp_cc
        tcp_cc=$(preferred_tcp_congestion)
        [ -n "$tcp_cc" ] && parts+=("\"sockopt\": { \"tcpcongestion\": $(json_quote "$tcp_cc") }")
    fi

    case "$SECURITY" in
        tls)
            parts+=("\"security\": \"tls\"")
            if [[ "$role" == "remote" ]]; then
                parts+=("\"tlsSettings\": { \"certificates\": [ { \"certificateFile\": $(json_quote "$CERT_FILE"), \"keyFile\": $(json_quote "$KEY_FILE") } ] }")
            else
                local tls_local="\"serverName\": $(json_quote "$LOCAL_SERVER_NAME")"
                [ -n "$LOCAL_PINNED_SHA" ] && tls_local="$tls_local, \"pinnedPeerCertSha256\": $(json_quote "$LOCAL_PINNED_SHA")"
                parts+=("\"tlsSettings\": { $tls_local }")
            fi
            ;;
        reality)
            parts+=("\"security\": \"reality\"")
            if [[ "$role" == "remote" ]]; then
                parts+=("\"realitySettings\": { \"show\": false, \"dest\": $(json_quote "$REALITY_DEST"), \"serverNames\": [ $(json_quote "$REALITY_SNI") ], \"privateKey\": $(json_quote "$REALITY_PRIVATE"), \"shortIds\": [ $(json_quote "$REALITY_SHORTID") ] }")
            else
                parts+=("\"realitySettings\": { \"serverName\": $(json_quote "$REALITY_SNI"), \"fingerprint\": $(json_quote "$REALITY_FINGERPRINT"), \"publicKey\": $(json_quote "$REALITY_PUBLIC"), \"shortId\": $(json_quote "$REALITY_SHORTID") }")
            fi
            ;;
        *)
            parts+=("\"security\": \"none\"")
            ;;
    esac

    local IFS=","
    echo "${parts[*]}"
}

remote_settings() {
    case "$PROTOCOL" in
        vless)
            local client="\"id\": $(json_quote "$UUID"), \"level\": 0"
            [ -n "$FLOW" ] && client="$client, \"flow\": $(json_quote "$FLOW")"
            echo "\"clients\": [ { $client } ], \"decryption\": $(json_quote "$VLESS_DECRYPTION")"
            ;;
        vmess)
            echo "\"clients\": [ { \"id\": $(json_quote "$UUID"), \"alterId\": 0 } ]"
            ;;
        trojan)
            echo "\"clients\": [ { \"password\": $(json_quote "$PASSWORD") } ]"
            ;;
        shadowsocks)
            local ss_net="tcp,udp"
            [[ "$SECURITY" != "none" ]] && ss_net="tcp"
            echo "\"method\": $(json_quote "$SS_METHOD"), \"password\": $(json_quote "$PASSWORD"), \"network\": $(json_quote "$ss_net")"
            ;;
        socks)
            local socks_udp="true"
            [[ "$SECURITY" != "none" ]] && socks_udp="false"
            echo "\"auth\": \"password\", \"accounts\": [ { \"user\": \"tunnel\", \"pass\": $(json_quote "$PASSWORD") } ], \"udp\": $socks_udp"
            ;;
    esac
}

local_settings() {
    case "$PROTOCOL" in
        vless)
            local user="\"id\": $(json_quote "$UUID"), \"encryption\": $(json_quote "$VLESS_ENCRYPTION"), \"level\": 0"
            [ -n "$FLOW" ] && user="$user, \"flow\": $(json_quote "$FLOW")"
            echo "\"vnext\": [ { \"address\": $(json_quote "$REMOTE_IP"), \"port\": $TUNNEL_PORT, \"users\": [ { $user } ] } ]"
            ;;
        vmess)
            echo "\"vnext\": [ { \"address\": $(json_quote "$REMOTE_IP"), \"port\": $TUNNEL_PORT, \"users\": [ { \"id\": $(json_quote "$UUID"), \"security\": $(json_quote "$VMESS_SECURITY"), \"level\": 0 } ] } ]"
            ;;
        trojan)
            echo "\"servers\": [ { \"address\": $(json_quote "$REMOTE_IP"), \"port\": $TUNNEL_PORT, \"password\": $(json_quote "$PASSWORD") } ]"
            ;;
        shadowsocks)
            echo "\"servers\": [ { \"address\": $(json_quote "$REMOTE_IP"), \"port\": $TUNNEL_PORT, \"password\": $(json_quote "$PASSWORD"), \"method\": $(json_quote "$SS_METHOD") } ]"
            ;;
        socks)
            echo "\"servers\": [ { \"address\": $(json_quote "$REMOTE_IP"), \"port\": $TUNNEL_PORT, \"users\": [ { \"user\": \"tunnel\", \"pass\": $(json_quote "$PASSWORD") } ] } ]"
            ;;
    esac
}

# Protocols that can carry a transport (ws/grpc/...) and a security layer
# (tls/reality). Shadowsocks and Socks are included: Xray supports streamSettings
# for them over TCP, and without camouflage Iran's DPI drops the tunnel's return
# traffic (proven 2026-07-17 with a two-sided capture). Both tunnel ends are
# Xray, so compatibility with stock Shadowsocks clients does not matter here.
is_stream_protocol() {
    [[ "$PROTOCOL" == "vless" || "$PROTOCOL" == "vmess" || "$PROTOCOL" == "trojan" \
       || "$PROTOCOL" == "shadowsocks" || "$PROTOCOL" == "socks" ]]
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
        CERT_SHA256=""   # a real certificate validates normally; no pin needed

        # Reload the tunnel after every automatic certificate renewal.
        mkdir -p /etc/letsencrypt/renewal-hooks/deploy
        cat <<'HOOK' > /etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh
#!/bin/bash
systemctl restart wild-tunnel
HOOK
        chmod +x /etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh
    else
        CERT_FILE="$CONF_DIR/cert.crt"
        KEY_FILE="$CONF_DIR/private.key"
        SERVER_NAME="bing.com"
        ALLOW_INSECURE="true"
        # Xray certificate pinning requires a leaf certificate (CA:FALSE). Keep a
        # compatible existing leaf to preserve its pin; migrate older CA-style
        # self-signed certificates and print the new pin in the summary.
        local reuse_cert=false
        if [ -f "$CERT_FILE" ] && [ -f "$KEY_FILE" ]; then
            reuse_cert=true
            if [[ "$ENGINE" == "xray" ]] && ! openssl x509 -in "$CERT_FILE" -noout -text 2>/dev/null | grep -q 'CA:FALSE'; then
                reuse_cert=false
                echo -e "${YELLOW}Replacing an old CA-style self-signed certificate with a TLS leaf certificate; update the local pin.${NC}"
            fi
        fi
        if [ "$reuse_cert" = true ]; then
            echo -e "${GREEN}Reusing the existing self-signed certificate (keeps its pin stable).${NC}"
        else
            echo -e "${GREEN}Generating a self-signed TLS leaf certificate...${NC}"
            openssl ecparam -genkey -name prime256v1 -out "$KEY_FILE" \
                || die "Failed to generate private key"
            openssl req -new -x509 -days 3650 -key "$KEY_FILE" -out "$CERT_FILE" \
                -subj "/CN=$SERVER_NAME" \
                -addext "basicConstraints=critical,CA:FALSE" \
                -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
                -addext "extendedKeyUsage=serverAuth" \
                -addext "subjectAltName=DNS:$SERVER_NAME" >/dev/null 2>&1 \
                || die "Failed to generate self-signed certificate"
        fi
        chmod 600 "$KEY_FILE" "$CERT_FILE" || die "Could not secure certificate files"
        CERT_SHA256=$(cert_sha256 "$CERT_FILE")
        [ -n "$CERT_SHA256" ] || die "Could not compute the certificate SHA-256 fingerprint"
    fi
}

# ---------------------------------------------------------------------------
# Config generation
# ---------------------------------------------------------------------------

json_quote() {
    jq -Rn --arg value "$1" '$value'
}

yaml_quote() {
    # JSON quoted scalars are valid YAML and safely preserve punctuation.
    json_quote "$1"
}

validate_yaml_file() {
    python3 - "$1" <<'PY'
import sys
import yaml
with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
if not isinstance(data, dict):
    raise SystemExit("configuration root must be a mapping")
PY
}

install_private_config() {
    local source="$1" destination="$2" stale="$3"
    install -m 0600 "$source" "$destination" || {
        rm -f -- "$source"
        die "Failed to install validated configuration"
    }
    rm -f -- "$source" "$stale"
}

create_remote_hysteria() {
    local output="$1"
    cat <<EOF > "$output"
listen: $(yaml_quote ":$TUNNEL_PORT")

tls:
  cert: $(yaml_quote "$CERT_FILE")
  key: $(yaml_quote "$KEY_FILE")

auth:
  type: password
  password: $(yaml_quote "$PASSWORD")

obfs:
  type: salamander
  salamander:
    password: $(yaml_quote "$OBFS_PASS")
EOF
}

create_remote_config() {
    local tmp settings stream
    if [[ "$ENGINE" == "hysteria" ]]; then
        make_certs
        tmp=$(mktemp "$CONF_DIR/.config.XXXXXX.yaml") || die "Could not create a temporary config"
        create_remote_hysteria "$tmp"
        validate_yaml_file "$tmp" || { rm -f -- "$tmp"; die "Generated Hysteria YAML is invalid"; }
        install_private_config "$tmp" "$CONF_DIR/config.yaml" "$CONF_DIR/config.json"
        return
    fi

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

    settings=$(remote_settings)
    if is_stream_protocol; then
        stream=$(stream_json remote)
    else
        stream='"network": "tcp", "security": "none"'
    fi

    tmp=$(mktemp "$CONF_DIR/.config.XXXXXX.json") || die "Could not create a temporary config"
    cat <<EOF > "$tmp"
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
    jq -e . "$tmp" >/dev/null || { rm -f -- "$tmp"; die "Generated Xray JSON is invalid"; }
    "$CORE_DIR/xray" run -test -config "$tmp" >/dev/null 2>&1 || {
        "$CORE_DIR/xray" run -test -config "$tmp" >&2
        rm -f -- "$tmp"
        die "Xray rejected the generated remote configuration"
    }
    install_private_config "$tmp" "$CONF_DIR/config.json" "$CONF_DIR/config.yaml"
}

create_local_hysteria() {
    local output="$1"
    local sni="${LOCAL_SERVER_NAME:-bing.com}"
    local insecure="${LOCAL_ALLOW_INSECURE:-true}"
    local pin="${LOCAL_PINNED_SHA:-}" pin_line=""
    local bbr_profile="${HYSTERIA_BBR_PROFILE:-aggressive}"
    [ -n "$pin" ] && pin_line="  pinSHA256: $(yaml_quote "$pin")"
    [[ "$bbr_profile" == "aggressive" || "$bbr_profile" == "standard" || "$bbr_profile" == "conservative" ]] ||
        die "Invalid Hysteria BBR profile in saved state"

    cat <<EOF > "$output"
server: $(yaml_quote "$REMOTE_IP:$TUNNEL_PORT")

auth: $(yaml_quote "$PASSWORD")

tls:
  sni: $(yaml_quote "$sni")
  insecure: $insecure
$pin_line

obfs:
  type: salamander
  salamander:
    password: $(yaml_quote "$OBFS_PASS")

congestion:
  type: bbr
  bbrProfile: $(yaml_quote "$bbr_profile")

tcpForwarding:
EOF

    IFS=',' read -ra PORT_ARRAY <<< "$FORWARD_PORTS"
    for port in "${PORT_ARRAY[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        [ -z "$port" ] && continue
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || {
            rm -f -- "$output"
            die "Invalid forward port: $port"
        }
        check_port "$port"
        cat <<EOF >> "$output"
  - listen: $(yaml_quote "0.0.0.0:$port")
    remote: $(yaml_quote "127.0.0.1:$port")
EOF
    done

    echo "" >> "$output"
    echo "udpForwarding:" >> "$output"
    for port in "${PORT_ARRAY[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        [ -z "$port" ] && continue
        cat <<EOF >> "$output"
  - listen: $(yaml_quote "0.0.0.0:$port")
    remote: $(yaml_quote "127.0.0.1:$port")
EOF
    done
}

create_local_config() {
    local tmp settings stream local_udp=true

    if [[ "$ENGINE" == "xray" ]]; then
        configure_xray_bbr
    else
        remove_xray_bbr
    fi

    if [ -n "$LOCAL_PINNED_SHA" ]; then
        LOCAL_PINNED_SHA=$(normalize_cert_pin "$LOCAL_PINNED_SHA") ||
            die "Invalid SHA256 certificate pin in saved state"
    fi

    if [[ "$ENGINE" == "hysteria" ]]; then
        tmp=$(mktemp "$CONF_DIR/.config.XXXXXX.yaml") || die "Could not create a temporary config"
        create_local_hysteria "$tmp"
        validate_yaml_file "$tmp" || { rm -f -- "$tmp"; die "Generated Hysteria YAML is invalid"; }
        install_private_config "$tmp" "$CONF_DIR/config.yaml" "$CONF_DIR/config.json"
        return
    fi

    settings=$(local_settings)
    if is_stream_protocol; then
        stream=$(stream_json local)
    else
        stream='"network": "tcp", "security": "none"'
    fi
    if [[ "$SECURITY" != "none" && ( "$PROTOCOL" == "shadowsocks" || "$PROTOCOL" == "socks" ) ]]; then
        local_udp=false
    fi

    tmp=$(mktemp "$CONF_DIR/.config.XXXXXX.json") || die "Could not create a temporary config"
    cat <<EOF > "$tmp"
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": $SOCKS_PORT,
      "protocol": "socks",
      "settings": { "auth": "noauth", "udp": $local_udp },
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
    jq -e . "$tmp" >/dev/null || { rm -f -- "$tmp"; die "Generated Xray JSON is invalid"; }
    "$CORE_DIR/xray" run -test -config "$tmp" >/dev/null 2>&1 || {
        "$CORE_DIR/xray" run -test -config "$tmp" >&2
        rm -f -- "$tmp"
        die "Xray rejected the generated local configuration"
    }
    install_private_config "$tmp" "$CONF_DIR/config.json" "$CONF_DIR/config.yaml"

    install_tun2socks
    write_forward_scripts
}

# Generate the up/down scripts that build the TUN device + iptables rules so the
# chosen ports are forwarded through the tunnel (system-level, no dokodemo-door).
write_forward_scripts() {
    local ports_line="" udp_enabled=true
    IFS=',' read -ra PORT_ARRAY <<< "$FORWARD_PORTS"
    for port in "${PORT_ARRAY[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        [ -z "$port" ] && continue
        [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die "Invalid forward port: $port"
        check_port "$port"
        ports_line="$ports_line $port"
    done
    ports_line="${ports_line# }"
    [ -n "$ports_line" ] || die "No valid forward ports provided"
    if [[ "$SECURITY" != "none" && ( "$PROTOCOL" == "shadowsocks" || "$PROTOCOL" == "socks" ) ]]; then
        udp_enabled=false
    fi

    cat <<EOF > "$CONF_DIR/forward-up.sh"
#!/bin/bash
# Auto-generated by Wild Tunnel installer. Brings up the forwarding TUN + rules.
set -euo pipefail
TUN="$TUN_NAME"
TUN_CIDR_ADDR="$TUN_ADDR/$TUN_CIDR"
TUN_MTU="$TUN_MTU"
TUN_TXQLEN="$TUN_TXQLEN"
SENTINEL="$SENTINEL_IP"
PORTS=($ports_line)
ENABLE_UDP=$udp_enabled
SYSCTL_STATE="$CONF_DIR/forward-sysctl.state"
EOF
    cat <<'EOF' >> "$CONF_DIR/forward-up.sh"
if [ ! -f "$SYSCTL_STATE" ]; then
    {
        sysctl -n net.ipv4.ip_forward
        sysctl -n net.ipv4.conf.all.rp_filter
        sysctl -n net.ipv4.conf.default.rp_filter
    } > "$SYSCTL_STATE"
    chmod 600 "$SYSCTL_STATE"
fi
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null 2>&1
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null 2>&1

if ! ip link show "$TUN" >/dev/null 2>&1; then
    ip tuntap add mode tun dev "$TUN"
fi
ip addr replace "$TUN_CIDR_ADDR" dev "$TUN"
ip link set dev "$TUN" mtu "$TUN_MTU" txqueuelen "$TUN_TXQLEN" up

ensure() { local t="$1" c="$2"; shift 2; iptables -t "$t" -C "$c" "$@" 2>/dev/null || iptables -t "$t" -A "$c" "$@"; }

for p in "${PORTS[@]}"; do
    ensure nat PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "$SENTINEL:$p" -m comment --comment wild-tunnel
    ensure filter FORWARD -o "$TUN" -d "$SENTINEL" -p tcp --dport "$p" -j ACCEPT -m comment --comment wild-tunnel
    if [ "$ENABLE_UDP" = true ]; then
        ensure nat PREROUTING -p udp --dport "$p" -j DNAT --to-destination "$SENTINEL:$p" -m comment --comment wild-tunnel
        ensure filter FORWARD -o "$TUN" -d "$SENTINEL" -p udp --dport "$p" -j ACCEPT -m comment --comment wild-tunnel
    fi
done
ensure nat POSTROUTING -o "$TUN" -j MASQUERADE -m comment --comment wild-tunnel
ensure filter FORWARD -i "$TUN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment wild-tunnel
EOF
    chmod 700 "$CONF_DIR/forward-up.sh"

    cat <<EOF > "$CONF_DIR/forward-down.sh"
#!/bin/bash
# Auto-generated by Wild Tunnel installer. Tears down the forwarding TUN + rules.
TUN="$TUN_NAME"
SENTINEL="$SENTINEL_IP"
PORTS=($ports_line)
ENABLE_UDP=$udp_enabled
SYSCTL_STATE="$CONF_DIR/forward-sysctl.state"
EOF
    cat <<'EOF' >> "$CONF_DIR/forward-down.sh"
for p in "${PORTS[@]}"; do
    iptables -t nat -D PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "$SENTINEL:$p" -m comment --comment wild-tunnel 2>/dev/null
    iptables -D FORWARD -o "$TUN" -d "$SENTINEL" -p tcp --dport "$p" -j ACCEPT -m comment --comment wild-tunnel 2>/dev/null
    if [ "$ENABLE_UDP" = true ]; then
        iptables -t nat -D PREROUTING -p udp --dport "$p" -j DNAT --to-destination "$SENTINEL:$p" -m comment --comment wild-tunnel 2>/dev/null
        iptables -D FORWARD -o "$TUN" -d "$SENTINEL" -p udp --dport "$p" -j ACCEPT -m comment --comment wild-tunnel 2>/dev/null
    fi
done
iptables -t nat -D POSTROUTING -o "$TUN" -j MASQUERADE -m comment --comment wild-tunnel 2>/dev/null
iptables -D FORWARD -i "$TUN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment wild-tunnel 2>/dev/null
# Remove broad rules left by releases before the scoped-rule migration.
iptables -D FORWARD -o "$TUN" -j ACCEPT -m comment --comment wild-tunnel 2>/dev/null
iptables -D FORWARD -i "$TUN" -j ACCEPT -m comment --comment wild-tunnel 2>/dev/null
ip link set dev "$TUN" down 2>/dev/null
ip link del "$TUN" 2>/dev/null

if [ -f "$SYSCTL_STATE" ]; then
    old_forward=$(sed -n '1p' "$SYSCTL_STATE")
    old_all_rp=$(sed -n '2p' "$SYSCTL_STATE")
    old_default_rp=$(sed -n '3p' "$SYSCTL_STATE")
    [[ "$old_forward" =~ ^[0-9]+$ ]] && sysctl -w "net.ipv4.ip_forward=$old_forward" >/dev/null 2>&1
    [[ "$old_all_rp" =~ ^[0-9]+$ ]] && sysctl -w "net.ipv4.conf.all.rp_filter=$old_all_rp" >/dev/null 2>&1
    [[ "$old_default_rp" =~ ^[0-9]+$ ]] && sysctl -w "net.ipv4.conf.default.rp_filter=$old_default_rp" >/dev/null 2>&1
    rm -f -- "$SYSCTL_STATE"
fi
EOF
    chmod 700 "$CONF_DIR/forward-down.sh"
}

stop_forward_runtime() {
    systemctl stop "$FWD_SERVICE" 2>/dev/null || true
    [ -f "$CONF_DIR/forward-down.sh" ] && bash "$CONF_DIR/forward-down.sh" 2>/dev/null || true
}

remove_forward_service() {
    stop_forward_runtime
    systemctl disable "$FWD_SERVICE" 2>/dev/null || true
    rm -f -- /etc/systemd/system/${FWD_SERVICE}.service
    rm -f -- "$CONF_DIR/forward-up.sh" "$CONF_DIR/forward-down.sh" "$CONF_DIR/forward-sysctl.state"
    systemctl daemon-reload >/dev/null 2>&1 || true
}

setup_forward_service() {
    echo -e "${GREEN}Setting up port-forwarding service (${FWD_SERVICE})...${NC}"
    local unit_tmp
    unit_tmp=$(mktemp) || die "Could not create a temporary forwarding unit"
    cat <<EOF > "$unit_tmp"
[Unit]
Description=Wild Tunnel Port Forwarder
Wants=network-online.target
After=network-online.target ${SERVICE}.service
Requires=${SERVICE}.service

[Service]
Type=simple
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=$CONF_DIR
UMask=0077
ExecStartPre=/bin/bash $CONF_DIR/forward-up.sh
ExecStart=$CORE_DIR/tun2socks --device $TUN_NAME --mtu $TUN_MTU --proxy socks5://127.0.0.1:$SOCKS_PORT --tcp-rcvbuf $TUN_TCP_RCVBUF --tcp-auto-tuning --loglevel warning
ExecStopPost=/bin/bash $CONF_DIR/forward-down.sh
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 "$unit_tmp" /etc/systemd/system/${FWD_SERVICE}.service || {
        rm -f -- "$unit_tmp"
        die "Failed to install forwarding systemd unit"
    }
    rm -f -- "$unit_tmp"
    systemctl daemon-reload || die "systemd daemon-reload failed"
    systemctl enable "$FWD_SERVICE" || die "Could not enable $FWD_SERVICE"
    if ! systemctl restart "$FWD_SERVICE" || ! systemctl is-active --quiet "$FWD_SERVICE"; then
        journalctl -u "$FWD_SERVICE" -n 30 --no-pager >&2
        die "$FWD_SERVICE failed to start"
    fi
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
    if [[ "$ENGINE" == "hysteria" ]]; then
        if [[ "$ALLOW_INSECURE" == "false" ]]; then
            echo "Domain/SNI: $SERVER_NAME"
        else
            echo "TLS SNI: $SERVER_NAME"
            echo "TLS cert SHA256 pin: $CERT_SHA256"
        fi
    elif [[ "$SECURITY" == "tls" ]]; then
        if [[ "$ALLOW_INSECURE" == "false" ]]; then
            echo "Domain/SNI: $SERVER_NAME"
        else
            echo "TLS SNI: $SERVER_NAME"
            echo "TLS cert SHA256 pin: $CERT_SHA256"
        fi
    fi
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
    CERT_FILE=""; KEY_FILE=""; SERVER_NAME=""; ALLOW_INSECURE=""
    CERT_SHA256=""; LOCAL_PINNED_SHA=""
    FORWARD_PORTS=""; REMOTE_IP=""; TUNNEL_PORT=""; HYSTERIA_BBR_PROFILE="aggressive"
}

# Persist every selection so the configuration can be edited later. This is the
# single source of truth the "Edit Configuration" menu reads from.
save_state() {
    local tmp var
    local -a state_vars=(
        ROLE ENGINE PROTOCOL TUNNEL_PORT REMOTE_IP UUID PASSWORD OBFS_PASS
        SS_METHOD VMESS_SECURITY NETWORK WS_PATH HTTP_HOST GRPC_SERVICE HTTP_PATH
        SECURITY FLOW VLESS_ENC VLESS_ENCRYPTION VLESS_DECRYPTION
        REALITY_DEST REALITY_SNI REALITY_PUBLIC REALITY_PRIVATE REALITY_SHORTID
        REALITY_FINGERPRINT USE_REAL_SSL DOMAIN CERT_FILE KEY_FILE SERVER_NAME
        ALLOW_INSECURE CERT_SHA256 LOCAL_SERVER_NAME LOCAL_ALLOW_INSECURE
        LOCAL_PINNED_SHA FORWARD_PORTS HYSTERIA_BBR_PROFILE
    )
    mkdir -p "$CONF_DIR"
    chmod 700 "$CONF_DIR"
    tmp=$(mktemp "$CONF_DIR/.wild.conf.XXXXXX") || die "Could not create temporary state"
    {
        for var in "${state_vars[@]}"; do
            # %q emits a Bash-safe assignment value without re-evaluating user
            # supplied dollar signs, quotes, backticks or command substitutions.
            printf '%s=%q\n' "$var" "${!var}"
        done
    } > "$tmp"
    install -m 0600 "$tmp" "$CONF_DIR/wild.conf" || {
        rm -f -- "$tmp"
        die "Could not save configuration state"
    }
    rm -f -- "$tmp"
}

# Load a previously saved configuration into the current shell. The file is
# generated with printf %q, owned by root and private before it is sourced.
load_state() {
    local state="$CONF_DIR/wild.conf"
    [ -f "$state" ] || return 1
    [ ! -L "$state" ] || die "Refusing to load symlinked state file"
    [[ $(stat -c '%u' "$state" 2>/dev/null) == "0" ]] || die "State file must be owned by root"
    chmod 600 "$state" || die "Could not secure state file"
    # shellcheck disable=SC1090
    . "$state"
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
        LOCAL_PINNED_SHA=""
    else
        LOCAL_SERVER_NAME="bing.com"
        LOCAL_ALLOW_INSECURE="true"
        while true; do
            read -p "Enter TLS cert SHA256 pin (from the remote summary) (0=Back): " LOCAL_PINNED_SHA
            [ "$LOCAL_PINNED_SHA" = "0" ] && return $BACK_RC
            if LOCAL_PINNED_SHA=$(normalize_cert_pin "$LOCAL_PINNED_SHA"); then
                break
            fi
            echo -e "${RED}Invalid SHA256 certificate pin; enter exactly 64 hex digits (colons are optional).${NC}"
        done
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
        pause_enter
        return 1
    fi
    check_port "$TUNNEL_PORT"
    install_core
    # A previous local/Xray installation may have left a TUN forwarder behind.
    remove_forward_service
    remove_xray_bbr
    create_remote_config
    setup_service
    save_state
    print_remote_summary
    echo
    echo -e "${YELLOW}Copy the details above to the Iran (local) server before continuing.${NC}"
    pause_enter
    return 0
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
        pause_enter
        return 1
    fi
    install_core
    if [[ "$ENGINE" == "xray" ]]; then
        # Tear down rules using the old script before it is regenerated.
        stop_forward_runtime
    else
        remove_forward_service
    fi
    create_local_config
    setup_service
    [[ "$ENGINE" == "xray" ]] && setup_forward_service
    save_state
    echo -e "${GREEN}Local (Iran) tunnel installed.${NC}"
    pause_enter
    return 0
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
    local ans candidate
    read -p "Does the Remote use a REAL Domain for TLS? (y/n) [current insecure=$LOCAL_ALLOW_INSECURE] (0=cancel): " ans
    [ "$ans" = "0" ] && return 1
    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        edit_field LOCAL_SERVER_NAME "Domain Name" || return 1
        LOCAL_ALLOW_INSECURE="false"; LOCAL_PINNED_SHA=""
    elif [[ "$ans" == "n" || "$ans" == "N" ]]; then
        LOCAL_SERVER_NAME="bing.com"; LOCAL_ALLOW_INSECURE="true"
    fi
    if [[ "$LOCAL_ALLOW_INSECURE" == "true" ]]; then
        while true; do
            read -p "TLS cert SHA256 pin (from remote) (0=cancel): " candidate
            [ "$candidate" = "0" ] && return 1
            if LOCAL_PINNED_SHA=$(normalize_cert_pin "$candidate"); then
                break
            fi
            echo -e "${RED}Invalid SHA256 certificate pin; enter exactly 64 hex digits (colons are optional).${NC}"
        done
    fi
    return 0
}

edit_vless_enc_string() { edit_field VLESS_ENCRYPTION "VLESS Encryption string (from remote)"; }

edit_hysteria_bbr_profile() {
    echo "Hysteria client BBR profile (controls this server's upload):"
    echo "1) aggressive (higher throughput, more loss-sensitive)"
    echo "2) standard (balanced)"
    echo "3) conservative"
    read -p "Choice [1-3]: " profile_choice
    case "$profile_choice" in
        1) HYSTERIA_BBR_PROFILE="aggressive" ;;
        2) HYSTERIA_BBR_PROFILE="standard" ;;
        3) HYSTERIA_BBR_PROFILE="conservative" ;;
        *) echo -e "${RED}Invalid profile.${NC}"; return 1 ;;
    esac
}

show_config_brief() {
    echo -e "${YELLOW}Current:  role=$ROLE  protocol=$PROTOCOL  port=$TUNNEL_PORT  security=${SECURITY:-none}  network=${NETWORK:-tcp}${NC}"
    [[ "$ROLE" == "local" ]] && \
        echo -e "${YELLOW}          remote_ip=$REMOTE_IP  forward_ports=$FORWARD_PORTS${NC}"
}

apply_remote() {
    echo -e "${GREEN}Applying changes on the Foreign (remote) server...${NC}"
    ensure_core
    remove_forward_service
    remove_xray_bbr
    create_remote_config
    setup_service
    save_state
    print_remote_summary
}

apply_local() {
    echo -e "${GREEN}Applying changes on the Iran (local) server...${NC}"
    ensure_core
    if [[ "$ENGINE" == "xray" ]]; then
        stop_forward_runtime
    else
        remove_forward_service
    fi
    create_local_config
    setup_service
    [[ "$ENGINE" == "xray" ]] && setup_forward_service
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
        [[ "$ENGINE" == "hysteria" ]] && echo "11) Hysteria upload profile [current: $HYSTERIA_BBR_PROFILE]"
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
            11) if [[ "$ENGINE" == "hysteria" ]]; then edit_hysteria_bbr_profile && dirty=1; else echo -e "${RED}Not applicable.${NC}"; fi ;;
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
    local confirmation
    read -p "Type UNINSTALL to remove Wild Tunnel and its local configuration: " confirmation
    if [ "$confirmation" != "UNINSTALL" ]; then
        echo -e "${YELLOW}Uninstall cancelled.${NC}"
        return 1
    fi
    echo -e "${RED}Uninstalling Wild Tunnel...${NC}"
    remove_forward_service
    remove_xray_bbr
    systemctl stop "$SERVICE" 2>/dev/null
    systemctl disable "$SERVICE" 2>/dev/null
    remove_cron 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE}.service
    rm -f /etc/letsencrypt/renewal-hooks/deploy/wild-tunnel.sh
    rm -rf "$CORE_DIR"
    rm -rf "$CONF_DIR"
    rm -f /usr/local/bin/wild
    rm -rf /usr/local/lib/wild-tunnel
    systemctl daemon-reload
    systemctl reset-failed "$SERVICE" 2>/dev/null
    systemctl reset-failed "$FWD_SERVICE" 2>/dev/null
    echo -e "${GREEN}Uninstallation complete.${NC}"
    echo "Note: the Sanaei/3x-ui panel (if installed) was not touched."
}

# ---------------------------------------------------------------------------
# Post-install management menu (shown right after a successful install)
# ---------------------------------------------------------------------------

pause_enter() { echo; read -p "Press Enter to continue..." _; }

has_forward() { [ -f /etc/systemd/system/${FWD_SERVICE}.service ]; }

svc_status() {
    systemctl status "$SERVICE" --no-pager | head -n 15
    has_forward && { echo; systemctl status "$FWD_SERVICE" --no-pager | head -n 15; }
}

svc_logs() {
    echo -e "${YELLOW}Showing live logs for $SERVICE. Press Ctrl+C to stop.${NC}"
    journalctl -u "$SERVICE" -f
}

restart_services() {
    if ! systemctl restart "$SERVICE" || ! systemctl is-active --quiet "$SERVICE"; then
        echo -e "${RED}Tunnel restart failed.${NC}"
        journalctl -u "$SERVICE" -n 20 --no-pager
        return 1
    fi
    if has_forward; then
        systemctl restart "$FWD_SERVICE" && systemctl is-active --quiet "$FWD_SERVICE" || {
            echo -e "${RED}Forwarder restart failed.${NC}"
            journalctl -u "$FWD_SERVICE" -n 20 --no-pager
            return 1
        }
    fi
    echo -e "${GREEN}Restarted.${NC}"
}

show_full_config() {
    [ -f "$CONF_DIR/config.json" ] && { echo -e "${GREEN}--- config.json ---${NC}"; cat "$CONF_DIR/config.json"; echo; }
    [ -f "$CONF_DIR/config.yaml" ] && { echo -e "${GREEN}--- config.yaml ---${NC}"; cat "$CONF_DIR/config.yaml"; echo; }
    [ -f "$CONF_DIR/wild.conf" ]   && { echo -e "${GREEN}--- saved parameters (wild.conf) ---${NC}"; cat "$CONF_DIR/wild.conf"; }
}

post_install_menu() {
    while true; do
        show_banner
        echo -e "${GREEN}Tunnel is installed. Management menu:${NC}"
        echo "1) Status"
        echo "2) Restart tunnel"
        echo "3) Stop tunnel"
        echo "4) Start tunnel"
        echo "5) Live logs (Ctrl+C to exit)"
        echo "6) Show config"
        echo "7) Edit Configuration"
        echo "8) Schedule auto-restart"
        echo "9) Remove scheduled restart"
        echo "10) Uninstall"
        echo "11) Back to main menu"
        echo "0) Exit"
        read -p "Select an option [0-11]: " opt
        case "$opt" in
            1) svc_status ;;
            2) restart_services ;;
            3) systemctl stop "$SERVICE"; has_forward && systemctl stop "$FWD_SERVICE"; echo -e "${YELLOW}Stopped.${NC}" ;;
            4) systemctl start "$SERVICE"; has_forward && systemctl start "$FWD_SERVICE"; echo -e "${GREEN}Started.${NC}" ;;
            5) svc_logs ;;
            6) show_full_config ;;
            7) do_edit ;;
            8) schedule_restart ;;
            9) remove_cron && echo -e "${GREEN}Scheduled restart removed.${NC}" ;;
            10) do_uninstall; pause_enter; return ;;
            11) return ;;
            0) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
            *) echo -e "${RED}Invalid option.${NC}" ;;
        esac
        pause_enter
    done
}

# ---------------------------------------------------------------------------
# Main menu (loops until Exit)
# ---------------------------------------------------------------------------

# If a tunnel is already installed, refresh the `wild` shortcut so an existing
# installation immediately picks up this version's new management menu/banner.
refresh_shortcut_if_installed() {
    { [ -f "$CONF_DIR/config.json" ] || [ -f "$CONF_DIR/config.yaml" ]; } \
        && install_shortcut >/dev/null 2>&1
    return 0
}

main_menu() {
    refresh_shortcut_if_installed
    local installed=0
    while true; do
        show_banner
        { [ -f "$CONF_DIR/config.json" ] || [ -f "$CONF_DIR/config.yaml" ]; } && installed=1 || installed=0
        echo "1) Install Remote Server (Foreign - Receiver)"
        echo "2) Install Local Server (Iran - Forwarder)"
        [ "$installed" -eq 1 ] && echo "3) Management menu (post-install)"
        if [ "$installed" -eq 1 ]; then
            echo "4) Uninstall Wild Tunnel"
            echo "5) Exit"
        else
            echo "3) Uninstall Wild Tunnel"
            echo "4) Exit"
        fi
        read -p "Select an option: " role_option
        case "$role_option" in
            1) do_remote_setup && post_install_menu ;;
            2) do_local_setup && post_install_menu ;;
            3)
                if [ "$installed" -eq 1 ]; then
                    post_install_menu
                else
                    do_uninstall; pause_enter
                fi
                ;;
            4)
                if [ "$installed" -eq 1 ]; then
                    do_uninstall; pause_enter
                else
                    echo -e "${GREEN}Goodbye!${NC}"; exit 0
                fi
                ;;
            5)
                [ "$installed" -eq 1 ] && { echo -e "${GREEN}Goodbye!${NC}"; exit 0; } \
                    || echo -e "${RED}Invalid option selected.${NC}"
                pause_enter
                ;;
            *) echo -e "${RED}Invalid option selected.${NC}"; pause_enter ;;
        esac
    done
}

main_menu
