#!/bin/bash
# ============================================================================
#  n0d3-check.sh  —  "The Digital Keeper" full systems check
#  Runs on the Mac. Checks the backup side locally and the server over SSH.
#
#  Usage:  ./n0d3-check.sh            (full show: colors + animations)
#          ./n0d3-check.sh --plain    (no colors, no animation; good for saving)
#          ./n0d3-check.sh --fast     (colors, but skip the animations)
#          ./n0d3-check.sh --help
#
#  Written for macOS's built-in bash 3.2. Read-only: it changes nothing.
# ============================================================================

# ---------------------------- CONFIG (edit me) ------------------------------
SERVER_HOST="192.168.1.50"           # change: your server's IP
SERVER_USER="youruser"               # change: your normal login on the server
BACKUP_VOL="/Volumes/n0d3-backup"    # the Toshiba
PULL_LOG="/var/log/n0d3-pull.log"    # written by n0d3-pull.sh
PULL_JOB="com.n0d3.pull"             # launchd label
IMMICH_PORT="2283"
NEXTCLOUD_PORT="8080"
MAX_BACKUP_AGE_H=26                  # warn if last good backup is older than this
EXPECTED_CONTAINERS="immich_server immich_postgres immich_redis nextcloud-app-1 nextcloud-db-1 nextcloud-redis-1 nextcloud-cron-1"
# ----------------------------------------------------------------------------

ANIM=1; COLOR=1
case "${1:-}" in
  --plain) ANIM=0; COLOR=0 ;;
  --fast)  ANIM=0 ;;
  -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
esac
[ -t 1 ] || { ANIM=0; COLOR=0; }      # piped to a file? keep it clean
[ -n "${NO_COLOR:-}" ] && COLOR=0

if [ "$COLOR" = 1 ]; then
  R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[34m'; M=$'\033[35m'
  C=$'\033[36m'; W=$'\033[97m'; D=$'\033[2m'; BOLD=$'\033[1m'; X=$'\033[0m'
else
  R=; G=; Y=; B=; M=; C=; W=; D=; BOLD=; X=
fi

PASS=0; WARN=0; FAIL=0; FIXES=""
nap() { [ "$ANIM" = 1 ] && sleep "$1"; }

typeout() {                           # typewriter effect
  local s="$1" i
  if [ "$ANIM" = 1 ]; then
    for (( i=0; i<${#s}; i++ )); do printf '%s' "${s:$i:1}"; sleep 0.012; done
    printf '\n'
  else
    printf '%s\n' "$s"
  fi
}

ok()   { PASS=$((PASS+1)); printf "  ${G}[ OK ]${X}  %-30s ${D}%s${X}\n" "$1" "$2"; nap 0.05; }
warn() { WARN=$((WARN+1)); printf "  ${Y}[WARN]${X}  %-30s ${Y}%s${X}\n" "$1" "$2"
         [ -n "${3:-}" ] && FIXES="${FIXES}  ${Y}•${X} $1: $3\n"; nap 0.05; }
bad()  { FAIL=$((FAIL+1)); printf "  ${R}[FAIL]${X}  %-30s ${R}%s${X}\n" "$1" "$2"
         [ -n "${3:-}" ] && FIXES="${FIXES}  ${R}•${X} $1: $3\n"; nap 0.05; }
info() { printf "  ${C}[INFO]${X}  %-30s ${W}%s${X}\n" "$1" "$2"; nap 0.03; }

section() {
  printf "\n${M}${BOLD}┌─[ %s ]" "$1"
  local n=$(( 62 - ${#1} )) i; for (( i=0; i<n; i++ )); do printf '─'; done; printf "┐${X}\n"
  if [ "$ANIM" = 1 ]; then                # little scan bar
    printf "  ${D}scanning "
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '▰'; sleep 0.02; done
    printf "\r\033[K${X}"
  fi
}

spin_while() {                        # spinner while a background PID runs
  local pid=$1 msg=$2 f='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
  if [ "$ANIM" = 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf "\r  ${C}%s${X} %s" "${f:$((i % 10)):1}" "$msg"; i=$((i+1)); sleep 0.08
    done
    printf "\r\033[K"
  fi
  wait "$pid"
}

# ============================== THE SHOW ====================================
[ "$ANIM" = 1 ] && clear
printf "${C}${BOLD}"
cat <<'ART'
          ___      _ _____
   _ __  / _ \  __| |___ /
  | '_ \| | | |/ _` | |_ \
  | | | | |_| | (_| |___) |
  |_| |_|\___/ \__,_|____/   d i g i t a l   k e e p e r
ART
printf "${X}${D}"
cat <<'ART'
        .--------------------------.
       /  ________________________ /|     2011 Mac mini
      /  /______________________ //|     "still on duty"
     /__________________________// |
     |  [o]   n0d3   ~~~~~~~~  |   /
     |__________________________|_/
ART
printf "${X}\n"

typeout "${D}> waking the keeper...${X}"
typeout "${D}> loading checklist: mac · server · storage · apps · backups${X}"
typeout "${D}> $(date '+%A %B %d %Y, %I:%M %p')${X}"

# Ask for sudo once, up front (needed to read launchd + backup folder details)
if ! sudo -n true 2>/dev/null; then
  printf "\n  ${Y}🔑 sudo needed once for read-only Mac checks:${X}\n"
  sudo -v || { printf "  ${R}No sudo — some Mac checks will be skipped.${X}\n"; }
fi

# ============================ 1. THE MAC ====================================
section "1 · BACKUP MAC"

if mount | grep -q " on ${BACKUP_VOL} ("; then
  ok "Backup drive mounted" "$BACKUP_VOL"
  if mount | grep " on ${BACKUP_VOL} (" | grep -q noowners; then
    bad "File ownership" "ignored (noowners)" "sudo diskutil enableOwnership $BACKUP_VOL"
  else
    ok "File ownership" "preserved"
  fi
  read -r vsize vused vavail vpct <<<"$(df -h "$BACKUP_VOL" | awk 'NR==2{print $2, $3, $4, $5}')"
  pct=${vpct%\%}
  if [ "${pct:-0}" -ge 90 ]; then bad "Backup drive space" "$vused used of $vsize ($vpct)" "free space or prune changed/"
  elif [ "${pct:-0}" -ge 75 ]; then warn "Backup drive space" "$vused used of $vsize ($vpct)" "keep an eye on growth"
  else ok "Backup drive space" "$vused used of $vsize, $vavail free"; fi
  if mdutil -s "$BACKUP_VOL" 2>/dev/null | grep -qi "disabled"; then ok "Spotlight indexing" "off"
  else warn "Spotlight indexing" "on" "sudo mdutil -i off $BACKUP_VOL"; fi
  if diskutil info "$BACKUP_VOL" 2>/dev/null | grep -q "FileVault:.*Yes"; then ok "Encryption" "on"
  else warn "Encryption" "off — backup holds .env secrets" "Finder → right-click drive → Encrypt"; fi
  if [ -d "$BACKUP_VOL/changed" ]; then
    vers=$(ls -1 "$BACKUP_VOL/changed" 2>/dev/null | wc -l | tr -d ' ')
    info "Versioned change folders" "$vers day(s) kept (30-day window)"
  fi
else
  bad "Backup drive mounted" "NOT mounted" "plug the Toshiba directly into the Mac"
fi

if sudo -n launchctl print "system/$PULL_JOB" >/dev/null 2>&1; then
  ok "Nightly pull job" "loaded (runs 3:00 AM)"
else
  bad "Nightly pull job" "not loaded" "sudo launchctl bootstrap system /Library/LaunchDaemons/$PULL_JOB.plist"
fi

if [ -r "$PULL_LOG" ]; then
  last=$(grep "finished rc=" "$PULL_LOG" | tail -1)
  rc=${last##*rc=}
  when=$(echo "$last" | sed -e 's/^=== //' -e 's/ finished.*//' | tr -s ' ')
  epoch=$(date -j -f "%a %b %d %T %Z %Y" "$when" +%s 2>/dev/null)
  if [ -n "$epoch" ]; then
    age_h=$(( ($(date +%s) - epoch) / 3600 ))
    agetxt="${age_h}h ago"
  else
    age_h=0; agetxt="$when"
  fi
  if [ "$rc" = "0" ] && [ "$age_h" -le "$MAX_BACKUP_AGE_H" ]; then
    ok "Last backup" "succeeded, $agetxt"
  elif [ "$rc" = "0" ]; then
    warn "Last backup" "succeeded but $agetxt" "is the Mac on at 3 AM? check pmset"
  else
    bad "Last backup" "rc=$rc, $agetxt" "sudo grep -E 'rsync:|ERROR' $PULL_LOG | tail"
  fi
else
  warn "Last backup" "no log yet" "has n0d3-pull.sh run?"
fi

if command -v brew >/dev/null 2>&1 && brew list --pinned 2>/dev/null | grep -qx rsync; then
  ok "Homebrew rsync" "pinned ($(/opt/homebrew/bin/rsync --version 2>/dev/null | head -1 | awk '{print $3}'))"
else
  warn "Homebrew rsync" "not pinned" "brew pin rsync (Full Disk Access is tied to its path)"
fi

pm=$(pmset -g 2>/dev/null)
ds=$(echo "$pm" | awk '$1=="disksleep"{print $2}')
ar=$(echo "$pm" | awk '$1=="autorestart"{print $2}')
[ "${ds:-1}" = "0" ] && ok "Disk sleep" "off" || warn "Disk sleep" "${ds:+on ($ds min)}${ds:-unknown}" "turn off 'Put hard disks to sleep'"
[ "${ar:-0}" = "1" ] && ok "Restart after power loss" "on" \
  || warn "Restart after power loss" "off" "Settings → Energy → Start up when power is connected"

# ============================ 2. NETWORK ====================================
section "2 · NETWORK"

if ping -c1 -t2 "$SERVER_HOST" >/dev/null 2>&1; then
  rtt=$(ping -c3 -t3 "$SERVER_HOST" 2>/dev/null | awk -F'/' '/round-trip/{printf "%.1f ms", $5}')
  ok "n0d3 reachable" "$SERVER_HOST ($rtt avg)"
else
  bad "n0d3 reachable" "no reply from $SERVER_HOST" "is the server on? ethernet plugged in?"
fi

imm=$(curl -s --max-time 5 "http://$SERVER_HOST:$IMMICH_PORT/api/server/ping" 2>/dev/null)
echo "$imm" | grep -q pong && ok "Immich web" "answering on :$IMMICH_PORT" \
  || bad "Immich web" "no answer on :$IMMICH_PORT" "cd ~/immich && docker compose ps (on n0d3)"

nc=$(curl -s --max-time 5 "http://$SERVER_HOST:$NEXTCLOUD_PORT/status.php" 2>/dev/null)
if echo "$nc" | grep -q '"installed":true'; then
  ncv=$(echo "$nc" | sed -n 's/.*"versionstring":"\([^"]*\)".*/\1/p')
  if echo "$nc" | grep -q '"maintenance":true'; then
    warn "Nextcloud web" "v$ncv — in maintenance mode" "occ maintenance:mode --off"
  else
    ok "Nextcloud web" "v$ncv answering on :$NEXTCLOUD_PORT"
  fi
else
  bad "Nextcloud web" "no answer on :$NEXTCLOUD_PORT" "cd ~/nextcloud && docker compose ps (on n0d3)"
fi

# ============================ 3. THE SERVER =================================
section "3 · n0d3 (over SSH)"

REMOTE=$(mktemp "${TMPDIR:-/tmp}/n0d3chk.XXXXXX")
remote_cmds() {
cat <<'EOS'
echo "HOST|$(hostname)"
echo "OS|$(. /etc/os-release; echo "$PRETTY_NAME")"
echo "UPTIME|$(uptime -p | sed 's/^up //')"
echo "LOAD|$(cut -d' ' -f1-3 /proc/loadavg)"
echo "MEM|$(free -m | awk '/^Mem:/{print $3" "$2}')"
for h in /sys/class/hwmon/hwmon*; do
  [ "$(cat $h/name 2>/dev/null)" = coretemp ] && echo "TEMP|$(( $(cat $h/temp1_input) / 1000 ))"
done
if findmnt -n /mnt/data >/dev/null 2>&1; then
  echo "DATAMNT|$(findmnt -n -o SOURCE,OPTIONS /mnt/data | awk '{print $1" "$2}')"
  echo "DFDATA|$(df -hP /mnt/data | awk 'NR==2{print $3" "$2" "$5}')"
else
  echo "DATAMNT|"
fi
echo "DFROOT|$(df -hP / | awk 'NR==2{print $3" "$2" "$5}')"
echo "LV|$(lsblk -bndo SIZE /dev/mapper/ubuntu--vg-ubuntu--lv 2>/dev/null) $(lsblk -bndo SIZE /dev/sda3 2>/dev/null)"
docker ps -a --format 'CT|{{.Names}}|{{.Status}}' 2>/dev/null || echo "DOCKER|down"
echo "TIMER|$(systemctl is-active n0d3-prebackup.timer 2>/dev/null)"
echo "PRERES|$(systemctl show n0d3-prebackup.service -p Result --value 2>/dev/null)"
echo "PRELAST|$(systemctl show n0d3-prebackup.service -p ExecMainExitTimestamp --value 2>/dev/null)"
echo "USBDROPS|$(journalctl -k --since '-24h' --no-pager 2>/dev/null | grep -c 'USB disconnect')"
echo "EXT4ERR|$(journalctl -k --since '-24h' --no-pager 2>/dev/null | grep -ci 'EXT4-fs error')"
echo "UPDATES|$(/usr/lib/update-notifier/apt-check 2>&1)"
[ -f /var/run/reboot-required ] && echo "REBOOT|yes" || echo "REBOOT|no"
EOS
}

( remote_cmds | ssh -o BatchMode=yes -o ConnectTimeout=6 "$SERVER_USER@$SERVER_HOST" 'bash -s' >"$REMOTE" 2>/dev/null ) &
spin_while $! "establishing uplink to n0d3..."
if [ ! -s "$REMOTE" ]; then
  printf "  ${Y}Key login unavailable — asking for your n0d3 password instead:${X}\n"
  remote_cmds | ssh -o ConnectTimeout=6 "$SERVER_USER@$SERVER_HOST" 'bash -s' >"$REMOTE" 2>/dev/null
fi

val() { grep "^$1|" "$REMOTE" | head -1 | cut -d'|' -f2-; }

if [ ! -s "$REMOTE" ]; then
  bad "SSH to n0d3" "could not log in" "ssh $SERVER_USER@$SERVER_HOST — does it work by hand?"
else
  ok "SSH to n0d3" "$(val HOST) · $(val OS)"
  info "Uptime" "$(val UPTIME)"
  info "Load (1/5/15 min)" "$(val LOAD)"
  read -r mu mt <<<"$(val MEM)"
  [ -n "$mt" ] && info "Memory" "${mu} MB used of ${mt} MB"
  t=$(val TEMP)
  if [ -n "$t" ]; then
    if   [ "$t" -ge 85 ]; then bad  "CPU temperature" "${t}°C — HOT" "check airflow; fan sensor is broken"
    elif [ "$t" -ge 70 ]; then warn "CPU temperature" "${t}°C — warm" "fan sensor is broken; watch this"
    else ok "CPU temperature" "${t}°C"; fi
  fi

  dm=$(val DATAMNT)
  if [ -n "$dm" ]; then
    set -- $dm
    case "$2" in
      rw,*) ok "Data drive (/mnt/data)" "mounted $1, read-write" ;;
      *)    bad "Data drive (/mnt/data)" "mounted READ-ONLY" "drive hit errors: stop apps, e2fsck, remount" ;;
    esac
    set -- $(val DFDATA)
    p=${3%\%}; [ "${p:-0}" -ge 85 ] && warn "Data drive space" "$1 of $2 ($3)" "nearly full" \
                                    || ok "Data drive space" "$1 of $2 used ($3)"
  else
    bad "Data drive (/mnt/data)" "NOT mounted" "stop apps, run e2fsck, then sudo mount -a"
  fi

  set -- $(val DFROOT); ok "System SSD (/)" "$1 of $2 used ($3)"
  set -- $(val LV)
  if [ -n "${1:-}" ] && [ -n "${2:-}" ] && [ "$1" -lt $(( $2 * 9 / 10 )) ]; then
    warn "Ubuntu volume size" "$(( $1 / 1073741824 ))G of $(( $2 / 1073741824 ))G allocated" \
         "sudo lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv"
  else
    ok "Ubuntu volume size" "using full disk"
  fi

  drops=$(val USBDROPS); errs=$(val EXT4ERR)
  [ "${drops:-0}" -eq 0 ] && ok "USB disconnects (24h)" "none" \
    || warn "USB disconnects (24h)" "$drops event(s)" "did someone hot-plug USB? check dmesg"
  [ "${errs:-0}" -eq 0 ] && ok "Filesystem errors (24h)" "none" \
    || bad "Filesystem errors (24h)" "$errs ext4 error(s)" "stop apps and run e2fsck"

  upd=$(val UPDATES); n_all=${upd%%;*}; n_sec=${upd##*;}
  if echo "$upd" | grep -q '^[0-9]*;[0-9]*$'; then
    if   [ "$n_sec" -gt 0 ]; then warn "OS updates" "$n_all pending ($n_sec security)" "sudo apt update && sudo apt upgrade"
    elif [ "$n_all" -gt 0 ]; then info "OS updates" "$n_all pending (none security)"
    else ok "OS updates" "up to date"; fi
  fi
  [ "$(val REBOOT)" = yes ] && warn "Reboot" "required after updates" "stop apps, then sudo reboot"

  # ------------------------------ containers --------------------------------
  section "4 · CONTAINERS"
  if grep -q "^DOCKER|down" "$REMOTE"; then
    bad "Docker" "not responding" "sudo systemctl status docker"
  else
    for c in $EXPECTED_CONTAINERS; do
      st=$(grep "^CT|$c|" "$REMOTE" | cut -d'|' -f3)
      case "$st" in
        Up*unhealthy*) bad  "$c" "$st" "docker logs $c --tail 30" ;;
        Up*)           ok   "$c" "$st" ;;
        "")            bad  "$c" "missing" "docker compose up -d in its folder" ;;
        *)             bad  "$c" "$st" "docker compose up -d in its folder" ;;
      esac
    done
    tg=$(grep "^CT|twingate-" "$REMOTE" | head -1)
    if [ -n "$tg" ]; then
      case "$(echo "$tg" | cut -d'|' -f3)" in
        Up*healthy*) ok "Twingate connector" "healthy" ;;
        Up*)         warn "Twingate connector" "up, health unknown" "check Twingate admin console" ;;
        *)           bad "Twingate connector" "down" "docker start $(echo "$tg" | cut -d'|' -f2)" ;;
      esac
    else
      bad "Twingate connector" "missing" "remote access is down"
    fi
  fi

  # ---------------------------- server backups ------------------------------
  section "5 · SERVER PRE-BACKUP"
  [ "$(val TIMER)" = active ] && ok "1:30 AM timer" "active" \
    || bad "1:30 AM timer" "$(val TIMER)" "sudo systemctl enable --now n0d3-prebackup.timer"
  pr=$(val PRERES); pl=$(val PRELAST)
  [ "$pr" = success ] && ok "Last pre-backup" "success · ${pl:-unknown}" \
    || bad "Last pre-backup" "${pr:-unknown}" "journalctl -u n0d3-prebackup.service -n 20"
fi
rm -f "$REMOTE"

# ============================ SCORECARD =====================================
TOTAL=$((PASS + WARN + FAIL)); SCORE=$(( TOTAL > 0 ? PASS * 100 / TOTAL : 0 ))
printf "\n${M}${BOLD}└"; for (( i=0; i<67; i++ )); do printf "─"; done; printf "┘${X}\n\n"

bar() { local n=$(( SCORE / 5 )) i; printf "  ${W}HEALTH ${X}["
  for (( i=0; i<20; i++ )); do
    if [ $i -lt $n ]; then printf "${G}█${X}"; else printf "${D}░${X}"; fi; nap 0.03
  done; printf "] ${BOLD}%d%%${X}\n" "$SCORE"; }
bar
printf "  ${G}%d passed${X}   ${Y}%d warnings${X}   ${R}%d failed${X}\n\n" "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then
  printf "${G}${BOLD}"; cat <<'ART'
        ___________
       '._==_==_=_.'      ALL SYSTEMS NOMINAL
       .-\:      /-.      The keeper keeps. Go to bed.
      | (|:.     |) |
       '-|:.     |-'
         \::.    /
          '::. .'
            ) (
          _.' '._
         '-------'
ART
elif [ "$FAIL" -eq 0 ]; then
  printf "${Y}${BOLD}"; cat <<'ART'
       .--.
      |o_o |      MOSTLY HEALTHY
      |:_/ |      A few things want attention when you have a minute.
     //   \ \
    (|     | )
   /'\_   _/`\
   \___)=(___/
ART
else
  printf "${R}${BOLD}"; cat <<'ART'
      _____
     /     \      HOUSTON, WE HAVE A PROBLEM
    | () () |     Something needs fixing before tonight's backup.
     \  ^  /
      |||||
      |||||
ART
fi
printf "${X}"

if [ -n "$FIXES" ]; then
  printf "\n  ${W}${BOLD}Suggested fixes:${X}\n"
  printf "%b" "$FIXES"
fi

QUOTES=(
  "There are two kinds of people: those who back up, and those who will."
  "A backup you've never restored from is only a hope."
  "Old hardware never dies. It just gets a Linux install."
  "It's not a bug, it's a 15-year-old feature."
  "Uptime is a lifestyle."
  "sudo make me a sandwich."
  "Have you tried turning it off and on again? (Don't. It's running backups.)"
)
q=${QUOTES[$(( RANDOM % ${#QUOTES[@]} ))]}
printf "\n  ${D}❝ %s ❞${X}\n\n" "$q"

[ "$FAIL" -gt 0 ] && exit 2
[ "$WARN" -gt 0 ] && exit 1
exit 0
