#!/usr/bin/env bats

setup() {
    source "$BATS_TEST_DIRNAME/../servarr-install-script.sh"
    WORK=$(mktemp -d /tmp/servarr-test.XXXXXXXX)
    STATE_DIR="$WORK/state"
    STACK_DIR="$WORK/stack"
    DOCKER_DATA="$WORK/docker-data"
    BACKUP_ROOT="$WORK/backups"
    mkdir -p "$STATE_DIR/apps"
    MODE=native ARCH=amd64
}

teardown() {
    if [[ ${WORK:-} == /tmp/servarr-test.* ]]; then rm -rf -- "$WORK"; fi
}

@test "sourcing the installer does not create installation state" {
    [ ! -e "$STATE_DIR/mode" ]
    [ "${#APP_IDS[@]}" -eq 7 ]
    ! valid_app readarr
}

@test "selection supports names, numbers, commas and deduplication" {
    parse_selection '3, sonarr 3 whisparr-v3'
    [ "${SELECTED[*]}" = 'radarr sonarr whisparr-v3' ]
    parse_selection all
    [ "${#SELECTED[@]}" -eq 7 ]
}

@test "invalid and empty selection never index an empty associative key" {
    for answer in '' '0' '8' 'radarr nonsense' ';touch /tmp/unwanted' '$(false)'; do
        run parse_selection "$answer"
        [ "$status" -ne 0 ]
        [[ "$output" != *'bad array subscript'* ]]
    done
}

@test "prompt assigns the caller variable and handles defaults" {
    local answer=''
    exec {PROMPT_FD}<<<'docker'
    prompt answer 'Mode'
    [ "$answer" = docker ]
    exec {PROMPT_FD}<<<''
    prompt answer 'Mode' native
    [ "$answer" = native ]
}

@test "closed prompt input exits with a helpful error" {
    exec {PROMPT_FD}</dev/null
    run prompt answer 'Mode'
    [ "$status" -ne 0 ]
    [[ "$output" == *'Input closed'* ]]
}

@test "accounts and paths reject root, injection and traversal" {
    valid_account whisparr-v3
    ! valid_account root
    ! valid_account '-r'
    valid_path /srv/media-data
    ! valid_path /srv/../etc
    ! valid_path '/srv/$(id)'
    ! valid_path /
}

@test "port validation rejects arithmetic injection and out of range values" {
    valid_port 5055
    valid_port 65535
    ! valid_port 65536
    ! valid_port 0
    ! valid_port '1+2'
    ! valid_port 05055
}

@test "architecture checks retain armhf Arr support but reject Seerr and Docker" {
    ARCH=armhf
    check_architecture radarr
    run check_architecture seerr
    [ "$status" -ne 0 ]
    MODE=docker
    run check_architecture radarr
    [ "$status" -ne 0 ]
}

@test "archive validation rejects traversal, absolute paths, links and wrong roots" {
    python3 - "$WORK" <<'PY'
import io, sys, tarfile
for kind, name in [('traversal','App/../../outside'), ('absolute','/outside'), ('link','App/link'), ('wrong','Wrong/file')]:
    with tarfile.open(sys.argv[1]+'/'+kind+'.tar.gz','w:gz') as t:
        m=tarfile.TarInfo(name)
        if kind=='link': m.type=tarfile.SYMTYPE; m.linkname='/etc'
        t.addfile(m,io.BytesIO())
PY
    mkdir "$WORK/extract"
    for kind in traversal absolute link wrong; do
        run extract_archive "$WORK/$kind.tar.gz" "$WORK/extract" App
        [ "$status" -ne 0 ]
    done
    [ ! -e "$WORK/outside" ]
}

@test "valid application archives extract only after validation" {
    mkdir -p "$WORK/input/App" "$WORK/extract"
    printf payload > "$WORK/input/App/file"
    tar -czf "$WORK/app.tar.gz" -C "$WORK/input" App
    run extract_archive "$WORK/app.tar.gz" "$WORK/extract" App
    [ "$status" -eq 0 ]
    [ "$(cat "$WORK/extract/App/file")" = payload ]
}

@test "release asset resolution is architecture specific and excludes musl" {
    cat > "$WORK/release.json" <<'JSON'
{"assets":[{"name":"Whisparr.3.linux-x64.tar.gz","browser_download_url":"https://example.org/right"},{"name":"Whisparr.3.linux-musl-x64.tar.gz","browser_download_url":"https://example.org/wrong"}]}
JSON
    [ "$(release_asset_url "$WORK/release.json" x64)" = https://example.org/right ]
    run release_asset_url "$WORK/release.json" arm64
    [ "$status" -ne 0 ]
}

@test "release resolution excludes drafts prereleases and another major" {
    fetch() {
        cat > "$2" <<'JSON'
[{"tag_name":"v4.0.0","draft":false,"prerelease":false,"published_at":"2026-09-11"},{"tag_name":"v3.9.0","draft":false,"prerelease":true,"published_at":"2026-09-10"},{"tag_name":"v3.1.0","draft":false,"prerelease":false,"published_at":"2026-09-09"}]
JSON
    }
    resolve_github_release owner/repo 3 "$WORK/release.json"
    [ "$(jq -r .tag_name "$WORK/release.json")" = v3.1.0 ]
}

@test "missing group is created even when username matches it" {
    getent() { return 2; }
    groupadd() { printf 'group %s\n' "$*" >> "$WORK/calls"; }
    useradd() { printf 'user %s\n' "$*" >> "$WORK/calls"; }
    id() { case $1 in -u) echo 900;; -G) echo 900;; esac; }
    usermod() { :; }
    # Group lookup must resolve after creation.
    getent() { if [[ $1 == group && -f $WORK/calls ]]; then echo 'seerr:x:900:'; else return 2; fi; }
    ensure_account seerr seerr
    grep -q 'group --system seerr' "$WORK/calls"
    grep -q 'user --system' "$WORK/calls"
}

@test "SQLite workaround is skipped when the bundled file is absent" {
    mkdir "$WORK/app"
    getconf() { return 99; }
    sqlite_compatibility "$WORK/app"
}

@test "SQLite workaround preserves a modern glibc bundle" {
    mkdir "$WORK/app"
    echo bundled > "$WORK/app/libe_sqlite3.so"
    getconf() { echo 'glibc 2.39'; }
    sqlite_compatibility "$WORK/app"
    [ ! -L "$WORK/app/libe_sqlite3.so" ]
}

@test "state is data not sourced shell and rejects mode changes" {
    ACCOUNT[radarr]=radarr GROUP[radarr]=media PORT[radarr]=7878
    write_state radarr 'https://example.org/a?x=1' v1 abc
    [ "$(jq -r .mode "$(state_file radarr)")" = native ]
    MODE=docker
    run read_saved_app radarr
    [ "$status" -ne 0 ]
    [[ "$output" == *'cross-mode migration'* ]]
}

make_records() {
    local app
    MODE=docker MEDIA_ROOT=/data TIMEZONE=Etc/UTC
    mkdir -p "$WORK/records"
    for app in "${APP_IDS[@]}"; do
        ACCOUNT[$app]=$app GROUP[$app]=media PORT[$app]=${DEFAULT_PORT[$app]}
        write_state "$app" "${IMAGE[$app]}" v1 "${IMAGE[$app]%:*}@sha256:$(printf 'a%.0s' {1..64})" "$WORK/records/$app.json"
        jq '.+{uid:"1001",gid:"1002"}' "$WORK/records/$app.json" > "$WORK/r.tmp"
        mv "$WORK/r.tmp" "$WORK/records/$app.json"
    done
}

@test "Compose uses independent Whisparr configs and fixed container ports" {
    make_records
    jq '.port=8888' "$WORK/records/radarr.json" > "$WORK/r.tmp"
    mv "$WORK/r.tmp" "$WORK/records/radarr.json"
    render_compose "$WORK/records" "$WORK/compose.yaml"
    jq -e '.services.radarr.ports[0] | .published=="8888" and .target==7878' "$WORK/compose.yaml"
    jq -e '.services["whisparr-v3"].ports[0] | .published=="6970" and .target==6969' "$WORK/compose.yaml"
    jq -e '.services.whisparr.volumes[0].source != .services["whisparr-v3"].volumes[0].source' "$WORK/compose.yaml"
}

@test "Compose preserves shared data paths and Seerr identity conventions" {
    make_records
    MEDIA_ROOT=/srv/library
    render_compose "$WORK/records" "$WORK/compose.yaml"
    jq -e '.services.radarr.volumes[1] | .source=="/srv/library" and .target=="/srv/library"' "$WORK/compose.yaml"
    jq -e '.services.seerr | .user=="1001:1002" and (.environment|has("PUID")|not) and (.volumes|length)==1' "$WORK/compose.yaml"
    jq -e '.services.prowlarr.volumes|length==1' "$WORK/compose.yaml"
}

@test "backup data can be restored including its contents" {
    mkdir "$WORK/data" "$WORK/restored"
    echo important > "$WORK/data/database"
    backup_data "$WORK/data" "$WORK/data.tar"
    tar -xf "$WORK/data.tar" -C "$WORK/restored"
    cmp "$WORK/data/database" "$WORK/restored/database"
}

@test "native unit uses explicit v3 executable and separate data" {
    ACCOUNT[whisparr-v3]=whisparr-v3 GROUP[whisparr-v3]=media
    write_native_unit whisparr-v3 "$WORK/unit"
    grep -q '/opt/Whisparr-v3/Whisparr -nobrowser -data=/var/lib/whisparr-v3' "$WORK/unit"
}

@test "Seerr unit uses isolated runtime and persistent config" {
    ACCOUNT[seerr]=seerr GROUP[seerr]=seerr
    write_native_unit seerr "$WORK/unit"
    grep -q 'ExecStart=/opt/servarr-runtime/seerr/bin/node /opt/Seerr/dist/index.js' "$WORK/unit"
    grep -q 'User=seerr' "$WORK/unit"
    grep -q 'EnvironmentFile=/etc/seerr/seerr.conf' "$WORK/unit"
}

@test "native readiness times out instead of hanging" {
    systemctl() { return 1; }
    sleep() { SECONDS=$((SECONDS+30)); }
    run native_ready radarr
    [ "$status" -ne 0 ]
}

@test "native readiness rejects an active service without HTTP" {
    systemctl() { return 0; }
    curl() { return 1; }
    sleep() { SECONDS=$((SECONDS+30)); }
    run native_ready radarr
    [ "$status" -ne 0 ]
}

@test "native HTTP probe respects existing bind address and URL base" {
    data_dir() { printf '%s' "$WORK"; }
    PORT[radarr]=7878
    printf '%s' '<Config><BindAddress>::</BindAddress><UrlBase>/radarr/</UrlBase></Config>' > "$WORK/config.xml"
    [ "$(native_probe_url radarr)" = 'http://[::1]:7878/radarr/ping' ]
}

@test "Docker readiness requires HTTP not just a running container" {
    PORT[radarr]=7878
    container_for() { echo example; }
    docker() { echo running; }
    curl() { return 22; }
    sleep() { SECONDS=$((SECONDS+60)); }
    run docker_ready radarr
    [ "$status" -ne 0 ]
}

@test "failed staging does not stop an existing service or modify its files" {
    run bash "$BATS_TEST_DIRNAME/transaction-fixture.sh" "$WORK" download
    [ "$status" -ne 0 ]
    [ "$(cat "$WORK/bin/Radarr")" = old-binary ]
    [ "$(cat "$WORK/data/db")" = important-data ]
    ! grep -q '^stop ' "$WORK/calls"
}

@test "backup failure restarts the old service without replacement" {
    run bash "$BATS_TEST_DIRNAME/transaction-fixture.sh" "$WORK" backup
    [ "$status" -ne 0 ]
    [ "$(cat "$WORK/bin/Radarr")" = old-binary ]
    [ "$(jq -r .version "$WORK/state/apps/radarr.json")" = old ]
    grep -q '^stop radarr.service' "$WORK/calls"
    grep -q '^start radarr.service' "$WORK/calls"
}

@test "pre-launch promotion failure restores old binaries unit and installer state" {
    run bash "$BATS_TEST_DIRNAME/transaction-fixture.sh" "$WORK" promote
    [ "$status" -ne 0 ]
    [ "$(cat "$WORK/bin/Radarr")" = old-binary ]
    [ "$(cat "$WORK/units/radarr.service")" = old-unit ]
    [ "$(jq -r .version "$WORK/state/apps/radarr.json")" = old ]
    grep -q '^start radarr.service' "$WORK/calls"
}

@test "post-launch failure retains matching backup and stops failed app" {
    run bash "$BATS_TEST_DIRNAME/transaction-fixture.sh" "$WORK" start
    [ "$status" -ne 0 ]
    [ "$(cat "$WORK/bin/Radarr")" = new-binary ]
    [ "$(cat "$WORK/data/db")" = important-data ]
    [ "$(find "$WORK/backups" -name data.tar | wc -l)" -eq 1 ]
    [ "$(find "$WORK/backups" -name RECOVERY.txt | wc -l)" -eq 1 ]
    [ "$(tail -n 2 "$WORK/calls" | head -n 1)" = 'stop radarr.service' ]
}

@test "artifact version is read from headers without retaining signed redirect tokens" {
    printf 'HTTP/2 200\ncontent-disposition: attachment; filename=Radarr.master.6.3.0.10514.linux-core-x64.tar.gz\n' > "$WORK/headers"
    [ "$(artifact_version "$WORK/headers" abc)" = 6.3.0.10514 ]
}
