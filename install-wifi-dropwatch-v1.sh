#!/bin/sh
set -u
REPO_RAW=https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main
DEST=/jffs/scripts
WATCH=$DEST/fcd-wifi-dropwatch.sh
SS=$DEST/services-start
TMP=/tmp/fcd-wifi-dropwatch.$$
BACKUP=/jffs/flowcache-doctor/dropwatch-backup-$(date '+%Y%m%d-%H%M%S')

fail(){ echo "ERROR: $*" >&2; rm -rf "$TMP"; exit 1; }
[ "$(nvram get jffs2_scripts 2>/dev/null)" = 1 ] || fail "Enable JFFS custom scripts first"
mkdir -p "$TMP" "$DEST" "$BACKUP" || fail "cannot create install directories"
[ -e "$WATCH" ] && cp -p "$WATCH" "$BACKUP/fcd-wifi-dropwatch.sh"
[ -e "$SS" ] && cp -p "$SS" "$BACKUP/services-start"

curl -fsSL "$REPO_RAW/scripts/fcd-wifi-dropwatch.sh?cb=$(date +%s)" -o "$TMP/fcd-wifi-dropwatch.sh" || fail "download failed"
sh -n "$TMP/fcd-wifi-dropwatch.sh" || fail "syntax check failed"

[ -x "$WATCH" ] && "$WATCH" stop >/dev/null 2>&1
cp "$TMP/fcd-wifi-dropwatch.sh" "$WATCH" || fail "install failed"
chmod 755 "$WATCH" || fail "cannot make executable"

[ -f "$SS" ] || { printf '#!/bin/sh\n' > "$SS"; chmod 755 "$SS"; }
sed -i '/fcd-wifi-dropwatch.sh start/d' "$SS"
printf '%s\n' "$WATCH start # fcd-wifi-dropwatch" >> "$SS"
chmod 755 "$SS"

cru d fcd-wifi-dropwatch 2>/dev/null
cru a fcd-wifi-dropwatch "* * * * * $WATCH start"

"$WATCH" start
sleep 3
"$WATCH" status
COUNT=$(ps w 2>/dev/null | awk '$0~/\/jffs\/scripts\/fcd-wifi-dropwatch[.]sh daemon/{n++}END{print n+0}')
[ "$COUNT" -eq 1 ] || fail "expected one dropwatch daemon, found $COUNT"
grep -q 'fcd-wifi-dropwatch.sh start' "$SS" || fail "boot hook missing"
cru l 2>/dev/null | grep -q fcd-wifi-dropwatch || fail "cron watchdog missing"
rm -rf "$TMP"
echo "Wi-Fi dropwatch installed. Backup: $BACKUP"
echo "After SSH returns from a drop, run: $WATCH mark after-drop"
echo "Then run: $WATCH latest"
