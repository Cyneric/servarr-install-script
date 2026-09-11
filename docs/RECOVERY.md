# Recovery and backups

Backups contain private settings and API keys. The installer creates them with root-only access beneath `/var/backups/servarr` and does not expire them automatically. Check capacity and remove old backups manually when they are no longer needed.

For native services, each transaction backs up application data as `data.tar`, the prior binaries as `binaries/`, the unit as `unit.service`, and installer state where present. Seerr also includes its matching runtime and environment configuration. The recorded prior state identifies whether the service was running and enabled.

For Docker, each transaction has a `stack/` snapshot, `installer-state/`, and one directory per affected application containing `data.tar` and the original container inspection. The saved Compose file identifies exact image digests. Unselected applications are not stopped.

If a failure occurs before new application code is launched, the installer restores the previous native binaries/unit or Compose configuration and restarts services that were running. After launch, it stops the affected application and retains backups for manual recovery. A newer application may have migrated its database, so reverting only the executable or container image is insufficient.

## Restore a native application

1. Read `RECOVERY.txt` and `prior-state.txt` in the specific backup directory.
2. Stop the service: `sudo systemctl stop radarr.service` (substitute the affected service).
3. Move the failed binary and data directories to separate diagnostic locations. Do not extract the old snapshot over a migrated database directory.
4. Restore `binaries/` to its original `/opt` location, preserving ownership with `cp -a`. Create an empty original data directory and restore `data.tar` using `tar --acls --xattrs -xpf BACKUP/data.tar -C DATA_DIRECTORY` as root.
5. Restore `unit.service` and any Seerr environment/runtime snapshot. Preserve existing systemd drop-ins; they are not modified by the installer.
6. Restore the saved application installer-state JSON if one exists, run `systemctl daemon-reload`, and restore the prior enabled/running state.
7. Verify logs and the web UI before discarding diagnostic data.

## Restore a Docker application

1. Stop the affected service using `sudo docker compose --project-directory /opt/servarr-stack stop SERVICE`.
2. Preserve the current configuration and failed app data separately. Restore the backed-up Compose files and installer state. If recovering only one app from a multi-app transaction, preserve newer unrelated services and restore only that app's saved image reference/settings.
3. Restore its `data.tar` into an empty original app-data directory, preserving ownership, ACLs and extended attributes.
4. Recreate only that service with `sudo docker compose --project-directory /opt/servarr-stack up -d --no-deps SERVICE`.
5. Verify logs and readiness. Never use `down -v` as a recovery step.

Cross-mode migrations, Whisparr v2-to-v3 database conversion, and Overseerr/Jellyseerr migration are not performed by this installer.
