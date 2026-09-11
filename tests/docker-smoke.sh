#!/usr/bin/env bash
# Run only in a disposable systemd VM or privileged Docker-in-Docker container.
set -Eeuo pipefail
[[ ${SERVARR_DISPOSABLE_TEST:-} == yes ]] || { echo 'Disposable host required.' >&2; exit 1; }
# shellcheck source=servarr-install-script.sh
source "$(dirname "$0")/../servarr-install-script.sh"
check_platform
MODE=docker
parse_selection "${1:-all}"
ensure_packages jq python3 curl tar gzip iproute2 util-linux
check_docker_environment
install -d -m 700 "$STATE_DIR/apps" "$BACKUP_ROOT"
echo docker > "$STATE_DIR/mode"
MEDIA_ROOT=/data TIMEZONE=Etc/UTC
for app in "${SELECTED[@]}"; do
    ACCOUNT[$app]=$app GROUP[$app]=media PORT[$app]=${DEFAULT_PORT[$app]} EXISTING[$app]=0
    [[ $app != seerr ]] || GROUP[$app]=seerr
    read_saved_app "$app"
    check_architecture "$app"
done
install_stack
for app in "${SELECTED[@]}"; do echo preserve-me > "$(data_dir "$app")/installer-smoke-marker"; done
before=$(compose "$STACK_DIR/compose.yaml" ps -q)
SELECTED=(radarr)
EXISTING[radarr]=1
NEED_DOCKER=0
install_stack
for app in "${APP_IDS[@]}"; do
    [[ -f $(state_file "$app") ]] || continue
    [[ $(cat "$(data_dir "$app")/installer-smoke-marker") == preserve-me ]]
    [[ -n $(container_for "$app") ]]
done
echo "PASS: stack install/selective update/data preservation (initial containers: $before)"
