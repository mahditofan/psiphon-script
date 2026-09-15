#!/bin/bash

# Visual styling
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

INSTALL_DIR="/root/PsiphonLinux"
CONFIG_BASE_DIR="/etc/psiphon"

# Root check
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root.${NC}"
  exit 1
fi

# Core installation check
ensure_psiphon_installed() {
    if [ ! -f "/usr/bin/psiphon" ]; then
        echo -e "${YELLOW}Downloading and installing core Psiphon binary...${NC}"
        cd /root
        mkdir -p "$INSTALL_DIR" && cd "$INSTALL_DIR"
        wget -q --show-progress https://raw.githubusercontent.com/SpherionOS/PsiphonLinux/main/plinstaller2 -O plinstaller2
        chmod +x plinstaller2
        ./plinstaller2
    fi
}

# Country List Array (Name | ISO Code)
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

    # Default Port calculation or custom prompt
    DEFAULT_PORT=$((1080 + C_INDEX))
    read -p "Enter SOCKS5 Port for $C_NAME (Default: $DEFAULT_PORT): " CUSTOM_PORT
    PORT=${CUSTOM_PORT:-$DEFAULT_PORT}

    # Check port usage
    if lsof -Pi :$PORT -sTCP:LISTEN -t >/dev/null ; then
        echo -e "${RED}Error: Port $PORT is already in use! Please choose another port.${NC}"
        return
    fi

    # Create directory and config file
    CONF_DIR="$CONFIG_BASE_DIR/$C_CODE"
    mkdir -p "$CONF_DIR"
    cat <<EOF > "$CONF_DIR/psiphon.config"
{
    "EgressRegion": "$C_CODE",
    "LocalSocksProxyPort": $PORT
}
EOF

    # Create dedicated Systemd Service
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
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"

    echo -e "${GREEN}\nService for $C_NAME on port $PORT installed and started successfully!${NC}"
    echo -e "${YELLOW}Testing connection for $C_NAME on port $PORT:${NC}"
    sleep 3
    curl --socks5-hostname 127.0.0.1:$PORT -s https://ipinfo.io | grep -E '"ip"|"country"|"city"'
}

list_and_test_services() {
    echo -e "\n${BLUE}=== Active Psiphon Services ===${NC}"
    SERVICES=$(ls /etc/systemd/system/psiphon-*.service 2>/dev/null)
    
    if [ -z "$SERVICES" ]; then
        echo -e "${YELLOW}No Psiphon locations are currently installed.${NC}"
        return
    fi

    for SVC in $SERVICES; do
        SVC_NAME=$(basename "$SVC")
        C_CODE=$(echo "$SVC_NAME" | sed 's/psiphon-//;s/\.service//' | tr '[:lower:]' '[:upper:]')
        
        # Extract Port from config
        PORT=$(grep -oP '"LocalSocksProxyPort":\s*\K\d+' "$CONFIG_BASE_DIR/$C_CODE/psiphon.config" 2>/dev/null)
        
        STATUS=$(systemctl is-active "$SVC_NAME")
        if [ "$STATUS" == "active" ]; then
            STATUS_STR="${GREEN}Active${NC}"
            IP_INFO=$(curl --socks5-hostname 127.0.0.1:$PORT -s --max-time 5 https://ipinfo.io | grep -oP '"country":\s*"\K[^"]+' || echo "N/A")
        else
            STATUS_STR="${RED}Inactive${NC}"
            IP_INFO="N/A"
        fi

        echo -e "Country: ${YELLOW}$C_CODE${NC} | SOCKS Port: ${GREEN}$PORT${NC} | Status: $STATUS_STR | Output Country: ${BLUE}$IP_INFO${NC}"
    done
}

remove_country_instance() {
    echo -e "\n${BLUE}=== Remove a Specific Location ===${NC}"
    SERVICES=$(ls /etc/systemd/system/psiphon-*.service 2>/dev/null)
    
    if [ -z "$SERVICES" ]; then
        echo -e "${YELLOW}No installed locations found to remove.${NC}"
        return
    fi

    echo "Installed Services:"
    select SVC in $SERVICES "Cancel"; do
        if [ "$SVC" == "Cancel" ] || [ -z "$SVC" ]; then
            return
        fi
        
        SVC_NAME=$(basename "$SVC")
        C_CODE=$(echo "$SVC_NAME" | sed 's/psiphon-//;s/\.service//' | tr '[:lower:]' '[:upper:]')
        
        systemctl stop "$SVC_NAME"
        systemctl disable "$SVC_NAME"
        rm -f "$SVC"
        rm -rf "$CONFIG_BASE_DIR/$C_CODE"
        systemctl daemon-reload
        
        echo -e "${GREEN}Location $C_CODE successfully removed.${NC}"
        break
    done
}

uninstall_all() {
    echo -e "${RED}=== Clean Uninstall All Psiphon Services and Files ===${NC}"
    read -p "Are you sure you want to uninstall all locations? (y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        systemctl stop psiphon-*.service 2>/dev/null
        systemctl disable psiphon-*.service 2>/dev/null
        rm -f /etc/systemd/system/psiphon-*.service
        systemctl daemon-reload

        rm -rf "$INSTALL_DIR"
        rm -rf "$CONFIG_BASE_DIR"
        rm -rf /root/.config/ca.psiphon.PsiphonTunnel.tunnel-core 2>/dev/null
        rm -rf /root/ca.psiphon.PsiphonTunnel.tunnel-core 2>/dev/null
        find / -type d -name "ca.psiphon.PsiphonTunnel.tunnel-core" -exec rm -rf {} + 2>/dev/null

        echo -e "${GREEN}All Psiphon instances and files have been completely uninstalled.${NC}"
    fi
}

# Main Menu
while true; do
    echo -e "\n${BLUE}==================================================${NC}"
    echo -e "${GREEN}      Psiphon Multi-Location Manager              ${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo "1) Install New Country Location (Custom Port)"
    echo "2) List Active Locations and Test IP"
    echo "3) Remove a Specific Location"
    echo "4) Clean Uninstall All Locations"
    echo "5) Exit"
    echo -e "${BLUE}--------------------------------------------------${NC}"
    read -p "Please select an option [1-5]: " CHOICE

    case $CHOICE in
        1) install_country_instance ;;
        2) list_and_test_services ;;
        3) remove_country_instance ;;
        4) uninstall_all ;;
        5) echo -e "${GREEN}Exiting.${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid option!${NC}" ;;
    esac
done
