#!/bin/sh
# Automatic per-client Runner hardware-flow repair for Broadcom Wi-Fi 7/MLO lifecycle races.
# Watches association events plus GT-BE19000AI kernel SBF reinit events and invalidates only
# hardware FlowCache entries for the positively-proven MLD family (all affiliated link MACs).

LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] || exit 1
. "$LIB"

FCD_MLO_HW_HEAL=${FCD_MLO_HW_HEAL:-1}
FCD_MLO_HW_SETTLE=${FCD_MLO_HW_SETTLE:-3}
FCD_MLO_HW_COOLDOWN=${FCD_MLO_HW_COOLDOWN:-60}
FCD_MLO_KERNEL_EVENTS=${FCD_MLO_KERNEL_EVENTS:-1}
EVLOG=${FCD_WIFI_EVENT_LOG:-/jffs/wifi_wlc.log}
STATE="$FCD_STATE/mlo-hw"
PIDFILE="$STATE/pid"
LOCK="$STATE/daemon.lock"
FAMILY="$STATE/family"

num_ok(){ case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
num_ok "$FCD_MLO_HW_SETTLE" || FCD_MLO_HW_SETTLE=3
num_ok "$FCD_MLO_HW_COOLDOWN" || FCD_MLO_HW_COOLDOWN=60
[ "$FCD_MLO_HW_SETTLE" -ge 2 ] || FCD_MLO_HW_SETTLE=2
[ "$FCD_MLO_HW_COOLDOWN" -ge 15 ] || FCD_MLO_HW_COOLDOWN=15

mkdir -p "$STATE" "$STATE/client" "$FAMILY"

pid_is_daemon(){
  _p=$1
  [ -n "$_p" ] && [ -r "/proc/$_p/cmdline" ] || return 1
  tr '\000' ' ' < "/proc/$_p/cmdline" 2>/dev/null |
    grep -q 'fcd-mlo-runner-heal.sh daemon'
}

current_bss(){ # mac bsslist
  _m=$(fcd_norm_mac "$1")
  shift
  for _b in "$@"; do
    wl -i "$_b" assoclist 2>/dev/null | awk '{print tolower($2)}' | grep -qx "$_m" && { printf '%s\n' "$_b"; return 0; }
  done
  return 1
}

peer_mld_for_mac(){ # mac bsslist
  _m=$(fcd_norm_mac "$1"); _bl=$2
  for _b in $_bl; do
    wl -i "$_b" assoclist 2>/dev/null | awk '{print tolower($2)}' | grep -qx "$_m" || continue
    _si=$(wl -i "$_b" sta_info "$_m" 2>/dev/null)
    [ -n "$_si" ] || continue
    _mld=$(printf '%s\n' "$_si" |
      grep -Ei 'peer.*mld' |
      grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' |
      head -1 | tr 'A-F' 'a-f')
    fcd_valid_mac "$_mld" && { printf '%s\n' "$_mld"; return 0; }
  done
  return 1
}

family_live_record(){ # event_mac bsslist -> mld|member1 member2 ...
  _m=$(fcd_norm_mac "$1"); _bl=$2
  _mld=$(peer_mld_for_mac "$_m" "$_bl" 2>/dev/null) || return 1
  fcd_valid_mac "$_mld" || return 1
  _tmp="$FAMILY/live.$$.tmp"
  : > "$_tmp"
  printf '%s\n' "$_m" >> "$_tmp"
  for _b in $_bl; do
    wl -i "$_b" assoclist 2>/dev/null | awk '{print tolower($2)}' |
    while IFS= read -r _x; do
      fcd_valid_mac "$_x" || continue
      _xmld=$(peer_mld_for_mac "$_x" "$_bl" 2>/dev/null) || continue
      [ "$_xmld" = "$_mld" ] && printf '%s\n' "$_x"
    done >> "$_tmp"
  done
  _members=$(sort -u "$_tmp" | tr '\n' ' ' | sed 's/ $//')
  rm -f "$_tmp"
  [ -n "$_members" ] || return 1
  printf '%s|%s\n' "$_mld" "$_members"
}

cache_family_record(){ # mld|members
  _rec=$1; _mld=${_rec%%|*}; _members=${_rec#*|}
  fcd_valid_mac "$_mld" || return 1
  [ -n "$_members" ] || return 1
  _mk=$(fcd_key "$_mld")
  printf '%s\n' "$_rec" > "$FAMILY/mld-$_mk"
  for _x in $_members; do
    fcd_valid_mac "$_x" || continue
    printf '%s\n' "$_rec" > "$FAMILY/mac-$(fcd_key "$_x")"
  done
}

cached_family_record(){ # mac
  _m=$(fcd_norm_mac "$1"); _f="$FAMILY/mac-$(fcd_key "$_m")"
  [ -r "$_f" ] || return 1
  _rec=$(cat "$_f" 2>/dev/null)
  _mld=${_rec%%|*}; _members=${_rec#*|}
  fcd_valid_mac "$_mld" || return 1
  [ -n "$_members" ] || return 1
  printf '%s\n' "$_rec"
}

resolve_family_record(){ # event_mac bsslist
  _m=$(fcd_norm_mac "$1"); _bl=$2
  _rec=$(family_live_record "$_m" "$_bl" 2>/dev/null)
  if [ -n "$_rec" ]; then
    cache_family_record "$_rec" >/dev/null 2>&1 || true
    printf '%s\n' "$_rec"
    return 0
  fi
  cached_family_record "$_m"
}

refresh_family_cache(){ # bsslist; best effort, read-only
  _bl=$1
  for _b in $_bl; do
    wl -i "$_b" assoclist 2>/dev/null | awk '{print tolower($2)}' |
    while IFS= read -r _m; do
      fcd_valid_mac "$_m" || continue
      _rec=$(family_live_record "$_m" "$_bl" 2>/dev/null) || continue
      [ -n "$_rec" ] && cache_family_record "$_rec" >/dev/null 2>&1
    done
  done
}

is_mlo_client(){ # mac bss bsslist
  _m=$(fcd_norm_mac "$1"); _b=$2; _bl=$3; _k=$(fcd_key "$_m")
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
  _bsslist=$(fcd_resolve_bsslist)
  [ -n "$_bsslist" ] || return 0

  _rec=$(resolve_family_record "$_m" "$_bsslist" 2>/dev/null)
  _mld=; _members=
  if [ -n "$_rec" ]; then
    _mld=${_rec%%|*}
    _members=${_rec#*|}
  fi

  # Only positively identified MLO/EHT identities are allowed through this special path.
  # A cached family exists only after a live peer_mld proof. Unknown/legacy clients never
  # inherit a family. A positively identified one-link EHT client remains event-MAC-only.
  _b=$(current_bss "$_m" $_bsslist 2>/dev/null)
  if [ -z "$_members" ] && ! is_mlo_client "$_m" "$_b" "$_bsslist"; then
    fcd_log MLO-HW-SKIP "mac=$_m reason=not-positive-mlo event=$_reason"
    return 0
  fi
  [ -n "$_members" ] || _members=$_m

  if [ -n "$_mld" ]; then
    _family_key=$(fcd_key "$_mld")
    _family_label="mld=$_mld"
  else
    _family_key=$(fcd_key "$_m")
    _family_label="mld=none"
  fi

  _lk="$STATE/client/$_family_key.lock"
  mkdir "$_lk" 2>/dev/null || return 0
  trap 'rmdir "$_lk" 2>/dev/null' EXIT INT TERM

  while :; do
    _latest=$(cat "$STATE/client/$(fcd_key "$_m").event" 2>/dev/null)
    num_ok "$_latest" || _latest=$_evt
    _now=$(fcd_now)
    _age=$((_now - _latest))
    [ "$_age" -ge "$FCD_MLO_HW_SETTLE" ] && break
    sleep $((FCD_MLO_HW_SETTLE - _age))
  done

  _last=$(cat "$STATE/client/$_family_key.last" 2>/dev/null)
  num_ok "$_last" || _last=0
  _now=$(fcd_now)
  if [ $((_now - _last)) -lt "$FCD_MLO_HW_COOLDOWN" ]; then
    fcd_log MLO-HW-SKIP "mac=$_m $_family_label reason=cooldown event=$_reason"
    rmdir "$_lk" 2>/dev/null
    trap - EXIT INT TERM
    return 0
  fi

  if [ "$FCD_MLO_HW_HEAL" != "1" ]; then
    fcd_log MLO-HW-AUDIT "would-flush-hw-family mac=$_m $_family_label members=$_members event=$_reason"
    rmdir "$_lk" 2>/dev/null
    trap - EXIT INT TERM
    return 0
  fi

  # Narrow repair only. Invalidate HW FlowCache entries for every positively-proven
  # affiliated link MAC in this one MLD family. Never synthesize bridge-FDB deletion,
  # globally flush FlowCache, cycle Runner, restart Wi-Fi, steer, or deauthenticate.
  _ok=1
  for _x in $_members; do
    fcd_valid_mac "$_x" || continue
    if fcctl flush --hw --mac "$_x" >/dev/null 2>&1; then
      fcd_log MLO-HW-FLUSH "mac=$_x trigger=$_m $_family_label event=$_reason"
    else
      _ok=0
      fcd_log ERROR "mlo-hw-flush-failed mac=$_x trigger=$_m $_family_label event=$_reason"
    fi
  done
  [ "$_ok" -eq 1 ] && printf '%s\n' "$_now" > "$STATE/client/$_family_key.last"

  rmdir "$_lk" 2>/dev/null
  trap - EXIT INT TERM
}

queue_heal(){ # mac reason
  _m=$(fcd_norm_mac "$1"); _reason=$2
  fcd_valid_mac "$_m" || return 0
  _k=$(fcd_key "$_m"); _now=$(fcd_now)
  printf '%s\n' "$_now" > "$STATE/client/$_k.event"
  ( trap '' HUP; sleep "$FCD_MLO_HW_SETTLE"; heal_one "$_m" "$_now" "$_reason" ) &
}

handle_line(){
  _line=$1; _type=; _mac=
  case "$_line" in
    *": ReAssoc "*Successful*) _type=reassoc;;
    *": Deauth_ind "*) _type=deauth;;
    *": Disassoc "*) _type=disassoc;;
    *"SBF: dhd"*": INIT ["*"]"*) _type=sbf-init;;
  esac
  [ -n "$_type" ] || return 0
  _mac=$(printf '%s\n' "$_line" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1 | tr 'A-F' 'a-f')
  fcd_valid_mac "$_mac" || return 0
  queue_heal "$_mac" "$_type"
}

daemon(){
  trap '' HUP
  [ "$FCD_MLO_HW_HEAL" = "1" ] || fcd_log MLO-HW-AUDIT "automatic hardware healing disabled"
  if [ ! -f "$EVLOG" ] && { [ "$FCD_MLO_KERNEL_EVENTS" != "1" ] || ! command -v logread >/dev/null 2>&1; }; then
    fcd_log WARN "MLO-HW no event source available"
    exit 1
  fi
  if ! mkdir "$LOCK" 2>/dev/null; then
    _p=$(cat "$PIDFILE" 2>/dev/null)
    pid_is_daemon "$_p" && exit 0
    rm -rf "$LOCK" 2>/dev/null
    mkdir "$LOCK" 2>/dev/null || exit 1
  fi
  printf '%s\n' $$ > "$PIDFILE"
  FIFO="$STATE/events.fifo"; TAILPID=; LOGPID=
  cleanup(){
    [ -n "$TAILPID" ] && kill "$TAILPID" 2>/dev/null
    [ -n "$LOGPID" ] && kill "$LOGPID" 2>/dev/null
    rm -f "$FIFO" "$PIDFILE"
    rmdir "$LOCK" 2>/dev/null
  }
  trap cleanup EXIT INT TERM
  trap '' HUP
  rm -f "$FIFO"
  mkfifo "$FIFO" 2>/dev/null || mknod "$FIFO" p 2>/dev/null || exit 1
  [ -f "$EVLOG" ] && { tail -n 0 -F "$EVLOG" > "$FIFO" 2>/dev/null & TAILPID=$!; }
  if [ "$FCD_MLO_KERNEL_EVENTS" = "1" ] && command -v logread >/dev/null 2>&1; then
    logread -f > "$FIFO" 2>/dev/null & LOGPID=$!
  fi

  # Seed MLD-family cache while all currently-associated link identities are available.
  _seed_bss=$(fcd_resolve_bsslist)
  [ -n "$_seed_bss" ] && refresh_family_cache "$_seed_bss" >/dev/null 2>&1

  fcd_log START "mlo-runner-heal pid=$$ settle=${FCD_MLO_HW_SETTLE}s cooldown=${FCD_MLO_HW_COOLDOWN}s kernel=${FCD_MLO_KERNEL_EVENTS} repair=mld-family-hw-only"

  while IFS= read -r _line; do
    handle_line "$_line"
  done < "$FIFO"
}

start(){
  _p=$(cat "$PIDFILE" 2>/dev/null)
  pid_is_daemon "$_p" && return 0
  ( trap '' HUP; exec "$0" daemon </dev/null >/dev/null 2>&1 ) &
}

stop(){
  _p=$(cat "$PIDFILE" 2>/dev/null)
  pid_is_daemon "$_p" && kill "$_p" 2>/dev/null
  sleep 1
  rm -f "$PIDFILE" "$STATE/events.fifo"
  rmdir "$LOCK" 2>/dev/null || true
  return 0
}

status(){
  _p=$(cat "$PIDFILE" 2>/dev/null)
  if pid_is_daemon "$_p"; then
    echo "mlo-runner-heal: running pid=$_p"
    echo "settle: ${FCD_MLO_HW_SETTLE}s"
    echo "cooldown: ${FCD_MLO_HW_COOLDOWN}s"
    echo "kernel-events: ${FCD_MLO_KERNEL_EVENTS}"
    echo "mode: $([ "$FCD_MLO_HW_HEAL" = 1 ] && echo automatic || echo audit)"
    echo "repair: mld-family-hw-flush-only"
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
