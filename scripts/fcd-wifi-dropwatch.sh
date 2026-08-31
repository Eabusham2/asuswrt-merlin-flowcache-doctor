#!/bin/sh
# Passive router-side Wi-Fi/connectivity drop recorder for Asuswrt-Merlin.
# Keeps a RAM ring buffer and writes to JFFS only on a confirmed trigger or manual mark.

set -u
LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
. "$LIB"

STATE=${FCD_STATE:-/tmp/flowcache-doctor}
ROOT=${FCD_ROOT:-/jffs/flowcache-doctor}
INTERVAL=${FCD_DROPWATCH_INTERVAL:-2}
UTIL_HIGH=${FCD_DROPWATCH_UTIL_HIGH:-94}
PUBLIC_IP=${FCD_PROBE_IP:-1.1.1.1}
PUBLIC_IP2=${FCD_DROPWATCH_PROBE_IP2:-9.9.9.9}
FAIL_CONFIRM=${FCD_DROPWATCH_FAIL_CONFIRMATIONS:-2}
KERNEL_EVENTS=${FCD_DROPWATCH_KERNEL_EVENTS:-1}
KERNEL_CHECK_SAMPLES=${FCD_DROPWATCH_KERNEL_CHECK_SAMPLES:-5}
RING_LINES=${FCD_DROPWATCH_RING_LINES:-240}
COOLDOWN=${FCD_DROPWATCH_COOLDOWN:-120}
RETENTION_DAYS=${FCD_DROPWATCH_RETENTION_DAYS:-14}
PIDFILE="$STATE/dropwatch.pid"
LOCK="$STATE/dropwatch.lock"
RING="$STATE/dropwatch-ring.tsv"
FAIL_STREAK_FILE="$STATE/dropwatch-connectivity-fail-streak"
KERNEL_COUNT_FILE="$STATE/dropwatch-kernel-count"
KERNEL_LINE_FILE="$STATE/dropwatch-kernel-last-line"

num_ok(){ case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
num_ok "$INTERVAL" || INTERVAL=2
num_ok "$UTIL_HIGH" || UTIL_HIGH=94
num_ok "$FAIL_CONFIRM" || FAIL_CONFIRM=2
num_ok "$KERNEL_CHECK_SAMPLES" || KERNEL_CHECK_SAMPLES=5
num_ok "$RING_LINES" || RING_LINES=240
num_ok "$COOLDOWN" || COOLDOWN=120
num_ok "$RETENTION_DAYS" || RETENTION_DAYS=14
[ "$INTERVAL" -ge 1 ] || INTERVAL=2
[ "$UTIL_HIGH" -ge 1 ] && [ "$UTIL_HIGH" -le 100 ] || UTIL_HIGH=94
[ "$FAIL_CONFIRM" -ge 2 ] || FAIL_CONFIRM=2
[ "$KERNEL_CHECK_SAMPLES" -ge 1 ] || KERNEL_CHECK_SAMPLES=5
[ "$RING_LINES" -ge 60 ] || RING_LINES=240
[ "$COOLDOWN" -ge 1 ] || COOLDOWN=120
[ "$RETENTION_DAYS" -ge 1 ] || RETENTION_DAYS=14
case "$KERNEL_EVENTS" in 0|1) :;; *) KERNEL_EVENTS=1;; esac

list_pids(){
  ps w 2>/dev/null | awk '$1~/^[0-9]+$/ && $0~/\/jffs\/scripts\/fcd-wifi-dropwatch[.]sh daemon/{print $1}' | sort -n -u
}
pid_alive(){ [ -n "${1:-}" ] && [ -d "/proc/$1" ]; }

bsslist(){
  _b=$(fcd_resolve_bsslist 2>/dev/null)
  [ -n "$_b" ] && { printf '%s\n' "$_b"; return; }
  ls /sys/class/net/br0/brif 2>/dev/null | grep -E '^wl[0-9]+([.][0-9]+)?$' | sort | tr '\n' ' '
}

wan_gateway(){
  _g=$(nvram get wan0_gateway 2>/dev/null)
  [ -n "$_g" ] || _g=$(nvram get wan_gateway 2>/dev/null)
  printf '%s\n' "$_g"
}

probe_bit(){
  _ip=$1
  [ -n "$_ip" ] || { echo -1; return; }
  ping -c 1 -W 1 "$_ip" >/dev/null 2>&1 && echo 1 || echo 0
}

sample_line(){
  _now=$(date +%s)
  _wall=$(date '+%Y-%m-%dT%H:%M:%S')
  _gwip=$(wan_gateway)
  _gw=$(probe_bit "$_gwip")
  _wan=$(probe_bit "$PUBLIC_IP")
  _wan2=$(probe_bit "$PUBLIC_IP2")
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
  printf '%s\t%s\twan=%s\tpublic2=%s\tgateway=%s\tgwip=%s\tmaxbusy=%s\tchanim_bad=%s\t%s\n' \
    "$_now" "$_wall" "$_wan" "$_wan2" "$_gw" "${_gwip:-none}" "$_max" "$_bad" "$_parts"
}

trim_ring(){
  _tmp="$RING.tmp.$$"
  tail -n "$RING_LINES" "$RING" 2>/dev/null > "$_tmp" && mv "$_tmp" "$RING"
}

cleanup_old(){
  _today=$(date '+%Y%m%d')
  _marker="$STATE/dropwatch-cleanup.$_today"
  [ -f "$_marker" ] && return 0
  rm -f "$STATE"/dropwatch-cleanup.* 2>/dev/null
  : > "$_marker"
  find "$ROOT/dropwatch" -type d -mtime +"$RETENTION_DAYS" 2>/dev/null |
  while IFS= read -r _d; do
    case "$_d" in
      "$ROOT/dropwatch"|"$ROOT/dropwatch/") ;;
      "$ROOT/dropwatch"/*) rm -rf "$_d";;
    esac
  done
}

cooldown_key(){
  case "$1" in
    util-high-*) echo util;;
    connectivity-*) echo connectivity;;
    kernel-*) echo kernel;;
    manual-*) echo manual;;
    *) echo other;;
  esac
}

snapshot(){
  _reason=$1
  _force=${2:-0}
  _now=$(date +%s)
  _group=$(cooldown_key "$_reason")
  _lastfile="$STATE/dropwatch-last-${_group}"
  _last=$(cat "$_lastfile" 2>/dev/null)
  num_ok "$_last" || _last=0
  if [ "$_force" != 1 ] && [ "$((_now - _last))" -lt "$COOLDOWN" ]; then
    return 0
  fi
  printf '%s\n' "$_now" > "$_lastfile"

  _stamp=$(date '+%Y%m%d-%H%M%S')
  _safe=$(printf '%s' "$_reason" | tr -c 'A-Za-z0-9._-' '_' | cut -c1-48)
  _dir="$ROOT/dropwatch/${_stamp}-${_safe:-event}"
  mkdir -p "$_dir" || return 1
  cp "$RING" "$_dir/ring.tsv" 2>/dev/null
  {
    echo "timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "reason: $_reason"
    echo "public_probe_1: $PUBLIC_IP"
    echo "public_probe_2: $PUBLIC_IP2"
    echo "wan_gateway: $(wan_gateway)"
    echo "bsslist: $(bsslist)"
    echo "airiq_enable: $(nvram get airiq_enable 2>/dev/null)"
    echo "airiq_processes: $(pidof airiq_monitor airiq_service airiq_app 2>/dev/null)"
    echo "automatic_utilization_floor: ${UTIL_HIGH}%"
    echo "connectivity_fail_confirmations: $FAIL_CONFIRM"
    echo "kernel_event_capture: $KERNEL_EVENTS"
    echo "retention_days: $RETENTION_DAYS"
    [ -s "$KERNEL_LINE_FILE" ] && echo "latest_kernel_trigger: $(tail -n 1 "$KERNEL_LINE_FILE")"
  } > "$_dir/meta.txt"

  _gw=$(wan_gateway)
  {
    echo "===== WAN/PUBLIC CONTROLS ====="
    echo "gateway=${_gw:-unknown}"
    [ -n "$_gw" ] && ping -c 3 -W 1 "$_gw" 2>&1
    echo "===== PUBLIC 1 $PUBLIC_IP ====="
    ping -c 3 -W 1 "$PUBLIC_IP" 2>&1
    echo "===== PUBLIC 2 $PUBLIC_IP2 ====="
    ping -c 3 -W 1 "$PUBLIC_IP2" 2>&1
    if which nslookup >/dev/null 2>&1; then
      echo "===== DNS READ-ONLY PROBE ====="
      nslookup example.com 2>&1
    fi
  } > "$_dir/controls.txt"

  {
    for _b in $(bsslist); do
      echo "===== $_b status ====="; wl -i "$_b" status 2>&1
      echo "===== $_b assoclist ====="; wl -i "$_b" assoclist 2>&1
      echo "===== $_b counters ====="; wl -i "$_b" counters 2>&1
      echo "===== $_b chanspec/channel/noise ====="
      wl -i "$_b" chanspec 2>&1; wl -i "$_b" channel 2>&1; wl -i "$_b" phy_noise 2>&1
    done
  } > "$_dir/wl.txt"

  {
    ip addr 2>&1
    ip link 2>&1
    ip -s link 2>&1
    ip neigh 2>&1
    brctl show 2>&1
    brctl showmacs br0 2>&1
    echo "===== /proc/net/dev ====="
    cat /proc/net/dev 2>&1
  } > "$_dir/network.txt"

  {
    echo "===== FLOWCACHE/RUNNER ====="
    if which fcctl >/dev/null 2>&1; then fcctl status 2>&1; else echo "fcctl unavailable"; fi
    echo "===== CONNTRACK ====="
    printf 'count='; cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null
    printf 'max='; cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null
    echo "===== FLOWCACHE PROC ====="
    for _f in /proc/fcache/stats/* /proc/fcache/misc/*; do
      [ -r "$_f" ] || continue
      echo "--- $_f ---"
      cat "$_f" 2>/dev/null
    done
  } > "$_dir/runner.txt"

  ps w > "$_dir/processes.txt" 2>&1
  dmesg | tail -n 500 > "$_dir/dmesg.txt" 2>&1
  if logread >/dev/null 2>&1; then
    logread 2>/dev/null | tail -n 900 > "$_dir/syslog.txt"
  else
    : > "$_dir/syslog.txt"
  fi
  {
    nvram show 2>/dev/null | grep -Ei '^(wl[0-9_:.].*(channel|chanspec|bw|bandwidth|mode|nmode|mlo|ssid|auth|crypto)|smart_connect|airiq|acs|territory|regulation)' | sort
  } > "$_dir/wifi-nvram.txt"

  printf '%s\n' "$_dir" > "$STATE/dropwatch-latest"
  fcd_log DROPWATCH "reason=$_reason dir=$_dir"
  cleanup_old
  echo "Captured: $_dir"
}

check_util_trigger(){
  _line=$1
  _max=$(printf '%s\n' "$_line" | sed -n 's/.*maxbusy=\([-0-9]*\).*/\1/p')
  num_ok "$_max" || return 0
  [ "$_max" -ge "$UTIL_HIGH" ] && snapshot "util-high-${_max}" 0
}

check_connectivity_trigger(){
  _line=$1
  _p1=$(printf '%s\n' "$_line" | sed -n 's/.*wan=\([-0-9]*\).*/\1/p')
  _p2=$(printf '%s\n' "$_line" | sed -n 's/.*public2=\([-0-9]*\).*/\1/p')
  _gw=$(printf '%s\n' "$_line" | sed -n 's/.*gateway=\([-0-9]*\).*/\1/p')

  if [ "$_p1" = 0 ] && [ "$_p2" = 0 ]; then
    _n=$(cat "$FAIL_STREAK_FILE" 2>/dev/null)
    num_ok "$_n" || _n=0
    _n=$((_n + 1))
    printf '%s\n' "$_n" > "$FAIL_STREAK_FILE"
    if [ "$_n" -ge "$FAIL_CONFIRM" ]; then
      case "$_gw" in
        0) _reason="connectivity-wan-gateway-and-public-down";;
        1) _reason="connectivity-beyond-gateway-down";;
        *) _reason="connectivity-public-probes-down";;
      esac
      snapshot "$_reason" 0
    fi
  else
    printf '0\n' > "$FAIL_STREAK_FILE"
  fi
}

kernel_event_lines(){
  dmesg 2>/dev/null | grep -Ei \
    'WLC_SCB_DEAUTHORIZE error|dhd_pktfwd_lut_lkup:.*mismatch|rdp_drv_dhd_cpu_tx_send_message failed|pktfwd.*(error|failed|mismatch)|runner.*(error|failed|timeout|hang)|wfd.*(error|failed|timeout|hang)'
}

prime_kernel_cursor(){
  [ "$KERNEL_EVENTS" = 1 ] || return 0
  _n=$(kernel_event_lines | wc -l | awk '{print $1}')
  num_ok "$_n" || _n=0
  printf '%s\n' "$_n" > "$KERNEL_COUNT_FILE"
  kernel_event_lines | tail -n 1 > "$KERNEL_LINE_FILE" 2>/dev/null
}

check_kernel_trigger(){
  [ "$KERNEL_EVENTS" = 1 ] || return 0
  _old=$(cat "$KERNEL_COUNT_FILE" 2>/dev/null)
  num_ok "$_old" || _old=0
  _new=$(kernel_event_lines | wc -l | awk '{print $1}')
  num_ok "$_new" || _new=0
  if [ "$_new" -gt "$_old" ]; then
    kernel_event_lines | tail -n 1 > "$KERNEL_LINE_FILE" 2>/dev/null
    printf '%s\n' "$_new" > "$KERNEL_COUNT_FILE"
    snapshot "kernel-network-error" 0
  elif [ "$_new" -lt "$_old" ]; then
    # dmesg ring wrapped or was cleared; re-prime without declaring a fault.
    printf '%s\n' "$_new" > "$KERNEL_COUNT_FILE"
    kernel_event_lines | tail -n 1 > "$KERNEL_LINE_FILE" 2>/dev/null
  fi
}

start_daemon(){
  mkdir -p "$STATE" "$ROOT/dropwatch"
  cleanup_old
  _pids=$(list_pids)
  _count=$(printf '%s\n' "$_pids" | awk 'NF{n++}END{print n+0}')
  if [ "$_count" -gt 0 ]; then
    _keep=$(printf '%s\n' "$_pids" | awk 'NF{print;exit}')
    printf '%s\n' "$_keep" > "$PIDFILE"
    for _p in $_pids; do
      [ "$_p" = "$_keep" ] && continue
      kill "$_p" 2>/dev/null
      sleep 1
      pid_alive "$_p" && kill -9 "$_p" 2>/dev/null
    done
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

health(){
  _rc=0
  _pids=$(list_pids)
  _count=$(printf '%s\n' "$_pids" | awk 'NF{n++}END{print n+0}')
  [ "$_count" -eq 1 ] && echo "  ok: exactly one dropwatch daemon" || { echo "  FAIL: dropwatch instances=$_count"; _rc=1; }
  [ -x /jffs/scripts/fcd-wifi-dropwatch.sh ] && echo "  ok: dropwatch executable" || { echo "  FAIL: dropwatch missing"; _rc=1; }
  grep -q 'fcd-wifi-dropwatch.sh start' /jffs/scripts/services-start 2>/dev/null && echo "  ok: boot hook installed" || { echo "  FAIL: boot hook missing"; _rc=1; }
  cru l 2>/dev/null | grep -q fcd-wifi-dropwatch && echo "  ok: cron watchdog armed" || { echo "  FAIL: cron watchdog missing"; _rc=1; }
  [ -d "$ROOT/dropwatch" ] && echo "  ok: capture directory present" || { echo "  FAIL: capture directory missing"; _rc=1; }
  echo "  ok: automatic utilization floor ${UTIL_HIGH}%"
  echo "  ok: dual-public failure trigger ${PUBLIC_IP}+${PUBLIC_IP2} x${FAIL_CONFIRM}"
  echo "  ok: WAN gateway used for failure classification"
  echo "  ok: kernel network-error trigger $([ "$KERNEL_EVENTS" = 1 ] && echo enabled || echo disabled)"
  echo "  ok: retention ${RETENTION_DAYS} days"
  return "$_rc"
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
    echo "automatic capture: busy>=${UTIL_HIGH}% OR both public probes fail ${FAIL_CONFIRM} consecutive samples OR new kernel network error"
    echo "public probes: $PUBLIC_IP $PUBLIC_IP2"
    echo "below thresholds: RAM sampling only; no automatic JFFS capture"
    echo "retention: ${RETENTION_DAYS} days"
    echo "ring: $RING"
    echo "latest: $(cat "$STATE/dropwatch-latest" 2>/dev/null || echo none)"
    exit 0;;
  health) health; exit $?;;
  cleanup) cleanup_old; echo "dropwatch cleanup complete (${RETENTION_DAYS}-day retention)"; exit 0;;
  mark)
    shift
    snapshot "manual-${*:-after-drop}" 1
    exit $?;;
  latest)
    _d=$(cat "$STATE/dropwatch-latest" 2>/dev/null)
    [ -n "$_d" ] && [ -d "$_d" ] || { echo "no capture"; exit 1; }
    cat "$_d/meta.txt" 2>/dev/null
    echo "directory: $_d"
    exit 0;;
  daemon) :;;
  *) echo "usage: $0 start|stop|status|health|cleanup|mark [reason]|latest|daemon"; exit 1;;
esac

mkdir -p "$STATE" "$ROOT/dropwatch"
mkdir "$LOCK" 2>/dev/null || exit 0
printf '%s\n' $$ > "$PIDFILE"
cleanup(){ rm -f "$PIDFILE"; rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM HUP
touch "$RING"
trim_ring
cleanup_old
printf '0\n' > "$FAIL_STREAK_FILE"
prime_kernel_cursor
_kernel_tick=0
while :; do
  LINE=$(sample_line)
  printf '%s\n' "$LINE" >> "$RING"
  trim_ring
  check_util_trigger "$LINE"
  check_connectivity_trigger "$LINE"
  _kernel_tick=$((_kernel_tick + 1))
  if [ "$_kernel_tick" -ge "$KERNEL_CHECK_SAMPLES" ]; then
    _kernel_tick=0
    check_kernel_trigger
  fi
  cleanup_old
  sleep "$INTERVAL"
done
