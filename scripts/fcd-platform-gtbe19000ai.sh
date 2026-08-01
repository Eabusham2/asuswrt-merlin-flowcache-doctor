#!/bin/sh
# GT-BE19000AI / Broadcom VER 8 live-format overrides.
# Sourced after fcd-lib.sh. Unknown or EHT/MLO output always fails closed.

FCD_UTIL_HIGH=${FCD_UTIL_HIGH:-85}
FCD_UTIL_RECOVER=${FCD_UTIL_RECOVER:-65}
FCD_UTIL_SPIKE_DELTA=${FCD_UTIL_SPIKE_DELTA:-20}
FCD_UTIL_LOG_COOLDOWN=${FCD_UTIL_LOG_COOLDOWN:-60}
FCD_INCIDENT_CAPTURE=${FCD_INCIDENT_CAPTURE:-1}

fcd_classify() { # mac current_bss bsslist
  local _m _bss _bsslist _ac _si _ms _k _eml
  _m=$(fcd_norm_mac "$1")
  _bss=$2; _bsslist=$3
  _k=$(fcd_key "$_m")
  [ -f "$FCD_STATE/class/$_k.protected" ] && { printf '%s\n' mlo-sticky; return; }
  fcd_valid_mac "$_m" || { printf '%s\n' mlo-fallback-invalid-mac; return; }

  _ac=$(fcd_assoc_count "$_m" "$_bsslist")
  fcd_num "$_ac" || _ac=0
  [ "$_ac" -gt 1 ] && { printf '%s\n' mlo-multiradio; return; }

  _si=$(fcd_sta_info "$_m" "$_bss")
  if [ -n "$_si" ] && printf '%s\n' "$_si" | grep -Eiq '(^|[^[:alnum:]_])(mlo|mld|multi[-_ ]?link|peer[_ -]?mld([_ -]?addr)?|valid[_ -]?links|link[_ -]?id|link[_ -]?map)([^[:alnum:]_]|$)'; then
    printf '%s\n' mlo-sta-info
    return
  fi

  if [ -n "$_si" ] && printf '%s\n' "$_si" | grep -Eiq '(^|[^[:alnum:]_])(EHT(_CAP)?|EHT[[:space:]]+caps?|EHT[[:space:]]+SET|802[.]11be|Wi-?Fi[[:space:]]*7|phy[[:space:]_-]*type[[:space:]]*[:=][[:space:]]*be)([^[:alnum:]_]|$)'; then
    printf '%s\n' mlo-or-eht
    return
  fi

  _eml=$(printf '%s\n' "$_si" | awk 'tolower($0) ~ /eml[[:space:]_-]*capabilities[[:space:]]*:/ {print $NF; exit}')
  case "$_eml" in ''|0|0x0|0X0) :;; *) printf '%s\n' mlo-eml-capable; return;; esac

  _ms=$(fcd_mlo_snapshot "$_bsslist")
  if [ -n "$_ms" ] && printf '%s\n' "$_ms" | tr 'A-F' 'a-f' | grep -q "$_m" \
     && printf '%s\n' "$_ms" | grep -Eiq '(mlo|mld|multi[-_ ]?link|peer[_ -]?mld|link[_ -]?(addr|id|map))'; then
    printf '%s\n' mlo-table
    return
  fi

  [ -n "$_si" ] || { printf '%s\n' mlo-fallback-no-sta-info; return; }

  # Explicit negotiated pre-EHT modes are the only automatic non-MLO path.
  if printf '%s\n' "$_si" | grep -Eq '^[[:space:]]*flags[[:space:]].*([[:space:]]|^)HE_CAP([[:space:]]|$)'; then
    printf '%s\n' nonmlo-negotiated-ax
    return
  fi
  if printf '%s\n' "$_si" | grep -Eq '^[[:space:]]*flags[[:space:]].*([[:space:]]|^)VHT_CAP([[:space:]]|$)'; then
    printf '%s\n' nonmlo-negotiated-ac
    return
  fi
  if printf '%s\n' "$_si" | grep -Eq '^[[:space:]]*flags[[:space:]].*([[:space:]]|^)N_CAP([[:space:]]|$)'; then
    printf '%s\n' nonmlo-negotiated-n
    return
  fi

  if printf '%s\n' "$_si" | grep -Eiq 'phy([[:space:]_-]*type)?[[:space:]]*[:=][[:space:]]*(a|b|g|n|ac|ax)([^[:alnum:]]|$)|802[.]11(ax|ac|n|g|b|a)([^[:alnum:]]|$)|Wi-?Fi[[:space:]]*[456]([^[:alnum:]]|$)'; then
    printf '%s\n' nonmlo-explicit-legacy
    return
  fi

  # Unknown is deliberately treated as MLO-safe fallback. It is protected now,
  # but not made permanently sticky so a later explicit pre-EHT result can heal.
  printf '%s\n' mlo-fallback-unclassified
}

# Override the base observer so temporary unknown output is MLO-protected without
# permanently blacklisting a legacy client after one transient driver miss.
fcd_observe_class() { # mac class bss
  local _m _class _bss _k _f _now _oldclass _count _last _oldbss
  _m=$(fcd_norm_mac "$1"); _class=$2; _bss=$3
  _k=$(fcd_key "$_m"); _f="$FCD_STATE/class/$_k"
  _now=$(fcd_now); _oldclass=; _count=0; _last=0; _oldbss=
  [ -f "$_f" ] && IFS='|' read -r _oldclass _count _last _oldbss < "$_f"
  fcd_num "$_count" || _count=0
  fcd_num "$_last" || _last=0
  case "$_class" in
    mlo-fallback-*)
      _count=0
      ;;
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

fcd_confirmation_progress() { # mac
  local _f _class _count _last _bss
  _f="$FCD_STATE/class/$(fcd_key "$1")"
  [ -f "$_f" ] || { printf '0/%s\n' "$FCD_CONFIRMATIONS"; return; }
  IFS='|' read -r _class _count _last _bss < "$_f"
  fcd_num "$_count" || _count=0
  [ "$_count" -gt "$FCD_CONFIRMATIONS" ] && _count=$FCD_CONFIRMATIONS
  printf '%s/%s\n' "$_count" "$FCD_CONFIRMATIONS"
}

fcd_radio_util() { # bss, best-effort 0-100 or ?
  local _u
  _u=$(wl -i "$1" chanim_stats 2>/dev/null | awk '
    $1=="chspec" {for(i=1;i<=NF;i++) if($i=="busy") busy=i; next}
    busy && $1!="version:" && NF>=busy && $busy ~ /^[0-9]+$/ {print $busy; exit}')
  [ -n "$_u" ] && printf '%s\n' "$_u" || printf '?\n'
}

fcd_chanim_fields() { # bss
  wl -i "$1" chanim_stats 2>/dev/null | awk '
    $1=="chspec" {
      for(i=1;i<=NF;i++) p[$i]=i
      next
    }
    p["busy"] && $1!="version:" && NF>=p["busy"] {
      printf "chspec=%s tx=%s inbss=%s obss=%s nocat=%s nopkt=%s doze=%s txop=%s goodtx=%s badtx=%s glitch=%s badplcp=%s knoise=%s idle=%s busy=%s timestamp=%s\n",
        $(p["chspec"]),$(p["tx"]),$(p["inbss"]),$(p["obss"]),$(p["nocat"]),$(p["nopkt"]),
        $(p["doze"]),$(p["txop"]),$(p["goodtx"]),$(p["badtx"]),$(p["glitch"]),
        $(p["badplcp"]),$(p["knoise"]),$(p["idle"]),$(p["busy"]),$(p["timestamps"])
      exit
    }'
}

fcd_kv() { # "key=value ..." key
  printf '%s\n' "$1" | tr ' ' '\n' | awk -F= -v k="$2" '$1==k{print $2; exit}'
}

fcd_chanim_cause_from_fields() { # fields
  local _f _busy _tx _in _ob _no _np _good _bad _foreign _local _explained
  _f=$1
  _busy=$(fcd_kv "$_f" busy); _tx=$(fcd_kv "$_f" tx); _in=$(fcd_kv "$_f" inbss)
  _ob=$(fcd_kv "$_f" obss); _no=$(fcd_kv "$_f" nocat); _np=$(fcd_kv "$_f" nopkt)
  _good=$(fcd_kv "$_f" goodtx); _bad=$(fcd_kv "$_f" badtx)
  for _v in "$_busy" "$_tx" "$_in" "$_ob" "$_no" "$_np" "$_good" "$_bad"; do
    fcd_num "$_v" || { printf '%s\n' unknown-telemetry; return; }
  done
  _foreign=$((_no + _np))
  _local=$((_tx + _in))
  _explained=$((_tx + _in + _ob + _no + _np))

  if [ "$_busy" -ge "$FCD_UTIL_HIGH" ] && [ "$_explained" -lt 25 ]; then
    printf '%s\n' driver-or-counter-anomaly
  elif [ "$_ob" -ge 25 ] && [ "$_ob" -ge "$_foreign" ] && [ "$_ob" -ge "$_in" ]; then
    printf '%s\n' other-wifi-contention
  elif [ "$_foreign" -ge 25 ] && [ "$_foreign" -ge "$_ob" ]; then
    printf '%s\n' nonwifi-or-undecodable-energy
  elif [ "$_local" -ge 35 ] || { [ "$_bad" -ge 10 ] && [ "$_bad" -gt "$_good" ]; }; then
    printf '%s\n' local-airtime-or-retries
  elif [ "$_busy" -ge "$FCD_UTIL_HIGH" ]; then
    printf '%s\n' mixed-high-airtime
  else
    printf '%s\n' mixed-or-transient
  fi
}

fcd_client_rates() {
  wl -i "$1" sta_info "$2" 2>/dev/null | awk '
    /rate of last tx pkt:/ && !tx {for(i=1;i<NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="kbps"){tx=$i; break}}
    /rate of last rx pkt:/ && !rx {for(i=1;i<NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="kbps"){rx=$i; break}}
    END {
      if(tx) txm=int((tx+500)/1000); else txm="?"
      if(rx) rxm=int((rx+500)/1000); else rxm="?"
      printf "%s/%sM", txm, rxm
    }'
}

fcd_util_snapshot() { # bsslist
  local _b _u _out _key _f _state _lastlog
  _out=
  for _b in $1; do
    _key=$(fcd_util_key "$_b"); _f="$FCD_STATE/util/$_key"; _u=
    [ -f "$_f" ] && IFS='|' read -r _u _state _lastlog < "$_f"
    fcd_num "$_u" || _u=$(fcd_radio_util "$_b")
    [ -n "$_out" ] && _out="$_out,"
    _out="${_out}${_b}=${_u}%"
  done
  printf '%s\n' "$_out"
}

fcd_util_key() { printf '%s\n' "$1" | tr -c 'A-Za-z0-9._-' '_'; }


fcd_cleanup_incidents() {
  local _today _marker _d
  mkdir -p "$FCD_ROOT/incidents"
  _today=$(date '+%Y%m%d')
  _marker="$FCD_STATE/incident-cleanup.$_today"
  [ -f "$_marker" ] && return 0
  rm -f "$FCD_STATE"/incident-cleanup.* 2>/dev/null
  : > "$_marker"
  find "$FCD_ROOT/incidents" -type d -mtime +"$FCD_LOG_RETENTION_DAYS" 2>/dev/null |
  while IFS= read -r _d; do
    [ "$_d" = "$FCD_ROOT/incidents" ] && continue
    case "$_d" in "$FCD_ROOT"/incidents/*) rm -rf "$_d";; esac
  done
}

fcd_trigger_incident() { # event bss previous current
  [ "$FCD_INCIDENT_CAPTURE" = "1" ] || return 0
  [ -x /jffs/scripts/fcd-incident.sh ] || return 0
  /jffs/scripts/fcd-incident.sh "$1" "$2" "$3" "$4" >/dev/null 2>&1 &
}

fcd_observe_radio_util() { # bss
  local _b _u _key _f _now _prev _state _lastlog _delta _abs _event _newstate _fields _cause
  _b=$1
  _u=$(fcd_radio_util "$_b")
  fcd_num "$_u" || return 0
  mkdir -p "$FCD_STATE/util"
  _key=$(fcd_util_key "$_b"); _f="$FCD_STATE/util/$_key"
  _now=$(fcd_now); _prev=; _state=normal; _lastlog=0
  [ -f "$_f" ] && IFS='|' read -r _prev _state _lastlog < "$_f"
  fcd_num "$_prev" || _prev=
  fcd_num "$_lastlog" || _lastlog=0
  _event=
  _newstate=$_state

  if [ -n "$_prev" ]; then
    _delta=$((_u - _prev)); _abs=$_delta; [ "$_abs" -lt 0 ] && _abs=$((-_abs))
    if [ "$_u" -ge "$FCD_UTIL_HIGH" ] && [ "$_prev" -lt "$FCD_UTIL_HIGH" ]; then
      _event=UTIL-HIGH; _newstate=high
    elif [ "$_prev" -ge "$FCD_UTIL_HIGH" ] && [ "$_u" -le "$FCD_UTIL_RECOVER" ]; then
      _event=UTIL-RECOVER; _newstate=normal
    elif [ "$_abs" -ge "$FCD_UTIL_SPIKE_DELTA" ] && [ $((_now - _lastlog)) -ge "$FCD_UTIL_LOG_COOLDOWN" ]; then
      _event=UTIL-SPIKE
    fi
  elif [ "$_u" -ge "$FCD_UTIL_HIGH" ]; then
    _event=UTIL-HIGH; _newstate=high
  fi

  if [ -n "$_event" ]; then
    _fields=$(fcd_chanim_fields "$_b")
    _cause=$(fcd_chanim_cause_from_fields "$_fields")
    fcd_log "$_event" "bss=$_b previous=${_prev:-?}% current=${_u}% cause=$_cause $_fields"
    _lastlog=$_now
    case "$_event" in UTIL-HIGH|UTIL-SPIKE) fcd_trigger_incident "$_event" "$_b" "${_prev:-?}" "$_u";; esac
  fi
  printf '%s|%s|%s\n' "$_u" "$_newstate" "$_lastlog" > "$_f.tmp" && mv "$_f.tmp" "$_f"
}
