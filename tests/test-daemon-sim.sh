#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/root"
cat > "$T/conf" <<EOFCONF
FCD_ROOT=$T/root
FCD_STATE=$T/state
FCD_LOG_SYSLOG=0
FCD_BSSLIST="wl0.1 wl1.1 wl2.1"
FCD_CONFIRMATIONS=5
FCD_CONFIRM_MAX_AGE=30
FCD_MIN_GAP=0
FCD_SETTLE_FLUSHES=""
FCD_AUTOFIX=1
FCD_EVENT_HEAL=0
EOFCONF
cat > "$T/bin/wl" <<'EOS'
#!/bin/sh
bss=$2; cmd=$3; mac=${4:-}
case "$cmd" in
 assoclist)
   case "$bss" in
     wl0.1) echo 'assoclist aa:bb:cc:dd:ee:10'; echo 'assoclist aa:bb:cc:dd:ee:20';;
     wl1.1) echo 'assoclist aa:bb:cc:dd:ee:20';;
   esac;;
 sta_info)
   case "$mac" in
     aa:bb:cc:dd:ee:10) echo 'phy type: ax'; echo 'HE Capable';;
     aa:bb:cc:dd:ee:20) echo 'phy type: be'; echo 'EHT capable'; echo 'peer_mld_addr 02:00:00:00:00:20';;
   esac;;
 mlo|mlo_status) echo 'MLD 02:00:00:00:00:20 link addr aa:bb:cc:dd:ee:20';;
 status) echo 'QBSS Channel Utilization: 20';;
 rssi) echo -50;;
esac
EOS
cat > "$T/bin/brctl" <<'EOS'
#!/bin/sh
:
EOS
cat > "$T/bin/fcctl" <<EOS
#!/bin/sh
echo "\$*" >> "$T/fcctl.calls"
EOS
cat > "$T/bin/logger" <<'EOS'
#!/bin/sh
:
EOS
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH" FCD_LIB="$ROOT/scripts/fcd-lib.sh" FCD_CONF="$T/conf" FCD_ONCE=1
for i in 1 2 3 4 5; do busybox sh "$ROOT/scripts/fcd-daemon.sh"; done
now=$(date +%s); exp=$((now+60))
printf 'aa:bb:cc:dd:ee:10|wl0.1|%s|simulated-roam\n' "$exp" > "$T/state/pending/aabbccddee10"
printf 'aa:bb:cc:dd:ee:20|wl0.1|%s|simulated-mlo-event\n' "$exp" > "$T/state/pending/aabbccddee20"
busybox sh "$ROOT/scripts/fcd-daemon.sh"
[ "$(grep -c 'aa:bb:cc:dd:ee:10' "$T/fcctl.calls" 2>/dev/null || true)" -eq 1 ]
[ "$(grep -c 'aa:bb:cc:dd:ee:20' "$T/fcctl.calls" 2>/dev/null || true)" -eq 0 ]
[ ! -e "$T/state/daemon.pid" ]
[ ! -d "$T/state/daemon.lock" ]
[ ! -e "$T/state/pending/aabbccddee10" ]
[ ! -e "$T/state/pending/aabbccddee20" ]
grep -q 'FLUSH mac=aa:bb:cc:dd:ee:10' "$T/root/log"/events-*.log
grep -q 'PROTECT mac=aa:bb:cc:dd:ee:20' "$T/root/log"/events-*.log
echo 'PASS daemon simulation'
