#!/bin/sh
set -eu
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FCD_ROOT="$T/root" FCD_STATE="$T/state" FCD_CONF="$T/none" FCD_LOG_SYSLOG=0
mkdir -p "$T/bin" "$FCD_STATE"
PATH="$T/bin:$PATH"; export PATH
cat > "$T/bin/wl" <<'EOS'
#!/bin/sh
b=; [ "$1" = -i ] && { b=$2; shift 2; }
cmd=$1; shift || true
m=$(printf '%s' "${1:-}" | tr 'a-f' 'A-F')
case "$cmd:$b:$m" in
  assoclist:wl0.1:*) printf 'assoclist C6:95:A6:65:81:94\nassoclist 14:D4:24:FB:FE:7C\n';;
  assoclist:wl1.1:*) printf 'assoclist EE:16:0C:C1:71:19\n';;
  sta_info:wl0.1:C6:95:A6:65:81:94) printf '%s\n' 'flags 0x1e13a: WME PS N_CAP AMPDU AMSDU' 'rate of last tx pkt: 58500 kbps - 19500 kbps' 'rate of last rx pkt: 52000 kbps' 'eml capabilities : 0x0';;
  sta_info:wl0.1:14:D4:24:FB:FE:7C) printf '%s\n' 'flags 0x1e13a: WME PS N_CAP AMPDU AMSDU' 'rate of last tx pkt: 65000 kbps - 19500 kbps' 'rate of last rx pkt: 39000 kbps' 'eml capabilities : 0x0';;
  sta_info:wl1.1:EE:16:0C:C1:71:19) printf '%s\n' 'flags 0x51e03b: BRCM WME N_CAP VHT_CAP HE_CAP AMPDU AMSDU' 'rate of last tx pkt: 648520 kbps - 216170 kbps' 'rate of last rx pkt: 144110 kbps' 'eml capabilities : 0x0';;
  chanim_stats:wl0.1:*) printf '%s\n' 'chspec tx inbss obss nocat nopkt doze txop goodtx badtx glitch badplcp knoise idle busy timestamps' '11 12 0 11 6 16 0 58 0 2 2810 24 -94 68 42 10879396';;
  chanim_stats:wl1.1:*) printf '%s\n' 'chspec tx inbss obss nocat nopkt doze txop goodtx badtx glitch badplcp knoise idle busy timestamps' '149/80 3 1 4 1 1 0 93 1 1 27 5 -91 95 8 10875099';;
  mlo:*:*) echo '1 (0x1)';;
  *) :;;
esac
EOS
chmod +x "$T/bin/wl"
. ./scripts/fcd-lib.sh
. ./scripts/fcd-platform-gtbe19000ai.sh
fcd_mkdirs
check(){ [ "$1" = "$2" ] || { echo "FAIL $3: got '$1', expected '$2'"; exit 1; }; }
check "$(fcd_classify c6:95:a6:65:81:94 wl0.1 'wl0.1 wl1.1 wl2.1')" nonmlo-negotiated-n n-cap
check "$(fcd_classify ee:16:0c:c1:71:19 wl1.1 'wl0.1 wl1.1 wl2.1')" nonmlo-negotiated-ax he-cap
check "$(fcd_client_rates wl0.1 c6:95:a6:65:81:94)" 59/52M n-rates
check "$(fcd_client_rates wl1.1 ee:16:0c:c1:71:19)" 649/144M he-rates
check "$(fcd_radio_util wl0.1)" 42 util-2g
check "$(fcd_radio_util wl1.1)" 8 util-5g
echo 'PASS GT-BE19000AI live format'
