#!/bin/bash
#
# Servarr Installation Script
# Author: Christian Blank (cyneric)
# Version: 3.0.13
# Date: 2024-11-03
# Repository: https://github.com/cyneric/servarr-install-script
#
# Description:
#   This script automates the installation of various Servarr applications
#   (Lidarr, Prowlarr, Radarr, Readarr, Sonarr, and Whisparr) on
#   Debian-based Linux distributions. It handles all aspects of installation
#   including dependencies, user/group creation, permissions, and service setup.
#
# Usage:
#   sudo ./servarr-install-script.sh
#
# Requirements:
#   - Debian-based Linux distribution
#   - Root privileges
#   - Internet connection
#
# Notes:
#   - The script must be run as root
#   - Default installation directory is /opt/<AppName>
#   - Default data directory is /var/lib/<appname>/
#   - Services are configured to start automatically

# Constants
readonly SCRIPT_VERSION="3.0.13"
readonly SCRIPT_DATE="2024-11-03"
readonly SCRIPT_AUTHOR="Christian Blank (cyneric)"
readonly SCRIPT_URL="https://github.com/cyneric/servarr-install"

# Color definitions for better readability
readonly GREEN='\033[0;32m'  # Success messages
readonly YELLOW='\033[1;33m' # Warnings and important info
readonly RED='\033[0;31m'    # Error messages
readonly BROWN='\033[0;33m'  # Highlights and notices
readonly RESET='\033[0m'     # Reset color

# Enable strict error handling
set -euo pipefail

# Root privilege check
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root!\nExiting script!${RESET}"
    exit 1
fi

# ASCII art title splash with feature description
echo -e ${BROWN}
echo -e "╔══════════════════════════════════════════════════════════════════════════════╗"
echo -e "║                                                                              ║"
echo -e "║                    🚀 Servarr Applications Installation Tool 🚀              ║"
echo -e "║                                                                              ║"
echo -e "║  ⚡️ A powerful installer that automates the setup process for all your      ║"
echo -e "║     favorite *arr applications. This script handles permissions, services,   ║"
echo -e "║     and dependencies to get you up and running quickly and securely.        ║"
echo -e "║                                                                              ║"
echo -e "║  🔧 Features:                                                               ║"
echo -e "║     • Automated dependency installation                                      ║"
echo -e "║     • Proper service configuration                                          ║"
echo -e "║     • Secure permissions setup                                              ║"
echo -e "║     • Multi-architecture support                                            ║"
echo -e "║                                                                              ║"
echo -e "╚══════════════════════════════════════════════════════════════════════════════╝"
echo -e ${RESET}

# Display script information
echo -e "\nRunning Servarr Install Script - Version ${BROWN}[$SCRIPT_VERSION]${RESET} as of ${BROWN}[$SCRIPT_DATE]${RESET}"
echo -e "Author: ${BROWN}$SCRIPT_AUTHOR${RESET}"
echo -e "Source: ${BROWN}$SCRIPT_URL${RESET}\n"

# Application configurations
# Format: "port|dependencies|umask|branch"
declare -A APP_CONFIGS=(
    ["lidarr"]="8686|curl sqlite3 libchromaprint-tools mediainfo|0002|master"
    ["prowlarr"]="9696|curl sqlite3|0002|master"
    ["radarr"]="7878|curl sqlite3|0002|master"
    ["readarr"]="8787|curl sqlite3|0002|develop"
    ["whisparr"]="6969|curl sqlite3|0002|nightly"
    ["sonarr"]="8989|curl sqlite3|0002|main"
)

# Application selection menu
echo -e "\nSelect the application to install:\n"
select app in "${!APP_CONFIGS[@]}" quit; do
    if [[ $app == "quit" ]]; then
        exit 0
    elif [[ -n ${APP_CONFIGS[$app]:-} ]]; then
        # Parse configuration string into separate variables
        IFS='|' read -r app_port app_prereq app_umask branch <<<"${APP_CONFIGS[$app]}"
        break
    else
        echo "Invalid option $REPLY"
    fi
done

# Define installation paths
readonly INSTALL_DIR="/opt"               # Base installation directory
readonly BIN_DIR="${INSTALL_DIR}/${app^}" # Application binary directory
readonly DATA_DIR="/var/lib/$app/"        # Application data directory
readonly APP_BIN=${app^}                  # Binary name

# Display warning for non-Prowlarr apps
if [[ $app != 'prowlarr' ]]; then
    echo -e "\n${RED}   WARNING! WARNING! WARNING!${RESET}\n"
    echo -e "   It is ${RED}CRITICAL${RESET} that the ${BROWN}User${RESET} and ${BROWN}Group${RESET} you select"
    echo -e "   to run ${BROWN}[${app^}]${RESET} will have both ${RED}READ${RESET} and ${RED}WRITE${RESET} access"
    echo -e "   to your Media Library and Download Client directories!${RESET}"
    sleep 5
fi

# Check install directory
if [[ "$INSTALL_DIR" == "$(dirname -- "$(readlink -f -- "$0")")" ]] ||
    [[ "$BIN_DIR" == "$(dirname -- "$(readlink -f -- "$0")")" ]]; then
    echo -e "\n${RED}Error!${RESET} You should not run this script from the intended install directory."
    echo "Please re-run it from another directory."
    echo "Exiting Script!"
    exit 1
fi

# Get user/group
read -r -p "What user should [${app^}] run as? (Default: $app): " app_uid
app_uid=$(echo "${app_uid:-$app}" | tr -d ' ')

read -r -p "What group should [${app^}] run as? (Default: media): " app_guid
app_guid=$(echo "${app_guid:-media}" | tr -d ' ')

# Display configuration
echo -e "\n${BROWN}[${app^}]${RESET} selected for installation."
echo -e "\n${BROWN}[${app^}]${RESET} will then be installed to ${BROWN}[$BIN_DIR]${RESET} and use ${BROWN}[$DATA_DIR]${RESET} for the AppData Directory."

if [[ $app == 'prowlarr' ]]; then
    echo -e "\n${BROWN}[${app^}]${RESET} will run as the user ${BROWN}[$app_uid]${RESET} and group ${BROWN}[$app_guid]${RESET}."
else
    echo -e "\n${BROWN}[${app^}]${RESET} will run as the user ${BROWN}[$app_uid]${RESET} and group ${BROWN}[$app_guid]${RESET}."
    echo -e "\n   By continuing, you've ${RED}CONFIRMED${RESET} that that ${BROWN}[$app_uid]${RESET} and ${BROWN}[$app_guid]${RESET}"
    echo -e "   will have both ${RED}READ${RESET} and ${RED}WRITE${RESET} access to all required directories.\n"
fi

# Confirm installation
read -r -p "Please type 'yes' to continue with the installation: " response
if [[ ${response,,} != "yes" ]]; then
    echo "Invalid response. Operation is canceled!"
    echo "Exiting script!"
    exit 0
fi

# Create user/group
if [[ "$app_guid" != "$app_uid" ]] && ! getent group "$app_guid" >/dev/null; then
    groupadd "$app_guid"
fi

if ! getent passwd "$app_uid" >/dev/null; then
    adduser --system --no-create-home --ingroup "$app_guid" "$app_uid"
    echo -e "\nCreated User ${YELLOW}$app_uid${RESET}"
    echo -e "\nCreated Group ${YELLOW}$app_guid${RESET}."
    sleep 3
fi

if ! getent group "$app_guid" | grep -qw "$app_uid"; then
    echo -e "\nUser ${YELLOW}$app_uid${RESET} did not exist in Group ${YELLOW}$app_guid${RESET}."
    usermod -a -G "$app_guid" "$app_uid"
    echo -e "\nAdded User ${YELLOW}$app_uid${RESET} to Group ${YELLOW}$app_guid${RESET}."
    sleep 3
fi

# Stop existing service
if service --status-all | grep -Fq "$app"; then
    systemctl disable --now "$app".service
    echo "Stopped existing $app."
fi

# Create directories
mkdir -p "$DATA_DIR"
chown -R "$app_uid":"$app_guid" "$DATA_DIR"
chmod 775 "$DATA_DIR"
echo -e "\nDirectories ${YELLOW}$BIN_DIR${RESET} and ${YELLOW}$DATA_DIR${RESET} created!"

# Check prerequisites
echo -e "\n${YELLOW}Checking Pre-Requisite Packages...${RESET}"
sleep 3

missing_packages=()
for pkg in $app_prereq; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        missing_packages+=("$pkg")
    fi
done

if ((${#missing_packages[@]} == 0)); then
    echo -e "\n${GREEN}All prerequisite packages are already installed!${RESET}"
else
    echo -e "\nInstalling missing prerequisite packages: ${BROWN}${missing_packages[*]}${RESET}"
    apt-get update && apt-get install -y "${missing_packages[@]}"
fi

# Download and install
echo -e "\n${YELLOW}Checking architecture...${RESET}"
readonly ARCH=$(dpkg --print-architecture)

if [[ $app == 'sonarr' ]]; then
    dlbase="https://services.sonarr.tv/v1/download/$branch/latest?version=4&os=linux"
else
    dlbase="https://$app.servarr.com/v1/update/$branch/updatefile?os=linux&runtime=netcore"
fi

case "$ARCH" in
"amd64") DLURL="${dlbase}&arch=x64" ;;
"armhf") DLURL="${dlbase}&arch=arm" ;;
"arm64") DLURL="${dlbase}&arch=arm64" ;;
*)
    echo -e "${RED}Architecture $ARCH is not supported!\nExiting installer script!${RESET}"
    exit 1
    ;;
esac

echo -e "${YELLOW}Removing old tarballs...${RESET}"
rm -f "${app^}".*.tar.gz

echo -e "\n${YELLOW}Downloading and extracting...${RESET}"
wget --content-disposition "$DLURL"
tar -xf "${app^}".*.tar.gz

echo -e "\n${YELLOW}Installing...${RESET}"
rm -rf "$BIN_DIR"
mv "${app^}" "$INSTALL_DIR"
chown -R "$app_uid":"$app_guid" "$BIN_DIR"
chmod 775 "$BIN_DIR"

touch "$DATA_DIR/update_required"
chown "$app_uid":"$app_guid" "$DATA_DIR/update_required"

rm -f "${app^}".*.tar.gz

echo -e "\nSuccessfully installed ${BROWN}[${app^}]${RESET}!"

# Create service file
echo -e "\nConfiguring service..."
cat >"/etc/systemd/system/$app.service" <<EOF
[Unit]
Description=${app^} Daemon
After=syslog.target network.target

[Service]
User=$app_uid
Group=$app_guid
UMask=$app_umask
Type=simple
ExecStart=$BIN_DIR/$APP_BIN -nobrowser -data=$DATA_DIR
TimeoutStopSec=20
KillMode=process
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

# Start service
echo -e "\n${BROWN}[${app^}]${RESET} is starting..."
systemctl daemon-reload
systemctl enable --now "$app"

# Wait for service
while ! systemctl is-active --quiet "$app"; do
    sleep 1
done

# Final status
readonly IP_LOCAL=$(hostname -I | awk '{print $1}')
echo -e "\nChecking connection at http://$IP_LOCAL:$app_port..."
sleep 3

if systemctl is-active --quiet "$app"; then
    echo -e "\nSuccessful connection!"
    echo -e "\nBrowse to ${GREEN}http://$IP_LOCAL:$app_port${RESET} for the GUI."
else
    echo -e "\n${RED}${app^} failed to start.${RESET}"
    echo -e "\nPlease try again."
fi

exit 0
