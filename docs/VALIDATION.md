# Validation evidence

Installer 4.0.0, checked locally on 2026-09-11. Tests used disposable Linux systemd containers on Docker Desktop's Linux engine. No installation tests targeted a production server. These results describe the tested snapshot; upstream downloads can change afterward.

## Completed checks

| Check | Environment | Result |
| --- | --- | --- |
| ShellCheck 0.11.0 | Installer and all shell test scripts | Passed |
| Bats regression suite | Debian 12, Debian 13, Ubuntu 22.04, Ubuntu 24.04; amd64 | 30 tests passed on each OS |
| Native fresh installation and reinstall | Debian 12 amd64; all seven applications | Passed; data marker and disabled service enablement preserved |
| Native fresh installation and reinstall | Debian 13, Ubuntu 22.04, Ubuntu 24.04; amd64; Radarr | Passed |
| Native fresh installation and reinstall | Debian 12 arm64 under QEMU emulation; Radarr | Passed; data marker and disabled service enablement preserved; HTTP responded |
| Docker bootstrap and complete stack | Debian 12 amd64; official Docker CE packages; all seven applications | Passed; applications responded over HTTP |
| Docker selective update | Debian 12 amd64; Radarr in the complete stack | Passed; persistent data and unrelated services preserved |
| Docker fault injection | Download, offline backup, post-launch readiness failure | Passed; prior containers resumed before launch failures; failed application stopped after launch |
| Docker shared storage and networking | Complete Debian 12 stack | Hardlink creation as the configured media identity and Seerr-to-Radarr service DNS/HTTP passed |
| Compose override validation | Real Compose configuration resolution | Logging override accepted; storage, identity and host-network overrides rejected |
| Native fault injection | Mocked transaction inside a temporary directory | Download, backup, promotion and post-launch failures passed |
| Interactive invocation | Pseudo-terminal, downloaded script and piped script | Wizard cancellation passed; invocation without a controlling terminal failed with the expected instruction |
| Listener conflict checks | Running native service and running Compose stack | Existing managed listeners accepted |

Native installation checks exercise real downloads, package dependencies, accounts, systemd units, backups and reinstalls. Readiness requires sustained service activity and successful public HTTP requests. The regression suite tests archive validation, stable release selection, architecture routing, input handling, state parsing, Compose generation, backup restoration and bounded readiness failures.

## Versions exercised

Native Debian 12 installations used Lidarr 3.1.0.4875, Prowlarr 2.5.2.5491, Radarr 6.3.0.10514, Sonarr 4.0.19.2979, Whisparr v2.2.0-release.231, Whisparr v3.5.0-release.1585 and Seerr v3.4.1. Native Seerr completed its source build and reinstall using the isolated Node 22.23.2 and pnpm 10.24.0 runtime.

Docker tests pulled the channels listed in the README and recorded their resolved digests in the disposable installation state. Whisparr v2 and v3 ran together with separate configuration directories and host ports.

## Reproduce

Run from the repository directory with a working Docker engine:

```bash
docker build --build-arg BASE=debian:12 -t servarr-tests -f tests/Dockerfile .
docker run --rm -v "$PWD:/work:ro" servarr-tests
docker run --rm -v "$PWD:/work:ro" -w /work koalaman/shellcheck:v0.11.0 -x servarr-install-script.sh tests/*.sh
bash tests/run-integration.sh native all debian:12
bash tests/run-integration.sh docker all debian:12
```

Substitute another supported base image to test that OS. The integration wrapper creates and removes its own privileged systemd container and isolated Docker storage. It does not mount the host Docker socket into that container. Nested Docker requires separate storage volumes because overlay-on-overlay storage failed in the initial test setup; the wrapper provides those volumes.

The regression workflow is configured for pushes and pull requests. The manual integration workflow covers the four supported OS releases on amd64 and arm64 runners. Those GitHub workflows have not been dispatched as part of this local implementation.

## Remaining coverage

The complete seven-application live matrix has not been run on every OS and architecture. Native tests on the other three OS releases used Radarr as the representative application. Radarr's armhf artifact downloaded and installed under QEMU, but its runtime repeatedly exited with signal 11 before HTTP startup. ARMv7 runtime support therefore remains unverified; this result does not establish the cause of the crash on physical hardware. It prompted strengthening native readiness from service activity alone to service activity plus HTTP.

Physical ARM hardware, reboot persistence, interrupted power, full-disk conditions, large real-world databases, and migrations from arbitrary custom installations have not been exercised. Cross-mode and database migrations are deliberately outside the installer scope.
