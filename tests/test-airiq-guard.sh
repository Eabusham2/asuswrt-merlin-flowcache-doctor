#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/nv"
export PATH="$T/bin:$PATH" NV="$T/nv" FCD_STATE="$T/state" FCD_LIB="$T/missing"

cat > "$T/bin/nvram" <<'EOS'
#!/bin/sh
case "$1:$2" in
  get:airiq_enable) cat "$NV/global" 2>/dev/null;;
  get:0:airiq_enable|get:1:airiq_enable|get:2:airiq_enable) :;;
  get:3:airiq_enable) cat "$NV/hidden" 2>/dev/null;;
  get:airiq_interval_sec) cat "$NV/interval" 2>/dev/null;;
  set:*) printf '%s\n' "$2" >> "$NV/set.log";;
esac
EOS
cat > "$T/bin/pidof" <<'EOS'
#!/bin/sh
[ -f "$NV/running" ] && echo 99999
EOS
cat > "$T/bin/killall" <<'EOS'
#!/bin/sh
printf '%s\n' "$1" >> "$NV/kill.log"
rm -f "$NV/running"
EOS
cat > "$T/bin/kill" <<'EOS'
#!/bin/sh
:
EOS
cat > "$T/bin/logger" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$NV/logger.log"
EOS
chmod +x "$T/bin"/*
GUARD="$ROOT/scripts/fcd-airiq-guard.sh"

# Explicitly enabled: do not touch processes or hidden values.
echo 1 > "$NV/global"; echo 1 > "$NV/hidden"; echo 30 > "$NV/interval"; touch "$NV/running"
"$GUARD" once
[ ! -e "$NV/kill.log" ] || { echo 'FAIL enabled AirIQ was killed'; exit 1; }
[ ! -e "$NV/set.log" ] || { echo 'FAIL enabled AirIQ settings changed'; exit 1; }

# Missing global setting: fail open and do not touch the service.
rm -f "$NV/global"
"$GUARD" once
[ -e "$NV/running" ] || { echo 'FAIL unknown AirIQ state was killed'; exit 1; }

# Explicitly disabled: stop services and clear stale indexed/runtime flags without commit.
echo 0 > "$NV/global"
"$GUARD" once
[ ! -e "$NV/running" ] || { echo 'FAIL disabled AirIQ remained running'; exit 1; }
grep -qx '3:airiq_enable=0' "$NV/set.log"
grep -qx 'airiq_interval_sec=0' "$NV/set.log"
for N in airiq_monitor airiq_service airiq_app; do grep -qx "$N" "$NV/kill.log"; done

echo 'PASS AirIQ guard fail-safe behavior'
