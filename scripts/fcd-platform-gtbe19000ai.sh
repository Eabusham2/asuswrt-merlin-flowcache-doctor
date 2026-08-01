#!/bin/sh
# GT-BE19000AI / Broadcom VER 8 live-format overrides.
# Sourced after fcd-lib.sh. Unknown or EHT/MLO output always fails closed.

fcd_classify() { # mac current_bss bsslist
  local _m _bss _bsslist _ac _si _ms _k _eml
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

  [ -n "$_si" ] || { printf '%s\n' unknown-no-sta-info; return; }

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

  printf '%s\n' unknown-unclassified
}

fcd_radio_util() { # bss, best-effort 0-100 or ?
  local _u
  _u=$(wl -i "$1" chanim_stats 2>/dev/null | awk '
    $1=="chspec" {for(i=1;i<=NF;i++) if($i=="busy") busy=i; next}
    busy && $1!="version:" && NF>=busy && $busy ~ /^[0-9]+$/ {print $busy; exit}')
  [ -n "$_u" ] && printf '%s\n' "$_u" || printf '?\n'
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
