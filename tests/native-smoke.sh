#!/usr/bin/env bash
# Destructive only inside a DISPOSABLE systemd container/VM. Never run on a real server.
set -Eeuo pipefail
[[ ${SERVARR_DISPOSABLE_TEST:-} == yes ]] || { echo 'Set SERVARR_DISPOSABLE_TEST=yes inside a disposable VM/container.' >&2; exit 1; }
# shellcheck source=servarr-install-script.sh
source "$(dirname "$0")/../servarr-install-script.sh"
check_platform
MODE=native
app=${1:?Application required}
valid_app "$app"
check_architecture "$app"
SELECTED=("$app")
ACCOUNT[$app]=$app GROUP[$app]=media PORT[$app]=${DEFAULT_PORT[$app]} EXISTING[$app]=0
[[ $app != seerr ]] || GROUP[$app]=seerr
ensure_packages jq python3 curl tar gzip iproute2 util-linux
install -d -m 700 "$STATE_DIR/apps" "$BACKUP_ROOT"
echo native > "$STATE_DIR/mode"
if [[ -f $(state_file "$app") ]]; then read_saved_app "$app"; inspect_native "$app"; fi
install_native "$app"
data=$(data_dir "$app")
echo preserve-me > "$data/installer-smoke-marker"
systemctl disable "$app.service"
EXISTING[$app]=1
inspect_native "$app"
install_native "$app"
[[ $(cat "$data/installer-smoke-marker") == preserve-me ]]
[[ $(systemctl is-enabled "$app.service" || true) == disabled ]]
systemctl is-active --quiet "$app.service"
test -f "$(state_file "$app")"
echo "PASS: $app fresh install/reinstall/data preservation/disabled state"
