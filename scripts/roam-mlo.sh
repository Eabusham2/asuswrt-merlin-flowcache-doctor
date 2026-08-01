#!/bin/sh
# roam-mlo.sh — MLO safety gate for flowcache-doctor.
#
# The Broadcom/ASUS CLI does not expose a stable, documented shell API that
# guarantees a complete MLD <-> link-MAC mapping on every model/SDK.  This
# library therefore defaults to FAIL-CLOSED strict mode:
#   * positively identified MLO clients are never flushed
#   * unclassified clients are never flushed
#   * only MACs explicitly allowlisted as non-MLO may be healed
#
# Optional auto mode can recognize obvious legacy/non-EHT clients, but strict
# mode is the only mode intended when "do not touch MLO" is the priority.

MLO_SAFETY_MODE=${MLO_SAFETY_MODE:-strict}   # strict | auto
NON_MLO_ALLOW_FILE=${NON_MLO_ALLOW_FILE:-/jffs/scripts/roam-nonmlo.allow}
MLO_IGNORE_FILE=${MLO_IGNORE_FILE:-/jffs/scripts/roam-mlo.ignore}
MLO_STATE_DIR=${MLO_STATE_DIR:-/tmp/roam-detect/mlo}
MLO_TAG=${MLO_TAG:-roam-mlo}

mlo_norm_mac() { echo "$1" | tr 'A-F' 'a-f'; }
mlo_valid_mac() { echo "$1" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'; }

mlo_file_has_mac() { # $1=file $2=mac
  [ -f "$1" ] || return 1
  _m=$(mlo_norm_mac "$2")
  awk -v m="$_m" 'tolower($1)==m {found=1} END{exit !found}' "$1" 2>/dev/null
}

mlo_assoc_count() { # $1=mac $2=bsslist
  _m=$(mlo_norm_mac "$1")
  if [ -n "${RD_ASSOC_MAP:-}" ] && [ -f "$RD_ASSOC_MAP" ]; then
    awk -v m="$_m" 'tolower($1)==m {n++} END{print n+0}' "$RD_ASSOC_MAP"
    return
  fi
  _n=0
  for _b in $2; do
    wl -i "$_b" assoclist 2>/dev/null | awk '{print tolower($2)}' | grep -qx "$_m" && _n=$((_n+1))
  done
  echo "$_n"
}

mlo_sta_info_all() { # $1=mac $2=bsslist
  for _b in $2; do
    wl -i "$_b" sta_info "$1" 2>/dev/null
  done
}

mlo_status_all() { # $1=bsslist
  # Firmware/SDK builds expose different command names. Unsupported commands
  # simply return nothing. We never treat an empty result as proof of non-MLO.
  for _b in $1; do
    wl -i "$_b" mlo 2>/dev/null
    wl -i "$_b" mlo_status 2>/dev/null
  done
}

mlo_positive_evidence() { # $1=mac $2=bsslist; prints reason on success
  _mac=$(mlo_norm_mac "$1")

  if mlo_file_has_mac "$MLO_IGNORE_FILE" "$_mac"; then
    echo mlo-explicit
    return 0
  fi

  _ac=$(mlo_assoc_count "$_mac" "$2")
  [ "${_ac:-0}" -gt 1 ] 2>/dev/null && { echo mlo-multilink-same-mac; return 0; }

  _si=$(mlo_sta_info_all "$_mac" "$2")
  if [ -n "$_si" ] && echo "$_si" | grep -Eiq '(^|[^[:alnum:]_])(mlo|mld|multi[-_ ]?link|peer[_ -]?mld|valid[_ -]?links|link[_ -]?id)([^[:alnum:]_]|$)'; then
    echo mlo-sta-info
    return 0
  fi

  _ms=$(mlo_status_all "$2")
  if [ -n "$_ms" ] && echo "$_ms" | tr 'A-F' 'a-f' | grep -q "$_mac" \
     && echo "$_ms" | grep -Eiq '(mlo|mld|multi[-_ ]?link|peer[_ -]?mld|link[_ -]?addr|link[_ -]?id)'; then
    echo mlo-status-table
    return 0
  fi

  return 1
}

mlo_classify_client() { # $1=mac $2=current-bss $3=bsslist
  _mac=$(mlo_norm_mac "$1")
  _bsslist=$3

  _why=$(mlo_positive_evidence "$_mac" "$_bsslist") && { echo "$_why"; return; }

  # Explicit non-MLO authorization comes only after all positive MLO checks,
  # so an accidentally double-listed MAC remains protected.  Also refuse an
  # allowlisted EHT/Wi-Fi 7 station: it may be an MLD with only one visible
  # link or incomplete CLI metadata.  Strict mode is intentionally for
  # pre-EHT/non-MLO clients.
  if mlo_file_has_mac "$NON_MLO_ALLOW_FILE" "$_mac"; then
    _allow_si=$(mlo_sta_info_all "$_mac" "$_bsslist")
    if [ -n "$_allow_si" ] && echo "$_allow_si" | grep -Eiq '(EHT|802[.]11be|Wi-?Fi[[:space:]]*7)'; then
      echo unknown-eht-allowlisted
    else
      echo nonmlo-explicit
    fi
    return
  fi

  [ "$MLO_SAFETY_MODE" = "auto" ] || { echo unknown-strict; return; }

  _si=$(mlo_sta_info_all "$_mac" "$_bsslist")
  [ -n "$_si" ] || { echo unknown-no-sta-info; return; }

  # Any EHT/11be indication is treated as uncertain, not as non-MLO. A Wi-Fi 7
  # client may currently have one active link while still being an MLD.
  if echo "$_si" | grep -Eiq '(EHT|802[.]11be|Wi-?Fi[[:space:]]*7)'; then
    echo unknown-eht-capable
    return
  fi

  # Auto-heal only when the station output positively identifies a pre-EHT
  # generation. Absence of EHT text alone is never enough.
  if echo "$_si" | grep -Eiq '(HE[[:space:]_-]*Capable|VHT[[:space:]_-]*Capable|HT[[:space:]_-]*Capable|802[.]11(ax|ac|n)|Wi-?Fi[[:space:]]*[456])'; then
    echo nonmlo-auto-legacy
    return
  fi

  echo unknown-unclassified
}

mlo_log_skip_once() { # $1=mac $2=class $3=reason
  mkdir -p "$MLO_STATE_DIR"
  _k=$(echo "$1" | tr -d ':' | tr 'A-F' 'a-f')
  _f="$MLO_STATE_DIR/$_k.skip"
  _old=$(cat "$_f" 2>/dev/null)
  [ "$_old" = "$2" ] && return 0
  echo "$2" > "$_f"
  logger -t "$MLO_TAG" "SKIPPED $1 ($3; classification=$2)"
}

mlo_heal_allowed() { # $1=mac $2=current-bss $3=bsslist $4=trigger reason
  _class=$(mlo_classify_client "$1" "$2" "$3")
  case "$_class" in
    nonmlo-*) return 0 ;;
    *) mlo_log_skip_once "$1" "$_class" "$4"; return 1 ;;
  esac
}
