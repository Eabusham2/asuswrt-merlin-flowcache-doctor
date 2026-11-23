#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/wl" <<'EOS'
#!/bin/sh
case "${3:-}" in
  txchain|rxchain)
    if [ "$#" -gt 3 ]; then
      printf '%s\n' "$*" >> "$TEST_ROOT/changes"
      exit 0
    fi
    case "$TEST_MODE" in
      healthy) printf '%s (0xf)\n' "$3";;
      repair)
        if [ -f "$TEST_ROOT/changes" ] && grep -q -- "-i $2 $3 0xf" "$TEST_ROOT/changes"; then
          printf '%s (0xf)\n' "$3"
        else
          printf '%s (0x3)\n' "$3"
        fi;;
      unknown) printf '%s unsupported\n' "$3";;
    esac;;
  txpwr_target_max|txpwr_adj_est) echo unavailable;;
esac
EOS
chmod +x "$T/bin/wl"
export PATH="$T/bin:$PATH" TEST_ROOT="$T"
TEST_MODE=healthy sh "$ROOT/scripts/fcd-rf-chain-guard.sh" > "$T/healthy"
[ ! -e "$T/changes" ]
grep -q 'PASS: all four TX/RX chains enabled' "$T/healthy"
TEST_MODE=repair sh "$ROOT/scripts/fcd-rf-chain-guard.sh" > "$T/repair"
[ "$(wc -l < "$T/changes" | tr -d ' ')" -eq 4 ]
grep -q 'REPAIRED: all four chains now enabled' "$T/repair"
rm "$T/changes"
rc=0
TEST_MODE=unknown sh "$ROOT/scripts/fcd-rf-chain-guard.sh" > "$T/unknown" || rc=$?
[ "$rc" -eq 2 ]
[ ! -e "$T/changes" ]
grep -q 'SAFE-STOP: chain mask unreadable; no change' "$T/unknown"
echo 'PASS RF chain-mask parser and guarded repair'
