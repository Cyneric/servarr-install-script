#!/usr/bin/env bash
# Servarr installer, Copyright (c) 2026 Christian Blank. MIT license.
# Community source: Servarr/Wiki, installer commit 57803a80a5177334e346979944ac4bcd65e59044.
# Deliberately self-contained: download this file, then run sudo bash ./servarr-install-script.sh.
set -Eeuo pipefail

readonly SCRIPT_VERSION=4.0.0
readonly SCRIPT_DATE=2026-09-11
readonly SCRIPT_URL=https://github.com/Cyneric/servarr-install-script
readonly NODE_VERSION=22.23.2 PNPM_VERSION=10.24.0
APP_IDS=(lidarr prowlarr radarr sonarr whisparr whisparr-v3 seerr)
declare -gA LABEL=([lidarr]=Lidarr [prowlarr]=Prowlarr [radarr]=Radarr [sonarr]=Sonarr [whisparr]='Whisparr v2' [whisparr-v3]='Whisparr v3' [seerr]=Seerr)
declare -gA BINARY=([lidarr]=Lidarr [prowlarr]=Prowlarr [radarr]=Radarr [sonarr]=Sonarr [whisparr]=Whisparr [whisparr-v3]=Whisparr [seerr]=Seerr)
declare -gA DIRECTORY=([lidarr]=Lidarr [prowlarr]=Prowlarr [radarr]=Radarr [sonarr]=Sonarr [whisparr]=Whisparr [whisparr-v3]=Whisparr-v3 [seerr]=Seerr)
declare -gA DEFAULT_PORT=([lidarr]=8686 [prowlarr]=9696 [radarr]=7878 [sonarr]=8989 [whisparr]=6969 [whisparr-v3]=6970 [seerr]=5055)
declare -gA IMAGE=([lidarr]=lscr.io/linuxserver/lidarr:latest [prowlarr]=lscr.io/linuxserver/prowlarr:latest [radarr]=lscr.io/linuxserver/radarr:latest [sonarr]=lscr.io/linuxserver/sonarr:latest [whisparr]=ghcr.io/hotio/whisparr:v2 [whisparr-v3]=ghcr.io/hotio/whisparr:v3 [seerr]=ghcr.io/seerr-team/seerr:latest)
declare -gA ACCOUNT=() GROUP=() PORT=() EXISTING=()
SELECTED=()
MODE='' ARCH='' OS_ID='' OS_VERSION='' OS_CODENAME='' MEDIA_ROOT=/data TIMEZONE=Etc/UTC
STATE_DIR=/var/lib/servarr-installer
STACK_DIR=/opt/servarr-stack
DOCKER_DATA=/var/lib/servarr/docker
BACKUP_ROOT=/var/backups/servarr
RUNTIME_DIR=/opt/servarr-runtime/seerr
UNIT_DIR=/etc/systemd/system
STAGING_ROOT=/opt
NEED_DOCKER=0 NEED_COMPOSE=0 DOCKER_AVAILABLE=0
PROMPT_FD=0

log() { printf '%s\n' "$*"; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
valid_app() { [[ ${1:-} =~ ^[a-z][a-z0-9-]*$ ]] && [[ -v LABEL[$1] ]]; }
valid_account() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,30}$ && $1 != root ]]; }
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && ((10#$1 <= 65535)); }
# Deliberately constrain paths used by systemd, Compose and recovery commands.
valid_path() { [[ $1 =~ ^/[a-zA-Z0-9_./-]+$ && $1 != / && $1 != *'/../'* && $1 != */.. && $1 != *'/./'* ]]; }
media_app() { [[ $1 != prowlarr && $1 != seerr ]]; }
data_dir() { if [[ $MODE == docker ]]; then printf '%s/%s' "$DOCKER_DATA" "$1"; else printf '/var/lib/%s' "$1"; fi; }
bin_dir() { printf '/opt/%s' "${DIRECTORY[$1]}"; }
state_file() { printf '%s/apps/%s.json' "$STATE_DIR" "$1"; }

prompt() {
    local name=$1 question=$2 default=${3:-} prompt_response
    printf '%s' "$question" >&2
    [[ -z $default ]] || printf ' [%s]' "$default" >&2
    printf ': ' >&2
    if ! IFS= read -r -u "$PROMPT_FD" prompt_response; then die 'Input closed; nothing further will be installed.'; fi
    printf -v "$name" '%s' "${prompt_response:-$default}"
}

parse_selection() {
    local answer=${1//,/ } token id
    local -A seen=()
    SELECTED=()
    if [[ $answer == all ]]; then SELECTED=("${APP_IDS[@]}"); return 0; fi
    for token in $answer; do
        if [[ $token =~ ^[1-7]$ ]]; then id=${APP_IDS[$((token-1))]}; else id=$token; fi
        valid_app "$id" || { SELECTED=(); return 1; }
        if [[ ! -v seen[$id] ]]; then SELECTED+=("$id"); seen[$id]=1; fi
    done
    ((${#SELECTED[@]} > 0))
}

check_platform() {
    [[ $(uname -s) == Linux ]] || die 'Run this installer on the target Linux host.'
    ((EUID == 0)) || die 'Run with sudo or as root.'
    [[ -f /etc/os-release ]] || die 'Cannot identify this operating system.'
    # This is the root-owned operating-system identity file, never installer state.
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID=$ID OS_VERSION=$VERSION_ID OS_CODENAME=${VERSION_CODENAME:-}
    case "$OS_ID:$OS_VERSION" in
        debian:12|debian:13|ubuntu:22.04|ubuntu:24.04) ;;
        *) die 'Supported targets: Debian 12/13 and Ubuntu 22.04/24.04. Derivatives require manual setup.' ;;
    esac
    [[ $OS_CODENAME =~ ^[a-z]+$ ]] || die 'Invalid distribution codename.'
    ARCH=$(dpkg --print-architecture)
    [[ $ARCH == amd64 || $ARCH == arm64 || $ARCH == armhf ]] || die "Unsupported architecture: $ARCH"
    [[ -d /run/systemd/system ]] || die 'A running systemd host is required (including for Docker Engine).'
}

check_architecture() {
    local app=$1
    if [[ $ARCH == armhf && ( $MODE == docker || $app == seerr ) ]]; then
        die "$MODE ${LABEL[$app]} supports amd64/arm64 only. Native Arr installations support armhf."
    fi
}

ensure_packages() {
    local pkg status missing=()
    for pkg in "$@"; do
        status=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null) || status=''
        [[ $status == 'install ok installed' ]] || missing+=("$pkg")
    done
    if ((${#missing[@]})); then
        log "Installing packages: ${missing[*]}"
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    fi
}

ensure_account() {
    local user=$1 group=$2 gid
    if ! valid_account "$user" || ! valid_account "$group"; then die 'Invalid service identity.'; fi
    getent group "$group" >/dev/null || groupadd --system "$group"
    getent passwd "$user" >/dev/null || useradd --system --no-create-home --gid "$group" --shell /usr/sbin/nologin "$user"
    [[ $(id -u "$user") != 0 ]] || die 'Applications cannot run with UID 0.'
    gid=$(getent group "$group" | cut -d: -f3)
    [[ $gid != 0 ]] || die 'Applications cannot use GID 0.'
    if [[ " $(id -G "$user") " != *" $gid "* ]]; then usermod -a -G "$group" "$user"; fi
}

assert_real_path() {
    local path=$1 cursor=$1
    valid_path "$path" || die "Unsupported path: $path (use letters, digits, /, ., _, -)."
    while [[ $cursor != / ]]; do
        [[ ! -L $cursor ]] || die "Refusing symlinked installation path: $cursor"
        cursor=$(dirname "$cursor")
    done
}

native_unit_exists() { [[ $(systemctl show "$1.service" -p LoadState --value) != not-found ]]; }

inspect_native() {
    local app=$1 unit="${1}.service" fragment command user group masked
    local bindir datadir
    bindir=$(bin_dir "$app"); datadir="/var/lib/$app"
    assert_real_path "$bindir"; assert_real_path "$datadir"
    if native_unit_exists "$app"; then
        [[ $MODE == native ]] || die "$app already has a native service. Cross-mode migration is not supported."
        fragment=$(systemctl show "$unit" -p FragmentPath --value)
        [[ $fragment == "$UNIT_DIR/$unit" && ! -L $fragment ]] || die "Custom or package-managed $unit is not supported."
        if dpkg-query -S "$fragment" >/dev/null 2>&1; then die "Package-managed unit: $unit"; fi
        command=$(systemctl show "$unit" -p ExecStart --value)
        if [[ $app == seerr ]]; then
            [[ -f $(state_file "$app") ]] || die 'Only installer-managed native Seerr reinstalls are supported.'
            [[ $command == *"$RUNTIME_DIR/"* && $command == *'/opt/Seerr/dist/index.js'* ]] || die 'Custom Seerr command; refusing replacement.'
        else
            [[ $command == *"path=$bindir/${BINARY[$app]} ;"* && $command == *"-data=$datadir"* ]] || die "Custom binary/data paths in $unit; manual migration required."
            # Check the complete -data token, not a prefix such as /var/lib/radarr-other.
            [[ $command =~ -data=([^\ ;]+) ]] || die "Missing data path in $unit"
            [[ ${BASH_REMATCH[1]%/} == "$datadir" ]] || die "Custom data directory in $unit"
        fi
        user=$(systemctl show "$unit" -p User --value)
        group=$(systemctl show "$unit" -p Group --value)
        [[ -n $group ]] || group=$(id -gn "$user")
        if ! valid_account "$user" || ! valid_account "$group"; then die "Unsupported identity in $unit"; fi
        ACCOUNT[$app]=$user GROUP[$app]=$group EXISTING[$app]=1
        if [[ $app == seerr ]]; then
            [[ -f /etc/seerr/seerr.conf && ! -L /etc/seerr/seerr.conf ]] || die 'Missing or symlinked Seerr environment file.'
            [[ $(sed -n 's/^CONFIG_DIRECTORY=//p' /etc/seerr/seerr.conf) == /var/lib/seerr ]] || die 'Custom Seerr data directory; manual migration required.'
            PORT[$app]=$(sed -n 's/^PORT=//p' /etc/seerr/seerr.conf)
        elif [[ -f $datadir/config.xml ]]; then
            if [[ $app == whisparr ]] && grep -Eqi '<Branch>eros[^<]*</Branch>|<GithubOwnerRepo>whisparr/whisparr-eros</GithubOwnerRepo>' "$datadir/config.xml"; then
                die 'Whisparr v3 detected in the legacy v2 directory. Move it explicitly; refusing a v2 downgrade.'
            fi
            PORT[$app]=$(tr '\n' ' ' < "$datadir/config.xml" | sed -n 's/.*<Port>\([0-9]*\)<\/Port>.*/\1/p')
        fi
        valid_port "${PORT[$app]}" || die "Cannot determine the existing port for $app."
        masked=$(systemctl is-enabled "$unit" 2>/dev/null) || true
        [[ $masked != masked ]] || die "$unit is masked; resolve that before reinstalling."
    elif [[ -e $bindir || -e $datadir ]]; then
        die "Found unmanaged $app files at $bindir or $datadir. Refusing to overwrite or migrate them."
    fi
}

check_docker_environment() {
    local context endpoint security pkg
    if [[ $MODE == native ]]; then
        if command -v docker >/dev/null && [[ -z ${DOCKER_HOST:-}${DOCKER_CONTEXT:-}${DOCKER_TLS_VERIFY:-} ]]; then
            context=$(docker context show)
            endpoint=$(docker context inspect "$context" --format '{{.Endpoints.docker.Host}}')
            if [[ $endpoint == unix:///var/run/docker.sock ]] && docker info >/dev/null 2>&1; then DOCKER_AVAILABLE=1; fi
        fi
        return 0
    fi
    if command -v docker >/dev/null; then
        [[ -z ${DOCKER_HOST:-} && -z ${DOCKER_CONTEXT:-} && -z ${DOCKER_TLS_VERIFY:-} ]] || die 'Unset Docker connection overrides; only the local engine is supported.'
        context=$(docker context show)
        endpoint=$(docker context inspect "$context" --format '{{.Endpoints.docker.Host}}')
        [[ $endpoint == unix:///var/run/docker.sock ]] || die "Unsupported Docker endpoint: $endpoint"
        docker info >/dev/null 2>&1 || die 'Docker is installed but unavailable. Start the local engine and retry.'
        security=$(docker info --format '{{json .SecurityOptions}}')
        [[ $security != *rootless* ]] || die 'Rootless Docker is outside the supported installation modes.'
        DOCKER_AVAILABLE=1
        if ! docker compose version >/dev/null 2>&1; then
            if ! dpkg-query -W docker-ce >/dev/null 2>&1; then die 'Install a compatible Compose plugin for your existing Docker distribution.'; fi
            NEED_COMPOSE=1
        fi
    elif [[ $MODE == docker ]]; then
        for pkg in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
            if [[ $(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true) == 'install ok installed' ]]; then
                die "Docker installation conflicts with $pkg. Resolve the package choice manually; no packages were removed."
            fi
        done
        NEED_DOCKER=1
    fi
}

container_for() { docker ps -aq --filter label=com.docker.compose.project=servarr --filter "label=com.docker.compose.service=$1"; }

check_container_conflicts() {
    local app=$1 ids id project service names
    ((DOCKER_AVAILABLE)) || return 0
    # Include stopped containers; they may restart after boot.
    ids=$(docker ps -aq)
    for id in $ids; do
        service=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "$id")
        names=$(docker inspect -f '{{.Name}}' "$id")
        if [[ $service == "$app" || $names == "/$app" ]]; then
            project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$id")
            [[ $MODE == docker && $project == servarr && -f $(state_file "$app") ]] || die "Existing container for $app detected; automatic adoption/migration is not supported."
        fi
    done
}

read_saved_app() {
    local app=$1 saved mode
    saved=$(state_file "$app")
    [[ -f $saved ]] || return 0
    command -v jq >/dev/null || die 'jq is required to read existing installer state.'
    mode=$(jq -er '.mode' "$saved")
    [[ $mode == "$MODE" ]] || die "$app is managed in $mode mode; cross-mode migration is not supported."
    ACCOUNT[$app]=$(jq -er '.user' "$saved")
    GROUP[$app]=$(jq -er '.group' "$saved")
    PORT[$app]=$(jq -er '.port | tostring' "$saved")
    if ! valid_account "${ACCOUNT[$app]}" || ! valid_account "${GROUP[$app]}" || ! valid_port "${PORT[$app]}"; then die "Invalid saved configuration for $app"; fi
    EXISTING[$app]=1
}

configure() {
    local answer id i=1 saved_mode user group port settings
    if [[ -f $STATE_DIR/mode ]]; then
        saved_mode=$(cat "$STATE_DIR/mode")
        [[ $saved_mode == native || $saved_mode == docker ]] || die 'Invalid saved deployment mode.'
        MODE=$saved_mode
        log "Existing installation: $MODE (adding or updating apps preserves this mode)."
    else
        log '1) Docker Compose stack   2) Native systemd services   q) Quit'
        while :; do
            prompt answer 'Deployment mode'
            case $answer in 1|docker) MODE=docker; break;; 2|native) MODE=native; break;; q|quit) exit 0;; *) log 'Choose 1 or 2.';; esac
        done
    fi
    for id in "${APP_IDS[@]}"; do log "$i) ${LABEL[$id]}"; ((i+=1)); done
    while :; do
        prompt answer 'Applications: numbers/names separated by spaces or commas, all, or q'
        [[ $answer != q && $answer != quit ]] || exit 0
        parse_selection "$answer" && break
        log 'Invalid selection. Choose one or more listed applications.'
    done
    check_docker_environment
    for id in "${SELECTED[@]}"; do
        check_architecture "$id"
        ACCOUNT[$id]=$id GROUP[$id]=media PORT[$id]=${DEFAULT_PORT[$id]} EXISTING[$id]=0
        [[ $id != seerr ]] || GROUP[$id]=seerr
        read_saved_app "$id"
        inspect_native "$id"
        check_container_conflicts "$id"
        if [[ $MODE == docker && ${EXISTING[$id]} == 0 && -e $(data_dir "$id") ]]; then
            die "Unmanaged Docker app data found for $id; refusing automatic adoption."
        fi
        if [[ ${EXISTING[$id]} == 0 ]]; then
            prompt user "${LABEL[$id]} service user" "${ACCOUNT[$id]}"
            prompt group "${LABEL[$id]} service group" "${GROUP[$id]}"
            if ! valid_account "$user" || ! valid_account "$group"; then die 'Use a non-root Linux account name (letters, numbers, _, -).'; fi
            ACCOUNT[$id]=$user GROUP[$id]=$group
            prompt port "${LABEL[$id]} host port" "${PORT[$id]}"
            valid_port "$port" || die 'Port must be an integer from 1 to 65535.'
            PORT[$id]=$port
        fi
    done
    if [[ $MODE == docker ]]; then
        assert_real_path "$STACK_DIR"; assert_real_path "$DOCKER_DATA"
        settings="$STACK_DIR/settings.json"
        if [[ -f $settings ]]; then
            TIMEZONE=$(jq -er '.timezone' "$settings"); MEDIA_ROOT=$(jq -er '.media_root' "$settings")
        else
            if [[ -d $STACK_DIR ]]; then
                [[ -f $STATE_DIR/mode && -z $(find "$STACK_DIR" -mindepth 1 -maxdepth 1 -print -quit) ]] || die "Unmanaged stack directory $STACK_DIR already exists."
            fi
            prompt TIMEZONE 'Timezone' "$(cat /etc/timezone 2>/dev/null || printf Etc/UTC)"
            prompt MEDIA_ROOT 'Common parent directory for downloads and media' /data
        fi
        valid_path "$MEDIA_ROOT" || die 'Use a simple absolute media path without spaces or traversal.'
        [[ $MEDIA_ROOT != /opt* && $MEDIA_ROOT != /etc* && $MEDIA_ROOT != /var/lib* && $MEDIA_ROOT != /usr* && $MEDIA_ROOT != /root* && $MEDIA_ROOT != /proc* && $MEDIA_ROOT != /sys* && $MEDIA_ROOT != /dev* ]] || die 'Select a dedicated media/download directory.'
        [[ $TIMEZONE =~ ^[a-zA-Z0-9_+/-]+$ && $TIMEZONE != *..* && -f /usr/share/zoneinfo/$TIMEZONE ]] || die 'Unknown timezone.'
    fi
    log ''
    log "Installation summary ($SCRIPT_VERSION): $MODE on $OS_ID $OS_VERSION / $ARCH"
    for id in "${SELECTED[@]}"; do
        log "  ${LABEL[$id]}: ${ACCOUNT[$id]}:${GROUP[$id]}, host port ${PORT[$id]}, data $(data_dir "$id")"
        [[ $MODE != docker ]] || log "    Image channel: ${IMAGE[$id]}"
    done
    if [[ $MODE == docker ]]; then
        log "  Stack: $STACK_DIR; media: $MEDIA_ROOT (same path in containers); timezone: $TIMEZONE"
        log '  Published ports bind to all host interfaces. Docker manages its own networking rules.'
        ((NEED_DOCKER == 0)) || log '  Install Docker Engine, containerd and Compose from the official Docker apt repository.'
        ((NEED_COMPOSE == 0)) || log '  Install Docker Compose plugin for the existing Docker CE engine.'
    else
        log '  Install missing download/runtime packages; Seerr additionally needs isolated Node/pnpm and compiler tools.'
    fi
    log "  Reinstalls back up application data/configuration under $BACKUP_ROOT. Media ownership is not changed."
    prompt answer "Type yes to install/update these applications"
    [[ ${answer,,} == yes ]] || { log 'Canceled.'; exit 0; }
}

fetch() {
    # Do not log signed redirect URLs. Persist the public source URL and payload hash instead.
    curl --fail --location --silent --show-error --retry 3 --retry-delay 2 --retry-max-time 120 \
        --connect-timeout 15 --max-time 1800 --proto '=https' --proto-redir '=https' \
        --output "$2" --dump-header "${3:-/dev/null}" "$1"
}

artifact_version() {
    python3 - "$1" "$2" <<'PY'
import email.message, re, sys
headers = open(sys.argv[1]).read()
filenames = []
for value in re.findall(r'^content-disposition:\s*(.*)$', headers, re.I | re.M):
    m = email.message.Message(); m['content-disposition'] = value.strip()
    filenames.append(m.get_filename() or '')
name = filenames[-1] if filenames else ''
version = re.search(r'\d+\.\d+\.\d+\.\d+', name)
print(version.group() if version else 'sha256:' + sys.argv[2][:16])
PY
}

extract_archive() {
    local archive=$1 destination=$2 expected=${3:-}
    # No links/devices: this makes validation safe even on Python versions predating tar filters.
    python3 - "$archive" "$destination" "$expected" <<'PY'
import pathlib, sys, tarfile
archive, destination, expected = sys.argv[1:]
with tarfile.open(archive) as tf:
    members = tf.getmembers()
    roots = set()
    for m in members:
        p = pathlib.PurePosixPath(m.name)
        if p.is_absolute() or '..' in p.parts or not (m.isfile() or m.isdir()):
            raise SystemExit('Unsafe archive member: ' + m.name)
        if not p.parts:
            continue
        roots.add(p.parts[0])
    if len(roots) != 1 or (expected and roots != {expected}):
        raise SystemExit('Unexpected archive root: ' + repr(roots))
    # Validation above is also applied on Python 3.10 without extraction filters.
    kwargs = {'filter': 'data'} if hasattr(tarfile, 'data_filter') else {}
    tf.extractall(destination, members=members, **kwargs)
    print(next(iter(roots)))
PY
}

resolve_github_release() {
    local repo=$1 major=$2 out=$3 page found=false
    # Walk pages so prereleases or a future major never silently change the chosen application.
    for page in 1 2 3 4 5; do
        fetch "https://api.github.com/repos/$repo/releases?per_page=100&page=$page" "$out.page" >/dev/null
        jq -e 'type == "array"' "$out.page" >/dev/null || die 'Invalid GitHub release response.'
        if jq -e --arg major "$major" '[.[] | select(.draft == false and .prerelease == false) | select($major == "" or (.tag_name | startswith("v" + $major + ".")))] | sort_by(.published_at) | last // empty' "$out.page" > "$out"; then found=true; break; fi
        [[ $(jq length "$out.page") == 100 ]] || break
    done
    [[ $found == true ]] || die "No supported stable release found for $repo (major $major)."
    rm -f "$out.page"
}

release_asset_url() {
    local release=$1 arch=$2
    jq -er --arg suffix ".linux-$arch.tar.gz" '[.assets[] | select(.name | endswith($suffix)) | .browser_download_url] | if length == 1 then .[0] else error("Missing or ambiguous Linux release asset") end' "$release"
}

sqlite_compatibility() {
    local dir=$1 glibc sqlite triplet
    [[ -f $dir/libe_sqlite3.so ]] || return 0
    glibc=$(getconf GNU_LIBC_VERSION); glibc=${glibc##* }
    dpkg --compare-versions "$glibc" lt 2.38 || return 0
    case $ARCH in amd64) triplet=x86_64-linux-gnu;; arm64) triplet=aarch64-linux-gnu;; armhf) triplet=arm-linux-gnueabihf;; *) die 'Unsupported SQLite architecture';; esac
    sqlite="/usr/lib/$triplet/libsqlite3.so.0"
    [[ -f $sqlite ]] || die "Required system SQLite library missing: $sqlite"
    mv "$dir/libe_sqlite3.so" "$dir/libe_sqlite3.so.bundled"
    ln -s "$sqlite" "$dir/libe_sqlite3.so"
}

prepare_binary() {
    local app=$1 stage=$2 arch url repo major
    case $ARCH in amd64) arch=x64;; arm64) arch=arm64;; armhf) arch=arm;; *) die 'Unsupported binary architecture';; esac
    case $app in
        whisparr|whisparr-v3)
            if [[ $app == whisparr ]]; then repo=Whisparr/Whisparr; major=2; else repo=Whisparr/Whisparr-Eros; major=3; fi
            resolve_github_release "$repo" "$major" "$stage/release.json"
            url=$(release_asset_url "$stage/release.json" "$arch")
            VERSION=$(jq -er .tag_name "$stage/release.json")
            ;;
        sonarr) url="https://services.sonarr.tv/v1/download/main/latest?version=4&os=linux&arch=$arch";;
        *) url="https://$app.servarr.com/v1/update/master/updatefile?os=linux&runtime=netcore&arch=$arch";;
    esac
    SOURCE=$url
    fetch "$url" "$stage/application.tar.gz" "$stage/headers"
    PAYLOAD_SHA=$(sha256sum "$stage/application.tar.gz" | cut -d' ' -f1)
    [[ -n ${VERSION:-} ]] || VERSION=$(artifact_version "$stage/headers" "$PAYLOAD_SHA")
    mkdir "$stage/extracted"
    extract_archive "$stage/application.tar.gz" "$stage/extracted" "${BINARY[$app]}" >/dev/null
    mv "$stage/extracted/${BINARY[$app]}" "$stage/application"
    [[ -f $stage/application/${BINARY[$app]} && -x $stage/application/${BINARY[$app]} ]] || die 'Archive has no executable application binary.'
    sqlite_compatibility "$stage/application"
    chown -R "${ACCOUNT[$app]}:${GROUP[$app]}" "$stage/application"
}

prepare_seerr() {
    local stage=$1 arch nodefile root commit manager engine mem
    ensure_packages git xz-utils build-essential python3
    mem=$(awk '/MemAvailable:|SwapFree:/ {total += $2} END {printf "%.0f", total}' /proc/meminfo)
    ((mem >= 2097152)) || die 'Native Seerr builds require at least 2 GiB available memory plus swap. Consider Docker mode on smaller hosts.'
    check_space /opt 4294967296
    ensure_account servarr-build servarr-build
    [[ $(id -G servarr-build) == "$(getent group servarr-build | cut -d: -f3)" ]] || die 'The build account must belong only to its dedicated group.'
    mkdir -p "$stage/home" "$stage/runtime" "$stage/extracted"
    resolve_github_release seerr-team/seerr '' "$stage/release.json"
    VERSION=$(jq -er .tag_name "$stage/release.json")
    [[ $VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Unsupported Seerr release tag.'
    fetch "https://api.github.com/repos/seerr-team/seerr/commits/$VERSION" "$stage/commit.json" >/dev/null
    commit=$(jq -er .sha "$stage/commit.json")
    [[ $commit =~ ^[a-f0-9]{40}$ ]] || die 'Invalid Seerr commit.'
    # Resolve source by the recorded commit, eliminating a moving-tag race.
    SOURCE="https://api.github.com/repos/seerr-team/seerr/tarball/$commit"
    fetch "$SOURCE" "$stage/source-pinned.tar.gz"
    root=$(extract_archive "$stage/source-pinned.tar.gz" "$stage/extracted")
    mv "$stage/extracted/$root" "$stage/application"
    PAYLOAD_SHA=$(sha256sum "$stage/source-pinned.tar.gz" | cut -d' ' -f1)
    manager=$(jq -er .packageManager "$stage/application/package.json")
    engine=$(jq -er .engines.node "$stage/application/package.json")
    [[ $manager == "pnpm@$PNPM_VERSION" && $engine == '^22.19.0' ]] || die "Seerr tool requirements changed ($engine, $manager). Update the reviewed runtime pins before building."
    case $ARCH in amd64) arch=x64;; arm64) arch=arm64;; *) die 'Native Seerr requires amd64/arm64';; esac
    nodefile="node-v$NODE_VERSION-linux-$arch.tar.xz"
    fetch "https://nodejs.org/dist/v$NODE_VERSION/$nodefile" "$stage/$nodefile" >/dev/null
    fetch "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt" "$stage/SHASUMS256.txt" >/dev/null
    (cd "$stage"; grep "  $nodefile\$" SHASUMS256.txt | sha256sum --check --strict -)
    # Official Node tarballs contain internal symlinks; GNU tar extracts only this pinned, checksummed tool archive.
    tar -xJf "$stage/$nodefile" --strip-components=1 -C "$stage/runtime"
    chown -R servarr-build:servarr-build "$stage"
    runuser -u servarr-build -- env -i HOME="$stage/home" PATH="$stage/runtime/tools/node_modules/.bin:$stage/runtime/bin:/usr/bin:/bin" \
        npm install --prefix "$stage/runtime/tools" --ignore-scripts --no-audit --no-fund "pnpm@$PNPM_VERSION"
    # shellcheck disable=SC2016
    runuser -u servarr-build -- env -i HOME="$stage/home" PATH="$stage/runtime/tools/node_modules/.bin:$stage/runtime/bin:/usr/bin:/bin" \
        CI=true CYPRESS_INSTALL_BINARY=0 NEXT_TELEMETRY_DISABLED=1 COMMIT_TAG="$VERSION" CONFIG_DIRECTORY="$stage/build-config" \
        bash -ec 'cd "$1"; "$2/bin/node" "$2/tools/node_modules/pnpm/bin/pnpm.cjs" install --frozen-lockfile --store-dir "$3/store"; exec "$2/bin/node" "$2/tools/node_modules/pnpm/bin/pnpm.cjs" build' \
        bash "$stage/application" "$stage/runtime" "$stage/home"
    [[ -f $stage/application/dist/index.js && -f $stage/application/.next/BUILD_ID ]] || die 'Seerr build output is incomplete.'
    printf '%s\n' "$commit" > "$stage/application/.servarr-source-commit"
    chown -R root:root "$stage/application" "$stage/runtime"
    chown root:root "$stage"
    chmod 755 "$stage/application" "$stage/runtime"
    mkdir -p "$stage/application/.next/cache"
    chown -R "${ACCOUNT[seerr]}:${GROUP[seerr]}" "$stage/application/.next/cache"
}

check_space() {
    local target=$1 bytes=$2 available
    available=$(df -PB1 "$target" | awk 'NR==2 {print $4}')
    if [[ ! $available =~ ^[0-9]+$ ]] || ((available <= bytes + 104857600)); then die "Insufficient free space on $target (need $bytes bytes plus reserve)."; fi
}

backup_data() {
    local source=$1 target=$2 bytes
    [[ -d $source ]] || return 0
    bytes=$(du -sb "$source" | cut -f1)
    check_space "$(dirname "$target")" "$bytes"
    tar --acls --xattrs -cpf "$target" -C "$source" .
    tar --acls --xattrs --compare -f "$target" -C "$source"
}

write_recovery() {
    local backup=$1 app=$2 mode=$3
    cat > "$backup/RECOVERY.txt" <<EOF
Servarr recovery: $app ($mode), $(date -u +%FT%TZ)
This directory is root-only and may contain credentials.
Stop the affected service/container before restoring. Keep the failed data directory
separately for diagnosis. Restore data.tar into an EMPTY application data directory,
preserving ownership, ACLs and extended attributes with tar --acls --xattrs -xpf.
Never run an old application against a database that a newer version has migrated.
Restore the matching binaries/runtime or image digest AND the matching data snapshot.
Native: restore binaries/ to $(bin_dir "$app"), unit.service to
/etc/systemd/system/$app.service, and any saved environment/runtime; daemon-reload.
Docker: restore the saved compose.yaml/settings.json and the matching data snapshot.
Only recreate the affected service; do not delete volumes or stop unrelated apps.
Prior service/container state and installed versions are recorded alongside this file.
EOF
}

write_state() {
    local app=$1 source=$2 version=$3 digest=${4:-} out=${5:-$(state_file "$1")}
    jq -n --arg id "$app" --arg mode "$MODE" --arg user "${ACCOUNT[$app]}" --arg group "${GROUP[$app]}" \
        --argjson port "${PORT[$app]}" --arg source "$source" --arg version "$version" --arg digest "$digest" \
        --arg data "$(data_dir "$app")" --arg installer "$SCRIPT_VERSION" \
        '{id:$id,mode:$mode,user:$user,group:$group,port:$port,source:$source,version:$version,digest:$digest,data:$data,installer:$installer}' > "$out.tmp"
    chmod 600 "$out.tmp"
    mv "$out.tmp" "$out"
}

write_native_unit() {
    local app=$1 file=$2 bindir
    bindir=$(bin_dir "$app")
    if [[ $app == seerr ]]; then
        cat > "$file" <<EOF
[Unit]
Description=Seerr
Wants=network-online.target
After=network-online.target
[Service]
Type=exec
User=${ACCOUNT[$app]}
Group=${GROUP[$app]}
UMask=0027
WorkingDirectory=$bindir
Environment=NODE_ENV=production
Environment=NEXT_TELEMETRY_DISABLED=1
EnvironmentFile=/etc/seerr/seerr.conf
ExecStart=$RUNTIME_DIR/bin/node $bindir/dist/index.js
Restart=on-failure
TimeoutStopSec=60
[Install]
WantedBy=multi-user.target
EOF
    else
        cat > "$file" <<EOF
[Unit]
Description=${LABEL[$app]}
After=network.target
[Service]
Type=simple
User=${ACCOUNT[$app]}
Group=${GROUP[$app]}
UMask=0002
ExecStart=$bindir/${BINARY[$app]} -nobrowser -data=/var/lib/$app
Restart=on-failure
TimeoutStopSec=60
KillMode=mixed
[Install]
WantedBy=multi-user.target
EOF
    fi
}

initialize_native_config() {
    local app=$1 data=$2
    if [[ $app == seerr ]]; then
        install -d -m 750 -o root -g "${GROUP[$app]}" /etc/seerr
        if [[ ! -e /etc/seerr/seerr.conf ]]; then
            printf 'PORT=%s\nCONFIG_DIRECTORY=/var/lib/seerr\n' "${PORT[$app]}" > /etc/seerr/seerr.conf
            chown "root:${GROUP[$app]}" /etc/seerr/seerr.conf; chmod 640 /etc/seerr/seerr.conf
        fi
    elif [[ ! -e $data/config.xml ]]; then
        printf '<Config><Port>%s</Port></Config>\n' "${PORT[$app]}" > "$data/config.xml"
        chown "${ACCOUNT[$app]}:${GROUP[$app]}" "$data/config.xml"; chmod 640 "$data/config.xml"
    fi
}

native_ready() {
    local app=$1 deadline=$((SECONDS+60)) consecutive=0 url
    url=$(native_probe_url "$app")
    while ((SECONDS < deadline)); do
        if systemctl is-active --quiet "$app.service"; then
            if curl -fs --connect-timeout 1 --max-time 2 "$url" >/dev/null; then
                ((consecutive+=1)); ((consecutive < 3)) || return 0
            else consecutive=0; fi
        else consecutive=0; fi
        sleep 1
    done
    return 1
}

native_probe_url() {
    local app=$1
    if [[ $app == seerr ]]; then
        printf 'http://127.0.0.1:%s/api/v1/settings/public' "${PORT[$app]}"
        return
    fi
    python3 - "$(data_dir "$app")/config.xml" "${PORT[$app]:-${DEFAULT_PORT[$app]}}" <<'PY'
import pathlib, sys, xml.etree.ElementTree as ET
config = pathlib.Path(sys.argv[1])
root = ET.parse(config).getroot() if config.exists() else ET.Element('Config')
host = root.findtext('BindAddress', '*')
host = {'*': '127.0.0.1', '0.0.0.0': '127.0.0.1', '::': '::1'}.get(host, host)
if ':' in host:
    host = '[' + host + ']'
base = root.findtext('UrlBase', '').strip('/')
print('http://' + host + ':' + sys.argv[2] + ('/' + base if base else '') + '/ping')
PY
}

install_native() (
    # A subshell isolates each transaction's EXIT trap. Call directly, never as an if-condition.
    local app=$1 stage='' backup='' data bindir unit was_active=0 was_enabled='' stopped=0 promoted=0 launched=0 complete=0 runtime_promoted=0 fresh_data=0 fresh_env=0
    local VERSION='' SOURCE='' PAYLOAD_SHA=''
    bindir=$(bin_dir "$app"); data=$(data_dir "$app"); unit="$UNIT_DIR/$app.service"
    # shellcheck disable=SC2329
    native_cleanup() {
        local result=$?
        trap - EXIT ERR INT TERM
        set +e
        if ((complete == 0 && stopped)); then
            if ((launched)); then
                timeout 90 systemctl stop "$app.service"
                log "Startup/replacement failed. Matching backups: $backup. Read RECOVERY.txt before restoring."
            else
                if ((promoted)); then
                    [[ ! -d $bindir ]] || mv "$bindir" "$stage/failed-application"
                    [[ ! -d $backup/binaries ]] || cp -a "$backup/binaries" "$bindir"
                    if [[ -f $backup/unit.service ]]; then cp -a "$backup/unit.service" "$unit"; else systemctl disable "$app.service"; rm -f "$unit"; fi
                    if ((runtime_promoted)); then
                        [[ ! -d $RUNTIME_DIR ]] || mv "$RUNTIME_DIR" "$stage/failed-runtime"
                        [[ ! -d $backup/runtime ]] || cp -a "$backup/runtime" "$RUNTIME_DIR"
                    fi
                    systemctl daemon-reload
                fi
                if [[ -f $backup/installer-state.json ]]; then cp -a "$backup/installer-state.json" "$(state_file "$app")"; else rm -f "$(state_file "$app")"; fi
                if ((fresh_data)) && [[ -d $data ]]; then mv "$data" "$backup/unstarted-data"; fi
                if ((fresh_env)); then mv /etc/seerr/seerr.conf "$backup/unstarted-seerr.conf"; fi
                ((was_active == 0)) || systemctl start "$app.service"
            fi
        fi
        [[ -z $stage ]] || rm -rf -- "$stage"
        ((result == 0)) || { systemctl status "$app.service" --no-pager; journalctl -u "$app.service" -n 40 --no-pager; }
        exit "$result"
    }
    trap native_cleanup EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    ensure_packages curl ca-certificates jq python3 tar gzip sqlite3 libsqlite3-0 libicu-dev
    [[ $app != lidarr ]] || ensure_packages libchromaprint-tools mediainfo
    ensure_account "${ACCOUNT[$app]}" "${GROUP[$app]}"
    install -d -m 755 "$STAGING_ROOT"
    stage=$(mktemp -d "$STAGING_ROOT/.servarr-$app.XXXXXXXX")
    if [[ $app == seerr ]]; then prepare_seerr "$stage"; else prepare_binary "$app" "$stage"; fi
    if [[ ${EXISTING[$app]} == 1 ]]; then
        systemctl is-active --quiet "$app.service" && was_active=1
        was_enabled=$(systemctl is-enabled "$app.service" 2>/dev/null) || true
    fi
    install -d -m 700 "$BACKUP_ROOT/$app"
    backup=$(mktemp -d "$BACKUP_ROOT/$app/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
    write_recovery "$backup" "$app" native
    printf 'active=%s\nenabled=%s\n' "$was_active" "$was_enabled" > "$backup/prior-state.txt"
    [[ ! -f $(state_file "$app") ]] || cp -a "$(state_file "$app")" "$backup/installer-state.json"
    stopped=1
    if [[ ${EXISTING[$app]} == 1 ]]; then timeout 90 systemctl stop "$app.service"; fi
    backup_data "$data" "$backup/data.tar"
    if [[ -d $bindir ]]; then
        check_space "$backup" "$(du -sb "$bindir" | cut -f1)"
        cp -a --reflink=auto "$bindir" "$backup/binaries"
    fi
    [[ ! -f $unit ]] || cp -a "$unit" "$backup/unit.service"
    if [[ $app == seerr ]]; then
        assert_real_path "$RUNTIME_DIR"
        if [[ -d $RUNTIME_DIR ]]; then
            check_space "$backup" "$(du -sb "$RUNTIME_DIR" | cut -f1)"
            cp -a --reflink=auto "$RUNTIME_DIR" "$backup/runtime"
        fi
        [[ ! -d /etc/seerr ]] || cp -a /etc/seerr "$backup/environment"
    fi
    if [[ ! -d $data ]]; then
        fresh_data=1
        install -d -m 750 -o "${ACCOUNT[$app]}" -g "${GROUP[$app]}" "$data"
    fi
    if [[ $app == seerr && ! -e /etc/seerr/seerr.conf ]]; then fresh_env=1; fi
    initialize_native_config "$app" "$data"
    if [[ ! -f $unit ]]; then write_native_unit "$app" "$stage/unit.service"; else cp -a "$unit" "$stage/unit.service"; fi
    # The old tree is retained in staging until commit; failures before launch restore the backup.
    promoted=1
    [[ ! -d $bindir ]] || mv "$bindir" "$stage/old-application"
    mv "$stage/application" "$bindir"
    if [[ $app == seerr ]]; then
        install -d -m 755 "$(dirname "$RUNTIME_DIR")"
        runtime_promoted=1
        [[ ! -d $RUNTIME_DIR ]] || mv "$RUNTIME_DIR" "$stage/old-runtime"
        mv "$stage/runtime" "$RUNTIME_DIR"
    else
        touch "$data/update_required"; chown "${ACCOUNT[$app]}:${GROUP[$app]}" "$data/update_required"
    fi
    install -m 644 "$stage/unit.service" "$unit"
    systemctl daemon-reload
    # Record intent before first launch; failed first installs can be repaired by rerunning.
    write_state "$app" "$SOURCE" "$VERSION" "$PAYLOAD_SHA"
    [[ ${EXISTING[$app]} == 1 ]] || systemctl enable "$app.service"
    launched=1
    timeout 90 systemctl start "$app.service"
    native_ready "$app" || die "$app did not become ready within 60 seconds."
    complete=1
    log "Installed ${LABEL[$app]} ($VERSION). Backup: $backup"
)

install_docker_engine() {
    if ((NEED_DOCKER)); then
        ensure_packages ca-certificates curl
        install -d -m 755 /etc/apt/keyrings
        [[ ! -e /etc/apt/sources.list.d/docker.sources && ! -e /etc/apt/sources.list.d/docker.list ]] || die 'Existing Docker repository configuration needs manual review.'
        fetch "https://download.docker.com/linux/$OS_ID/gpg" /etc/apt/keyrings/docker.asc >/dev/null
        chmod 644 /etc/apt/keyrings/docker.asc
        printf 'Types: deb\nURIs: https://download.docker.com/linux/%s\nSuites: %s\nComponents: stable\nArchitectures: %s\nSigned-By: /etc/apt/keyrings/docker.asc\n' \
            "$OS_ID" "$OS_CODENAME" "$ARCH" > /etc/apt/sources.list.d/docker.sources
        ensure_packages docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
        systemctl enable --now docker
    elif ((NEED_COMPOSE)); then ensure_packages docker-compose-plugin; fi
    docker info >/dev/null
    docker compose version >/dev/null
}

compose() {
    local file=$1; shift
    local args=(--project-name servarr --project-directory "$STACK_DIR" -f "$file")
    [[ ! -f $STACK_DIR/compose.override.yaml ]] || args+=(-f "$STACK_DIR/compose.override.yaml")
    docker compose "${args[@]}" "$@"
}

render_compose() {
    local records=$1 output=$2
    # JSON is YAML 1.2: generating with jq avoids shell/YAML interpolation bugs.
    jq -s --arg media "$MEDIA_ROOT" --arg tz "$TIMEZONE" '
      {name:"servarr",services:(map(. as $app | {
        key:.id, value:({image:.digest,restart:"unless-stopped",
          ports:[{target:({lidarr:8686,prowlarr:9696,radarr:7878,sonarr:8989,whisparr:6969,"whisparr-v3":6969,seerr:5055}[.id]),published:(.port|tostring),host_ip:"0.0.0.0",protocol:"tcp"}],
          volumes:([{type:"bind",source:.data,target:(if .id == "seerr" then "/app/config" else "/config" end),bind:{create_host_path:false}}] +
            (if .id == "prowlarr" or .id == "seerr" then [] else [{type:"bind",source:$media,target:$media,bind:{create_host_path:false}}] end)),
          environment:{TZ:$tz}}
          + (if .id == "seerr" then {user:(.uid+":"+.gid),init:true,environment:{TZ:$tz,PORT:"5055",LOG_LEVEL:"info"},
              cap_drop:["ALL"],security_opt:["no-new-privileges:true"],
              healthcheck:{test:["CMD-SHELL","wget -q --spider http://localhost:5055/api/v1/settings/public || exit 1"],start_period:"20s",interval:"15s",timeout:"3s",retries:3}}
            else {environment:{TZ:$tz,PUID:.uid,PGID:.gid,UMASK:"002"}} end))
      })|from_entries)}' "$records"/*.json > "$output"
}

validate_compose() {
    local generated=$1 effective=$2 app
    compose "$generated" config --format json > "$effective"
    # Overrides may tune resources/logging, but must not redirect data or bypass version/identity checks.
    jq -e --slurpfile base "$generated" '
      (.services|keys) == ($base[0].services|keys) and
      (.networks|keys) == ["default"] and
      (.networks.default.external // false) == false and (.networks.default.internal // false) == false and
      (.networks.default.driver // "bridge") == "bridge" and
      ([.services|to_entries[]|. as $e|$base[0].services[$e.key] as $b|
         ($e.value.image == $b.image and $e.value.volumes == $b.volumes and
          ($e.value.ports|map({target,published,host_ip,protocol})) == ($b.ports|map({target,published,host_ip,protocol})) and
          ($e.value.user // "") == ($b.user // "") and $e.value.environment == $b.environment and
          ($e.value.networks|keys) == ["default"] and
          ($e.value.network_mode // "") == "" and ($e.value.privileged // false) == false and
          ($e.value.command // null) == null and ($e.value.entrypoint // null) == null and
          ($e.value.volumes_from // []) == [] and ($e.value.devices // []) == [] and
          ($e.value.cap_add // []) == [] and ($e.value.pid // "") == "" and ($e.value.ipc // "") == "" and
          ($e.value.cap_drop // []) == ($b.cap_drop // []) and ($e.value.security_opt // []) == ($b.security_opt // []))] | all)' "$effective" >/dev/null \
        || die 'Compose overrides change protected images, storage, ports, identity or networking. Keep those in installer settings.'
    for app in "${SELECTED[@]}"; do
        [[ $(jq -r --arg id "$app" '.services[$id].image' "$effective") == *@sha256:* ]] || die 'Compose image is not pinned.'
    done
}

docker_ready() {
    local app=$1 deadline=$((SECONDS+120)) id status path=/ping port host
    [[ $app != seerr ]] || path=/api/v1/settings/public
    port=${PORT[$app]}; host=127.0.0.1
    while ((SECONDS < deadline)); do
        id=$(container_for "$app")
        if [[ -n $id ]]; then
            status=$(docker inspect -f '{{.State.Status}}' "$id")
            if [[ $status == running ]] && curl -fs --connect-timeout 1 --max-time 2 "http://$host:$port$path" >/dev/null; then return 0; fi
        fi
        sleep 2
    done
    return 1
}

install_stack() (
    local stage='' backup='' app saved id digest uid gid platform started=0 complete=0 published=0
    local -a stopped_apps=() created_data=()
    # shellcheck disable=SC2329
    docker_cleanup() {
        local result=$?
        trap - EXIT ERR INT TERM
        set +e
        if ((complete == 0)); then
            if ((started)); then
                compose "$STACK_DIR/compose.yaml" stop "${SELECTED[@]}"
                log "Deployment failed. Backup: $backup. Read the affected service's RECOVERY.txt in that backup before restoring data and images."
                compose "$STACK_DIR/compose.yaml" logs --tail 40 "${SELECTED[@]}"
            else
                if ((published)); then
                    if [[ -f $backup/stack/compose.yaml ]]; then
                        cp -a "$backup/stack/." "$STACK_DIR/"
                    else
                        rm -f "$STACK_DIR/compose.yaml" "$STACK_DIR/compose.sha256" "$STACK_DIR/settings.json" "$STACK_DIR/README.txt"
                    fi
                    for app in "${SELECTED[@]}"; do
                        if [[ -f $backup/installer-state/apps/$app.json ]]; then cp -a "$backup/installer-state/apps/$app.json" "$(state_file "$app")"; else rm -f "$(state_file "$app")"; fi
                    done
                fi
                for app in "${stopped_apps[@]}"; do docker start "$app" >/dev/null; done
                for app in "${created_data[@]}"; do rmdir -- "$app"; done
            fi
        fi
        [[ -z $stage ]] || rm -rf -- "$stage"
        exit "$result"
    }
    trap docker_cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
    install_docker_engine
    ensure_packages jq python3 curl
    install -d -m 755 /opt
    stage=$(mktemp -d /opt/.servarr-compose.XXXXXXXX)
    mkdir "$stage/records"
    if [[ -f $STACK_DIR/compose.yaml ]]; then
        (cd "$STACK_DIR"; sha256sum --check compose.sha256) || die 'Generated Compose file was edited. Restore it and use compose.override.yaml for supported customizations.'
    fi
    for saved in "$STATE_DIR"/apps/*.json; do
        [[ -f $saved ]] || continue
        app=$(jq -er .id "$saved"); valid_app "$app" || die 'Unknown app in state.'
        [[ $(jq -er .mode "$saved") == docker ]] || die 'Mixed deployment state is not supported.'
        cp "$saved" "$stage/records/$app.json"
    done
    for app in "${SELECTED[@]}"; do
        ensure_account "${ACCOUNT[$app]}" "${GROUP[$app]}"
        uid=$(id -u "${ACCOUNT[$app]}"); gid=$(getent group "${GROUP[$app]}" | cut -d: -f3)
        docker pull "${IMAGE[$app]}"
        platform=$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${IMAGE[$app]}")
        [[ $platform == "linux/$ARCH" ]] || die "Image platform mismatch: $platform"
        digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "${IMAGE[$app]}")
        [[ $digest =~ ^[a-zA-Z0-9./_-]+@sha256:[a-f0-9]{64}$ ]] || die "Invalid image digest for $app"
        write_state "$app" "${IMAGE[$app]}" "$digest" "$digest" "$stage/records/$app.json"
        jq --arg uid "$uid" --arg gid "$gid" '. + {uid:$uid,gid:$gid}' "$stage/records/$app.json" > "$stage/record.tmp"
        mv "$stage/record.tmp" "$stage/records/$app.json"
    done
    # No dependency scripts or containers have run yet; all images are now locally available.
    install -d -m 700 "$STACK_DIR"
    render_compose "$stage/records" "$stage/compose.yaml"
    validate_compose "$stage/compose.yaml" "$stage/effective.json"
    install -d -m 700 "$BACKUP_ROOT/stack"
    backup=$(mktemp -d "$BACKUP_ROOT/stack/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
    cp -a "$STACK_DIR/." "$backup/stack"
    cp -a "$STATE_DIR" "$backup/installer-state"
    for app in "${SELECTED[@]}"; do
        mkdir "$backup/$app"
        write_recovery "$backup/$app" "$app" docker
        id=$(container_for "$app")
        [[ $(wc -w <<< "$id") -le 1 ]] || die "Multiple containers found for $app"
        if [[ -n $id ]]; then
            docker inspect "$id" > "$backup/$app/container.json"
            if [[ $(docker inspect -f '{{.State.Running}}' "$id") == true ]]; then
                stopped_apps+=("$id")
                docker stop --time 60 "$id" >/dev/null
            fi
        fi
        backup_data "$(data_dir "$app")" "$backup/$app/data.tar"
    done
    for app in "${SELECTED[@]}"; do
        assert_real_path "$(data_dir "$app")"
        if [[ ! -d $(data_dir "$app") ]]; then
            created_data+=("$(data_dir "$app")")
            install -d -m 750 -o "${ACCOUNT[$app]}" -g "${GROUP[$app]}" "$(data_dir "$app")"
        fi
        if media_app "$app"; then
            if [[ ! -d $MEDIA_ROOT ]]; then install -d -m 2775 -o "${ACCOUNT[$app]}" -g "${GROUP[$app]}" "$MEDIA_ROOT"; fi
            runuser -u "${ACCOUNT[$app]}" -g "${GROUP[$app]}" -- test -r "$MEDIA_ROOT"
            runuser -u "${ACCOUNT[$app]}" -g "${GROUP[$app]}" -- test -w "$MEDIA_ROOT"
        fi
    done
    published=1
    cp "$stage/compose.yaml" "$STACK_DIR/compose.yaml"
    jq -n --arg timezone "$TIMEZONE" --arg media "$MEDIA_ROOT" '{timezone:$timezone,media_root:$media}' > "$STACK_DIR/settings.json"
    (cd "$STACK_DIR"; sha256sum compose.yaml > compose.sha256)
    for app in "${SELECTED[@]}"; do cp "$stage/records/$app.json" "$(state_file "$app")"; done
    cat > "$STACK_DIR/README.txt" <<EOF
Servarr Docker Compose stack. Generated by installer $SCRIPT_VERSION.
Use sudo docker compose --project-directory $STACK_DIR ps
Use sudo docker compose --project-directory $STACK_DIR logs --tail 100 SERVICE
Rerun the installer to add applications or update image digests with offline backups.
Images are pinned; plain compose pull does not upgrade their versions.
Do not edit compose.yaml. Supported resource/logging additions belong in compose.override.yaml.
Do not use down -v. Persistent configuration: $DOCKER_DATA
Media/download root is $MEDIA_ROOT both outside and inside containers.
External download clients must report paths under that same root.
Inside the stack use service names and container ports, not localhost or host ports:
radarr:7878, sonarr:8989, lidarr:8686, prowlarr:9696, whisparr:6969, whisparr-v3:6969.
Complete app integration/authentication in each application's web interface.
EOF
    started=1
    compose "$STACK_DIR/compose.yaml" up -d --no-deps "${SELECTED[@]}"
    for app in "${SELECTED[@]}"; do docker_ready "$app" || die "$app failed readiness within 120 seconds."; done
    complete=1
    log "Stack ready. Offline backups: $backup"
)

check_ports() {
    local app port state_file_path known other pid container
    local -A used=()
    for state_file_path in "$STATE_DIR"/apps/*.json; do
        [[ -f $state_file_path ]] || continue
        other=$(jq -er .id "$state_file_path")
        port=$(jq -er '.port|tostring' "$state_file_path")
        used[$port]=$other
    done
    for app in "${SELECTED[@]}"; do
        port=${PORT[$app]}
        if [[ ${used[$port]:-$app} != "$app" ]]; then die "Port $port also belongs to ${used[$port]}. Choose different ports."; fi
        used[$port]=$app
        if ss -H -ltn "sport = :$port" | grep -q .; then
            known=false
            if [[ ${EXISTING[$app]} == 1 ]]; then
                if [[ $MODE == native ]]; then
                    pid=$(systemctl show "$app.service" -p MainPID --value)
                    if [[ $pid =~ ^[1-9][0-9]*$ ]] && ss -H -ltnp "sport = :$port" | grep -q "pid=$pid,"; then known=true; fi
                else
                    container=$(container_for "$app")
                    if [[ -n $container ]] && docker inspect "$container" | jq -e --arg port "$port" '.[0] | .State.Running and ([.NetworkSettings.Ports[]? // [] | .[] | .HostPort] | index($port) != null)' >/dev/null; then known=true; fi
                fi
            fi
            [[ $known == true ]] || die "Host port $port is already in use. Stop the conflicting service or select another port."
        fi
    done
}

main() {
    local app lock_fd host
    [[ $# == 0 ]] || { [[ $1 == --help ]] && { log "Servarr $SCRIPT_VERSION: sudo bash servarr-install-script.sh (interactive native/Docker setup)"; return; }; die 'Unknown arguments; use --help.'; }
    check_platform
    # Prompts must never consume the program text in curl | sudo bash.
    if ! { exec {PROMPT_FD}<>/dev/tty; } 2>/dev/null; then die 'An interactive terminal is required. Download the script, then run sudo bash servarr-install-script.sh.'; fi
    exec {lock_fd}>/run/lock/servarr-installer.lock
    flock -n "$lock_fd" || die 'Another Servarr installation is running.'
    trap 'printf "\033[0m" >&2' EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    log "Servarr installer $SCRIPT_VERSION ($SCRIPT_DATE)"
    log "$SCRIPT_URL"
    assert_real_path "$STATE_DIR"; assert_real_path "$BACKUP_ROOT"
    configure
    ensure_packages curl ca-certificates jq python3 tar gzip iproute2 util-linux
    check_ports
    install -d -m 700 "$STATE_DIR" "$STATE_DIR/apps" "$BACKUP_ROOT"
    printf '%s\n' "$MODE" > "$STATE_DIR/mode"
    if [[ $MODE == docker ]]; then install_stack; else
        for app in "${SELECTED[@]}"; do install_native "$app"; done
    fi
    host=$(hostname -I | awk '{print $1}')
    host=${host:-localhost}
    [[ $host != *:* ]] || host="[$host]"
    log 'Installation complete:'
    for app in "${SELECTED[@]}"; do log "  ${LABEL[$app]}: http://$host:${PORT[$app]}"; done
}

# Sourceable by the regression harness; sourcing never installs or invokes main.
if [[ ${BASH_SOURCE[0]:-$0} == "$0" ]]; then main "$@"; fi
