#!/bin/sh
# Shared safety, classification, logging, and flow-cache helpers.

FCD_CONF=${FCD_CONF:-/jffs/scripts/flowcache-doctor.conf}
[ -f "$FCD_CONF" ] && . "$FCD_CONF"

FCD_ROOT=${FCD_ROOT:-/jffs/flowcache-doctor}
FCD_STATE=${FCD_STATE:-/tmp/flowcache-doctor}
FCD_LOG_DIR=${FCD_LOG_DIR:-$FCD_ROOT/log}
FCD_EVENT_QUEUE=${FCD_EVENT_QUEUE:-$FCD_STATE/events.queue}
FCD_INTERVAL=${FCD_INTERVAL:-2}
FCD_CONFIRMATIONS=${FCD_CONFIRMATIONS:-5}
FCD_CONFIRM_MAX_AGE=${FCD_CONFIRM_MAX_AGE:-8}
FCD_COOLDOWN=${FCD_COOLDOWN:-60}
FCD_MIN_GAP=${FCD_MIN_GAP:-8}
FCD_PENDING_TTL=${FCD_PENDING_TTL:-60}
FCD_SETTLE_FLUSHES=${FCD_SETTLE_FLUSHES:-"20 60 300"}
FCD_AUTOFIX=${FCD_AUTOFIX:-1}
FCD_EVENT_HEAL=${FCD_EVENT_HEAL:-1}
FCD_LOG_RETENTION_DAYS=${FCD_LOG_RETENTION_DAYS:-30}
FCD_STEER_MODE=${FCD_STEER_MODE:-advisor}
FCD_LOG_SYSLOG=${FCD_LOG_SYSLOG:-1}
FCD_BSSLIST=${FCD_BSSLIST:-auto}

fcd_now() { date +%s; }
fcd_norm_mac() { printf '%s\n' "$1" | tr 'A-F' 'a-f'; }
fcd_valid_mac() { printf '%s\n' "$1" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'; }
fcd_key() { printf '%s\n' "$1" | tr -d ':' | tr 'A-F' 'a-f'; }
fcd_num() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

fcd_mkdirs() {
  mkdir -p "$FCD_STATE" "$FCD_STATE/class" "$FCD_STATE/client" "$FCD_STATE/pending" \
    "$FCD_STATE/settle" "$FCD_STATE/locks" "$FCD_LOG_DIR"
}

fcd_log() { # level message...
  local _lvl _msg _line
  _lvl=$1; shift
  _msg=$*
  fcd_mkdirs
  _line="$(date '+%Y-%m-%d %H:%M:%S') $_lvl $_msg"
  printf '%s\n' "$_line" >> "$FCD_LOG_DIR/events-$(date '+%Y%m%d').log"
  [ "$FCD_LOG_SYSLOG" = "1" ] && logger -t flowcache-doctor "$_lvl $_msg"
  return 0
}

fcd_cleanup_logs() {
  local _today _marker _f
  fcd_mkdirs
  _today=$(date '+%Y%m%d')
  _marker="$FCD_STATE/cleanup.$_today"
  [ -f "$_marker" ] && return 0
  rm -f "$FCD_STATE"/cleanup.* 2>/dev/null
  : > "$_marker"
  find "$FCD_LOG_DIR" -type f -name 'events-*.log' -mtime +"$FCD_LOG_RETENTION_DAYS" 2>/dev/null |
  while IFS= read -r _f; do
    case "$_f" in "$FCD_LOG_DIR"/events-*.log) rm -f "$_f";; esac
  done
}

fcd_resolve_bsslist() {
  local _tmp _b _s
  if [ "$FCD_BSSLIST" != "auto" ]; then printf '%s\n' "$FCD_BSSLIST"; return; fi
  _tmp="$FCD_STATE/bss.$$.tmp"
  fcd_mkdirs
  : > "$_tmp"
  for _b in $(ls /sys/class/net/br0/brif 2>/dev/null | grep -v '^wds'); do
    _s=$(wl -i "$_b" ssid 2>/dev/null | sed 's/^Current SSID: //;s/^"//;s/"$//')
    [ -n "$_s" ] && printf '%s|%s\n' "$_s" "$_b" >> "$_tmp"
  done
  awk -F'|' '{n[$1]++; v[$1]=v[$1] " " $2} END{for(s in n) if(n[s]>=2 && s !~ /^[0-9A-Fa-f]{32}$/) print v[s]}' "$_tmp" |
    tr ' ' '\n' | grep . | sort -u | tr '\n' ' ' | sed 's/ $//'
  rm -f "$_tmp"
}

fcd_port_of() {
  [ -r "/sys/class/net/br0/brif/$1/port_no" ] || return 1
  printf '%d\n' "$(cat "/sys/class/net/br0/brif/$1/port_no" 2>/dev/null)" 2>/dev/null
}

fcd_assoc_count() { # mac bsslist
  local _m _n _b
  _m=$(fcd_norm_mac "$1")
  _n=0
  if [ -n "${FCD_ASSOC_MAP:-}" ] && [ -f "$FCD_ASSOC_MAP" ]; then
    awk -v m="$_m" 'tolower($1)==m{n++} END{print n+0}' "$FCD_ASSOC_MAP"
    return
  fi
  for _b in $2; do
    wl -i "$_b" assoclist 2>/dev/null | awk '{print tolower($2)}' | grep -qx "$_m" && _n=$((_n + 1))
  done
  printf '%s\n' "$_n"
}

fcd_sta_info() { # mac current_bss
  local _m _b
  _m=$1; _b=$2
  [ -n "$_b" ] && wl -i "$_b" sta_info "$_m" 2>/dev/null
}

fcd_mlo_snapshot() { # bsslist
  local _b
  if [ -n "${FCD_MLO_SNAPSHOT:-}" ] && [ -f "$FCD_MLO_SNAPSHOT" ]; then
    cat "$FCD_MLO_SNAPSHOT"
    return
  fi
  for _b in $1; do
    wl -i "$_b" mlo 2>/dev/null
    wl -i "$_b" mlo_status 2>/dev/null
  done
}

fcd_classify() { # mac current_bss bsslist
  local _m _bss _bsslist _ac _si _ms _k
  _m=$(fcd_norm_mac "$1")
  _bss=$2; _bsslist=$3
  _k=$(fcd_key "$_m")
  [ -f "$FCD_STATE/class/$_k.protected" ] && { printf '%s\n' mlo-sticky; return; }
  fcd_valid_mac "$_m" || { printf '%s\n' unknown-invalid-mac; return; }

  _ac=$(fcd_assoc_count "$_m" "$_bsslist")
  fcd_num "$_ac" || _ac=0
  [ "$_ac" -gt 1 ] && { printf '%s\n' mlo-multiradio; return; }

  _si=$(fcd_sta_info "$_m" "$_bss")
  if [ -n "$_si" ] && printf '%s\n' "$_si" | grep -Eiq '(^|[^[:alnum:]_])(mlo|mld|multi[-_ ]?link|peer[_ -]?mld([_ -]?addr)?|valid[_ -]?links|link[_ -]?id|link[_ -]?map)([^[:alnum:]_]|$)'; then
    printf '%s\n' mlo-sta-info
    return
  fi

  # Any active EHT/11be station is protected. A one-link MLO client is still EHT.
  if [ -n "$_si" ] && printf '%s\n' "$_si" | grep -Eiq '(^|[^[:alnum:]_])(EHT|802[.]11be|Wi-?Fi[[:space:]]*7)([^[:alnum:]_]|$)'; then
    printf '%s\n' mlo-or-eht
    return
  fi

  _ms=$(fcd_mlo_snapshot "$_bsslist")
  if [ -n "$_ms" ] && printf '%s\n' "$_ms" | tr 'A-F' 'a-f' | grep -q "$_m" \
     && printf '%s\n' "$_ms" | grep -Eiq '(mlo|mld|multi[-_ ]?link|peer[_ -]?mld|link[_ -]?(addr|id|map))'; then
    printf '%s\n' mlo-table
    return
  fi

  [ -n "$_si" ] || { printf '%s\n' unknown-no-sta-info; return; }

  # Auto-detect only explicit pre-EHT negotiated PHYs. Absence of MLO text is not enough.
  if printf '%s\n' "$_si" | grep -Eiq 'phy([[:space:]_-]*type)?[[:space:]]*[:=][[:space:]]*(a|b|g|n|ac|ax)([^[:alnum:]]|$)|802[.]11(ax|ac|n|g|b|a)([^[:alnum:]]|$)|Wi-?Fi[[:space:]]*[456]([^[:alnum:]]|$)'; then
    printf '%s\n' nonmlo-explicit-legacy
    return
  fi

  printf '%s\n' unknown-unclassified
}

fcd_observe_class() { # mac class bss
  local _m _class _bss _k _f _now _oldclass _count _last _oldbss
  _m=$(fcd_norm_mac "$1"); _class=$2; _bss=$3
  _k=$(fcd_key "$_m"); _f="$FCD_STATE/class/$_k"
  _now=$(fcd_now); _oldclass=; _count=0; _last=0; _oldbss=
  [ -f "$_f" ] && IFS='|' read -r _oldclass _count _last _oldbss < "$_f"
  fcd_num "$_count" || _count=0
  fcd_num "$_last" || _last=0
  case "$_class" in
    mlo-*)
      : > "$FCD_STATE/class/$_k.protected"
      _count=0
      ;;
    nonmlo-*)
      if [ "$_oldclass" = "$_class" ] && [ "$_oldbss" = "$_bss" ] && [ $((_now - _last)) -le $((FCD_INTERVAL * 3 + 2)) ]; then
        _count=$((_count + 1))
      else
        _count=1
      fi
      ;;
    *) _count=0 ;;
  esac
  printf '%s|%s|%s|%s\n' "$_class" "$_count" "$_now" "$_bss" > "$_f.tmp" && mv "$_f.tmp" "$_f"
}

fcd_confirmed_nonmlo() { # mac bss
  local _k _f _class _count _last _oldbss _now
  _k=$(fcd_key "$1"); _f="$FCD_STATE/class/$_k"
  [ -f "$_f" ] || return 1
  IFS='|' read -r _class _count _last _oldbss < "$_f"
  case "$_class" in nonmlo-*) ;; *) return 1;; esac
  fcd_num "$_count" || return 1
  fcd_num "$_last" || return 1
  [ "$_oldbss" = "$2" ] || return 1
  [ "$_count" -ge "$FCD_CONFIRMATIONS" ] || return 1
  _now=$(fcd_now)
  [ $((_now - _last)) -le "$FCD_CONFIRM_MAX_AGE" ] || return 1
}

fcd_record_pending() { # mac bss reason
  local _m _b _reason _now _exp _k
  _m=$(fcd_norm_mac "$1"); _b=$2; shift 2; _reason=$*
  fcd_valid_mac "$_m" || return 1
  _now=$(fcd_now); _exp=$((_now + FCD_PENDING_TTL)); _k=$(fcd_key "$_m")
  printf '%s|%s|%s|%s\n' "$_m" "$_b" "$_exp" "$_reason" > "$FCD_STATE/pending/$_k"
}

fcd_schedule_settle() { # mac bss reason base_epoch
  local _m _b _reason _base _k _off _due
  _m=$1; _b=$2; _reason=$3; _base=$4; _k=$(fcd_key "$_m")
  for _off in $FCD_SETTLE_FLUSHES; do
    fcd_num "$_off" || continue
    _due=$((_base + _off))
    printf '%s|%s|%s|%s\n' "$_m" "$_b" "$_due" "settle+${_off}s:$_reason" > "$FCD_STATE/settle/${_k}.${_due}"
  done
}

fcd_safe_flush() { # mac bss bsslist reason
  local _m _b _bsslist _reason _k _lock _class _ac _now _lastf _last
  _m=$(fcd_norm_mac "$1"); _b=$2; _bsslist=$3; shift 3; _reason=$*
  fcd_valid_mac "$_m" || return 3
  _k=$(fcd_key "$_m"); _lock="$FCD_STATE/locks/$_k"
  mkdir "$_lock" 2>/dev/null || return 4

  # Fresh classification immediately before the only executable fcctl path.
  _class=$(fcd_classify "$_m" "$_b" "$_bsslist")
  case "$_class" in
    nonmlo-*) ;;
    *) fcd_log PROTECT "mac=$_m class=$_class reason=$_reason"; rmdir "$_lock" 2>/dev/null; return 3;;
  esac
  fcd_confirmed_nonmlo "$_m" "$_b" || { rmdir "$_lock" 2>/dev/null; return 2; }
  _ac=$(fcd_assoc_count "$_m" "$_bsslist"); fcd_num "$_ac" || _ac=0
  [ "$_ac" -eq 1 ] || { fcd_log PROTECT "mac=$_m association-count=$_ac reason=$_reason"; rmdir "$_lock" 2>/dev/null; return 3; }

  _now=$(fcd_now); _lastf="$FCD_STATE/client/$_k.lastflush"; _last=0
  [ -f "$_lastf" ] && _last=$(cat "$_lastf" 2>/dev/null)
  fcd_num "$_last" || _last=0
  [ $((_now - _last)) -ge "$FCD_MIN_GAP" ] || { rmdir "$_lock" 2>/dev/null; return 4; }

  if [ "$FCD_AUTOFIX" != "1" ]; then
    fcd_log AUDIT "would-flush mac=$_m class=$_class bss=$_b reason=$_reason"
    rmdir "$_lock" 2>/dev/null; return 0
  fi

  if fcctl flush --mac "$_m" >/dev/null 2>&1; then
    printf '%s\n' "$_now" > "$_lastf"
    fcd_log FLUSH "mac=$_m class=$_class bss=$_b reason=$_reason"
    rmdir "$_lock" 2>/dev/null
    return 0
  fi
  fcd_log ERROR "fcctl-failed mac=$_m bss=$_b reason=$_reason"
  rmdir "$_lock" 2>/dev/null
  return 5
}

fcd_radio_util() { # bss, best-effort 0-100 or ?
  local _out _u
  _out=$(wl -i "$1" status 2>/dev/null)
  _u=$(printf '%s\n' "$_out" | awk 'BEGIN{IGNORECASE=1} /QBSS|channel utilization/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+%?$/){gsub(/%/,"",$i); if($i>=0&&$i<=100){print $i; exit}}}')
  [ -n "$_u" ] && printf '%s\n' "$_u" || printf '?\n'
}

fcd_client_rssi() { wl -i "$1" rssi "$2" 2>/dev/null | awk 'NR==1{print $1}'; }
fcd_client_rates() {
  wl -i "$1" sta_info "$2" 2>/dev/null | awk 'BEGIN{IGNORECASE=1}
    /tx.*rate/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+([.][0-9]+)?$/){tx=$i; break}}
    /rx.*rate/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+([.][0-9]+)?$/){rx=$i; break}}
    END{printf "%s/%s", (tx?tx:"?"), (rx?rx:"?")}'
}
