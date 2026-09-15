#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/opt/psiphon"
CONFIG_BASE_DIR="/etc/psiphon"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root.${NC}"
  exit 1
fi

ensure_psiphon_installed() {
    if [ ! -f "/usr/bin/psiphon" ]; then
        echo -e "${YELLOW}Installing Psiphon dependencies and core...${NC}"
        
        systemctl stop psiphon 2>/dev/null
        systemctl disable psiphon 2>/dev/null
        
        apt-get update -y && apt-get install -y wget curl lsof git golang-go 2>/dev/null
        
        echo -e "${YELLOW}Building Psiphon tunnel core...${NC}"
        mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
        git clone https://github.com/Psiphon-Labs/psiphon-tunnel-core.git . 2>/dev/null || git pull
        
        cd ConsoleClient
        go build -o /usr/bin/psiphon main.go
        chmod +x /usr/bin/psiphon
        
        if [ ! -f "/usr/bin/psiphon" ]; then
            echo -e "${RED}Build failed! Trying fallback download...${NC}"
            wget -q https://raw.githubusercontent.com/SpherionOS/PsiphonLinux/main/plinstaller2 -O /tmp/plinstaller2
            chmod +x /tmp/plinstaller2
            /tmp/plinstaller2
        fi
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

    CONF_DIR="$CONFIG_BASE_DIR/$C_CODE"
    mkdir -p "$CONF_DIR"
    
    cat <<EOF > "$CONF_DIR/psiphon.config"
{
    "EgressRegion": "$C_CODE",
    "LocalSocksProxyPort": $PORT,
    "Authorizations": []
}
EOF

    SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Psiphon Tunnel - $C_NAME ($C_CODE)
After=network.target

[Service]
Type=simple
WorkingDirectory=$CONF_DIR
ExecStart=/usr/bin/psiphon --config $CONF_DIR/psiphon.config
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
    echo -e "${YELLOW}Waiting 10 seconds for Psiphon tunnel to connect...${NC}"
    sleep 10
    
    TEST_RES=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 10 https://ipinfo.io)
    if [ -n "$TEST_RES" ]; then
        echo -e "${GREEN}Connection Successful!${NC}"
        echo "$TEST_RES" | grep -E '"ip"|"country"|"city"'
    else
        echo -e "${YELLOW}Tunnel is connecting in background. Check status in Option 2.${NC}"
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
        
        PORT=$(grep -oP '"LocalSocksProxyPort":\s*\K\d+' "$CONFIG_BASE_DIR/$C_CODE/psiphon.config" 2>/dev/null)
        
        STATUS=$(systemctl is-active "$SVC_NAME")
        if [ "$STATUS" == "active" ]; then
            STATUS_STR="${GREEN}Active${NC}"
            IP_INFO=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 6 https://ipinfo.io | grep -oP '"country":\s*"\K[^"]+' || echo "Connecting...")
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
        rm -rf "$CONFIG_BASE_DIR/$C_CODE"
    done
    systemctl daemon-reload
    echo -e "${GREEN}Removed successfully.${NC}"
}

uninstall_all() {
    echo -e "${RED}=== Clean Uninstall All ===${NC}"
    systemctl stop psiphon-*.service 2>/dev/null
    systemctl disable psiphon-*.service 2>/dev/null
    systemctl stop psiphon 2>/dev/null
    systemctl disable psiphon 2>/dev/null
    
    rm -f /etc/systemd/system/psiphon-*.service
    rm -f /etc/systemd/system/psiphon.service
    systemctl daemon-reload

    rm -rf "$INSTALL_DIR"
    rm -rf "$CONFIG_BASE_DIR"
    rm -f /usr/bin/psiphon
    rm -rf /root/.config/ca.psiphon.PsiphonTunnel.tunnel-core 2>/dev/null

    echo -e "${GREEN}All Psiphon instances uninstalled.${NC}"
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
