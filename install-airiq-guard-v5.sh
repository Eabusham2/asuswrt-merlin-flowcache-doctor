#!/bin/sh
set -u

REPO_RAW=https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main
DEST=/jffs/scripts
GUARD=$DEST/fcd-airiq-guard.sh
UTIL=$DEST/fcd-util-detail.sh
SS=$DEST/services-start
TMP=/tmp/fcd-airiq-guard-v5.$$
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
[ -e "$UTIL" ] && cp -p "$UTIL" "$BACKUP/fcd-util-detail.sh"
[ -e "$SS" ] && cp -p "$SS" "$BACKUP/services-start"

curl -fsSL "$REPO_RAW/scripts/fcd-airiq-guard.sh?cb=$(date +%s)" \
  -o "$TMP/fcd-airiq-guard.base.sh" || fail "guard download failed"
curl -fsSL "$REPO_RAW/scripts/fcd-util-detail.sh?cb=$(date +%s)" \
  -o "$TMP/fcd-util-detail.sh" || fail "utilization tool download failed"

# Patch only the timeout branch. Ordinary Off checks never commit NVRAM.
awk '
  /^enforce_enabled_timeout\(\) \{/ { in_timeout=1 }
  /^check_once\(\) \{/ { in_timeout=0 }
  {
    if (in_timeout && $0 ~ /log_msg AIRIQ-TIMEOUT/) {
      gsub(/commit=no/, "commit=requested")
    }
    print
    if (in_timeout && $0 == "  sync_hidden_off_flags") {
      print "  if nvram commit >/dev/null 2>&1; then"
      print "    log_msg AIRIQ-COMMIT \"timeout-off persisted=yes\""
      print "  else"
      print "    log_msg AIRIQ-COMMIT-FAIL \"timeout-off persisted=no; runtime-off still applied\""
      print "  fi"
      patched++
    }
    if ($0 ~ /echo \"enabled-session cap:/) {
      print "    echo \"timeout persistence: nvram commit once when the 10-minute limit expires\""
    }
  }
  END { if (patched != 1) exit 42 }
' "$TMP/fcd-airiq-guard.base.sh" > "$TMP/fcd-airiq-guard.sh" || fail "persistent-timeout patch failed"

sh -n "$TMP/fcd-airiq-guard.sh" || fail "guard syntax check failed"
sh -n "$TMP/fcd-util-detail.sh" || fail "utilization tool syntax check failed"
grep -q 'nvram commit' "$TMP/fcd-airiq-guard.sh" || fail "persistent commit missing"
grep -q 'AIRIQ-COMMIT' "$TMP/fcd-airiq-guard.sh" || fail "commit logging missing"
[ "$(grep -c 'nvram commit' "$TMP/fcd-airiq-guard.sh")" -eq 2 ] || fail "unexpected commit references"

stop_all_old_guards
cp "$TMP/fcd-airiq-guard.sh" "$GUARD" || fail "guard install failed"
cp "$TMP/fcd-util-detail.sh" "$UTIL" || fail "utilization tool install failed"
chmod 755 "$GUARD" "$UTIL" || fail "cannot make scripts executable"

[ -f "$SS" ] || {
  printf '#!/bin/sh\n' > "$SS" || fail "cannot create services-start"
  chmod 755 "$SS"
}
sed -i '/fcd-airiq-guard.sh start/d' "$SS"
printf '%s\n' "$GUARD start # fcd-airiq-guard" >> "$SS"
chmod 755 "$SS"

cru d fcd-airiq-guard 2>/dev/null
cru a fcd-airiq-guard "* * * * * $GUARD start"

"$GUARD" once || fail "initial AirIQ policy check failed"
"$GUARD" start || fail "guard start failed"
sleep 3

COUNT=$(guard_pids | awk 'NF{n++} END{print n+0}')
[ "$COUNT" -eq 1 ] || fail "expected one guard daemon, found $COUNT"
grep -q 'fcd-airiq-guard.sh start' "$SS" || fail "boot hook missing"
cru l 2>/dev/null | grep -q 'fcd-airiq-guard' || fail "cron watchdog missing"
[ -x "$UTIL" ] || fail "utilization detail tool missing"

"$GUARD" status
printf '%s\n' "Boot hook: installed"
printf '%s\n' "Cron watchdog: installed"
printf '%s\n' "AirIQ timeout: 600 seconds"
printf '%s\n' "Timeout action: persist Off with one nvram commit, then stop all AirIQ processes"
printf '%s\n' "Normal Off enforcement: runtime only, no repeated commits"
printf '%s\n' "AirIQ guard v5 installed. Backup: $BACKUP"
rm -rf "$TMP"
