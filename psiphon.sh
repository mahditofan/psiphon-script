#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root.${NC}"
  exit 1
fi

COUNTRIES=(
    "United States|US"
    "Germany|DE"
    "France|FR"
    "United Kingdom|GB"
    "Canada|CA"
    "Netherlands|NL"
    "Sweden|SE"
    "Switzerland|CH"
    "Japan|JP"
    "Finland|FI"
    "Singapore|SG"
    "Australia|AU"
    "Italy|IT"
    "Spain|ES"
    "Austria|AT"
    "Poland|PL"
    "Ireland|IE"
    "Belgium|BE"
    "Denmark|DK"
    "Norway|NO"
    "India|IN"
    "Indonesia|ID"
    "Romania|RO"
    "Czech Republic|CZ"
    "Serbia|RS"
)

install_country_instance() {
    echo -e "${YELLOW}Installing core via official installer...${NC}"
    apt-get update -y && apt-get install -y wget curl lsof jq 2>/dev/null
    
    cd /root
    mkdir -p PsiphonLinux && cd PsiphonLinux
    wget -q https://raw.githubusercontent.com/SpherionOS/PsiphonLinux/main/plinstaller2 -O plinstaller2
    chmod +x plinstaller2
    ./plinstaller2

    systemctl stop psiphon 2>/dev/null

    echo -e "\n${BLUE}=== Select Target Location ===${NC}"
    for i in "${!COUNTRIES[@]}"; do
        NAME=$(echo "${COUNTRIES[$i]}" | cut -d'|' -f1)
        CODE=$(echo "${COUNTRIES[$i]}" | cut -d'|' -f2)
        printf "%2d) %-25s [%s]\n" $((i+1)) "$NAME" "$CODE"
    done
    
    echo -e "${BLUE}--------------------------------------${NC}"
    read -p "Select country number: " C_INDEX

    if ! [[ "$C_INDEX" =~ ^[0-9]+$ ]] || [ "$C_INDEX" -lt 1 ] || [ "$C_INDEX" -gt "${#COUNTRIES[@]}" ]; then
        echo -e "${RED}Invalid selection!${NC}"
        return
    fi

    SELECTED="${COUNTRIES[$((C_INDEX-1))]}"
    C_NAME=$(echo "$SELECTED" | cut -d'|' -f1)
    C_CODE=$(echo "$SELECTED" | cut -d'|' -f2)

    DEFAULT_PORT=$((1080 + C_INDEX))
    read -p "Enter SOCKS5 Port for $C_NAME (Default: $DEFAULT_PORT): " CUSTOM_PORT
    PORT=${CUSTOM_PORT:-$DEFAULT_PORT}

    CONF_FILE="/etc/psiphon.config"
    if [ ! -f "$CONF_FILE" ]; then
        CONF_FILE="/etc/psiphon/psiphon.config"
    fi

    # Modify existing config without losing embedded server list
    if [ -f "$CONF_FILE" ]; then
        tmp=$(mktemp)
        jq --arg country "$C_CODE" --argport "$PORT" '.EgressRegion = $country | .LocalSocksProxyPort = ($port | tonumber)' "$CONF_FILE" > "$tmp" && mv "$tmp" "$CONF_FILE"
    fi

    PSIPHON_BIN=$(which psiphon 2>/dev/null || echo "/root/PsiphonLinux/psiphon-tunnel-core")

    # Override native service to use our updated config
    cat <<EOF > /etc/systemd/system/psiphon.service
[Unit]
Description=Psiphon Manager Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/PsiphonLinux
ExecStart=$PSIPHON_BIN --config $CONF_FILE
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable psiphon.service
    systemctl restart psiphon.service

    echo -e "${GREEN}\nConfigured location $C_NAME ($C_CODE) on port $PORT!${NC}"
    echo -e "${YELLOW}Waiting 15 seconds for connection...${NC}"
    sleep 15
    
    TEST_RES=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 10 https://ipinfo.io)
    if [ -n "$TEST_RES" ]; then
        echo -e "${GREEN}Connection Successful!${NC}"
        echo "$TEST_RES" | grep -E '"ip"|"country"|"city"'
    else
        echo -e "${YELLOW}Tunnel is connecting. Check status in option 2 shortly.${NC}"
    fi
}

list_and_test_services() {
    echo -e "\n${BLUE}=== Current Psiphon Status ===${NC}"
    
    CONF_FILE="/etc/psiphon.config"
    [ ! -f "$CONF_FILE" ] && CONF_FILE="/etc/psiphon/psiphon.config"

    STATUS=$(systemctl is-active psiphon.service 2>/dev/null)
    
    if [ "$STATUS" == "active" ]; then
        PORT=$(grep -oP '"LocalSocksProxyPort":\s*\K\d+' "$CONF_FILE" 2>/dev/null || echo "1080")
        REGION=$(grep -oP '"EgressRegion":\s*"\K[^"]+' "$CONF_FILE" 2>/dev/null || echo "N/A")
        
        IP_INFO=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 6 https://ipinfo.io | grep -oP '"country":\s*"\K[^"]+' || echo "Connecting...")
        
        echo -e "Status: ${GREEN}Active${NC} | Country: ${YELLOW}$REGION${NC} | Port: ${GREEN}$PORT${NC} | Exit IP Country: ${BLUE}$IP_INFO${NC}"
    else
        echo -e "Status: ${RED}Inactive${NC} (Service stopped)"
    fi
}

uninstall_all() {
    echo -e "${RED}=== Clean Uninstall ===${NC}"
    systemctl stop psiphon.service 2>/dev/null
    systemctl disable psiphon.service 2>/dev/null
    systemctl stop psiphon-manager.service 2>/dev/null
    systemctl disable psiphon-manager.service 2>/dev/null
    
    rm -f /etc/systemd/system/psiphon.service
    rm -f /etc/systemd/system/psiphon-manager.service
    systemctl daemon-reload

    rm -rf /etc/psiphon
    rm -f /etc/psiphon.config
    rm -rf /root/PsiphonLinux
    rm -f /usr/bin/psiphon
    rm -rf /root/.config/ca.psiphon.PsiphonTunnel.tunnel-core 2>/dev/null

    echo -e "${GREEN}Psiphon uninstalled completely.${NC}"
}

while true; do
    echo -e "\n${BLUE}==================================================${NC}"
    echo -e "${GREEN}          Psiphon Tunnel Manager                  ${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo "1) Install / Change Country Location & Port"
    echo "2) Check Service Status"
    echo "3) Clean Uninstall"
    echo "4) Exit"
    echo -e "${BLUE}--------------------------------------------------${NC}"
    read -p "Please select an option [1-4]: " CHOICE

    case $CHOICE in
        1) install_country_instance ;;
        2) list_and_test_services ;;
        3) uninstall_all ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
done
