#!/bin/sh
# Passive GT-BE19000AI MLO/range profiler.
# Captures Wi-Fi link state, per-station MLO metrics, CHANIM, and Runner state.
# Read-only: no steering, deauth, link changes, channel changes, flushes, or restarts.

set -u

DURATION=${1:-120}
INTERVAL=${2:-2}
OUT=${3:-}

num_ok() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
num_ok "$DURATION" || DURATION=120
num_ok "$INTERVAL" || INTERVAL=2
[ "$DURATION" -ge 10 ] || DURATION=10
[ "$DURATION" -le 900 ] || DURATION=900
[ "$INTERVAL" -ge 1 ] || INTERVAL=1
[ "$INTERVAL" -le 10 ] || INTERVAL=10

STAMP=$(date '+%Y%m%d-%H%M%S')
[ -n "$OUT" ] || OUT="/tmp/fcd-range-profile-$STAMP"
mkdir -p "$OUT" || exit 1
TSV="$OUT/samples.tsv"
META="$OUT/meta.txt"
EVENTS="$OUT/events.txt"
MLO="$OUT/mlo.txt"

printf '%s\n' 'epoch	wall	if	mac	mld	idle_s	rssi_dbm	last_tx_kbps	last_rx_kbps	tx_retries	tx_retry_exhausted	rx_retried	link_bw	chanim_busy	chanim_idle	chanim_noise' > "$TSV"

{
  echo "Flowcache Doctor passive range profile"
  echo "started: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "duration_s: $DURATION"
  echo "interval_s: $INTERVAL"
  echo "firmware: $(nvram get buildno 2>/dev/null)_$(nvram get extendno 2>/dev/null)"
  echo "kernel: $(uname -r 2>/dev/null)"
  echo "output: $OUT"
  echo "note: read-only; no Wi-Fi/Runner state is modified"
} > "$META"

bsslist() {
  for _if in wl0.1 wl1.1 wl2.1 wl0 wl1 wl2; do
    wl -i "$_if" status >/dev/null 2>&1 && printf '%s\n' "$_if"
  done | awk '!seen[$0]++'
}

field_first() {
  _text=$1
  _pat=$2
  printf '%s\n' "$_text" | sed -n "s/.*$_pat[[:space:]]*[:=]*[[:space:]]*//p" | head -n 1
}

num_from_line() {
  printf '%s\n' "$1" | sed -n 's/[^-0-9]*\(-*[0-9][0-9]*\).*/\1/p' | head -n 1
}

chanim_line() {
  wl -i "$1" chanim_stats 2>/dev/null | tail -n 1
}

sample_bss() {
  _if=$1
  _now=$2
  _wall=$3
  _cl=$(chanim_line "$_if")
  _busy=$(printf '%s\n' "$_cl" | awk '{print $(NF-1)}')
  _idle=$(printf '%s\n' "$_cl" | awk '{print $(NF-2)}')
  _noise=$(printf '%s\n' "$_cl" | awk '{print $(NF-3)}')
  case "$_busy" in ''|*[!0-9]*) _busy=?;; esac
  case "$_idle" in ''|*[!0-9]*) _idle=?;; esac
  case "$_noise" in ''|*[!0-9-]*) _noise=?;; esac

  wl -i "$_if" assoclist 2>/dev/null | awk '{print $2}' | while IFS= read -r _mac; do
    [ -n "$_mac" ] || continue
    _s=$(wl -i "$_if" sta_info "$_mac" 2>/dev/null)
    [ -n "$_s" ] || continue
    _mld=$(printf '%s\n' "$_s" | sed -n 's/.*MLO: peer mld address[[:space:]]*:[[:space:]]*//p' | head -n1)
    [ -n "$_mld" ] || _mld='-'
    _idlel=$(printf '%s\n' "$_s" | grep -m1 'idle ' 2>/dev/null)
    _idle_s=$(num_from_line "$_idlel"); [ -n "$_idle_s" ] || _idle_s=?
    _rssil=$(printf '%s\n' "$_s" | grep -m1 'smoothed rssi' 2>/dev/null)
    _rssi=$(num_from_line "$_rssil"); [ -n "$_rssi" ] || _rssi=?
    _txl=$(printf '%s\n' "$_s" | grep -m1 'rate of last tx pkt' 2>/dev/null)
    _tx=$(num_from_line "$_txl"); [ -n "$_tx" ] || _tx=?
    _rxl=$(printf '%s\n' "$_s" | grep -m1 'rate of last rx pkt' 2>/dev/null)
    _rx=$(num_from_line "$_rxl"); [ -n "$_rx" ] || _rx=?
    _retryl=$(printf '%s\n' "$_s" | grep -m1 'tx pkts retries' 2>/dev/null)
    _retry=$(num_from_line "$_retryl"); [ -n "$_retry" ] || _retry=?
    _exhl=$(printf '%s\n' "$_s" | grep -m1 'tx pkts retry exhausted' 2>/dev/null)
    _exh=$(num_from_line "$_exhl"); [ -n "$_exh" ] || _exh=?
    _rxrl=$(printf '%s\n' "$_s" | grep -m1 'rx total pkts retried' 2>/dev/null)
    _rxr=$(num_from_line "$_rxrl"); [ -n "$_rxr" ] || _rxr=?
    _bwl=$(printf '%s\n' "$_s" | grep -m1 'link bandwidth' 2>/dev/null)
    _bw=$(num_from_line "$_bwl"); [ -n "$_bw" ] || _bw=?

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_now" "$_wall" "$_if" "$_mac" "$_mld" "$_idle_s" "$_rssi" "$_tx" "$_rx" \
      "$_retry" "$_exh" "$_rxr" "$_bw" "$_busy" "$_idle" "$_noise" >> "$TSV"
  done
}

START=$(date +%s)
END=$((START + DURATION))
while :; do
  NOW=$(date +%s)
  [ "$NOW" -ge "$END" ] && break
  WALL=$(date '+%Y-%m-%dT%H:%M:%S')
  for IF in $(bsslist); do sample_bss "$IF" "$NOW" "$WALL"; done
  sleep "$INTERVAL"
done

{
  echo "=== MLO INFO ==="
  for IF in wl2.1 wl1.1 wl0.1; do
    echo "----- $IF -----"
    wl -i "$IF" mlo info 2>&1
    wl -i "$IF" mlo 2>&1
  done
  echo
  echo "=== RUNNER ==="
  fcctl status 2>&1
  echo
  echo "=== INTERFACES ==="
  cat /proc/net/dev 2>/dev/null
  echo
  echo "=== CHANIM FINAL ==="
  for IF in wl0 wl1 wl2; do
    echo "----- $IF -----"
    wl -i "$IF" chanim_stats 2>&1 | tail -n 3
  done
} > "$MLO"

{
  dmesg 2>/dev/null | grep -Ei 'd3lut|pktfwd|pool.*mismatch|WLC_SCB|deauth|disassoc|reassoc|SBF|runner|wfd|timeout|hang|error|fail' | tail -n 300
} > "$EVENTS"

{
  echo "finished: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "sample_rows: $(awk 'NR>1{n++}END{print n+0}' "$TSV")"
  echo "mlo_rows: $(awk -F '\t' 'NR>1 && $5!="-"{n++}END{print n+0}' "$TSV")"
  echo "worst_rssi_dbm: $(awk -F '\t' 'NR>1 && $7 ~ /^-?[0-9]+$/ {if(!seen || $7<min){min=$7;seen=1}} END{if(seen)print min;else print "?"}' "$TSV")"
  echo "max_retry_exhausted: $(awk -F '\t' 'NR>1 && $11 ~ /^[0-9]+$/ {if($11>m)m=$11} END{print m+0}' "$TSV")"
} >> "$META"

echo "Captured passive range profile: $OUT"
echo "Summary: $META"
echo "Samples: $TSV"
exit 0
