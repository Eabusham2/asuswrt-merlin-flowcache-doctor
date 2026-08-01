#!/bin/sh
set -u
REPO_RAW=https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main
DEST=/jffs/scripts
WATCH=$DEST/fcd-wifi-dropwatch.sh
HEALTH=$DEST/fcd-suite-health.sh
SS=$DEST/services-start
TMP=/tmp/fcd-wifi-dropwatch-v2.$$
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

[ -x "$WATCH" ] && "$WATCH" stop >/dev/null 2>&1
cp "$TMP/fcd-wifi-dropwatch.sh" "$WATCH" || fail "dropwatch install failed"
cp "$TMP/fcd-suite-health.sh" "$HEALTH" || fail "health checker install failed"
chmod 755 "$WATCH" "$HEALTH" || fail "cannot make scripts executable"

[ -f "$SS" ] || { printf '#!/bin/sh\n' > "$SS"; chmod 755 "$SS"; }
# Rebuild only our three managed startup lines, preserving every unrelated hook.
sed -i '\|/jffs/scripts/roamctl boot|d;\|fcd-airiq-guard.sh start|d;\|fcd-wifi-dropwatch.sh start|d' "$SS"
printf '%s\n' '/jffs/scripts/roamctl boot' >> "$SS"
printf '%s\n' '/jffs/scripts/fcd-airiq-guard.sh start # fcd-airiq-guard' >> "$SS"
printf '%s\n' '/jffs/scripts/fcd-wifi-dropwatch.sh start # fcd-wifi-dropwatch' >> "$SS"
chmod 755 "$SS"

# Re-arm all watchdogs idempotently.
cru d flowcache-doctor-watchdog 2>/dev/null
cru a flowcache-doctor-watchdog '* * * * * /jffs/scripts/roamctl watchdog'
cru d fcd-airiq-guard 2>/dev/null
cru a fcd-airiq-guard '* * * * * /jffs/scripts/fcd-airiq-guard.sh start'
cru d fcd-wifi-dropwatch 2>/dev/null
cru a fcd-wifi-dropwatch '* * * * * /jffs/scripts/fcd-wifi-dropwatch.sh start'

[ -x /jffs/scripts/roamctl ] && /jffs/scripts/roamctl watchdog >/dev/null 2>&1
[ -x /jffs/scripts/fcd-airiq-guard.sh ] && /jffs/scripts/fcd-airiq-guard.sh start >/dev/null 2>&1
"$WATCH" start
sleep 3
"$WATCH" cleanup >/dev/null 2>&1

"$HEALTH" || fail "suite health verification failed"
rm -rf "$TMP"
echo "Wi-Fi Dropwatch v2 installed. Backup: $BACKUP"
echo "All three services have boot hooks and one-minute watchdogs."
echo "Flowcache event logs and Dropwatch captures are retained for 30 days."
echo "Manual marks always capture, even immediately after an automatic event."
