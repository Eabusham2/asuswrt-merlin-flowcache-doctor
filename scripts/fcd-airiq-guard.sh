#!/bin/sh
# Enforce the user-facing AirIQ setting without touching Wi-Fi, MLO, channels, or flow cache.
# Explicit global airiq_enable=0 stops AirIQ. Explicit airiq_enable=1 ensures its monitor is running.

set -u
LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] && . "$LIB"

STATE=${FCD_STATE:-/tmp/flowcache-doctor}
INTERVAL=${FCD_AIRIQ_GUARD_INTERVAL:-10}
KILL_GRACE=${FCD_AIRIQ_KILL_GRACE:-2}
START_GRACE=${FCD_AIRIQ_START_GRACE:-4}
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
num_ok "$START_GRACE" || START_GRACE=4
[ "$INTERVAL" -ge 5 ] || INTERVAL=5

list_airiq_pids() {
  for _name in airiq_monitor airiq_service airiq_app; do
    pidof "$_name" 2>/dev/null
  done | tr ' ' '\n' | awk '/^[0-9]+$/' | sort -u
}

list_guard_pids() {
  ps w 2>/dev/null | awk '
    $1 ~ /^[0-9]+$/ && $0 ~ /\/jffs\/scripts\/fcd-airiq-guard[.]sh daemon/ {print $1}
  ' | sort -n -u
}

pid_alive() { [ -n "${1:-}" ] && [ -d "/proc/$1" ]; }

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

ensure_airiq_started() {
  _started=0
  _marker="$STATE/airiq-start-failed.warned"
  _monitor=$(pidof airiq_monitor 2>/dev/null)
  if [ -z "$_monitor" ]; then
    _bin=$(which airiq_monitor 2>/dev/null)
    if [ -z "$_bin" ] || [ ! -x "$_bin" ]; then
      if [ ! -f "$_marker" ]; then
        : > "$_marker"
        log_msg AIRIQ-START-FAIL "global=1 airiq_monitor-unavailable"
      fi
      return 0
    fi
    log_msg AIRIQ-START "global=1 action=start-monitor binary=$_bin"
    "$_bin" >/dev/null 2>&1 &
    _started=1
    sleep "$START_GRACE"
  fi

  _after=$(process_details)
  if [ "$_after" = none ]; then
    if [ ! -f "$_marker" ]; then
      : > "$_marker"
      log_msg AIRIQ-START-FAIL "global=1 no-airiq-processes-after-start"
    fi
  else
    rm -f "$_marker"
    [ "$_started" = 1 ] && log_msg AIRIQ-ON "global=1 processes=$_after"
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
      ensure_airiq_started
      ;;
    *)
      _marker="$STATE/airiq-unknown.warned"
      if [ ! -f "$_marker" ]; then
        mkdir -p "$STATE"
        : > "$_marker"
        log_msg AIRIQ-WARN "global-setting=${_global:-missing}; guard took no action"
      fi
      ;;
  esac
}

stop_guard_daemons() {
  _pids=$(list_guard_pids)
  for _pid in $_pids; do
    [ "$_pid" = "$$" ] && continue
    kill "$_pid" 2>/dev/null
  done
  sleep 2
  _pids=$(list_guard_pids)
  for _pid in $_pids; do
    [ "$_pid" = "$$" ] && continue
    kill -9 "$_pid" 2>/dev/null
  done
  rm -f "$PIDFILE"
  rm -rf "$LOCK" 2>/dev/null
}

start_guard() {
  mkdir -p "$STATE"
  _pids=$(list_guard_pids)
  _count=$(printf '%s\n' "$_pids" | awk 'NF{n++} END{print n+0}')
  if [ "$_count" -gt 0 ]; then
    _keep=$(printf '%s\n' "$_pids" | awk 'NF{print; exit}')
    printf '%s\n' "$_keep" > "$PIDFILE"
    if [ "$_count" -gt 1 ]; then
      for _pid in $_pids; do
        [ "$_pid" = "$_keep" ] && continue
        kill "$_pid" 2>/dev/null
        sleep 1
        pid_alive "$_pid" && kill -9 "$_pid" 2>/dev/null
      done
      log_msg AIRIQ-GUARD-DEDUP "kept=$_keep removed=$((_count - 1))"
    fi
    return 0
  fi
  rm -rf "$LOCK" 2>/dev/null
  "$0" daemon >/dev/null 2>&1 &
}

case "${1:-daemon}" in
  once)
    check_once
    exit 0
    ;;
  start)
    start_guard
    exit 0
    ;;
  stop)
    stop_guard_daemons
    exit 0
    ;;
  status)
    _global=$(nvram get airiq_enable 2>/dev/null)
    _gpids=$(list_guard_pids)
    _gcount=$(printf '%s\n' "$_gpids" | awk 'NF{n++} END{print n+0}')
    echo "AirIQ guard: $([ "$_gcount" -gt 0 ] && echo running || echo stopped)${_gpids:+ (pids $(printf '%s' "$_gpids" | tr '\n' ',' | sed 's/,$//'))}"
    echo "guard instances: $_gcount"
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
cleanup() { rm -f "$PIDFILE"; rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT
trap 'cleanup; exit 0' INT TERM HUP
log_msg START "airiq-guard pid=$$ interval=${INTERVAL}s"

while :; do
  check_once
  sleep "$INTERVAL"
done
