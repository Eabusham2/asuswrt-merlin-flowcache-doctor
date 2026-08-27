#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/nv"
export PATH="$T/bin:$PATH" NV="$T/nv" FCD_STATE="$T/state" FCD_LIB="$T/missing"
export FCD_AIRIQ_MAX_ON_SECONDS=600 FCD_AIRIQ_KILL_GRACE=0 FCD_AIRIQ_START_GRACE=0

cat > "$T/bin/nvram" <<'EOS'
#!/bin/sh
case "$1:$2" in
  get:airiq_enable) cat "$NV/global" 2>/dev/null;;
  get:0:airiq_enable|get:1:airiq_enable|get:2:airiq_enable) :;;
  get:3:airiq_enable) echo 1;;
  get:airiq_interval_sec) echo 30;;
  set:*) printf '%s\n' "$2" >> "$NV/set.log";;
  commit:) printf '%s\n' commit >> "$NV/commit.log";;
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
cat > "$T/bin/date" <<'EOS'
#!/bin/sh
case "$1" in +%s) cat "$NV/now";; *) /bin/date "$@";; esac
EOS
chmod +x "$T/bin"/*

echo 1 > "$NV/global"
touch "$NV/running"
echo 1000 > "$NV/now"
"$ROOT/scripts/fcd-airiq-guard.sh" once
[ "$(cat "$T/state/airiq-on-since")" = 1000 ]
[ -e "$NV/running" ]
[ ! -e "$NV/commit.log" ]

echo 1599 > "$NV/now"
"$ROOT/scripts/fcd-airiq-guard.sh" once
[ -e "$NV/running" ] || { echo 'FAIL stopped before ten minutes'; exit 1; }
[ ! -e "$NV/commit.log" ]

echo 1600 > "$NV/now"
"$ROOT/scripts/fcd-airiq-guard.sh" once
[ ! -e "$NV/running" ] || { echo 'FAIL AirIQ still running at ten-minute cap'; exit 1; }
grep -qx 'airiq_enable=0' "$NV/set.log"
grep -qx '3:airiq_enable=0' "$NV/set.log"
grep -qx 'airiq_interval_sec=0' "$NV/set.log"
[ ! -e "$T/state/airiq-on-since" ]
[ "$(wc -l < "$NV/commit.log" | tr -d ' ')" -eq 1 ] || { echo 'FAIL timeout did not commit exactly once'; exit 1; }
grep -q 'AIRIQ-TIMEOUT' "$NV/logger.log"
grep -q 'AIRIQ-COMMIT' "$NV/logger.log"

echo 'PASS AirIQ ten-minute session cap'
