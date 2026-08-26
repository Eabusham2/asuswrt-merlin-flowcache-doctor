#!/bin/sh
set -eu
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FCD_ROOT="$T/root"
export FCD_WIRED_CONTROL_IP=192.168.50.133
mkdir -p "$T/bin" "$FCD_ROOT"
PATH="$T/bin:$PATH"; export PATH

cat > "$T/bin/nvram" <<'EOS'
#!/bin/sh
case "$1:$2" in
  get:productid) echo GT-BE19000AI;;
  get:firmver) echo 3.0.0.6;;
  get:buildno) echo 102;;
  get:extendno) echo 8_4;;
  get:wan0_gateway) echo 192.0.2.1;;
  *) :;;
esac
EOS

cat > "$T/bin/ping" <<'EOS'
#!/bin/sh
exit 0
EOS

cat > "$T/bin/ip" <<'EOS'
#!/bin/sh
case "$*" in
  *neigh*) echo '192.168.50.19 dev eth1 lladdr 20:7b:d2:ce:fa:ba REACHABLE';;
  *'-s link'*) echo 'IPLINK_COUNTERS';;
  *) echo 'IPDATA';;
esac
EOS

cat > "$T/bin/brctl" <<'EOS'
#!/bin/sh
case "$1" in
  showmacs) echo '  3 20:7b:d2:ce:fa:ba no 0.01';;
  *) echo 'BRIDGEDATA';;
esac
EOS

cat > "$T/bin/ethctl" <<'EOS'
#!/bin/sh
echo 'PHYMAP_DATA'
EOS
cat > "$T/bin/fcctl" <<'EOS'
#!/bin/sh
echo 'FLOWCACHE_DATA'
EOS
cat > "$T/bin/blogctl" <<'EOS'
#!/bin/sh
echo 'BLOG_DATA'
EOS
cat > "$T/bin/dmesg" <<'EOS'
#!/bin/sh
echo 'eth port runner flowcache bridge event'
EOS
chmod +x "$T/bin"/*

OUT=$(sh scripts/fcd-wired-incident.sh 192.168.50.19 20:7b:d2:ce:fa:ba)
[ -d "$OUT" ] || { echo 'FAIL no incident dir'; exit 1; }
S="$OUT/summary.txt"
R="$OUT/raw.txt"
grep -q 'public_ip_ping: ok' "$S" || { cat "$S"; echo 'FAIL public probe'; exit 1; }
grep -q 'affected_mac: 20:7b:d2:ce:fa:ba' "$S" || { cat "$S"; echo 'FAIL affected MAC'; exit 1; }
grep -q 'client firewall may block ICMP' "$S" || { cat "$S"; echo 'FAIL ICMP warning'; exit 1; }
grep -q 'PHYMAP_DATA' "$R" || { cat "$R"; echo 'FAIL phy map'; exit 1; }
grep -q 'FLOWCACHE_DATA' "$R" || { cat "$R"; echo 'FAIL flowcache'; exit 1; }
grep -q 'BLOG_DATA' "$R" || { cat "$R"; echo 'FAIL blog'; exit 1; }
grep -qi '20:7b:d2:ce:fa:ba' "$R" || { cat "$R"; echo 'FAIL MAC lookup'; exit 1; }
echo 'PASS wired incident capture'
