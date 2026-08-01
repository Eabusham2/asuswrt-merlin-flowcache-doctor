#!/bin/sh
DEST=/jffs/scripts
GUARD=$DEST/fcd-airiq-guard.sh
SS=$DEST/services-start
[ -x "$GUARD" ] && "$GUARD" stop >/dev/null 2>&1
cru d fcd-airiq-guard 2>/dev/null
[ -f "$SS" ] && sed -i '/fcd-airiq-guard.sh start/d' "$SS"
rm -f "$GUARD"
rm -rf /tmp/flowcache-doctor/airiq-guard.lock
rm -f /tmp/flowcache-doctor/airiq-guard.pid /tmp/flowcache-doctor/airiq-unknown.warned
echo "AirIQ guard removed. AirIQ settings were not changed or committed."
