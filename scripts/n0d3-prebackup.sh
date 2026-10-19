#!/bin/bash
# n0d3-prebackup.sh — runs on the SERVER at 1:30 AM (systemd timer).
# Dumps both databases and the config files onto the data drive,
# so the Mac's 3:00 AM pull captures everything needed for a restore.
set -euo pipefail
umask 077

APP_ROOT=/home/youruser            # change: folder that holds immich/ and nextcloud/
DEST=/mnt/data/_server-backup

# Refuse to run if the data drive isn't mounted (prevents writing to the SSD)
mountpoint -q /mnt/data || { echo "ERROR: /mnt/data not mounted" >&2; exit 1; }

mkdir -p "$DEST"
chmod 700 "$DEST"

# Nextcloud database dump (custom format, compressed)
docker exec nextcloud-db-1 pg_dump -U nextcloud -Fc nextcloud > "$DEST/nextcloud-db.dump.tmp"
mv "$DEST/nextcloud-db.dump.tmp" "$DEST/nextcloud-db.dump"

# Immich database dump (official method: pg_dumpall, gzipped)
docker exec immich_postgres pg_dumpall --clean --if-exists --username=postgres | gzip > "$DEST/immich-db.sql.gz.tmp"
mv "$DEST/immich-db.sql.gz.tmp" "$DEST/immich-db.sql.gz"

# Config files for both apps (compose files, .env secrets, Nextcloud config)
tar -czf "$DEST/configs.tar.gz.tmp" -C "$APP_ROOT" \
  immich/docker-compose.yml immich/.env \
  nextcloud/compose.yaml nextcloud/.env nextcloud/html/config
mv "$DEST/configs.tar.gz.tmp" "$DEST/configs.tar.gz"

date > "$DEST/last-run.txt"
echo "Pre-backup OK"
