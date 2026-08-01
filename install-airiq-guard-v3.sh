#!/bin/sh
set -u

REPO_RAW=https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main
DEST=/jffs/scripts
GUARD=$DEST/fcd-airiq-guard.sh
SS=$DEST/services-start
TMP=/tmp/fcd-airiq-guard-v3.$$
BACKUP=/jffs/flowcache-doctor/airiq-guard-backup-$(date '+%Y%m%d-%H%M%S')

fail() {
  echo "ERROR: $*" >&2
  rm -rf "$TMP"
  exit 1
}

guard_pids() {
  ps w 2>/dev/null | awk '
    $1 ~ /^[0-9]+$/ && $0 ~ /\/jffs\/scripts\/fcd-airiq-guard[.]sh daemon/ {print $1}
  ' | sort -n -u
}

stop_all_old_guards() {
  for P in $(guard_pids); do kill "$P" 2>/dev/null; done
  sleep 2
  for P in $(guard_pids); do kill -9 "$P" 2>/dev/null; done
  rm -f /tmp/flowcache-doctor/airiq-guard.pid
  rm -rf /tmp/flowcache-doctor/airiq-guard.lock 2>/dev/null
}

[ "$(nvram get jffs2_scripts 2>/dev/null)" = 1 ] || fail "Enable JFFS custom scripts first"
mkdir -p "$TMP" "$DEST" "$BACKUP" || fail "cannot create install directories"

[ -e "$GUARD" ] && cp -p "$GUARD" "$BACKUP/fcd-airiq-guard.sh"
[ -e "$SS" ] && cp -p "$SS" "$BACKUP/services-start"

curl -fsSL "$REPO_RAW/scripts/fcd-airiq-guard.sh?cb=$(date +%s)" \
  -o "$TMP/fcd-airiq-guard.sh" || fail "guard download failed"
sh -n "$TMP/fcd-airiq-guard.sh" || fail "guard syntax check failed"

stop_all_old_guards
cp "$TMP/fcd-airiq-guard.sh" "$GUARD" || fail "guard install failed"
chmod 755 "$GUARD" || fail "cannot make guard executable"

[ -f "$SS" ] || {
  printf '#!/bin/sh\n' > "$SS" || fail "cannot create services-start"
  chmod 755 "$SS"
}
sed -i '/fcd-airiq-guard.sh start/d' "$SS"
printf '%s\n' "$GUARD start # fcd-airiq-guard" >> "$SS"
chmod 755 "$SS"

cru d fcd-airiq-guard 2>/dev/null
cru a fcd-airiq-guard "* * * * * $GUARD start"

# Enforce the current GUI policy immediately:
# Off -> stop AirIQ; On -> ensure airiq_monitor is started.
"$GUARD" once || fail "initial AirIQ policy check failed"
"$GUARD" start || fail "guard start failed"
sleep 3

COUNT=$(guard_pids | awk 'NF{n++} END{print n+0}')
[ "$COUNT" -eq 1 ] || fail "expected one guard daemon, found $COUNT"
grep -q 'fcd-airiq-guard.sh start' "$SS" || fail "boot hook missing"
cru l 2>/dev/null | grep -q 'fcd-airiq-guard' || fail "cron watchdog missing"

"$GUARD" status
printf '%s\n' "Boot hook: installed"
printf '%s\n' "Cron watchdog: installed"
printf '%s\n' "Bidirectional policy: Off stops AirIQ; On starts airiq_monitor if missing"
printf '%s\n' "AirIQ guard installed. Backup: $BACKUP"
rm -rf "$TMP"
