#!/bin/sh
DEST=/jffs/scripts
SS=$DEST/services-start
PROFILE=/jffs/configs/profile.add
[ -x "$DEST/roamctl" ] && "$DEST/roamctl" stop >/dev/null 2>&1
cru d flowcache-doctor-watchdog 2>/dev/null
[ -f "$SS" ] && sed -i '/roamctl boot/d; /flowcache-doctor-watchdog/d' "$SS"
[ -f "$PROFILE" ] && sed -i '/alias roamctl=.*flowcache-doctor/d' "$PROFILE"
rm -f "$DEST/fcd-lib.sh" "$DEST/fcd-platform-gtbe19000ai.sh" "$DEST/fcd-daemon.sh" \
  "$DEST/fcd-events.sh" "$DEST/fcd-incident.sh" "$DEST/roamctl" \
  "$DEST/flowcache-doctor.conf" "$DEST/flowcache-doctor-uninstall.sh" \
  "$DEST/flowcache-doctor.disabled"
rm -rf /tmp/flowcache-doctor
# Keep backups; remove only this add-on's generated logs and incident captures.
rm -rf /jffs/flowcache-doctor/log /jffs/flowcache-doctor/incidents
echo "flowcache-doctor removed; backups remain under /jffs/flowcache-doctor/"
