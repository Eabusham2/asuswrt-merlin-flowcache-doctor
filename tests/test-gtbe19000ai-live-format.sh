#!/bin/sh
set -eu
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FCD_ROOT="$T/root" FCD_STATE="$T/state" FCD_LOG_SYSLOG=0
export FCD_UTIL_SPIKE_DELTA=20 FCD_UTIL_LOG_COOLDOWN=0
mkdir -p "$T/bin" "$FCD_STATE"
PATH="$T/bin:$PATH"; export PATH
UTIL2G_FILE="$T/util2g"; echo 42 > "$UTIL2G_FILE"; export UTIL2G_FILE

cat > "$T/bin/wl" <<'EOS'
#!/bin/sh
b=; [ "$1" = -i ] && { b=$2; shift 2; }
cmd=${1:-}; shift || true
m=$(printf '%s' "${1:-}" | tr 'a-f' 'A-F')
case "$cmd:$b:$m" in
  assoclist:wl0.1:*) printf 'assoclist 00:11:22:33:44:55\nassoclist 02:11:22:33:44:77\n';;
  assoclist:wl1.1:*) printf 'assoclist 00:11:22:33:44:66\nassoclist 02:11:22:33:44:88\n';;
  sta_info:wl0.1:00:11:22:33:44:55) printf '%s\n' 'flags 0x1e13a: WME PS N_CAP AMPDU AMSDU' 'rate of last tx pkt: 58500 kbps - 19500 kbps' 'rate of last rx pkt: 52000 kbps' 'eml capabilities : 0x0';;
  sta_info:wl1.1:00:11:22:33:44:66) printf '%s\n' 'flags 0x51e03b: BRCM WME N_CAP VHT_CAP HE_CAP AMPDU AMSDU' 'rate of last tx pkt: 648520 kbps - 216170 kbps' 'rate of last rx pkt: 144110 kbps' 'eml capabilities : 0x0';;
  sta_info:wl0.1:02:11:22:33:44:77) printf '%s\n' 'flags 0x100: WME PS' 'eml capabilities : 0x0';;
  sta_info:wl1.1:02:11:22:33:44:88) printf '%s\n' 'flags 0x900: WME EHT_CAP AMPDU' 'EHT caps 0x1' 'eml capabilities : 0x1';;
  chanim_stats:wl0.1:*) u=$(cat "$UTIL2G_FILE"); printf '%s\n' 'chspec tx inbss obss nocat nopkt doze txop goodtx badtx glitch badplcp knoise idle busy timestamps' "11 12 0 11 6 16 0 58 0 2 2810 24 -94 68 $u 10879396";;
  chanim_stats:wl1.1:*) printf '%s\n' 'chspec tx inbss obss nocat nopkt doze txop goodtx badtx glitch badplcp knoise idle busy timestamps' '149/80 3 1 4 1 1 0 93 1 1 27 5 -91 95 8 10875099';;
  chanim_stats:wl2.1:*) printf '%s\n' 'chspec tx inbss obss nocat nopkt doze txop goodtx badtx glitch badplcp knoise idle busy timestamps' '6g37/320-2 1 0 1 1 1 0 99 0 0 0 2 -86 100 1 10869531';;
  rssi:*:*) echo -60;;
  mlo:*:*) echo '1 (0x1)';;
  mlo_status:*:*) echo 'wl: Unsupported';;
  *) :;;
esac
EOS
chmod +x "$T/bin/wl"

. ./scripts/fcd-lib.sh
. ./scripts/fcd-platform-gtbe19000ai.sh
fcd_mkdirs
check(){ [ "$1" = "$2" ] || { echo "FAIL $3: got '$1', expected '$2'"; exit 1; }; }

check "$(fcd_classify 00:11:22:33:44:55 wl0.1 'wl0.1 wl1.1 wl2.1')" nonmlo-negotiated-n n-cap
check "$(fcd_classify 00:11:22:33:44:66 wl1.1 'wl0.1 wl1.1 wl2.1')" nonmlo-negotiated-ax he-cap
check "$(fcd_classify 02:11:22:33:44:77 wl0.1 'wl0.1 wl1.1 wl2.1')" mlo-fallback-unclassified unknown-mlo-fallback
check "$(fcd_classify 02:11:22:33:44:88 wl1.1 'wl0.1 wl1.1 wl2.1')" mlo-or-eht one-link-eht-protected
check "$(fcd_client_rates wl0.1 00:11:22:33:44:55)" 59/52M n-rates
check "$(fcd_client_rates wl1.1 00:11:22:33:44:66)" 649/144M he-rates
check "$(fcd_radio_util wl0.1)" 42 util-2g
check "$(fcd_radio_util wl1.1)" 8 util-5g

FIELDS=$(fcd_chanim_fields wl0.1)
check "$(fcd_kv "$FIELDS" busy)" 42 fields-busy
check "$(fcd_chanim_cause_from_fields 'chspec=1 tx=2 inbss=2 obss=55 nocat=1 nopkt=2 doze=0 txop=30 goodtx=1 badtx=1 glitch=0 badplcp=0 knoise=-90 idle=30 busy=70 timestamp=1')" other-wifi-contention cause-obss
check "$(fcd_chanim_cause_from_fields 'chspec=1 tx=2 inbss=2 obss=4 nocat=30 nopkt=20 doze=0 txop=30 goodtx=1 badtx=1 glitch=0 badplcp=0 knoise=-90 idle=30 busy=70 timestamp=1')" nonwifi-or-undecodable-energy cause-nonwifi
check "$(fcd_chanim_cause_from_fields 'chspec=1 tx=40 inbss=20 obss=1 nocat=1 nopkt=1 doze=0 txop=30 goodtx=20 badtx=2 glitch=0 badplcp=0 knoise=-90 idle=30 busy=65 timestamp=1')" local-airtime-or-retries cause-local
check "$(fcd_chanim_cause_from_fields 'chspec=1 tx=2 inbss=2 obss=2 nocat=2 nopkt=2 doze=0 txop=1 goodtx=0 badtx=0 glitch=0 badplcp=0 knoise=-90 idle=5 busy=95 timestamp=1')" driver-or-counter-anomaly cause-driver

fcd_observe_class 02:11:22:33:44:77 mlo-fallback-unclassified wl0.1
[ ! -e "$FCD_STATE/class/021122334477.protected" ] || { echo 'FAIL fallback became sticky'; exit 1; }

echo 10 > "$UTIL2G_FILE"; fcd_observe_radio_util wl0.1
echo 50 > "$UTIL2G_FILE"; fcd_observe_radio_util wl0.1
grep -q 'UTIL-SPIKE.*bss=wl0.1.*previous=10% current=50%' "$FCD_ROOT/log"/events.log || { echo 'FAIL utilization spike log'; exit 1; }

echo 'PASS GT-BE19000AI live format, cause classifier, and fail-closed fallback'
