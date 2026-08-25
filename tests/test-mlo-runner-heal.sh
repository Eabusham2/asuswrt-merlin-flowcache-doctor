#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'FCD_LIB="$ROOT/scripts/fcd-lib.sh" FCD_STATE="$T/state" FCD_ROOT="$T/root" FCD_CONF="$T/none" FCD_WIFI_EVENT_LOG="$T/wifi.log" FCD_MLO_KERNEL_EVENTS=0 "$ROOT/scripts/fcd-mlo-runner-heal.sh" stop >/dev/null 2>&1 || true; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/root"
: > "$T/wifi.log"

M1=02:11:22:33:44:55
M2=02:11:22:33:44:66
UNK=02:aa:bb:cc:dd:ee
export M1 M2 UNK

cat > "$T/bin/ls" <<'EOS'
#!/bin/sh
if [ "${1:-}" = /sys/class/net/br0/brif ]; then
  printf 'wl0.1\nwl1.1\n'
else
  /bin/ls "$@"
fi
EOS

cat > "$T/bin/wl" <<'EOS'
#!/bin/sh
case "$*" in
  *" ssid") echo 'Current SSID: "Home"';;
  *" assoclist") printf 'assoclist %s\nassoclist %s\n' "$M1" "$M2";;
  *" sta_info $M1"|*" sta_info $M2") echo 'flags AUTH ASSOC AUTHORIZED EHT_CAP'; echo 'peer_mld_addr 02:11:22:33:44:00';;
  *" mlo"|*" mlo_status") :;;
  *) :;;
esac
EOS

cat > "$T/bin/fcctl" <<EOS
#!/bin/sh
printf '%s\n' "\$*" >> "$T/fcctl.calls"
EOS
cat > "$T/bin/logger" <<'EOS'
#!/bin/sh
:
EOS
chmod +x "$T/bin"/*
PATH="$T/bin:$PATH"; export PATH

export FCD_LIB="$ROOT/scripts/fcd-lib.sh"
export FCD_STATE="$T/state"
export FCD_ROOT="$T/root"
export FCD_CONF="$T/none"
export FCD_LOG_SYSLOG=0
export FCD_WIFI_EVENT_LOG="$T/wifi.log"
export FCD_MLO_KERNEL_EVENTS=0
export FCD_MLO_HW_HEAL=1
export FCD_MLO_HW_SETTLE=2
export FCD_MLO_HW_COOLDOWN=15

"$ROOT/scripts/fcd-mlo-runner-heal.sh" start
sleep 1

printf 'Aug 23 16:00:00 wlceventd: wl1.1: ReAssoc %s Successful\n' "$M1" >> "$T/wifi.log"
sleep 4
[ -s "$T/fcctl.calls" ] || { echo 'FAIL reassoc did not auto-heal'; exit 1; }
grep -qx "flush --hw --mac $M1" "$T/fcctl.calls" || { echo 'FAIL wrong reassoc repair command'; cat "$T/fcctl.calls"; exit 1; }

a=$(wc -l < "$T/fcctl.calls" | tr -d ' ')
printf 'Aug 23 16:00:10 wlceventd: wl1.1: ReAssoc %s Successful\n' "$UNK" >> "$T/wifi.log"
sleep 4
b=$(wc -l < "$T/fcctl.calls" | tr -d ' ')
[ "$a" = "$b" ] || { echo 'FAIL unknown client reached hardware flush'; exit 1; }

printf 'Aug 23 16:00:20 kernel: SBF: dhd2: INIT [%s] ID 65535 BFW 65535 THRSH 2048\n' "$M2" >> "$T/wifi.log"
sleep 4
grep -qx "flush --hw --mac $M2" "$T/fcctl.calls" || { echo 'FAIL SBF INIT did not auto-heal'; cat "$T/fcctl.calls"; exit 1; }

[ "$(wc -l < "$T/fcctl.calls" | tr -d ' ')" -eq 2 ] || { echo 'FAIL unexpected hardware flush count'; cat "$T/fcctl.calls"; exit 1; }
status_out=$("$ROOT/scripts/fcd-mlo-runner-heal.sh" status)
printf '%s\n' "$status_out" | grep -q running
"$ROOT/scripts/fcd-mlo-runner-heal.sh" stop

echo 'PASS automatic MLO Runner healing'
