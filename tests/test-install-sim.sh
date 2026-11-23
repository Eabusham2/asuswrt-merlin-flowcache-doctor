#!/bin/sh
# Exercise the real installer in a relocated fixture tree, never host /jffs.
set -eu
SOURCE=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
ROOT="$T/source"
JFFS="$T/jffs"
cleanup() {
  [ ! -x "$JFFS/scripts/fcd-mlo-runner-heal.sh" ] || "$JFFS/scripts/fcd-mlo-runner-heal.sh" stop >/dev/null 2>&1 || true
  [ ! -x "$JFFS/scripts/roamctl" ] || "$JFFS/scripts/roamctl" stop >/dev/null 2>&1 || true
  rm -rf "$T"
}
trap cleanup EXIT
mkdir -p "$ROOT" "$JFFS/scripts" "$JFFS/configs" "$T/bin"
# Only fixed filesystem roots are relocated. Commands and installer logic are
# unchanged; curl supplies the exact staged files instead of using the network.
python3 - "$SOURCE" "$ROOT" "$JFFS" "$T/state" <<'PY'
from pathlib import Path
import sys
source, target, jffs, state = map(Path, sys.argv[1:])
for path in [source/'install.sh', source/'uninstall.sh', *(source/'scripts').iterdir()]:
    dest = target/path.relative_to(source)
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(path.read_text().replace('/jffs', str(jffs)).replace('/tmp/flowcache-doctor', str(state)))
    dest.chmod(0o755)
PY
: > "$JFFS/wifi_wlc.log"
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
printf '%s\n' "\$url" >> "$T/downloads"
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
cat > "$T/bin/sleep" <<'EOS'
#!/bin/sh
# The boot-only tuning delay is unnecessary in an isolated command fixture.
[ "${1:-}" != 20 ] || exit 0
exec /bin/sleep "$@"
EOS
for x in fcctl logger brctl bridge dhd; do
  printf '#!/bin/sh\n:\n' > "$T/bin/$x"
done
chmod +x "$T/bin"/*
export PATH="$T/bin:$PATH" FCD_REF=v1.0.9
printf '#!/bin/sh\nexit 0\n' > "$JFFS/scripts/roam-detect.sh"
chmod +x "$JFFS/scripts/roam-detect.sh"
printf '#!/bin/sh\necho unrelated-addon\ncru a roam-detect-wd "* * * * * old"\n' > "$JFFS/scripts/services-start"
chmod +x "$JFFS/scripts/services-start"
printf 'alias unrelated=true\n' > "$JFFS/configs/profile.add"
printf 'keep me\n' > "$JFFS/scripts/unrelated.conf"

busybox sh "$ROOT/install.sh"
VERSION=$(sed -n 's/^VERSION=//p' "$SOURCE/install.sh")
"$JFFS/scripts/roamctl" status > "$T/status"
grep -Fq "version: $VERSION" "$T/status"
"$JFFS/scripts/roamctl" health > "$T/health"
grep -q healthy "$T/health"
"$JFFS/scripts/fcd-mlo-runner-heal.sh" status > "$T/healer-status"
grep -q running "$T/healer-status"
[ ! -e "$JFFS/scripts/roam-detect.sh" ]
[ -x "$JFFS/scripts/fcd-daemon.sh" ]
[ -x "$JFFS/scripts/fcd-mlo-runner-heal.sh" ]
[ -f "$JFFS/scripts/flowcache-doctor.conf" ]
grep -q 'FCD_CONFIRMATIONS=5' "$JFFS/scripts/flowcache-doctor.conf"
grep -q 'FCD_MLO_HW_HEAL=1' "$JFFS/scripts/flowcache-doctor.conf"
! grep -q 'FCD_MLO_D3LUT_RELEARN' "$JFFS/scripts/flowcache-doctor.conf"
grep -q 'FCD_MLO_HW_SETTLE=3' "$JFFS/scripts/flowcache-doctor.conf"
grep -q 'FCD_LOG_RETENTION_DAYS=7' "$JFFS/scripts/flowcache-doctor.conf"
grep -q 'FCD_INCIDENT_CAPTURE=0' "$JFFS/scripts/flowcache-doctor.conf"
grep -q 'flowcache-doctor-mlo-hw-watchdog' "$T/cron"
grep -q 'fcd-mlo-runner-heal.sh start' "$JFFS/scripts/services-start"
! grep -v '/v1.0.9/' "$T/downloads"

# Repeat installation: managed hooks stay unique and unrelated hooks survive.
busybox sh "$ROOT/install.sh"
[ "$(grep -c 'fcd-mlo-runner-heal.sh start' "$JFFS/scripts/services-start")" -eq 1 ]
[ "$(grep -c '/roamctl boot' "$JFFS/scripts/services-start")" -eq 1 ]
grep -qx 'echo unrelated-addon' "$JFFS/scripts/services-start"
grep -qx 'alias unrelated=true' "$JFFS/configs/profile.add"
grep -qx 'keep me' "$JFFS/scripts/unrelated.conf"

"$JFFS/scripts/roamctl" uninstall
[ ! -e "$JFFS/scripts/fcd-daemon.sh" ]
[ ! -e "$JFFS/scripts/fcd-mlo-runner-heal.sh" ]
grep -qx 'echo unrelated-addon' "$JFFS/scripts/services-start"
grep -qx 'alias unrelated=true' "$JFFS/configs/profile.add"
grep -qx 'keep me' "$JFFS/scripts/unrelated.conf"
[ -n "$(find "$JFFS/flowcache-doctor" -maxdepth 1 -type d -name 'backup-*' -print)" ]
echo 'PASS isolated installer lifecycle, pinned downloads, repeat install, and hook preservation'
