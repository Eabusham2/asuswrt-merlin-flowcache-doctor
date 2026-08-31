#!/bin/sh
set -u

REPO_RAW=https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main
DEST=/jffs/scripts
WATCH=$DEST/fcd-wifi-dropwatch.sh
HEALTH=$DEST/fcd-suite-health.sh
CONF=$DEST/flowcache-doctor.conf
SS=$DEST/services-start
TMP=/tmp/fcd-wifi-dropwatch.$$
BACKUP=/jffs/flowcache-doctor/dropwatch-backup-$(date '+%Y%m%d-%H%M%S')

fail(){ echo "ERROR: $*" >&2; rm -rf "$TMP"; exit 1; }

[ "$(nvram get jffs2_scripts 2>/dev/null)" = 1 ] || fail "Enable JFFS custom scripts first"
mkdir -p "$TMP" "$DEST" "$BACKUP" || fail "cannot create install directories"

for F in fcd-wifi-dropwatch.sh fcd-suite-health.sh; do
  [ -e "$DEST/$F" ] && cp -p "$DEST/$F" "$BACKUP/$F"
  curl -fsSL "$REPO_RAW/scripts/$F?cb=$(date +%s)" -o "$TMP/$F" || fail "download failed: $F"
  sh -n "$TMP/$F" || fail "syntax check failed: $F"
done
[ -e "$SS" ] && cp -p "$SS" "$BACKUP/services-start"
[ -e "$CONF" ] && cp -p "$CONF" "$BACKUP/flowcache-doctor.conf"

[ -x "$WATCH" ] && "$WATCH" stop >/dev/null 2>&1
cp "$TMP/fcd-wifi-dropwatch.sh" "$WATCH" || fail "dropwatch install failed"
cp "$TMP/fcd-suite-health.sh" "$HEALTH" || fail "health checker install failed"
chmod 755 "$WATCH" "$HEALTH" || fail "cannot make scripts executable"

# Existing user policy wins. New/full-suite installs without an explicit Dropwatch
# retention setting inherit the script's conservative 14-day default.
if [ -f "$CONF" ] && ! grep -q '^FCD_DROPWATCH_RETENTION_DAYS=' "$CONF" 2>/dev/null; then
  printf '%s\n' 'FCD_DROPWATCH_RETENTION_DAYS=14' >> "$CONF"
fi

[ -f "$SS" ] || {
  printf '#!/bin/sh\n' > "$SS" || fail "cannot create services-start"
  chmod 755 "$SS"
}

# Always manage Dropwatch. Repair the other suite hooks only when those
# components are already installed, preserving standalone v1 behavior.
sed -i '/fcd-wifi-dropwatch.sh start/d' "$SS"
printf '%s\n' "$WATCH start # fcd-wifi-dropwatch" >> "$SS"
cru d fcd-wifi-dropwatch 2>/dev/null
cru a fcd-wifi-dropwatch "* * * * * $WATCH start"

if [ -x "$DEST/roamctl" ]; then
  sed -i '/\/jffs\/scripts\/roamctl boot/d' "$SS"
  printf '%s\n' "$DEST/roamctl boot" >> "$SS"
  cru d flowcache-doctor-watchdog 2>/dev/null
  cru a flowcache-doctor-watchdog "* * * * * $DEST/roamctl watchdog"
  "$DEST/roamctl" watchdog >/dev/null 2>&1
fi

if [ -x "$DEST/fcd-airiq-guard.sh" ]; then
  sed -i '/fcd-airiq-guard.sh start/d' "$SS"
  printf '%s\n' "$DEST/fcd-airiq-guard.sh start # fcd-airiq-guard" >> "$SS"
  cru d fcd-airiq-guard 2>/dev/null
  cru a fcd-airiq-guard "* * * * * $DEST/fcd-airiq-guard.sh start"
  "$DEST/fcd-airiq-guard.sh" start >/dev/null 2>&1
fi
chmod 755 "$SS"

"$WATCH" start || fail "dropwatch start failed"
sleep 3
"$WATCH" cleanup >/dev/null 2>&1

if [ -x "$DEST/roamctl" ] && [ -x "$DEST/fcd-airiq-guard.sh" ] && [ -x "$DEST/fcd-util-detail.sh" ]; then
  "$HEALTH" || fail "suite health verification failed"
  printf '%s\n' "Full suite health: passed"
else
  "$WATCH" health || fail "dropwatch health verification failed"
  printf '%s\n' "Dropwatch standalone health: passed"
fi

RETENTION=$("$WATCH" status 2>/dev/null | sed -n 's/^retention: //p' | head -n 1)
[ -n "$RETENTION" ] || RETENTION='14 days'
rm -rf "$TMP"
printf '%s\n' "Wi-Fi Dropwatch installed. Backup: $BACKUP"
printf '%s\n' "Dropwatch captures are retained for $RETENTION."
printf '%s\n' "Automatic triggers: high utilization, confirmed dual-public connectivity failure, and new kernel network errors."
printf '%s\n' "Manual marks always capture, even immediately after an automatic event."
printf '%s\n' "After SSH returns from a selective-client drop: $WATCH mark after-drop"
printf '%s\n' "Then inspect it with: $WATCH latest"
