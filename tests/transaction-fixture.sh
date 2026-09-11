#!/usr/bin/env bash
set -Eeuo pipefail
# Everything, including fake units and staging, is confined to the caller's test directory.
root=${1:?} fault=${2:?}
# shellcheck source=servarr-install-script.sh
source "$(dirname "$0")/../servarr-install-script.sh"
MODE=native ARCH=amd64
STATE_DIR="$root/state" BACKUP_ROOT="$root/backups" UNIT_DIR="$root/units" STAGING_ROOT="$root/staging"
ACCOUNT[radarr]=$(id -un) GROUP[radarr]=$(id -gn) PORT[radarr]=7878 EXISTING[radarr]=1
bin_dir() { printf '%s/bin' "$root"; }
data_dir() { printf '%s/data' "$root"; }
mkdir -p "$root/bin" "$root/data" "$STATE_DIR/apps" "$UNIT_DIR"
echo old-binary > "$root/bin/Radarr"
echo important-data > "$root/data/db"
echo old-unit > "$UNIT_DIR/radarr.service"
echo '{"mode":"native","version":"old"}' > "$STATE_DIR/apps/radarr.json"
ensure_packages() { :; }
ensure_account() { :; }
initialize_native_config() { :; }
systemctl() {
    printf '%s\n' "$*" >> "$root/calls"
    case $1 in
        is-active) return 0;;
        is-enabled) echo disabled;;
        daemon-reload) [[ $fault != promote ]];;
    esac
}
timeout() { shift; "$@"; }
journalctl() { :; }
prepare_binary() {
    [[ $fault != download ]] || die 'Injected download failure'
    mkdir "$2/application"
    echo new-binary > "$2/application/Radarr"
    SOURCE=https://example.org/release VERSION=new PAYLOAD_SHA=abc
}
native_ready() { [[ $fault != start ]]; }
if [[ $fault == backup ]]; then backup_data() { die 'Injected backup failure'; }; fi
install_native radarr
