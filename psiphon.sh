#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

CONF_DIR="/etc/psiphon"
CONF_FILE="$CONF_DIR/psiphon.config"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root.${NC}"
  exit 1
fi

install_psiphon() {
    echo -e "${YELLOW}Installing Psiphon Core...${NC}"
    apt-get update -y && apt-get install -y wget curl lsof jq 2>/dev/null
    
    cd /root
    mkdir -p PsiphonLinux && cd PsiphonLinux
    wget -q https://raw.githubusercontent.com/SpherionOS/PsiphonLinux/main/plinstaller2 -O plinstaller2
    chmod +x plinstaller2
    ./plinstaller2
    
    systemctl stop psiphon.service 2>/dev/null
    echo -e "${GREEN}Psiphon installed successfully.${NC}"
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

change_location() {
    if [ ! -f "/usr/bin/psiphon" ]; then
        install_psiphon
    fi

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

    read -p "Enter SOCKS5 Port (Default: 1080): " CUSTOM_PORT
    PORT=${CUSTOM_PORT:-1080}

    mkdir -p "$CONF_DIR"
    cat <<EOF > "$CONF_FILE"
{
    "EgressRegion": "$C_CODE",
    "LocalSocksProxyPort": $PORT
}
EOF

    SERVICE_FILE="/etc/systemd/system/psiphon.service"
    cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Psiphon Service
After=network.target

[Service]
Type=simple
WorkingDirectory=/root/PsiphonLinux
ExecStart=/usr/bin/psiphon
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable psiphon
    systemctl restart psiphon

    echo -e "${GREEN}\nApplying $C_NAME ($C_CODE) on port $PORT...${NC}"
    echo -e "${YELLOW}Waiting 10 seconds for connection...${NC}"
    sleep 10
    
    TEST_RES=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 10 https://ipinfo.io)
    if [ -n "$TEST_RES" ]; then
        echo -e "${GREEN}Connected successfully!${NC}"
        echo "$TEST_RES" | grep -E '"ip"|"country"|"city"'
    else
        echo -e "${YELLOW}Service restarted. Check status via Option 2.${NC}"
    fi
}

check_status() {
    echo -e "\n${BLUE}=== Current Psiphon Status ===${NC}"
    STATUS=$(systemctl is-active psiphon 2>/dev/null)
    
    if [ "$STATUS" == "active" ]; then
        PORT=$(grep -oP '"LocalSocksProxyPort":\s*\K\d+' "$CONF_FILE" 2>/dev/null || echo "1080")
        REGION=$(grep -oP '"EgressRegion":\s*"\K[^"]+' "$CONF_FILE" 2>/dev/null || echo "Auto")
        IP_INFO=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 6 https://ipinfo.io | grep -oP '"country":\s*"\K[^"]+' || echo "Connecting...")
        
        echo -e "Status: ${GREEN}Active (Running)${NC}"
        echo -e "Configured Country: ${YELLOW}$REGION${NC}"
        echo -e "SOCKS Port: ${GREEN}$PORT${NC}"
        echo -e "Exit IP Country: ${BLUE}$IP_INFO${NC}"
    else
        echo -e "Status: ${RED}Inactive (Stopped)${NC}"
    fi
}

uninstall_all() {
    echo -e "${RED}=== Clean Uninstall ===${NC}"
    systemctl stop psiphon 2>/dev/null
    systemctl disable psiphon 2>/dev/null
    rm -f /etc/systemd/system/psiphon.service
    systemctl daemon-reload

    rm -rf "$CONF_DIR"
    rm -rf /root/PsiphonLinux
    rm -f /usr/bin/psiphon
    rm -rf /root/.config/ca.psiphon.PsiphonTunnel.tunnel-core 2>/dev/null

    echo -e "${GREEN}Psiphon uninstalled completely.${NC}"
}

while true; do
    echo -e "\n${BLUE}==================================================${NC}"
    echo -e "${GREEN}          Psiphon Tunnel Manager                  ${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo "1) Change/Set Country Location & Port"
    echo "2) Check Connection Status"
    echo "3) Clean Uninstall"
    echo "4) Exit"
    echo -e "${BLUE}--------------------------------------------------${NC}"
    read -p "Please select an option [1-4]: " CHOICE

    case $CHOICE in
        1) change_location ;;
        2) check_status ;;
        3) uninstall_all ;;
        4) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
done
