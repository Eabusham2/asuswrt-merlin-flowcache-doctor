#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T" /jffs /tmp/flowcache-doctor' EXIT
rm -rf /jffs /tmp/flowcache-doctor
mkdir -p /jffs/scripts /jffs/configs "$T/bin"
: > /jffs/wifi_wlc.log
cat > "$T/bin/nvram" <<'EOS'
#!/bin/sh
[ "$1" = get ] && [ "$2" = jffs2_scripts ] && echo 1
EOS
cat > "$T/bin/cru" <<EOS
#!/bin/sh
F="$T/cron"
case "\$1" in
 l) cat "\$F" 2>/dev/null;;
 d) [ -f "\$F" ] && grep -v "#\$2#" "\$F" > "\$F.tmp" || true; [ -f "\$F.tmp" ] && mv "\$F.tmp" "\$F";;
 a) echo "\$3 #\$2#" >> "\$F";;
esac
EOS
cat > "$T/bin/curl" <<EOS
#!/bin/sh
for a in "\$@"; do case "\$a" in http*) url=\$a;; esac; done
out=
prev=
for a in "\$@"; do [ "\$prev" = -o ] && out=\$a; prev=\$a; done
base=\${url%%\?*}; name=\${base##*/}
case "\$base" in
 */scripts/*) src="$ROOT/scripts/\$name";;
 */uninstall.sh) src="$ROOT/uninstall.sh";;
 *) exit 22;;
esac
cp "\$src" "\$out"
EOS
cat > "$T/bin/wl" <<'EOS'
#!/bin/sh
cmd=$3
case "$cmd" in
 ssid) echo 'Current SSID: "Home"';;
 assoclist|mlo|mlo_status) :;;
esac
EOS
cat > "$T/bin/ls" <<'EOS'
#!/bin/sh
if [ "$1" = /sys/class/net/br0/brif ]; then printf 'wl0.1\nwl1.1\nwl2.1\n'; else /usr/bin/ls "$@"; fi
EOS
for x in fcctl logger brctl bridge; do cat > "$T/bin/$x" <<'EOS'
#!/bin/sh
:
EOS
chmod +x "$T/bin/$x"; done
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH"
printf '#!/bin/sh\nexit 0\n' > /jffs/scripts/roam-detect.sh
chmod +x /jffs/scripts/roam-detect.sh
printf '#!/bin/sh\ncru a roam-detect-wd "* * * * * /jffs/scripts/old"\n' > /jffs/scripts/services-start
chmod +x /jffs/scripts/services-start
busybox sh "$ROOT/install.sh"
/jffs/scripts/roamctl status | grep -q '1.0.5-d3lut-relearn'
/jffs/scripts/roamctl health | grep -q healthy
/jffs/scripts/fcd-mlo-runner-heal.sh status | grep -q 'running'
[ ! -e /jffs/scripts/roam-detect.sh ]
[ -x /jffs/scripts/fcd-daemon.sh ]
[ -x /jffs/scripts/fcd-mlo-runner-heal.sh ]
[ -f /jffs/scripts/flowcache-doctor.conf ]
grep -q 'FCD_CONFIRMATIONS=5' /jffs/scripts/flowcache-doctor.conf
grep -q 'FCD_MLO_HW_HEAL=1' /jffs/scripts/flowcache-doctor.conf
grep -q 'FCD_MLO_D3LUT_RELEARN=1' /jffs/scripts/flowcache-doctor.conf
grep -q 'FCD_MLO_HW_SETTLE=3' /jffs/scripts/flowcache-doctor.conf
grep -q 'flowcache-doctor-mlo-hw-watchdog' "$T/cron"
grep -q 'fcd-mlo-runner-heal.sh start' /jffs/scripts/services-start
/jffs/scripts/roamctl uninstall
[ ! -e /jffs/scripts/fcd-daemon.sh ]
[ ! -e /jffs/scripts/fcd-mlo-runner-heal.sh ]
echo 'PASS installer lifecycle'
