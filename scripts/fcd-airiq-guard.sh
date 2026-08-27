#!/bin/sh
# Enforce the user-facing AirIQ setting without touching Wi-Fi, MLO, channels, or flow cache.
# Explicit airiq_enable=0 stops AirIQ. Explicit airiq_enable=1 starts it if missing,
# but each detected enabled session is capped and forced Off after 10 minutes by default.

set -u
LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] && . "$LIB"

STATE=${FCD_STATE:-/tmp/flowcache-doctor}
INTERVAL=${FCD_AIRIQ_GUARD_INTERVAL:-10}
KILL_GRACE=${FCD_AIRIQ_KILL_GRACE:-2}
START_GRACE=${FCD_AIRIQ_START_GRACE:-4}
MAX_ON_SECONDS=${FCD_AIRIQ_MAX_ON_SECONDS:-600}
PIDFILE="$STATE/airiq-guard.pid"
LOCK="$STATE/airiq-guard.lock"
ON_SINCE="$STATE/airiq-on-since"

log_msg() {
  if command -v fcd_log >/dev/null 2>&1; then
    fcd_log "$1" "$2"
  else
    logger -t flowcache-doctor "$1 $2" 2>/dev/null
  fi
}

num_ok() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }
now_epoch() { date +%s; }
num_ok "$INTERVAL" || INTERVAL=10
num_ok "$KILL_GRACE" || KILL_GRACE=2
num_ok "$START_GRACE" || START_GRACE=4
num_ok "$MAX_ON_SECONDS" || MAX_ON_SECONDS=600
[ "$INTERVAL" -ge 5 ] || INTERVAL=5
[ "$MAX_ON_SECONDS" -ge 60 ] || MAX_ON_SECONDS=60

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

enforce_enabled_timeout() {
  _details=$(process_details)
  [ "$_details" != none ] || { rm -f "$ON_SINCE"; return 0; }

  _now=$(now_epoch)
  num_ok "$_now" || return 0
  _since=$(cat "$ON_SINCE" 2>/dev/null)
  if ! num_ok "$_since" || [ "$_since" -gt "$_now" ]; then
    printf '%s\n' "$_now" > "$ON_SINCE"
    log_msg AIRIQ-TIMER "global=1 started=$_now max=${MAX_ON_SECONDS}s"
    return 0
  fi

  _elapsed=$((_now - _since))
  [ "$_elapsed" -lt "$MAX_ON_SECONDS" ] && return 0

  log_msg AIRIQ-TIMEOUT "global=1 elapsed=${_elapsed}s limit=${MAX_ON_SECONDS}s action=force-off commit=requested processes=$_details"
  nvram set airiq_enable=0
  sync_hidden_off_flags
  if nvram commit >/dev/null 2>&1; then
    log_msg AIRIQ-COMMIT "timeout-off persisted=yes"
  else
    log_msg AIRIQ-COMMIT-FAIL "timeout-off persisted=no; runtime-off still applied"
  fi
  stop_airiq
  rm -f "$ON_SINCE"
}

check_once() {
  mkdir -p "$STATE"
  _global=$(nvram get airiq_enable 2>/dev/null)
  case "$_global" in
    0)
      rm -f "$ON_SINCE"
      sync_hidden_off_flags
      stop_airiq
      ;;
    1)
      ensure_airiq_started
      enforce_enabled_timeout
      ;;
    *)
      rm -f "$ON_SINCE"
      _marker="$STATE/airiq-unknown.warned"
      if [ ! -f "$_marker" ]; then
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
    _elapsed=0
    _since=$(cat "$ON_SINCE" 2>/dev/null)
    _now=$(now_epoch)
    if num_ok "$_since" && num_ok "$_now" && [ "$_now" -ge "$_since" ]; then _elapsed=$((_now - _since)); fi
    echo "AirIQ guard: $([ "$_gcount" -gt 0 ] && echo running || echo stopped)${_gpids:+ (pids $(printf '%s' "$_gpids" | tr '\n' ',' | sed 's/,$//'))}"
    echo "guard instances: $_gcount"
    echo "global airiq_enable: ${_global:-missing}"
    echo "enabled-session cap: ${MAX_ON_SECONDS}s (elapsed ${_elapsed}s)"
    echo "timeout persistence: nvram commit once when the enabled-session cap expires"
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
log_msg START "airiq-guard pid=$$ interval=${INTERVAL}s max-on=${MAX_ON_SECONDS}s"

while :; do
  check_once
  sleep "$INTERVAL"
done
