# Changelog

## 4.0.0 - 2026-09-11

- Choose native systemd services or a Docker Compose stack, then one, several, or all applications.
- Add independent Whisparr v3 and native/container Seerr installation. Keep Radarr, Sonarr, Lidarr, Prowlarr, and Whisparr v2.
- Resolve native Whisparr releases from the respective GitHub repositories, filtering stable releases by major version.
- Remove retired Readarr from new installations. Existing Readarr data and services are untouched.
- Add system SQLite/ICU dependencies and the conditional glibc compatibility workaround. Preserve Sonarr's separate native download route.
- Fix empty menu input, interactive piped invocation, account/group creation, package-state checks, missing download dependencies, and unbounded startup waits.
- Stage native downloads and Seerr builds before downtime. Back up offline application data, binaries/runtime, and service configuration before replacement.
- Install Docker from its official apt repository when requested. Pin deployed container digests; update selected services without deleting unrelated services or volumes.
- Add automated regression checks and opt-in live installation/update tests across Debian 12/13 and Ubuntu 22.04/24.04.

### Upstream provenance

Compared with the November 2024 Cyneric snapshot, upstream added Whisparr v3 in December 2024, removed Readarr in September 2025, corrected SQLite loading in October 2025, and added ICU dependencies and a startup timeout in September 2026. The reviewed installer baseline is [Servarr/Wiki at 57803a80](https://github.com/Servarr/Wiki/blob/57803a80a5177334e346979944ac4bcd65e59044/servarr/servarr-install-script.sh).

Upstream's later removal of the old Whisparr v3 download route is not a reason to remove native v3 support: the [Whisparr-Eros repository](https://github.com/Whisparr/Whisparr-Eros/releases) currently publishes native binaries. This installer uses those releases directly.

The fork remains independent and retains Christian Blank's authorship and the original community credits: DoctorArr, Bakerboy448, and the Servarr community.
