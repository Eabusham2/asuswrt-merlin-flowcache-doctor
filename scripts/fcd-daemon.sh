#!/bin/sh
LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] || exit 1
. "$LIB"
fcd_mkdirs

LOCK="$FCD_STATE/daemon.lock"
PIDFILE="$FCD_STATE/daemon.pid"
if ! mkdir "$LOCK" 2>/dev/null; then
  _p=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$_p" ] && [ -d "/proc/$_p" ] && exit 0
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || exit 1
fi
printf '%s\n' $$ > "$PIDFILE"
cleanup(){ rm -f "$PIDFILE" "$FCD_STATE/.map.$$" "$FCD_STATE/.mlo.$$"; rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT INT TERM
fcd_log START "daemon pid=$$ interval=${FCD_INTERVAL}s"

process_events() {
  _q="$FCD_EVENT_QUEUE"; _w="$FCD_STATE/events.$$.work"
  [ -s "$_q" ] || return 0
  mv "$_q" "$_w" 2>/dev/null || return 0
  : > "$_q"
  while IFS='|' read -r _ts _type _mac _bss; do
    fcd_num "$_ts" || continue
    fcd_valid_mac "$_mac" || continue
    case "$_type" in assoc|reassoc|deauth|disassoc) fcd_record_pending "$_mac" "$_bss" "event-$_type";; esac
  done < "$_w"
  rm -f "$_w"
}

process_pending() {
  _now=$(fcd_now)
  for _f in "$FCD_STATE"/pending/*; do
    [ -f "$_f" ] || continue
    IFS='|' read -r _mac _bss _exp _reason < "$_f"
    fcd_valid_mac "$_mac" || { rm -f "$_f"; continue; }
    fcd_num "$_exp" || { rm -f "$_f"; continue; }
    [ "$_now" -le "$_exp" ] || { rm -f "$_f"; continue; }
    _cur=$(awk -v m="$(fcd_norm_mac "$_mac")" '$1==m{print $2; exit}' "$FCD_ASSOC_MAP" 2>/dev/null)
    [ -n "$_cur" ] && _bss=$_cur
    fcd_safe_flush "$_mac" "$_bss" "$BSSLIST" "$_reason"
    _rc=$?
    case "$_rc" in
      0) rm -f "$_f"; fcd_schedule_settle "$_mac" "$_bss" "$_reason" "$_now";;
      3|5) rm -f "$_f";;
      *) :;;
    esac
  done
}

process_settle() {
  _now=$(fcd_now)
  for _f in "$FCD_STATE"/settle/*; do
    [ -f "$_f" ] || continue
    IFS='|' read -r _mac _bss _due _reason < "$_f"
    fcd_valid_mac "$_mac" || { rm -f "$_f"; continue; }
    fcd_num "$_due" || { rm -f "$_f"; continue; }
    [ "$_now" -ge "$_due" ] || continue
    fcd_safe_flush "$_mac" "$_bss" "$BSSLIST" "$_reason"
    _rc=$?
    case "$_rc" in
      2|4) _new=$((_now + FCD_INTERVAL)); printf '%s|%s|%s|%s\n' "$_mac" "$_bss" "$_new" "$_reason" > "$_f";;
      *) rm -f "$_f";;
    esac
  done
}

while :; do
  fcd_cleanup_logs
  BSSLIST=$(fcd_resolve_bsslist)
  if [ -z "$BSSLIST" ]; then
    [ -f "$FCD_STATE/no-bss.warned" ] || { fcd_log WARN "no roamable BSS interfaces resolved"; : > "$FCD_STATE/no-bss.warned"; }
    sleep 10
    continue
  fi
  rm -f "$FCD_STATE/no-bss.warned"

  MAP="$FCD_STATE/.map.$$"; MLO="$FCD_STATE/mlo.snapshot"; MLOTS="$FCD_STATE/mlo.snapshot.ts"
  : > "$MAP"
  for _b in $BSSLIST; do
    wl -i "$_b" assoclist 2>/dev/null | awk -v b="$_b" '{if($2!="") print tolower($2),b}' >> "$MAP"
  done
  _now=$(fcd_now); _mts=$(cat "$MLOTS" 2>/dev/null); fcd_num "$_mts" || _mts=0
  if [ ! -f "$MLO" ] || [ $((_now - _mts)) -ge 10 ]; then
    : > "$MLO.tmp"
    for _b in $BSSLIST; do { wl -i "$_b" mlo 2>/dev/null; wl -i "$_b" mlo_status 2>/dev/null; } >> "$MLO.tmp"; done
    mv "$MLO.tmp" "$MLO"; printf '%s\n' "$_now" > "$MLOTS"
  fi
  FCD_ASSOC_MAP="$MAP"; FCD_MLO_SNAPSHOT="$MLO"; export FCD_ASSOC_MAP FCD_MLO_SNAPSHOT
  FDB=$(brctl showmacs br0 2>/dev/null)

  for _mac in $(awk '{print $1}' "$MAP" | sort -u); do
    _count=$(awk -v m="$_mac" '$1==m{n++} END{print n+0}' "$MAP")
    _bss=$(awk -v m="$_mac" '$1==m{print $2; exit}' "$MAP")
    _class=$(fcd_classify "$_mac" "$_bss" "$BSSLIST")
    fcd_observe_class "$_mac" "$_class" "$_bss"
    _k=$(fcd_key "$_mac"); _state="$FCD_STATE/client/$_k.state"
    _prevb=; _prevstatus=OK; _prevport=
    [ -f "$_state" ] && IFS='|' read -r _prevb _prevstatus _prevport < "$_state"

    if [ "$_count" -gt 1 ]; then
      printf '%s|%s|%s\n' "$_bss" MULTI '' > "$_state"
      continue
    fi

    if [ -n "$_prevb" ] && [ "$_prevb" != "$_bss" ] && [ "$_prevstatus" != "MULTI" ]; then
      fcd_log ROAM "mac=$_mac $_prevb->$_bss class=$_class"
      fcd_record_pending "$_mac" "$_bss" "roam-$_prevb-to-$_bss"
    fi

    _bp=$(fcd_port_of "$_bss" 2>/dev/null)
    _fp=$(printf '%s\n' "$FDB" | awk -v m="$_mac" 'tolower($2)==m && $3=="no"{print $1; exit}')
    _status=OK
    if [ -n "$_bp" ] && [ -n "$_fp" ] && [ "$_bp" != "$_fp" ]; then
      if [ "$_prevstatus" = "STALE1" ] && [ "$_prevport" = "$_fp" ]; then
        _status=STALE2
        fcd_log STALE "mac=$_mac assoc=$_bss assoc-port=$_bp fdb-port=$_fp class=$_class"
        fcd_record_pending "$_mac" "$_bss" "stale-fdb-port-$_fp"
      else
        _status=STALE1
      fi
    fi
    printf '%s|%s|%s\n' "$_bss" "$_status" "$_fp" > "$_state.tmp" && mv "$_state.tmp" "$_state"
  done

  process_events
  process_pending
  process_settle
  rm -f "$MAP"
  unset FCD_ASSOC_MAP FCD_MLO_SNAPSHOT
  [ "${FCD_ONCE:-0}" = "1" ] && break
  sleep "$FCD_INTERVAL"
done
