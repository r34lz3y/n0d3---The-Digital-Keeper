#!/bin/bash
# n0d3-pull.sh — runs on the MAC at 3:00 AM (launchd).
# Pulls the server's /mnt/data to the backup drive over read-only rsync.
# Changed or deleted files are kept in dated folders for 30 days.
set -uo pipefail

RSYNC=/opt/homebrew/bin/rsync           # Homebrew rsync (macOS ships openrsync)
KEY="REPLACE_WITH_FULL_PATH_TO_BACKUP_KEY"   # full path: root's ~ is not yours
SERVER="nbackup@192.168.1.50"           # change: your server's IP
DEST=/Volumes/n0d3-backup
LOG=/var/log/n0d3-pull.log
STAMP=$(date +%Y-%m-%d)

exec >>"$LOG" 2>&1
echo "=== $(date) start"

# Guard 1: the backup drive must be a real mount, not just a folder
mount | grep -q " on $DEST (" && [ -d "$DEST/data" ] || { echo "ERROR: backup drive not mounted"; exit 1; }

# Guard 2: the server's data drive must be mounted (marker file must exist)
if ! $RSYNC -e "ssh -i $KEY" "$SERVER:/_server-backup/last-run.txt" /tmp/n0d3-lastrun.txt; then
  echo "ERROR: server data not reachable or data drive not mounted"; exit 1
fi
echo "Server pre-backup ran: $(cat /tmp/n0d3-lastrun.txt)"

# Mirror, keeping changed/deleted files in a dated folder
$RSYNC -a --numeric-ids --delete \
  --backup --backup-dir="$DEST/changed/$STAMP" \
  -e "ssh -i $KEY" "$SERVER:/" "$DEST/data/"
rc=$?

# Clean up change folders older than 30 days
find "$DEST/changed" -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2>/dev/null

echo "=== $(date) finished rc=$rc"
exit $rc
