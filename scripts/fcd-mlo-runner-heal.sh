#!/bin/sh
# Automatic per-client Runner hardware-flow repair for Broadcom Wi-Fi 7/MLO lifecycle races.
# Watches wlceventd's event log and invalidates only the affected client's HW-offloaded flows.

LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] || exit 1
. "$LIB"

FCD_MLO_HW_HEAL=${FCD_MLO_HW_HEAL:-1}
FCD_MLO_HW_SETTLE=${FCD_MLO_HW_SETTLE:-3}
FCD_MLO_HW_COOLDOWN=${FCD_MLO_HW_COOLDOWN:-60}
EVLOG=${FCD_WIFI_EVENT_LOG:-/jffs/wifi_wlc.log}
STATE="$FCD_STATE/mlo-hw"
PIDFILE="$STATE/pid"
LOCK="$STATE/daemon.lock"

num_ok(){ case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
for _v in FCD_MLO_HW_SETTLE FCD_MLO_HW_COOLDOWN; do
  eval _x=\$$_v
  num_ok "$_x" || eval "$_v=3"
done
[ "$FCD_MLO_HW_SETTLE" -ge 2 ] || FCD_MLO_HW_SETTLE=2
[ "$FCD_MLO_HW_COOLDOWN" -ge 15 ] || FCD_MLO_HW_COOLDOWN=15

mkdir -p "$STATE" "$STATE/client"

current_bss(){ # mac bsslist
  _m=$(fcd_norm_mac "$1")
  shift
  for _b in "$@"; do
    wl -i "$_b" assoclist 2>/dev/null | awk '{print tolower($2)}' | grep -qx "$_m" && { printf '%s\n' "$_b"; return 0; }
  done
  return 1
}

is_mlo_client(){ # mac bss bsslist
  _m=$(fcd_norm_mac "$1"); _b=$2; _bl=$3; _k=$(fcd_key "$_m")
  # A previously positively identified MLO/EHT identity remains eligible even if it is between links now.
  [ -f "$FCD_STATE/class/$_k.protected" ] && return 0
  _c=$(fcd_classify "$_m" "$_b" "$_bl")
  case "$_c" in
    mlo-sticky|mlo-multiradio|mlo-sta-info|mlo-or-eht|mlo-table|mlo-eml-capable) return 0;;
    *) return 1;;
  esac
}

heal_one(){ # mac event_epoch reason
  _m=$(fcd_norm_mac "$1"); _evt=$2; _reason=$3
  fcd_valid_mac "$_m" || return 0
  _k=$(fcd_key "$_m")
  _lk="$STATE/client/$_k.lock"
  mkdir "$_lk" 2>/dev/null || return 0
  trap 'rmdir "$_lk" 2>/dev/null' EXIT INT TERM

  # Debounce: if another lifecycle event arrived during settle, wait from the newest one.
  while :; do
    _latest=$(cat "$STATE/client/$_k.event" 2>/dev/null)
    num_ok "$_latest" || _latest=$_evt
    _now=$(fcd_now)
    _age=$((_now - _latest))
    [ "$_age" -ge "$FCD_MLO_HW_SETTLE" ] && break
    sleep $((FCD_MLO_HW_SETTLE - _age))
  done

  _last=$(cat "$STATE/client/$_k.last" 2>/dev/null)
  num_ok "$_last" || _last=0
  _now=$(fcd_now)
  if [ $((_now - _last)) -lt "$FCD_MLO_HW_COOLDOWN" ]; then
    fcd_log MLO-HW-SKIP "mac=$_m reason=cooldown event=$_reason"
    rmdir "$_lk" 2>/dev/null
    trap - EXIT INT TERM
    return 0
  fi

  _bsslist=$(fcd_resolve_bsslist)
  [ -n "$_bsslist" ] || { rmdir "$_lk" 2>/dev/null; trap - EXIT INT TERM; return 0; }
  _b=$(current_bss "$_m" $_bsslist 2>/dev/null)

  # Only positively identified MLO/EHT identities are allowed through this special path.
  # Unknown/fallback and legacy clients are never hardware-flushed here.
  if ! is_mlo_client "$_m" "$_b" "$_bsslist"; then
    fcd_log MLO-HW-SKIP "mac=$_m reason=not-positive-mlo event=$_reason"
    rmdir "$_lk" 2>/dev/null
    trap - EXIT INT TERM
    return 0
  fi

  if [ "$FCD_MLO_HW_HEAL" != "1" ]; then
    fcd_log MLO-HW-AUDIT "would-flush-hw mac=$_m bss=${_b:-none} event=$_reason"
    rmdir "$_lk" 2>/dev/null
    trap - EXIT INT TERM
    return 0
  fi

  # Narrow repair only: invalidate this client's hardware-accelerated flows.
  # Never globally flush FlowCache and never cycle Runner from this daemon.
  if fcctl flush --hw --mac "$_m" >/dev/null 2>&1; then
    printf '%s\n' "$_now" > "$STATE/client/$_k.last"
    fcd_log MLO-HW-FLUSH "mac=$_m bss=${_b:-none} event=$_reason"
  else
    fcd_log ERROR "mlo-hw-flush-failed mac=$_m event=$_reason"
  fi

  rmdir "$_lk" 2>/dev/null
  trap - EXIT INT TERM
}

queue_heal(){ # mac reason
  _m=$(fcd_norm_mac "$1"); _reason=$2
  fcd_valid_mac "$_m" || return 0
  _k=$(fcd_key "$_m"); _now=$(fcd_now)
  printf '%s\n' "$_now" > "$STATE/client/$_k.event"
  ( sleep "$FCD_MLO_HW_SETTLE"; heal_one "$_m" "$_now" "$_reason" ) &
}

daemon(){
  [ "$FCD_MLO_HW_HEAL" = "1" ] || fcd_log MLO-HW-AUDIT "automatic hardware healing disabled"
  [ -f "$EVLOG" ] || { fcd_log WARN "MLO-HW event-log-missing path=$EVLOG"; exit 1; }
  if ! mkdir "$LOCK" 2>/dev/null; then
    _p=$(cat "$PIDFILE" 2>/dev/null)
    [ -n "$_p" ] && [ -d "/proc/$_p" ] && exit 0
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 1
  fi
  printf '%s\n' $$ > "$PIDFILE"
  FIFO="$STATE/events.fifo"; TAILPID=
  cleanup(){ [ -n "$TAILPID" ] && kill "$TAILPID" 2>/dev/null; rm -f "$FIFO" "$PIDFILE"; rmdir "$LOCK" 2>/dev/null; }
  trap cleanup EXIT INT TERM
  rm -f "$FIFO"
  mkfifo "$FIFO" 2>/dev/null || mknod "$FIFO" p 2>/dev/null || exit 1
  tail -n 0 -F "$EVLOG" > "$FIFO" 2>/dev/null & TAILPID=$!
  fcd_log START "mlo-runner-heal pid=$$ settle=${FCD_MLO_HW_SETTLE}s cooldown=${FCD_MLO_HW_COOLDOWN}s"

  while IFS= read -r _line; do
    _type=
    case "$_line" in
      *": ReAssoc "*Successful*) _type=reassoc;;
      *": Deauth_ind "*) _type=deauth;;
      *": Disassoc "*) _type=disassoc;;
    esac
    [ -n "$_type" ] || continue
    _mac=$(printf '%s\n' "$_line" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1 | tr 'A-F' 'a-f')
    fcd_valid_mac "$_mac" || continue
    queue_heal "$_mac" "$_type"
  done < "$FIFO"
}

start(){
  _p=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$_p" ] && [ -d "/proc/$_p" ] && return 0
  "$0" daemon >/dev/null 2>&1 &
}

stop(){
  _p=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$_p" ] && kill "$_p" 2>/dev/null
  sleep 1
  rm -f "$PIDFILE"
  rmdir "$LOCK" 2>/dev/null
}

status(){
  _p=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$_p" ] && [ -d "/proc/$_p" ]; then
    echo "mlo-runner-heal: running pid=$_p"
    echo "settle: ${FCD_MLO_HW_SETTLE}s"
    echo "cooldown: ${FCD_MLO_HW_COOLDOWN}s"
    echo "mode: $([ "$FCD_MLO_HW_HEAL" = 1 ] && echo automatic || echo audit)"
    return 0
  fi
  echo "mlo-runner-heal: stopped"
  return 1
}

case "${1:-daemon}" in
  daemon) daemon;;
  start) start;;
  stop) stop;;
  restart) stop; start;;
  watchdog) status >/dev/null 2>&1 || start;;
  status) status;;
  *) echo "usage: $0 {start|stop|restart|watchdog|status|daemon}"; exit 2;;
esac
