#!/bin/sh
set -u

REPO_RAW=https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main
DEST=/jffs/scripts
GUARD=$DEST/fcd-airiq-guard.sh
SS=$DEST/services-start
TMP=/tmp/fcd-airiq-guard-v2.$$
BACKUP=/jffs/flowcache-doctor/airiq-guard-backup-$(date '+%Y%m%d-%H%M%S')

fail() {
  echo "ERROR: $*" >&2
  rm -rf "$TMP"
  exit 1
}

[ "$(nvram get jffs2_scripts 2>/dev/null)" = 1 ] || fail "Enable JFFS custom scripts first"
mkdir -p "$TMP" "$DEST" "$BACKUP" || fail "cannot create install directories"

[ -e "$GUARD" ] && cp -p "$GUARD" "$BACKUP/fcd-airiq-guard.sh"
[ -e "$SS" ] && cp -p "$SS" "$BACKUP/services-start"

# Do not pre-detect curl. The invoking command already proves it is available,
# and some BusyBox shells misreport command -v/which for applets.
curl -fsSL "$REPO_RAW/scripts/fcd-airiq-guard.sh?cb=$(date +%s)" \
  -o "$TMP/fcd-airiq-guard.sh" || fail "guard download failed"
sh -n "$TMP/fcd-airiq-guard.sh" || fail "guard syntax check failed"

[ -x "$GUARD" ] && "$GUARD" stop >/dev/null 2>&1
cp "$TMP/fcd-airiq-guard.sh" "$GUARD" || fail "guard install failed"
chmod 755 "$GUARD" || fail "cannot make guard executable"

[ -f "$SS" ] || {
  printf '#!/bin/sh\n' > "$SS" || fail "cannot create services-start"
  chmod 755 "$SS"
}

# Idempotent boot hook: one and only one AirIQ guard startup line.
sed -i '/fcd-airiq-guard.sh start/d' "$SS"
printf '%s\n' "$GUARD start # fcd-airiq-guard" >> "$SS"
chmod 755 "$SS"

# The boot hook starts it after reboot. The cron entry repairs it if it is ever killed.
cru d fcd-airiq-guard 2>/dev/null
cru a fcd-airiq-guard "* * * * * $GUARD start"

# Apply the current Off setting immediately, then keep enforcing it.
"$GUARD" once || fail "initial AirIQ policy check failed"
"$GUARD" start || fail "guard start failed"
sleep 2

PID=$(cat /tmp/flowcache-doctor/airiq-guard.pid 2>/dev/null)
[ -n "$PID" ] && [ -d "/proc/$PID" ] || fail "guard did not remain running"
grep -q 'fcd-airiq-guard.sh start' "$SS" || fail "boot hook missing"
cru l 2>/dev/null | grep -q 'fcd-airiq-guard' || fail "cron watchdog missing"

"$GUARD" status
printf '%s\n' "Boot hook: installed"
printf '%s\n' "Cron watchdog: installed"
printf '%s\n' "AirIQ guard installed. Backup: $BACKUP"
rm -rf "$TMP"
