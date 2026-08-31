#!/bin/sh
set -u

SS=/jffs/scripts/services-start
CONF=/jffs/scripts/flowcache-doctor.conf
CLEANUP=/jffs/scripts/flowcache-doctor-cleanup.sh
RC=0
ok(){ echo "  ok: $*"; }
bad(){ echo "  FAIL: $*"; RC=1; }
warn(){ echo "  warn: $*"; }

check_exec(){ [ -x "$1" ] && ok "executable $1" || bad "missing/not executable $1"; }
check_hook(){ grep -q "$1" "$SS" 2>/dev/null && ok "boot hook: $2" || bad "boot hook missing: $2"; }
check_cron(){ cru l 2>/dev/null | grep -q "$1" && ok "cron watchdog: $2" || bad "cron watchdog missing: $2"; }

echo "flowcache-doctor suite health"
[ "$(nvram get jffs2_scripts 2>/dev/null)" = 1 ] && ok "JFFS custom scripts enabled" || bad "JFFS custom scripts disabled"
[ -x "$SS" ] && ok "services-start executable" || bad "services-start missing/not executable"

check_exec /jffs/scripts/roamctl
check_exec /jffs/scripts/fcd-airiq-guard.sh
check_exec /jffs/scripts/fcd-wifi-dropwatch.sh
check_exec /jffs/scripts/fcd-util-detail.sh

check_hook '/jffs/scripts/roamctl boot' 'Flowcache Doctor'
check_hook 'fcd-airiq-guard.sh start' 'AirIQ Guard'
check_hook 'fcd-wifi-dropwatch.sh start' 'Wi-Fi Dropwatch'

check_cron 'flowcache-doctor-watchdog' 'Flowcache Doctor'
check_cron 'fcd-airiq-guard' 'AirIQ Guard'
check_cron 'fcd-wifi-dropwatch' 'Wi-Fi Dropwatch'

if [ -x /jffs/scripts/roamctl ]; then
  /jffs/scripts/roamctl health >/tmp/fcd-suite-roamctl-health.$$ 2>&1
  if [ $? -eq 0 ]; then ok "Flowcache Doctor runtime healthy"; else bad "Flowcache Doctor runtime unhealthy"; cat /tmp/fcd-suite-roamctl-health.$$; fi
  rm -f /tmp/fcd-suite-roamctl-health.$$
fi

if [ -x /jffs/scripts/fcd-airiq-guard.sh ]; then
  _a=$(/jffs/scripts/fcd-airiq-guard.sh status 2>/dev/null)
  printf '%s\n' "$_a" | grep -q 'guard instances: 1' && ok "AirIQ Guard exactly one instance" || { bad "AirIQ Guard instance count wrong"; printf '%s\n' "$_a"; }
fi

if [ -x /jffs/scripts/fcd-wifi-dropwatch.sh ]; then
  /jffs/scripts/fcd-wifi-dropwatch.sh health >/tmp/fcd-suite-dropwatch-health.$$ 2>&1
  if [ $? -eq 0 ]; then ok "Wi-Fi Dropwatch healthy"; else bad "Wi-Fi Dropwatch unhealthy"; cat /tmp/fcd-suite-dropwatch-health.$$; fi
  rm -f /tmp/fcd-suite-dropwatch-health.$$
fi

[ -d /jffs/flowcache-doctor/log ] && ok "event log directory present" || warn "event log directory absent until first log"
[ -d /jffs/flowcache-doctor/dropwatch ] && ok "dropwatch capture directory present" || warn "dropwatch capture directory absent until first start"

DROP_RET=14
if [ -f "$CONF" ]; then
  _dr=$(sed -n 's/^FCD_DROPWATCH_RETENTION_DAYS=//p' "$CONF" | tail -n 1)
  case "$_dr" in ''|*[!0-9]*) :;; *) DROP_RET=$_dr;; esac
fi

FLOW_RET=30
if [ -f "$CLEANUP" ]; then
  _fr=$(sed -n 's/^DAYS=//p' "$CLEANUP" | head -n 1)
  case "$_fr" in ''|*[!0-9]*) :;; *) FLOW_RET=$_fr;; esac
elif [ -f "$CONF" ]; then
  _fr=$(sed -n 's/^FCD_LOG_RETENTION_DAYS=//p' "$CONF" | tail -n 1)
  case "$_fr" in ''|*[!0-9]*) :;; *) FLOW_RET=$_fr;; esac
fi

echo "  retention: Flowcache logs ${FLOW_RET} days; Dropwatch captures ${DROP_RET} days"

[ "$RC" -eq 0 ] && echo healthy || echo "problems found"
exit "$RC"
