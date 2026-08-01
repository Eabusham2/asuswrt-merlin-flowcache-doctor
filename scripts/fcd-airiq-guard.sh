#!/bin/sh
# Enforce the user-facing AirIQ setting without touching Wi-Fi, MLO, channels, or flow cache.
# Only an explicit global airiq_enable=0 authorizes stopping AirIQ processes.

set -u
LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] && . "$LIB"

STATE=${FCD_STATE:-/tmp/flowcache-doctor}
INTERVAL=${FCD_AIRIQ_GUARD_INTERVAL:-10}
KILL_GRACE=${FCD_AIRIQ_KILL_GRACE:-2}
PIDFILE="$STATE/airiq-guard.pid"
LOCK="$STATE/airiq-guard.lock"

log_msg() {
  if command -v fcd_log >/dev/null 2>&1; then
    fcd_log "$1" "$2"
  else
    logger -t flowcache-doctor "$1 $2" 2>/dev/null
  fi
}

num_ok() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
num_ok "$INTERVAL" || INTERVAL=10
num_ok "$KILL_GRACE" || KILL_GRACE=2
[ "$INTERVAL" -ge 5 ] || INTERVAL=5

list_airiq_pids() {
  for _name in airiq_monitor airiq_service airiq_app; do
    pidof "$_name" 2>/dev/null
  done | tr ' ' '\n' | awk '/^[0-9]+$/' | sort -u
}

process_details() {
  _out=
  for _pid in $(list_airiq_pids); do
    _name=$(awk '/^Name:/{print $2; exit}' "/proc/$_pid/status" 2>/dev/null)
    _ppid=$(awk '/^PPid:/{print $2; exit}' "/proc/$_pid/status" 2>/dev/null)
    if [ -r "/proc/$_pid/cmdline" ]; then
      _cmd=$(tr '\0' ' ' < "/proc/$_pid/cmdline" | tr '|' '/')
    else
      _cmd=?
    fi
    [ -n "$_out" ] && _out="$_out;"
    _out="${_out}${_name:-airiq}:$_pid/ppid=${_ppid:-?}/cmd=${_cmd:-?}"
  done
  printf '%s\n' "${_out:-none}"
}

sync_hidden_off_flags() {
  _changed=
  for _var in '0:airiq_enable' '1:airiq_enable' '2:airiq_enable' '3:airiq_enable'; do
    _val=$(nvram get "$_var" 2>/dev/null)
    [ -n "$_val" ] || continue
    [ "$_val" = 0 ] && continue
    nvram set "$_var=0"
    [ -n "$_changed" ] && _changed="$_changed,"
    _changed="${_changed}${_var}:${_val}->0"
  done
  _ival=$(nvram get airiq_interval_sec 2>/dev/null)
  if [ -n "$_ival" ] && [ "$_ival" != 0 ]; then
    nvram set airiq_interval_sec=0
    [ -n "$_changed" ] && _changed="$_changed,"
    _changed="${_changed}airiq_interval_sec:${_ival}->0"
  fi
  [ -n "$_changed" ] && log_msg AIRIQ-SYNC "global=0 changes=$_changed commit=no"
}

stop_airiq() {
  _before=$(process_details)
  [ "$_before" != none ] || return 0
  log_msg AIRIQ-GUARD "global=0 action=stop before=$_before"

  # Stop supervisors before workers so they cannot immediately respawn them.
  killall airiq_monitor 2>/dev/null
  killall airiq_service 2>/dev/null
  killall airiq_app 2>/dev/null
  sleep "$KILL_GRACE"

  _remaining=$(list_airiq_pids)
  if [ -n "$_remaining" ]; then
    kill -9 $_remaining 2>/dev/null
    sleep 1
  fi

  _after=$(process_details)
  if [ "$_after" = none ]; then
    log_msg AIRIQ-GUARD "global=0 result=stopped"
  else
    log_msg AIRIQ-RESPAWN "global=0 still-running=$_after"
  fi
}

check_once() {
  _global=$(nvram get airiq_enable 2>/dev/null)
  case "$_global" in
    0)
      sync_hidden_off_flags
      stop_airiq
      ;;
    1)
      # AirIQ is explicitly enabled by the user; never interfere.
      ;;
    *)
      # Missing or unfamiliar setting: fail open and leave services untouched.
      _marker="$STATE/airiq-unknown.warned"
      if [ ! -f "$_marker" ]; then
        mkdir -p "$STATE"
        : > "$_marker"
        log_msg AIRIQ-WARN "global-setting=${_global:-missing}; guard took no action"
      fi
      ;;
  esac
}

pid_alive() { [ -n "${1:-}" ] && [ -d "/proc/$1" ]; }

case "${1:-daemon}" in
  once)
    check_once
    exit 0
    ;;
  start)
    mkdir -p "$STATE"
    _pid=$(cat "$PIDFILE" 2>/dev/null)
    if pid_alive "$_pid"; then
      exit 0
    fi
    "$0" daemon >/dev/null 2>&1 &
    exit 0
    ;;
  stop)
    _pid=$(cat "$PIDFILE" 2>/dev/null)
    pid_alive "$_pid" && kill "$_pid" 2>/dev/null
    rm -f "$PIDFILE"
    sleep 1
    rm -rf "$LOCK" 2>/dev/null
    exit 0
    ;;
  status)
    _global=$(nvram get airiq_enable 2>/dev/null)
    _pid=$(cat "$PIDFILE" 2>/dev/null)
    echo "AirIQ guard: $(pid_alive "$_pid" && echo running || echo stopped)${_pid:+ (pid $_pid)}"
    echo "global airiq_enable: ${_global:-missing}"
    echo "indexed flags: $(for _v in '0:airiq_enable' '1:airiq_enable' '2:airiq_enable' '3:airiq_enable'; do _x=$(nvram get "$_v" 2>/dev/null); [ -n "$_x" ] && printf '%s=%s ' "$_v" "$_x"; done)"
    echo "AirIQ processes: $(process_details)"
    exit 0
    ;;
  daemon) :;;
  *) echo "usage: $0 start|stop|status|once|daemon"; exit 1;;
esac

mkdir -p "$STATE"
if ! mkdir "$LOCK" 2>/dev/null; then
  _old=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$_old" ] && [ -d "/proc/$_old" ] && exit 0
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || exit 1
fi
printf '%s\n' $$ > "$PIDFILE"
cleanup(){ rm -f "$PIDFILE"; rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT INT TERM
log_msg START "airiq-guard pid=$$ interval=${INTERVAL}s"

while :; do
  check_once
  sleep "$INTERVAL"
done
