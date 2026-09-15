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

ensure_psiphon_installed() {
    if [ ! -f "/usr/bin/psiphon" ]; then
        echo -e "${YELLOW}Running original installer...${NC}"
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

    DEFAULT_PORT=$((1080 + C_INDEX))
    read -p "Enter SOCKS5 Port for $C_NAME (Default: $DEFAULT_PORT): " CUSTOM_PORT
    PORT=${CUSTOM_PORT:-$DEFAULT_PORT}

    # Set up native config directory
    mkdir -p /etc/psiphon
    cat <<EOF > /etc/psiphon/psiphon.config
{
    "EgressRegion": "$C_CODE",
    "LocalSocksProxyPort": $PORT
}
EOF

    # Configure original systemd service
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

    echo -e "${GREEN}\nService started on port $PORT!${NC}"
    echo -e "${YELLOW}Waiting 10 seconds for connection...${NC}"
    sleep 10
    
    TEST_RES=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 10 https://ipinfo.io)
    if [ -n "$TEST_RES" ]; then
        echo -e "${GREEN}Connection Successful!${NC}"
        echo "$TEST_RES" | grep -E '"ip"|"country"|"city"'
    else
        echo -e "${YELLOW}Service running. Check Option 2 in a moment.${NC}"
    fi
}

list_and_test_services() {
    echo -e "\n${BLUE}=== Current Psiphon Status ===${NC}"
    STATUS=$(systemctl is-active psiphon 2>/dev/null)
    
    if [ "$STATUS" == "active" ]; then
        PORT=$(grep -oP '"LocalSocksProxyPort":\s*\K\d+' /etc/psiphon/psiphon.config 2>/dev/null || echo "1080")
        REGION=$(grep -oP '"EgressRegion":\s*"\K[^"]+' /etc/psiphon/psiphon.config 2>/dev/null || echo "N/A")
        
        IP_INFO=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 6 https://ipinfo.io | grep -oP '"country":\s*"\K[^"]+' || echo "Connecting...")
        
        echo -e "Status: ${GREEN}Active${NC} | Configured Country: ${YELLOW}$REGION${NC} | Port: ${GREEN}$PORT${NC} | Exit Country: ${BLUE}$IP_INFO${NC}"
    else
        echo -e "Status: ${RED}Inactive${NC}"
    fi
}

uninstall_all() {
    echo -e "${RED}=== Clean Uninstall ===${NC}"
    systemctl stop psiphon 2>/dev/null
    systemctl disable psiphon 2>/dev/null
    rm -f /etc/systemd/system/psiphon.service
    systemctl daemon-reload

    rm -rf /etc/psiphon
    rm -rf /root/PsiphonLinux
    rm -f /usr/bin/psiphon
    rm -rf /root/.config/ca.psiphon.PsiphonTunnel.tunnel-core 2>/dev/null

    echo -e "${GREEN}Uninstalled completely.${NC}"
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
        4) uninstall_all; exit 0 ;;
        5) exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
done
