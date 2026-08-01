#!/bin/sh
# Passive router-side Wi-Fi drop recorder for Asuswrt-Merlin.
# Keeps a RAM ring buffer and writes to JFFS only on an anomaly or manual mark.

set -u
LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
. "$LIB"

STATE=${FCD_STATE:-/tmp/flowcache-doctor}
ROOT=${FCD_ROOT:-/jffs/flowcache-doctor}
INTERVAL=${FCD_DROPWATCH_INTERVAL:-2}
UTIL_HIGH=${FCD_DROPWATCH_UTIL_HIGH:-80}
UTIL_DELTA=${FCD_DROPWATCH_UTIL_DELTA:-30}
PUBLIC_IP=${FCD_PROBE_IP:-1.1.1.1}
RING_LINES=${FCD_DROPWATCH_RING_LINES:-240}
COOLDOWN=${FCD_DROPWATCH_COOLDOWN:-120}
PIDFILE="$STATE/dropwatch.pid"
LOCK="$STATE/dropwatch.lock"
RING="$STATE/dropwatch-ring.tsv"
LAST="$STATE/dropwatch-last"
LAST_EVENT="$STATE/dropwatch-last-event"

num_ok(){ case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
for V in INTERVAL UTIL_HIGH UTIL_DELTA RING_LINES COOLDOWN; do
  eval X=\$$V
  num_ok "$X" || eval "$V=2"
done
[ "$INTERVAL" -ge 1 ] || INTERVAL=2
[ "$RING_LINES" -ge 60 ] || RING_LINES=240

list_pids(){
  ps w 2>/dev/null | awk '$1~/^[0-9]+$/ && $0~/\/jffs\/scripts\/fcd-wifi-dropwatch[.]sh daemon/{print $1}' | sort -n -u
}
pid_alive(){ [ -n "${1:-}" ] && [ -d "/proc/$1" ]; }

bsslist(){
  _b=$(fcd_resolve_bsslist 2>/dev/null)
  [ -n "$_b" ] && { printf '%s\n' "$_b"; return; }
  ls /sys/class/net/br0/brif 2>/dev/null | grep -E '^wl[0-9]+([.][0-9]+)?$' | sort | tr '\n' ' '
}

sample_line(){
  _now=$(date +%s)
  _wall=$(date '+%Y-%m-%dT%H:%M:%S')
  ping -c 1 -W 1 "$PUBLIC_IP" >/dev/null 2>&1 && _wan=1 || _wan=0
  _parts=
  _max=-1
  _bad=0
  for _b in $(bsslist); do
    _f=$(fcd_chanim_fields "$_b" 2>/dev/null)
    _busy=$(fcd_kv "$_f" busy)
    case "$_busy" in ''|*[!0-9]*) _busy=-1; _bad=1;; esac
    [ "$_busy" -gt "$_max" ] 2>/dev/null && _max=$_busy
    _tx=$(fcd_kv "$_f" tx); _in=$(fcd_kv "$_f" inbss); _ob=$(fcd_kv "$_f" obss)
    _nc=$(fcd_kv "$_f" nocat); _np=$(fcd_kv "$_f" nopkt)
    [ -n "$_parts" ] && _parts="$_parts;"
    _parts="${_parts}${_b},busy=${_busy},tx=${_tx:-?},inbss=${_in:-?},obss=${_ob:-?},nocat=${_nc:-?},nopkt=${_np:-?}"
  done
  printf '%s\t%s\twan=%s\tmaxbusy=%s\tchanim_bad=%s\t%s\n' "$_now" "$_wall" "$_wan" "$_max" "$_bad" "$_parts"
}

trim_ring(){
  _tmp="$RING.tmp.$$"
  tail -n "$RING_LINES" "$RING" 2>/dev/null > "$_tmp" && mv "$_tmp" "$RING"
}

snapshot(){
  _reason=$1
  _now=$(date +%s)
  _last=$(cat "$LAST_EVENT" 2>/dev/null)
  num_ok "$_last" || _last=0
  [ "$((_now - _last))" -ge "$COOLDOWN" ] || return 0
  printf '%s\n' "$_now" > "$LAST_EVENT"

  _stamp=$(date '+%Y%m%d-%H%M%S')
  _safe=$(printf '%s' "$_reason" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-48)
  _dir="$ROOT/dropwatch/${_stamp}-${_safe:-event}"
  mkdir -p "$_dir" || return 1
  cp "$RING" "$_dir/ring.tsv" 2>/dev/null
  {
    echo "timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "reason: $_reason"
    echo "public_probe: $PUBLIC_IP"
    echo "bsslist: $(bsslist)"
    echo "airiq_enable: $(nvram get airiq_enable 2>/dev/null)"
    echo "airiq_processes: $(pidof airiq_monitor airiq_service airiq_app 2>/dev/null)"
  } > "$_dir/meta.txt"

  {
    for _b in $(bsslist); do
      echo "===== $_b status ====="; wl -i "$_b" status 2>&1
      echo "===== $_b assoclist ====="; wl -i "$_b" assoclist 2>&1
      echo "===== $_b counters ====="; wl -i "$_b" counters 2>&1
      echo "===== $_b chanspec/channel/noise ====="
      wl -i "$_b" chanspec 2>&1; wl -i "$_b" channel 2>&1; wl -i "$_b" phy_noise 2>&1
    done
  } > "$_dir/wl.txt"
  { ip addr 2>&1; ip link 2>&1; ip neigh 2>&1; brctl show 2>&1; brctl showmacs br0 2>&1; } > "$_dir/network.txt"
  ps w > "$_dir/processes.txt" 2>&1
  dmesg | tail -n 400 > "$_dir/dmesg.txt" 2>&1
  logread | tail -n 800 > "$_dir/syslog.txt" 2>&1
  {
    nvram show 2>/dev/null | grep -Ei '^(wl[0-9_:.].*(channel|chanspec|bw|bandwidth|mode|nmode|mlo|ssid|auth|crypto)|smart_connect|airiq|acs|territory|regulation)' | sort
  } > "$_dir/wifi-nvram.txt"

  printf '%s\n' "$_dir" > "$STATE/dropwatch-latest"
  command -v fcd_log >/dev/null 2>&1 && fcd_log DROPWATCH "reason=$_reason dir=$_dir"
  echo "Captured: $_dir"
}

check_trigger(){
  _line=$1
  _max=$(printf '%s\n' "$_line" | sed -n 's/.*maxbusy=\([-0-9]*\).*/\1/p')
  _bad=$(printf '%s\n' "$_line" | sed -n 's/.*chanim_bad=\([01]\).*/\1/p')
  num_ok "$_max" || _max=0
  _prev=$(cat "$LAST" 2>/dev/null)
  num_ok "$_prev" || _prev=$_max
  printf '%s\n' "$_max" > "$LAST"
  _delta=$((_max - _prev)); [ "$_delta" -lt 0 ] && _delta=$((-_delta))
  if [ "$_max" -ge "$UTIL_HIGH" ]; then snapshot "util-high-${_max}"; return; fi
  if [ "$_delta" -ge "$UTIL_DELTA" ]; then snapshot "util-delta-${_prev}-to-${_max}"; return; fi
  [ "$_bad" = 1 ] && snapshot "chanim-read-failure"
}

start_daemon(){
  mkdir -p "$STATE" "$ROOT/dropwatch"
  _pids=$(list_pids)
  _count=$(printf '%s\n' "$_pids" | awk 'NF{n++}END{print n+0}')
  if [ "$_count" -gt 0 ]; then
    _keep=$(printf '%s\n' "$_pids" | awk 'NF{print;exit}')
    printf '%s\n' "$_keep" > "$PIDFILE"
    for _p in $_pids; do [ "$_p" = "$_keep" ] || kill "$_p" 2>/dev/null; done
    return 0
  fi
  rm -rf "$LOCK" 2>/dev/null
  "$0" daemon >/dev/null 2>&1 &
}

stop_daemon(){
  for _p in $(list_pids); do kill "$_p" 2>/dev/null; done
  sleep 2
  for _p in $(list_pids); do kill -9 "$_p" 2>/dev/null; done
  rm -f "$PIDFILE"; rm -rf "$LOCK" 2>/dev/null
}

case "${1:-daemon}" in
  start) start_daemon; exit 0;;
  stop) stop_daemon; exit 0;;
  status)
    _pids=$(list_pids); _count=$(printf '%s\n' "$_pids" | awk 'NF{n++}END{print n+0}')
    echo "dropwatch: $([ "$_count" -gt 0 ] && echo running || echo stopped)"
    echo "instances: $_count"
    echo "pids: ${_pids:-none}"
    echo "interval: ${INTERVAL}s"
    echo "automatic triggers: busy>=${UTIL_HIGH}% or delta>=${UTIL_DELTA} points or CHANIM read failure"
    echo "ring: $RING"
    echo "latest: $(cat "$STATE/dropwatch-latest" 2>/dev/null || echo none)"
    exit 0;;
  mark)
    shift
    snapshot "manual-${*:-after-drop}"
    exit $?;;
  latest)
    _d=$(cat "$STATE/dropwatch-latest" 2>/dev/null)
    [ -n "$_d" ] && [ -d "$_d" ] || { echo "no capture"; exit 1; }
    cat "$_d/meta.txt" 2>/dev/null
    echo "directory: $_d"
    exit 0;;
  daemon) :;;
  *) echo "usage: $0 start|stop|status|mark [reason]|latest|daemon"; exit 1;;
esac

mkdir -p "$STATE" "$ROOT/dropwatch"
mkdir "$LOCK" 2>/dev/null || exit 0
printf '%s\n' $$ > "$PIDFILE"
cleanup(){ rm -f "$PIDFILE"; rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM HUP
: > "$RING"
while :; do
  LINE=$(sample_line)
  printf '%s\n' "$LINE" >> "$RING"
  trim_ring
  check_trigger "$LINE"
  sleep "$INTERVAL"
done
