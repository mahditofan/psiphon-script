#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

BASE_DIR="/etc/psiphon-multi"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root.${NC}"
  exit 1
fi

ensure_psiphon_installed() {
    if [ ! -f "/usr/bin/psiphon" ]; then
        echo -e "${YELLOW}Installing Psiphon base core...${NC}"
        apt-get update -y && apt-get install -y wget curl lsof jq 2>/dev/null
        
        cd /root
        mkdir -p PsiphonLinux && cd PsiphonLinux
        wget -q https://raw.githubusercontent.com/SpherionOS/PsiphonLinux/main/plinstaller2 -O plinstaller2
        chmod +x plinstaller2
        ./plinstaller2
        
        systemctl stop psiphon.service 2>/dev/null
        systemctl disable psiphon.service 2>/dev/null
    fi
}

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
    ensure_psiphon_installed

    echo -e "\n${BLUE}=== Select Location to Install ===${NC}"
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
    SERVICE_NAME="psiphon-${C_CODE,,}"

    DEFAULT_PORT=$((1080 + C_INDEX))
    read -p "Enter SOCKS5 Port for $C_NAME (Default: $DEFAULT_PORT): " CUSTOM_PORT
    PORT=${CUSTOM_PORT:-$DEFAULT_PORT}

    # Stop any conflicting running services first
    systemctl stop psiphon-*.service 2>/dev/null

    # Global Config Directory Setup
    mkdir -p /etc/psiphon
    cat <<EOF > "/etc/psiphon/psiphon.config"
{
    "EgressRegion": "$C_CODE",
    "LocalSocksProxyPort": $PORT
}
EOF

    # Instance Storage
    INSTANCE_DIR="$BASE_DIR/$C_CODE"
    mkdir -p "$INSTANCE_DIR"
    cp /etc/psiphon/psiphon.config "$INSTANCE_DIR/psiphon.config"

    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Psiphon Tunnel - $C_NAME ($C_CODE)
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/PsiphonLinux
ExecStartPre=/usr/bin/cp -f $INSTANCE_DIR/psiphon.config /etc/psiphon/psiphon.config
ExecStart=/usr/bin/psiphon
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    echo -e "${GREEN}\nService for $C_NAME on port $PORT started!${NC}"
    echo -e "${YELLOW}Establishing tunnel connection (15s)...${NC}"
    sleep 15
    
    TEST_RES=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 10 https://ipinfo.io)
    if [ -n "$TEST_RES" ]; then
        echo -e "${GREEN}Successfully Connected!${NC}"
        echo "$TEST_RES" | grep -E '"ip"|"country"|"city"'
    else
        echo -e "${YELLOW}Connection is initializing. Please check Option 2 in a few seconds.${NC}"
    fi
}

list_and_test_services() {
    echo -e "\n${BLUE}=== Active Psiphon Services ===${NC}"
    SERVICES=$(ls /etc/systemd/system/psiphon-*.service 2>/dev/null)
    
    if [ -z "$SERVICES" ]; then
        echo -e "${YELLOW}No Psiphon locations installed.${NC}"
        return
    fi

    for SVC in $SERVICES; do
        SVC_NAME=$(basename "$SVC")
        C_CODE=$(echo "$SVC_NAME" | sed 's/psiphon-//;s/\.service//' | tr '[:lower:]' '[:upper:]')
        
        PORT=$(grep -oP '"LocalSocksProxyPort":\s*\K\d+' "$BASE_DIR/$C_CODE/psiphon.config" 2>/dev/null)
        
        STATUS=$(systemctl is-active "$SVC_NAME")
        if [ "$STATUS" == "active" ]; then
            STATUS_STR="${GREEN}Active${NC}"
            IP_INFO=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 8 https://ipinfo.io | grep -oP '"country":\s*"\K[^"]+' || echo "Connecting...")
        else
            STATUS_STR="${RED}Inactive${NC}"
            IP_INFO="N/A"
        fi

        echo -e "Country: ${YELLOW}$C_CODE${NC} | SOCKS Port: ${GREEN}$PORT${NC} | Status: $STATUS_STR | Exit Country: ${BLUE}$IP_INFO${NC}"
    done
}

remove_country_instance() {
    echo -e "\n${BLUE}=== Remove Location ===${NC}"
    SERVICES=$(ls /etc/systemd/system/psiphon-*.service 2>/dev/null)
    
    if [ -z "$SERVICES" ]; then
        echo -e "${YELLOW}No locations to remove.${NC}"
        return
    fi

    for SVC in $SERVICES; do
        SVC_NAME=$(basename "$SVC")
        C_CODE=$(echo "$SVC_NAME" | sed 's/psiphon-//;s/\.service//' | tr '[:lower:]' '[:upper:]')
        
        systemctl stop "$SVC_NAME" 2>/dev/null
        systemctl disable "$SVC_NAME" 2>/dev/null
        rm -f "$SVC"
        rm -rf "$BASE_DIR/$C_CODE"
    done
    systemctl daemon-reload
    echo -e "${GREEN}Removed successfully.${NC}"
}

uninstall_all() {
    echo -e "${RED}=== Clean Uninstall All ===${NC}"
    systemctl stop psiphon-*.service 2>/dev/null
    systemctl disable psiphon-*.service 2>/dev/null
    systemctl stop psiphon.service 2>/dev/null
    systemctl disable psiphon.service 2>/dev/null
    
    rm -f /etc/systemd/system/psiphon-*.service
    rm -f /etc/systemd/system/psiphon.service
    systemctl daemon-reload

    rm -rf "$BASE_DIR"
    rm -rf /etc/psiphon
    rm -rf /root/PsiphonLinux
    rm -f /usr/bin/psiphon
    rm -rf /root/.config/ca.psiphon.PsiphonTunnel.tunnel-core 2>/dev/null

    echo -e "${GREEN}All Psiphon instances uninstalled completely.${NC}"
}

while true; do
    echo -e "\n${BLUE}==================================================${NC}"
    echo -e "${GREEN}      Psiphon Multi-Location Manager              ${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo "1) Install New Country Location"
    echo "2) List Active Locations and Test IP"
    echo "3) Remove Location"
    echo "4) Clean Uninstall All Locations"
    echo "5) Exit"
    echo -e "${BLUE}--------------------------------------------------${NC}"
    read -p "Please select an option [1-5]: " CHOICE

    case $CHOICE in
        1) install_country_instance ;;
        2) list_and_test_services ;;
        3) remove_country_instance ;;
        4) uninstall_all ;;
        5) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
done
