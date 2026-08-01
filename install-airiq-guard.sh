#!/bin/sh
set -u
REPO_RAW=https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main
DEST=/jffs/scripts
GUARD=$DEST/fcd-airiq-guard.sh
SS=$DEST/services-start
TMP=/tmp/fcd-airiq-guard.$$
BACKUP=/jffs/flowcache-doctor/airiq-guard-backup-$(date '+%Y%m%d-%H%M%S')

fail(){ echo "ERROR: $*" >&2; rm -rf "$TMP"; exit 1; }
[ "$(nvram get jffs2_scripts 2>/dev/null)" = 1 ] || fail "Enable JFFS custom scripts first"
command -v curl >/dev/null 2>&1 || fail "curl is unavailable"
mkdir -p "$TMP" "$DEST" "$BACKUP" || fail "cannot create install directories"

[ -e "$GUARD" ] && cp -p "$GUARD" "$BACKUP/fcd-airiq-guard.sh"
[ -e "$SS" ] && cp -p "$SS" "$BACKUP/services-start"

curl -fsSL "$REPO_RAW/scripts/fcd-airiq-guard.sh?cb=$(date +%s)" -o "$TMP/fcd-airiq-guard.sh" || fail "download failed"
sh -n "$TMP/fcd-airiq-guard.sh" || fail "syntax check failed"

[ -x "$GUARD" ] && "$GUARD" stop >/dev/null 2>&1
cp "$TMP/fcd-airiq-guard.sh" "$GUARD" || fail "install failed"
chmod 755 "$GUARD"

[ -f "$SS" ] || { printf '#!/bin/sh\n' > "$SS"; chmod 755 "$SS"; }
sed -i '/fcd-airiq-guard.sh start/d' "$SS"
printf '%s\n' "$GUARD start # fcd-airiq-guard" >> "$SS"

cru d fcd-airiq-guard 2>/dev/null
cru a fcd-airiq-guard "* * * * * $GUARD start"

"$GUARD" start
sleep 2
"$GUARD" status
rm -rf "$TMP"
echo "AirIQ guard installed. Backup: $BACKUP"
echo "It checks every 10 seconds and only stops AirIQ when global airiq_enable=0."
