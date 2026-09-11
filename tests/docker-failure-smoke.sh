#!/usr/bin/env bash
# Requires the disposable full stack created by docker-smoke.sh.
set -Eeuo pipefail
[[ ${SERVARR_DISPOSABLE_TEST:-} == yes ]] || exit 1
# shellcheck source=servarr-install-script.sh
source "$(dirname "$0")/../servarr-install-script.sh"
MODE=docker ARCH=$(dpkg --print-architecture)
SELECTED=(radarr)
read_saved_app radarr
TIMEZONE=$(jq -r .timezone "$STACK_DIR/settings.json")
MEDIA_ROOT=$(jq -r .media_root "$STACK_DIR/settings.json")
fault=${1:-verify}
case $fault in
    overrides)
        override_stage=$(mktemp -d)
        trap 'rm -rf -- "$override_stage"' EXIT
        cp "$STACK_DIR/compose.yaml" "$override_stage/compose.yaml"
        STACK_DIR=$override_stage
        printf '%s\n' '{"services":{"radarr":{"logging":{"driver":"json-file","options":{"max-size":"10m"}}}}}' > "$STACK_DIR/compose.override.yaml"
        validate_compose "$STACK_DIR/compose.yaml" "$STACK_DIR/effective.json"
        for override in '{"user":"0:0"}' '{"network_mode":"host"}' '{"volumes":["/tmp:/config"]}'; do
            printf '{"services":{"radarr":%s}}\n' "$override" > "$STACK_DIR/compose.override.yaml"
            if (validate_compose "$STACK_DIR/compose.yaml" "$STACK_DIR/effective.json"); then
                echo "Protected override was accepted: $override" >&2; exit 1
            fi
        done
        echo 'PASS: logging override accepted; identity, networking and storage overrides rejected'
        ;;
    pull)
        docker() { if [[ $1 == pull ]]; then return 42; else command docker "$@"; fi; }
        install_stack
        ;;
    backup)
        backup_data() { die 'Injected offline backup failure'; }
        install_stack
        ;;
    start)
        docker_ready() { die 'Injected readiness failure after launch'; }
        install_stack
        ;;
    verify)
        bash "$0" overrides
        radarr=$(container_for radarr)
        sonarr=$(container_for sonarr)
        old_state=$(sha256sum "$(state_file radarr)")
        old_compose=$(sha256sum "$STACK_DIR/compose.yaml")
        for fault in pull backup; do
            if bash "$0" "$fault"; then echo "Fault $fault did not fail" >&2; exit 1; fi
            [[ $(docker inspect -f '{{.State.Running}}' "$radarr") == true ]]
            [[ $(sha256sum "$(state_file radarr)") == "$old_state" ]]
            [[ $(sha256sum "$STACK_DIR/compose.yaml") == "$old_compose" ]]
        done
        if bash "$0" start; then echo 'Readiness fault did not fail' >&2; exit 1; fi
        [[ $(docker inspect -f '{{.State.Running}}' "$radarr") == false ]]
        [[ $(docker inspect -f '{{.State.Running}}' "$sonarr") == true ]]
        [[ $(cat "$(data_dir radarr)/installer-smoke-marker") == preserve-me ]]
        compose "$STACK_DIR/compose.yaml" up -d --no-deps radarr
        docker_ready radarr
        # Verify shared group permissions and actual hardlinks under the single data mount.
        uid=$(jq -r .uid "$(state_file radarr)"); gid=$(jq -r .gid "$(state_file radarr)")
        docker exec --user "$uid:$gid" "$radarr" sh -ec 'mkdir -p /data/installer-test/downloads /data/installer-test/media; echo sample > /data/installer-test/downloads/file; ln /data/installer-test/downloads/file /data/installer-test/media/file; test "$(stat -c %i /data/installer-test/downloads/file)" = "$(stat -c %i /data/installer-test/media/file)"'
        docker exec "$(container_for seerr)" node -e 'require("http").get("http://radarr:7878/ping", r => { if(r.statusCode !== 200) process.exit(1); r.resume(); }).on("error", () => process.exit(1));'
        echo 'PASS: Docker pull/backup/startup faults, unrelated-service preservation, hardlinks and service DNS'
        ;;
    *) exit 2;;
esac
