#!/bin/sh
# Passive GT-BE19000AI MLO/range profiler.
# Captures Wi-Fi link state, per-station traffic/radio metrics, CHANIM, MLO, and Runner state.
# Read-only: no steering, deauth, link changes, channel changes, flushes, or restarts.

set -u

DURATION=${1:-75}
INTERVAL=${2:-1}
OUT=${3:-}

num_ok() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
num_ok "$DURATION" || DURATION=75
num_ok "$INTERVAL" || INTERVAL=1
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
RANK="$OUT/traffic-rank.txt"

printf '%s\n' 'epoch\twall\tif\tmac\tmld\tidle_s\trssi_dbm\tlast_tx_kbps\tlast_rx_kbps\ttx_retries\ttx_retry_exhausted\trx_retried\tlink_bw\tchanim_busy\tchanim_idle\tchanim_noise\ttx_total_bytes\trx_data_bytes\ttx_failures' > "$TSV"

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

num_from_line() {
  printf '%s\n' "$1" | sed -n 's/[^-0-9]*\(-*[0-9][0-9]*\).*/\1/p' | head -n 1
}

chanim_line() {
  wl -i "$1" chanim_stats 2>/dev/null | tail -n 1
}

mlo_dump() {
  _label=$1
  {
    echo "=== MLO $_label ==="
    for _if in wl2.1 wl1.1 wl0.1; do
      echo "----- $_if -----"
      wl -i "$_if" mlo info 2>&1
      wl -i "$_if" mlo 2>&1
    done
  }
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

    # sta_info formatting differs across Broadcom branches; traffic ranking below
    # does not depend on MLD parsing.
    _mld=$(printf '%s\n' "$_s" | sed -n -E 's/.*([Pp]eer[[:space:]_-]*mld([[:space:]_-]*address)?|mld[[:space:]_-]*addr(ess)?)[[:space:]]*[:=][[:space:]]*(([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}).*/\5/p' | head -n1)
    [ -n "$_mld" ] || _mld='-'

    _v=$(printf '%s\n' "$_s" | grep -m1 'idle ' 2>/dev/null); _idle_s=$(num_from_line "$_v"); [ -n "$_idle_s" ] || _idle_s=?
    _v=$(printf '%s\n' "$_s" | grep -m1 'smoothed rssi' 2>/dev/null); _rssi=$(num_from_line "$_v"); [ -n "$_rssi" ] || _rssi=?
    _v=$(printf '%s\n' "$_s" | grep -m1 'rate of last tx pkt' 2>/dev/null); _tx=$(num_from_line "$_v"); [ -n "$_tx" ] || _tx=?
    _v=$(printf '%s\n' "$_s" | grep -m1 'rate of last rx pkt' 2>/dev/null); _rx=$(num_from_line "$_v"); [ -n "$_rx" ] || _rx=?
    _v=$(printf '%s\n' "$_s" | grep -m1 'tx pkts retries' 2>/dev/null); _retry=$(num_from_line "$_v"); [ -n "$_retry" ] || _retry=?
    _v=$(printf '%s\n' "$_s" | grep -m1 'tx pkts retry exhausted' 2>/dev/null); _exh=$(num_from_line "$_v"); [ -n "$_exh" ] || _exh=?
    _v=$(printf '%s\n' "$_s" | grep -m1 'rx total pkts retried' 2>/dev/null); _rxr=$(num_from_line "$_v"); [ -n "$_rxr" ] || _rxr=?
    _v=$(printf '%s\n' "$_s" | grep -m1 'link bandwidth' 2>/dev/null); _bw=$(num_from_line "$_v"); [ -n "$_bw" ] || _bw=?
    _v=$(printf '%s\n' "$_s" | grep -m1 'tx total bytes:' 2>/dev/null); _txb=$(num_from_line "$_v"); [ -n "$_txb" ] || _txb=?
    _v=$(printf '%s\n' "$_s" | grep -m1 'rx data bytes:' 2>/dev/null); _rxb=$(num_from_line "$_v"); [ -n "$_rxb" ] || _rxb=?
    _v=$(printf '%s\n' "$_s" | grep -m1 'tx failures:' 2>/dev/null); _txf=$(num_from_line "$_v"); [ -n "$_txf" ] || _txf=?

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_now" "$_wall" "$_if" "$_mac" "$_mld" "$_idle_s" "$_rssi" "$_tx" "$_rx" \
      "$_retry" "$_exh" "$_rxr" "$_bw" "$_busy" "$_idle" "$_noise" "$_txb" "$_rxb" "$_txf" >> "$TSV"
  done
}

mlo_dump START > "$MLO"

START=$(date +%s)
END=$((START + DURATION))
while :; do
  NOW=$(date +%s)
  [ "$NOW" -ge "$END" ] && break
  WALL=$(date '+%Y-%m-%dT%H:%M:%S')
  for IF in $(bsslist); do sample_bss "$IF" "$NOW" "$WALL"; done
  sleep "$INTERVAL"
done

mlo_dump END >> "$MLO"
{
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
} >> "$MLO"

{
  dmesg 2>/dev/null | grep -Ei 'd3lut|pktfwd|pool.*mismatch|WLC_SCB|deauth|disassoc|reassoc|SBF|runner|wfd|timeout|hang|error|fail' | tail -n 300
} > "$EVENTS"

# Rank stations by traffic growth during the capture. This identifies the client
# doing the Speedtest even when MLO link/MLD addresses are randomized or omitted.
awk -F '\t' '
NR>1 && $17 ~ /^[0-9]+$/ && $18 ~ /^[0-9]+$/ {
  k=$3 "/" tolower($4)
  if (!(k in seen)) {
    first_tx[k]=$17; first_rx[k]=$18; first_rssi[k]=$7; seen[k]=1
  }
  last_tx[k]=$17; last_rx[k]=$18; last_rssi[k]=$7
  if ($7 ~ /^-?[0-9]+$/) {
    if (!(k in minr) || $7<minr[k]) minr[k]=$7
    if (!(k in maxr) || $7>maxr[k]) maxr[k]=$7
  }
  if ($11 ~ /^[0-9]+$/ && $11>maxexh[k]) maxexh[k]=$11
  if ($19 ~ /^[0-9]+$/ && $19>maxfail[k]) maxfail[k]=$19
}
END {
  for (k in seen) {
    dtx=last_tx[k]-first_tx[k]; drx=last_rx[k]-first_rx[k]; total=dtx+drx
    printf "%012d total_bytes=%d tx_delta=%d rx_delta=%d RSSI=%s..%s exhausted=%d tx_failures=%d station=%s\n", total,total,dtx,drx,minr[k],maxr[k],maxexh[k]+0,maxfail[k]+0,k
  }
}' "$TSV" | sort -nr > "$RANK"

TOP=$(head -n1 "$RANK" 2>/dev/null)
{
  echo "finished: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "sample_rows: $(awk 'NR>1{n++}END{print n+0}' "$TSV")"
  echo "mlo_rows: $(awk -F '\t' 'NR>1 && $5!="-"{n++}END{print n+0}' "$TSV")"
  echo "worst_rssi_dbm: $(awk -F '\t' 'NR>1 && $7 ~ /^-?[0-9]+$/ {if(!seen || $7<min){min=$7;seen=1}} END{if(seen)print min;else print "?"}' "$TSV")"
  echo "max_retry_exhausted: $(awk -F '\t' 'NR>1 && $11 ~ /^[0-9]+$/ {if($11>m)m=$11} END{print m+0}' "$TSV")"
  echo "top_traffic_station: ${TOP:-none}"
} >> "$META"

echo "Captured passive range profile: $OUT"
echo "Summary: $META"
echo "Traffic rank: $RANK"
echo "Samples: $TSV"
exit 0
