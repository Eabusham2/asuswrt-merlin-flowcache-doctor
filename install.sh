#!/bin/sh
set -u
VERSION=1.0.4-mlo-runner-heal
REPO_RAW=https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main
DEST=/jffs/scripts
ROOT=/jffs/flowcache-doctor
SS=$DEST/services-start
PROFILE=/jffs/configs/profile.add
TMP=/tmp/flowcache-doctor-install.$$
BACKUP=$ROOT/backup-$(date '+%Y%m%d-%H%M%S')
STAGE=0
FILES="fcd-lib.sh fcd-platform-gtbe19000ai.sh fcd-daemon.sh fcd-events.sh fcd-mlo-runner-heal.sh fcd-incident.sh roamctl"

rollback(){
  [ "$STAGE" = "1" ] || return 0
  echo "Rolling back to the previous installation..." >&2
  [ -x "$DEST/fcd-mlo-runner-heal.sh" ] && "$DEST/fcd-mlo-runner-heal.sh" stop >/dev/null 2>&1
  [ -x "$DEST/roamctl" ] && "$DEST/roamctl" stop >/dev/null 2>&1
  cru d flowcache-doctor-watchdog 2>/dev/null
  cru d flowcache-doctor-mlo-hw-watchdog 2>/dev/null
  rm -f "$DEST/fcd-lib.sh" "$DEST/fcd-platform-gtbe19000ai.sh" "$DEST/fcd-daemon.sh" \
    "$DEST/fcd-events.sh" "$DEST/fcd-mlo-runner-heal.sh" "$DEST/fcd-incident.sh" "$DEST/roamctl" "$DEST/flowcache-doctor.conf" \
    "$DEST/flowcache-doctor-uninstall.sh" "$DEST/flowcache-doctor.disabled"
  for f in roam-detect.sh roam-events.sh roam-lib.sh roam-mlo.sh roamctl fcd-lib.sh \
    fcd-platform-gtbe19000ai.sh fcd-daemon.sh fcd-events.sh fcd-mlo-runner-heal.sh fcd-incident.sh flowcache-doctor.conf \
    flowcache-doctor-uninstall.sh; do
    [ -e "$BACKUP/$f" ] && cp -p "$BACKUP/$f" "$DEST/$f"
  done
  [ -e "$BACKUP/services-start" ] && cp -p "$BACKUP/services-start" "$SS"
  [ -e "$BACKUP/profile.add" ] && cp -p "$BACKUP/profile.add" "$PROFILE"
  rm -rf /tmp/flowcache-doctor /tmp/roam-detect
  [ -x "$DEST/roamctl" ] && "$DEST/roamctl" start >/dev/null 2>&1
  [ -x "$DEST/fcd-mlo-runner-heal.sh" ] && "$DEST/fcd-mlo-runner-heal.sh" start >/dev/null 2>&1
  [ -f "$SS" ] && grep 'cru a roam-detect-wd' "$SS" 2>/dev/null | sh >/dev/null 2>&1
}
fail(){ echo "ERROR: $*" >&2; rollback; rm -rf "$TMP"; exit 1; }

[ -d /jffs ] || fail "/jffs is unavailable"
[ "$(nvram get jffs2_scripts)" = "1" ] || fail "Enable JFFS custom scripts first"
which curl >/dev/null 2>&1 || fail "curl is unavailable"
which fcctl >/dev/null 2>&1 || fail "fcctl is unavailable"
mkdir -p "$TMP" "$DEST" "$ROOT" "$BACKUP" /jffs/configs

[ -x "$DEST/fcd-mlo-runner-heal.sh" ] && "$DEST/fcd-mlo-runner-heal.sh" stop >/dev/null 2>&1
[ -x "$DEST/roamctl" ] && "$DEST/roamctl" stop >/dev/null 2>&1
for f in roam-detect.sh roam-events.sh roam-lib.sh roam-mlo.sh roamctl fcd-lib.sh \
  fcd-platform-gtbe19000ai.sh fcd-daemon.sh fcd-events.sh fcd-mlo-runner-heal.sh fcd-incident.sh flowcache-doctor.conf \
  flowcache-doctor-uninstall.sh; do
  [ -e "$DEST/$f" ] && cp -p "$DEST/$f" "$BACKUP/$f"
done
[ -e "$SS" ] && cp -p "$SS" "$BACKUP/services-start"
[ -e "$PROFILE" ] && cp -p "$PROFILE" "$BACKUP/profile.add"

for f in $FILES; do
  curl -fsSL "$REPO_RAW/scripts/$f?cb=$(date +%s)" -o "$TMP/$f" || fail "download failed: $f"
  sh -n "$TMP/$f" || fail "syntax check failed: $f"
done

# Make the model parser part of every process that sources fcd-lib.sh.
printf '\n%s\n' '[ -r /jffs/scripts/fcd-platform-gtbe19000ai.sh ] && . /jffs/scripts/fcd-platform-gtbe19000ai.sh' >> "$TMP/fcd-lib.sh"
sh -n "$TMP/fcd-lib.sh" || fail "combined library syntax check failed"
sed -i "s/^VERSION=.*/VERSION=$VERSION/" "$TMP/roamctl"
sh -n "$TMP/roamctl" || fail "versioned roamctl syntax check failed"

curl -fsSL "$REPO_RAW/uninstall.sh?cb=$(date +%s)" -o "$TMP/uninstall.sh" || fail "download failed: uninstall.sh"
sh -n "$TMP/uninstall.sh" || fail "syntax check failed: uninstall.sh"

cat > "$TMP/flowcache-doctor.conf" <<'EOFCONF'
# Legacy/pre-EHT auto-heal remains fail-closed. MLO/EHT uses the separate lifecycle-triggered HW healer below.
FCD_INTERVAL=2
FCD_CONFIRMATIONS=5
FCD_CONFIRM_MAX_AGE=8
FCD_AUTOFIX=1
FCD_EVENT_HEAL=1
FCD_MIN_GAP=8
FCD_COOLDOWN=60
FCD_PENDING_TTL=60
FCD_SETTLE_FLUSHES="20 60 300"
FCD_LOG_RETENTION_DAYS=30
FCD_STEER_MODE=advisor
FCD_LOG_SYSLOG=0
FCD_BSSLIST=auto

# Automatic MLO Runner stale-state repair. Triggered only by client lifecycle/reinit events.
# It waits for the MLO session to settle, then invalidates only that client's HW-offloaded flows.
# No global FlowCache flush, Runner cycle, Wi-Fi restart, steering, or deauthentication is performed.
FCD_MLO_HW_HEAL=1
FCD_MLO_HW_SETTLE=3
FCD_MLO_HW_COOLDOWN=60
FCD_MLO_KERNEL_EVENTS=1

# Passive congestion correlation. It never steers, restarts, changes channels, or flushes a radio.
FCD_UTIL_HIGH=85
FCD_UTIL_RECOVER=65
FCD_UTIL_SPIKE_DELTA=20
FCD_UTIL_LOG_COOLDOWN=60
FCD_INCIDENT_CAPTURE=1
FCD_INCIDENT_SAMPLES=6
FCD_INCIDENT_SAMPLE_INTERVAL=2
FCD_INCIDENT_COOLDOWN=120
FCD_PROBE_IP=1.1.1.1
EOFCONF
sh -n "$TMP/flowcache-doctor.conf" || fail "default config invalid"

STAGE=1
for f in $FILES; do
  cp "$TMP/$f" "$DEST/$f" || fail "install failed: $f"
  chmod 755 "$DEST/$f"
done
cp "$TMP/uninstall.sh" "$DEST/flowcache-doctor-uninstall.sh" || fail "install failed: uninstall"
chmod 755 "$DEST/flowcache-doctor-uninstall.sh"
cp "$TMP/flowcache-doctor.conf" "$DEST/flowcache-doctor.conf" || fail "install failed: config"
chmod 644 "$DEST/flowcache-doctor.conf"

# Remove upstream runtime scripts only after the replacement is complete.
rm -f "$DEST/roam-detect.sh" "$DEST/roam-events.sh" "$DEST/roam-lib.sh" "$DEST/roam-mlo.sh" \
  "$DEST/roam-detect.conf" "$DEST/roam-detect.flush" "$DEST/roam-detect.policy" \
  "$DEST/roam-nonmlo.allow" "$DEST/roam-mlo.ignore"
rm -rf /tmp/roam-detect
cru d roam-detect-wd 2>/dev/null

[ -f "$SS" ] || { printf '#!/bin/sh\n' > "$SS"; chmod 755 "$SS"; }
sed -i '/roamctl boot/d; /roam-detect-wd/d; /flowcache-doctor-watchdog/d; /fcd-mlo-runner-heal.sh start/d; /flowcache-doctor-mlo-hw-watchdog/d' "$SS"
printf '%s\n' "$DEST/roamctl boot" >> "$SS"
printf '%s\n' "$DEST/fcd-mlo-runner-heal.sh start" >> "$SS"
printf '%s\n' 'cru a flowcache-doctor-watchdog "* * * * * /jffs/scripts/roamctl watchdog"' >> "$SS"
printf '%s\n' 'cru a flowcache-doctor-mlo-hw-watchdog "* * * * * /jffs/scripts/fcd-mlo-runner-heal.sh watchdog"' >> "$SS"
cru d flowcache-doctor-watchdog 2>/dev/null
cru a flowcache-doctor-watchdog "* * * * * $DEST/roamctl watchdog"
cru d flowcache-doctor-mlo-hw-watchdog 2>/dev/null
cru a flowcache-doctor-mlo-hw-watchdog "* * * * * $DEST/fcd-mlo-runner-heal.sh watchdog"
[ -f "$PROFILE" ] || : > "$PROFILE"
sed -i '/alias roamctl=.*flowcache-doctor/d' "$PROFILE"
printf '%s\n' "alias roamctl='$DEST/roamctl' # flowcache-doctor" >> "$PROFILE"
rm -f "$DEST/flowcache-doctor.disabled"
rm -rf /tmp/flowcache-doctor
"$DEST/roamctl" start
"$DEST/fcd-mlo-runner-heal.sh" start
sleep 3
"$DEST/roamctl" health || fail "installed files failed health check; previous version restored; backup is at $BACKUP"
if [ -f /jffs/wifi_wlc.log ] || which logread >/dev/null 2>&1; then
  "$DEST/fcd-mlo-runner-heal.sh" status >/dev/null 2>&1 || fail "MLO Runner healer failed to start; previous version restored; backup is at $BACKUP"
fi
[ -x "$DEST/fcd-platform-gtbe19000ai.sh" ] || fail "platform parser missing after install"
[ -x "$DEST/fcd-incident.sh" ] || fail "incident capture missing after install"
STAGE=2
rm -rf "$TMP"
echo "Installed flowcache-doctor $VERSION"
echo "Backup of the previous version: $BACKUP"
if [ -f /jffs/wifi_wlc.log ] || which logread >/dev/null 2>&1; then
  echo "MLO Runner hardware stale-state healer: active"
else
  echo "MLO Runner hardware stale-state healer: armed; waiting for event source"
fi
echo "Run: /jffs/scripts/roamctl clients"
