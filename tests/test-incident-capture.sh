#!/bin/sh
set -eu
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FCD_ROOT="$T/root" FCD_STATE="$T/state" FCD_LOG_SYSLOG=0
export FCD_BSSLIST="wl0.1 wl1.1 wl2.1"
export FCD_INCIDENT_SAMPLES=2 FCD_INCIDENT_SAMPLE_INTERVAL=0 FCD_INCIDENT_COOLDOWN=0
mkdir -p "$T/bin" "$T/lib" "$FCD_ROOT" "$FCD_STATE"
cat scripts/fcd-lib.sh scripts/fcd-platform-gtbe19000ai.sh > "$T/lib/fcd-lib.sh"
export FCD_LIB="$T/lib/fcd-lib.sh"
PATH="$T/bin:$PATH"; export PATH

cat > "$T/bin/nvram" <<'EOS'
#!/bin/sh
case "$1:$2" in
  get:productid) echo GT-BE19000AI;;
  get:firmver) echo 3.0.0.6;;
  get:buildno) echo 102;;
  get:extendno) echo test;;
  get:wan0_gateway) echo 192.0.2.1;;
  get:dhcp_dns1_x) echo 192.0.2.53;;
  get:smart_connect_x) echo 1;;
  get:mld_enable) echo 1;;
  show:*) echo test=value;;
  *) :;;
esac
EOS
cat > "$T/bin/wl" <<'EOS'
#!/bin/sh
b=; [ "$1" = -i ] && { b=$2; shift 2; }
cmd=${1:-}; shift || true
m=$(printf '%s' "${1:-}" | tr 'a-f' 'A-F')
case "$cmd:$b:$m" in
  ssid:*:*) echo 'Current SSID: "Test"';;
  assoclist:wl0.1:*) echo 'assoclist 00:11:22:33:44:55';;
  assoclist:*:*) :;;
  chanim_stats:wl0.1:*) printf '%s\n' 'chspec tx inbss obss nocat nopkt doze txop goodtx badtx glitch badplcp knoise idle busy timestamps' '11 50 25 2 2 2 0 10 30 2 2 1 -95 10 90 1';;
  chanim_stats:wl1.1:*) printf '%s\n' 'chspec tx inbss obss nocat nopkt doze txop goodtx badtx glitch badplcp knoise idle busy timestamps' '149/80 2 2 2 1 1 0 90 2 1 1 1 -92 90 10 1';;
  chanim_stats:wl2.1:*) printf '%s\n' 'chspec tx inbss obss nocat nopkt doze txop goodtx badtx glitch badplcp knoise idle busy timestamps' '6g37/320-2 1 1 1 1 1 0 95 1 0 0 0 -88 95 5 1';;
  sta_info:wl0.1:00:11:22:33:44:55) printf '%s\n' 'flags 0x1: N_CAP' 'smoothed rssi: -60' 'tx total pkts sent: 100' 'tx pkts retries: 80' 'tx pkts retry exhausted: 1' 'tx failures: 1' 'rate of last tx pkt: 65000 kbps' 'rate of last rx pkt: 52000 kbps' 'eml capabilities : 0x0';;
  counters:*:*) echo 'txbcnfrm 1';;
  mlo:*:*) echo '1 (0x1)';;
  mlo_status:*:*) echo 'wl: Unsupported';;
  *) :;;
esac
EOS
for c in ping nslookup ip brctl fcctl; do
cat > "$T/bin/$c" <<EOS
#!/bin/sh
echo "$c ok"
exit 0
EOS
done
chmod +x "$T/bin"/*

./scripts/fcd-incident.sh UTIL-HIGH wl0.1 10 90
S=$(find "$FCD_ROOT/incidents" -name summary.txt | head -n 1)
[ -f "$S" ] || { echo 'FAIL no summary'; exit 1; }
grep -q 'classification: local-airtime-or-retries' "$S" || { cat "$S"; echo 'FAIL classification'; exit 1; }
grep -q 'public_ip_ping: ok' "$S" || { cat "$S"; echo 'FAIL ping'; exit 1; }
grep -q 'dns_probe: ok' "$S" || { cat "$S"; echo 'FAIL dns'; exit 1; }
echo 'PASS incident capture'
