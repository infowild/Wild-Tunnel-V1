#!/bin/bash
# Wild Tunnel v1 Installer Script (Dynamic Protocol + UDP + Hysteria2 + Real SSL)
# Designed for Ubuntu/Debian

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Welcome to Wild Tunnel v1 Installer${NC}"
echo "1) Install Remote Server (Foreign - Receiver)"
echo "2) Install Local Server (Iran - Forwarder)"
echo "3) Uninstall Wild Tunnel"
read -p "Select an option [1-3]: " role_option

install_xray() {
    echo -e "${GREEN}Installing Xray core...${NC}"
    mkdir -p /usr/local/bin/wild-xray
    mkdir -p /etc/wild-tunnel
    
    wget -qO /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v1.8.8/Xray-linux-64.zip
    apt-get update -q && apt-get install -y unzip uuid-runtime jq openssl
    unzip -qo /tmp/xray.zip -d /usr/local/bin/wild-xray/
    rm /tmp/xray.zip
    chmod +x /usr/local/bin/wild-xray/xray
}

setup_service() {
    echo -e "${GREEN}Setting up Systemd service...${NC}"
    cp services/wild-tunnel.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable wild-tunnel
    systemctl restart wild-tunnel
    echo -e "${GREEN}Wild Tunnel started successfully!${NC}"
    systemctl status wild-tunnel --no-pager | head -n 10
}

generate_uuid() { uuidgen; }
generate_password() { tr -dc A-Za-z0-9 </dev/urandom | head -c 16; }

prompt_tunnel_port() {
    read -p "Enter Tunnel Port [Default: 50000]: " TUNNEL_PORT
    TUNNEL_PORT=${TUNNEL_PORT:-50000}
}

prompt_protocol_info() {
    echo -e "${GREEN}Select Tunnel Protocol:${NC}"
    echo "1) VLESS (TCP)"
    echo "2) VMESS (TCP)"
    echo "3) Trojan (TCP)"
    echo "4) Shadowsocks (TCP/UDP, aes-256-gcm)"
    echo "5) Socks (TCP/UDP)"
    echo "6) Hysteria 2 (UDP, with Obfuscation)"
    read -p "Protocol [1-6]: " proto_opt
    
    case $proto_opt in
        1) PROTOCOL="vless";;
        2) PROTOCOL="vmess";;
        3) PROTOCOL="trojan";;
        4) PROTOCOL="shadowsocks";;
        5) PROTOCOL="socks";;
        6) PROTOCOL="hysteria2";;
        *) PROTOCOL="vless"; echo "Defaulting to vless";;
    esac

    if [[ "$PROTOCOL" == "vless" || "$PROTOCOL" == "vmess" ]]; then
        read -p "Enter UUID [Leave blank to auto-generate]: " UUID
        if [ -z "$UUID" ]; then
            UUID=$(generate_uuid)
            echo "Generated UUID: $UUID"
        fi
    elif [[ "$PROTOCOL" == "trojan" || "$PROTOCOL" == "shadowsocks" || "$PROTOCOL" == "socks" || "$PROTOCOL" == "hysteria2" ]]; then
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
}

generate_certs() {
    echo -e "${GREEN}Do you want to get a REAL SSL certificate using Let's Encrypt? (y/n)${NC}"
    echo "Note: You must have a domain pointing to this server's IP."
    read -p "Choice: " USE_REAL_SSL

    if [[ "$USE_REAL_SSL" == "y" || "$USE_REAL_SSL" == "Y" ]]; then
        read -p "Enter your Domain Name (e.g., sub.domain.com): " DOMAIN
        echo -e "${GREEN}Installing Nginx and Certbot...${NC}"
        apt-get update -q && apt-get install -y nginx certbot python3-certbot-nginx
        systemctl stop nginx 2>/dev/null
        certbot certonly --standalone -d $DOMAIN --non-interactive --agree-tos -m admin@$DOMAIN
        
        CERT_FILE="/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
        KEY_FILE="/etc/letsencrypt/live/$DOMAIN/privkey.pem"
        SERVER_NAME="$DOMAIN"
        ALLOW_INSECURE="false"
    else
        echo -e "${GREEN}Generating self-signed certificates...${NC}"
        openssl ecparam -genkey -name prime256v1 -out /etc/wild-tunnel/private.key
        openssl req -new -x509 -days 3650 -key /etc/wild-tunnel/private.key -out /etc/wild-tunnel/cert.crt -subj "/CN=bing.com" >/dev/null 2>&1
        CERT_FILE="/etc/wild-tunnel/cert.crt"
        KEY_FILE="/etc/wild-tunnel/private.key"
        SERVER_NAME="bing.com"
        ALLOW_INSECURE="true"
    fi
}

create_remote_config() {
    if [[ "$PROTOCOL" == "hysteria2" || "$PROTOCOL" == "trojan" ]]; then
        generate_certs
    fi

    cat <<EOF > /etc/wild-tunnel/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $TUNNEL_PORT,
      "listen": "0.0.0.0",
      "protocol": "$PROTOCOL",
      "settings": {
        $(if [[ "$PROTOCOL" == "vless" ]]; then
          echo "\"clients\": [ { \"id\": \"$UUID\", \"level\": 0 } ], \"decryption\": \"none\""
        elif [[ "$PROTOCOL" == "vmess" ]]; then
          echo "\"clients\": [ { \"id\": \"$UUID\", \"alterId\": 0 } ]"
        elif [[ "$PROTOCOL" == "trojan" ]]; then
          echo "\"clients\": [ { \"password\": \"$PASSWORD\" } ]"
        elif [[ "$PROTOCOL" == "shadowsocks" ]]; then
          echo "\"method\": \"aes-256-gcm\", \"password\": \"$PASSWORD\", \"network\": \"tcp,udp\""
        elif [[ "$PROTOCOL" == "socks" ]]; then
          echo "\"auth\": \"password\", \"accounts\": [ { \"user\": \"tunnel\", \"pass\": \"$PASSWORD\" } ], \"udp\": true"
        elif [[ "$PROTOCOL" == "hysteria2" ]]; then
          echo "\"password\": \"$PASSWORD\", \"obfuscation\": { \"type\": \"salamander\", \"password\": \"$OBFS_PASS\" }"
        fi)
      },
      "streamSettings": {
        $(if [[ "$PROTOCOL" == "hysteria2" ]]; then
          echo "\"network\": \"hysteria2\", \"tlsSettings\": { \"certificates\": [ { \"certificateFile\": \"$CERT_FILE\", \"keyFile\": \"$KEY_FILE\" } ] }"
        elif [[ "$PROTOCOL" == "trojan" ]]; then
          echo "\"network\": \"tcp\", \"security\": \"tls\", \"tlsSettings\": { \"certificates\": [ { \"certificateFile\": \"$CERT_FILE\", \"keyFile\": \"$KEY_FILE\" } ] }"
        else
          echo "\"network\": \"tcp\", \"security\": \"none\""
        fi)
      },
      "sniffing": { "enabled": false }
    }
  ],
  "outbounds": [ { "protocol": "freedom", "settings": {} } ]
}
EOF
}

create_local_config() {
    read -p "Enter ports to tunnel (comma separated, e.g., 2053,8443): " TUNNEL_PORTS
    
    # Optional TLS settings for local connecting to remote
    if [[ "$PROTOCOL" == "hysteria2" || "$PROTOCOL" == "trojan" ]]; then
        read -p "Does the Remote Server use a REAL Domain Name for TLS? (y/n): " HAS_REAL_DOMAIN
        if [[ "$HAS_REAL_DOMAIN" == "y" || "$HAS_REAL_DOMAIN" == "Y" ]]; then
            read -p "Enter the Domain Name: " LOCAL_SERVER_NAME
            LOCAL_ALLOW_INSECURE="false"
        else
            LOCAL_SERVER_NAME="bing.com"
            LOCAL_ALLOW_INSECURE="true"
        fi
    fi

    cat <<EOF > /etc/wild-tunnel/config.json
{
  "log": { "loglevel": "warning" },
  "inbounds": [],
  "outbounds": [
    {
      "protocol": "$PROTOCOL",
      "settings": {
        $(if [[ "$PROTOCOL" == "vless" || "$PROTOCOL" == "vmess" ]]; then
          echo "\"vnext\": [ { \"address\": \"$REMOTE_IP\", \"port\": $TUNNEL_PORT, \"users\": [ { \"id\": \"$UUID\", \"encryption\": \"none\", \"level\": 0 } ] } ]"
        elif [[ "$PROTOCOL" == "trojan" ]]; then
          echo "\"servers\": [ { \"address\": \"$REMOTE_IP\", \"port\": $TUNNEL_PORT, \"password\": \"$PASSWORD\" } ]"
        elif [[ "$PROTOCOL" == "shadowsocks" ]]; then
          echo "\"servers\": [ { \"address\": \"$REMOTE_IP\", \"port\": $TUNNEL_PORT, \"password\": \"$PASSWORD\", \"method\": \"aes-256-gcm\" } ]"
        elif [[ "$PROTOCOL" == "socks" ]]; then
          echo "\"servers\": [ { \"address\": \"$REMOTE_IP\", \"port\": $TUNNEL_PORT, \"users\": [ { \"user\": \"tunnel\", \"pass\": \"$PASSWORD\" } ] } ]"
        elif [[ "$PROTOCOL" == "hysteria2" ]]; then
          echo "\"server\": \"$REMOTE_IP:$TUNNEL_PORT\", \"password\": \"$PASSWORD\", \"obfuscation\": { \"type\": \"salamander\", \"password\": \"$OBFS_PASS\" }, \"upMbps\": 1000, \"downMbps\": 1000"
        fi)
      },
      "streamSettings": {
        $(if [[ "$PROTOCOL" == "hysteria2" ]]; then
          echo "\"network\": \"hysteria2\", \"tlsSettings\": { \"serverName\": \"$LOCAL_SERVER_NAME\", \"allowInsecure\": $LOCAL_ALLOW_INSECURE }"
        elif [[ "$PROTOCOL" == "trojan" ]]; then
          echo "\"network\": \"tcp\", \"security\": \"tls\", \"tlsSettings\": { \"serverName\": \"$LOCAL_SERVER_NAME\", \"allowInsecure\": $LOCAL_ALLOW_INSECURE }"
        else
          echo "\"network\": \"tcp\", \"security\": \"none\""
        fi)
      }
    }
  ]
}
EOF

    IFS=',' read -ra PORT_ARRAY <<< "$TUNNEL_PORTS"
    for port in "${PORT_ARRAY[@]}"; do
        port=$(echo $port | tr -d ' ')
        jq --argjson p "$port" '.inbounds += [{"port": $p, "listen": "0.0.0.0", "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1", "port": $p, "network": "tcp,udp"}, "sniffing": {"enabled": false}}]' /etc/wild-tunnel/config.json > tmp.json && mv tmp.json /etc/wild-tunnel/config.json
    done
}


if [ "$role_option" == "1" ]; then
    echo -e "${GREEN}--- Remote Server Setup ---${NC}"
    prompt_tunnel_port
    prompt_protocol_info
    install_xray
    create_remote_config
    setup_service
    echo -e "${GREEN}Save these details for the Local Server setup:${NC}"
    echo "Tunnel Port: $TUNNEL_PORT"
    echo "Protocol: $PROTOCOL"
    [[ -n "$UUID" ]] && echo "UUID: $UUID"
    [[ -n "$PASSWORD" ]] && echo "Password: $PASSWORD"
    [[ -n "$OBFS_PASS" ]] && echo "Obfuscation: $OBFS_PASS"
    [[ -n "$SERVER_NAME" && "$ALLOW_INSECURE" == "false" ]] && echo "Domain/SNI: $SERVER_NAME"

elif [ "$role_option" == "2" ]; then
    echo -e "${GREEN}--- Local Server Setup ---${NC}"
    read -p "Enter Remote Server IP: " REMOTE_IP
    prompt_tunnel_port
    prompt_protocol_info
    install_xray
    create_local_config
    setup_service

elif [ "$role_option" == "3" ]; then
    echo -e "${RED}Uninstalling Wild Tunnel...${NC}"
    systemctl stop wild-tunnel
    systemctl disable wild-tunnel
    rm /etc/systemd/system/wild-tunnel.service
    rm -rf /usr/local/bin/wild-xray
    rm -rf /etc/wild-tunnel
    systemctl daemon-reload
    echo -e "${GREEN}Uninstallation complete.${NC}"
else
    echo -e "${RED}Invalid option selected.${NC}"
fi
