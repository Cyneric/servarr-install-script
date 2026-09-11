# Servarr Installation Script

Install one, several, or all supported applications as **native systemd services** or a **Docker Compose stack**. The installer manages downloads, accounts, dependencies, persistent data, startup checks, and backed-up reinstalls.

Written by Christian Blank ([Cyneric](https://github.com/Cyneric)), based on the community Servarr installation script by DoctorArr, Bakerboy448, and other Servarr contributors.

## Applications

| Application | Default host port | Native installation | Container image/channel |
| --- | --- | --- | --- |
| Lidarr | 8686 | Servarr master | `lscr.io/linuxserver/lidarr:latest` |
| Prowlarr | 9696 | Servarr master | `lscr.io/linuxserver/prowlarr:latest` |
| Radarr | 7878 | Servarr master | `lscr.io/linuxserver/radarr:latest` |
| Sonarr | 8989 | Sonarr v4 main | `lscr.io/linuxserver/sonarr:latest` |
| Whisparr v2 | 6969 | Stable v2 GitHub release | `ghcr.io/hotio/whisparr:v2` |
| Whisparr v3 | 6970 | Stable Whisparr-Eros v3 release | `ghcr.io/hotio/whisparr:v3` |
| Seerr | 5055 | Stable source build | `ghcr.io/seerr-team/seerr:latest` |

Whisparr v2 and v3 have independent services and data. Selecting v3 never upgrades or converts v2's database. Readarr has retired and is no longer offered for new installations; existing Readarr files and services are not touched.

## Requirements

- Debian 12/13 or Ubuntu 22.04/24.04, with systemd running.
- Root/sudo access, an interactive terminal, and an internet connection.
- Docker mode: amd64 or arm64. Docker Engine and the Compose plugin can be installed by the wizard.
- Native Arr applications: amd64, arm64, or armhf where the upstream release provides an artifact. Native Seerr: amd64 or arm64.
- Native Seerr builds need at least 2 GiB available memory plus swap and 4 GiB free build space. Large hosts may still need more memory for current source builds. Docker avoids the local build.
- Space for downloaded/staged application files and full offline application-data backups.

Derivatives and other OS releases are not automatically configured. Rootless/remote Docker, custom native layouts, cross-mode migrations, and automatic Overseerr/Jellyseerr migrations are outside this release.

## Run

Download the script and run it from a terminal:

```bash
curl -fL https://raw.githubusercontent.com/Cyneric/servarr-install-script/main/servarr-install-script.sh -o servarr-install-script.sh
sudo bash servarr-install-script.sh
```

For a branch under review, download that branch's file instead of `main`.

The existing piped invocation is also supported when a controlling terminal is available:

```bash
curl -fsSL https://raw.githubusercontent.com/Cyneric/servarr-install-script/main/servarr-install-script.sh | sudo bash
```

The wizard asks for a deployment mode, applications, service identities, and host ports. Docker mode also asks for timezone and the common media/download directory. Select applications by number or name, separated by spaces or commas; `all` selects every application. Nothing is installed until the summary is confirmed with `yes`.

After installation, open the printed host URLs and finish each application's setup, including authentication and connections to other services, through its web interface.

## Native mode

Existing applications retain the conventional paths:

| Application | Program directory | Data directory | systemd service |
| --- | --- | --- | --- |
| Lidarr / Prowlarr / Radarr / Sonarr | `/opt/<AppName>` | `/var/lib/<appname>` | `<appname>.service` |
| Whisparr v2 | `/opt/Whisparr` | `/var/lib/whisparr` | `whisparr.service` |
| Whisparr v3 | `/opt/Whisparr-v3` | `/var/lib/whisparr-v3` | `whisparr-v3.service` |
| Seerr | `/opt/Seerr` | `/var/lib/seerr` | `seerr.service` |

Arr identities default to the application user and `media` group. Seerr defaults to `seerr:seerr`. Existing service identities and configuration are preserved on reinstall.

Seerr uses an isolated Node.js/pnpm runtime under `/opt/servarr-runtime/seerr` and environment configuration at `/etc/seerr/seerr.conf`. The installer builds a stable source commit using a separate unprivileged build account; it does not replace system Node or install pnpm globally. If a later Seerr release changes its tool requirements, the installer stops before replacing the running installation until the reviewed tool pins are updated.

```bash
sudo systemctl status radarr.service
sudo journalctl -u radarr.service -n 100 --no-pager
```

The native completion check requires sustained service activity and successful HTTP responses. Arr checks respect existing bind addresses and URL bases; Seerr uses its public settings endpoint.

## Docker mode

The generated stack is stored in `/opt/servarr-stack`; persistent configuration lives in `/var/lib/servarr/docker/<app>`. Images are resolved from the listed channels and pinned by digest, so an ordinary restart does not unexpectedly change versions.

The wizard can install Docker from its official apt repository. A working existing engine is reused. Conflicting container-runtime packages require manual resolution; the installer does not uninstall them. Published host ports default to all interfaces, and Docker manages its own networking rules.

### Media and downloads

Choose one common parent directory for media and downloads, for example:

```text
/data/
  downloads/
  media/
    movies/
    tv/
    music/
```

The selected root is mounted at the **same path** inside all media managers. A single mount preserves the possibility of hardlinks and atomic moves when downloads and media share a filesystem. External download clients must report consistent paths. Existing media ownership is never changed recursively; give the selected accounts/groups the required access first.

Prowlarr and Seerr do not receive media mounts. Seerr uses its image's explicit user/group setting; LinuxServer and Hotio images use their supported PUID/PGID configuration.

### Connections and operations

Inside the stack, applications connect using service names and container ports:

```text
http://radarr:7878
http://sonarr:8989
http://prowlarr:9696
http://lidarr:8686
http://whisparr:6969
http://whisparr-v3:6969
```

Whisparr v3's host port is 6970, but its container still listens on 6969. Host-port customization does not change container ports. Use host URLs from your browser; `localhost` inside a container refers to that container.

```bash
sudo docker compose --project-directory /opt/servarr-stack ps
sudo docker compose --project-directory /opt/servarr-stack logs --tail 100 radarr
sudo docker compose --project-directory /opt/servarr-stack restart radarr
```

Do not edit generated `compose.yaml`. Supported resource/logging adjustments can be placed in `compose.override.yaml`; overrides that redirect images, volumes, ports, identities, or networking are rejected during installer updates. The generated file uses JSON syntax, which is valid YAML and can be read directly by Compose.

## Add applications and update

Rerun the same script and select the applications to add or update. The saved installation mode is reused. Apps that are not selected remain installed and are not stopped by Docker updates. No automatic update scheduler is installed.

Native files are downloaded or built before the existing service is stopped. Docker images are pulled and validated before downtime. Offline backups are made before replacement. Fresh native services are enabled at boot; existing enablement settings are preserved.

A failed download/build leaves the existing application running. A failed backup prevents replacement. Before new code has launched, failures restore the prior installation and running state; after launch, the affected application is stopped and matching data/code backups are retained for manual recovery because the database may have migrated.

Backups accumulate under `/var/backups/servarr`. They are private, may contain API keys, and are not automatically expired. See [recovery instructions](docs/RECOVERY.md).

## Development and validation

```bash
docker build -t servarr-tests -f tests/Dockerfile .
docker run --rm -v "$PWD:/work:ro" servarr-tests
docker run --rm -v "$PWD:/work:ro" -w /work koalaman/shellcheck:v0.11.0 -x servarr-install-script.sh tests/*.sh
```

For live installation/update tests, use the guarded disposable-container harness:

```bash
bash tests/run-integration.sh native all debian:12
bash tests/run-integration.sh docker all debian:13
```

It creates its own privileged systemd container, with isolated Docker storage for nested stack tests, and removes that container afterward. Never run `native-smoke.sh` or `docker-smoke.sh` directly on a real server. GitHub Actions runs regression tests on all four OS versions; the manually dispatched integration workflow also covers amd64/arm64 runners.

See [validation evidence](docs/VALIDATION.md) for checks actually run, and [the changelog](CHANGELOG.md) for upstream provenance. A configured test matrix is not a claim that every live platform combination has already passed.

## License

[MIT](LICENSE).
