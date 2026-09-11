#!/usr/bin/env bash
# This creates a disposable, privileged systemd container. Never mounts the Docker socket.
set -Eeuo pipefail
mode=${1:-docker} app=${2:-all} base=${3:-debian:12}
[[ $mode == native || $mode == docker ]] || exit 2
case $app in all|lidarr|prowlarr|radarr|sonarr|whisparr|whisparr-v3|seerr) ;; *) exit 2;; esac
case $base in debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;; *) exit 2;; esac
cd "$(dirname "$0")/.."
name="servarr-integration-$$-$RANDOM"
container=''
cleanup() {
    local result=$?
    trap - EXIT
    if [[ -n $container ]]; then
        docker exec "$container" journalctl --no-pager -n 40 || true
        docker rm -fv "$container" >/dev/null
    fi
    exit "$result"
}
trap cleanup EXIT
docker build --build-arg "BASE=$base" -t "$name" -f tests/Dockerfile .
container=$(docker run -d --name "$name" --privileged --cgroupns=private --tmpfs /run --tmpfs /run/lock \
    --mount type=volume,destination=/var/lib/docker --mount type=volume,destination=/var/lib/containerd \
    -v "$PWD:/work:ro" "$name" /sbin/init)
for _ in {1..30}; do
    if docker exec "$container" systemctl list-units >/dev/null 2>&1; then break; fi
    sleep 1
done
docker exec "$container" python3 /work/tests/terminal-smoke.py
if [[ $mode == docker ]]; then
    docker exec -e SERVARR_DISPOSABLE_TEST=yes "$container" bash /work/tests/docker-smoke.sh all
    docker exec -e SERVARR_DISPOSABLE_TEST=yes "$container" bash /work/tests/docker-failure-smoke.sh
else
    apps=("$app")
    [[ $app != all ]] || apps=(lidarr prowlarr radarr sonarr whisparr whisparr-v3 seerr)
    for app in "${apps[@]}"; do
        docker exec -e SERVARR_DISPOSABLE_TEST=yes "$container" bash /work/tests/native-smoke.sh "$app"
    done
fi
