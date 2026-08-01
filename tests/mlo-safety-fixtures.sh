#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=${TMPDIR:-/tmp}/fcd-mlo-test.$$
trap 'rm -rf "$TMP"' EXIT INT TERM
mkdir -p "$TMP"
MLO_STATE_DIR="$TMP/state"
NON_MLO_ALLOW_FILE="$TMP/allow"
MLO_IGNORE_FILE="$TMP/ignore"
MLO_TAG=test-mlo
logger() { :; }
WL_CASE=none
wl() {
  case "$WL_CASE:$*" in
    mlo-sta:*sta_info*) echo 'MLO peer_mld_addr aa:bb:cc:dd:ee:ff link_id 1' ;;
    mlo-table:*mlo_status*) echo 'MLD aa:bb:cc:dd:ee:ff link_addr 02:00:00:00:00:01 link_addr 02:00:00:00:00:02 link_addr 02:00:00:00:00:03' ;;
    eht:*sta_info*) echo 'EHT Capable: yes' ;;
    legacy:*sta_info*) echo 'HE Capable: yes 802.11ax' ;;
    *assoclist*) : ;;
    *) : ;;
  esac
}
. "$ROOT/scripts/roam-mlo.sh"

pass=0
check() { got=$1 exp=$2 name=$3; [ "$got" = "$exp" ] || { echo "FAIL $name: got=$got expected=$exp"; exit 1; }; echo "ok $name"; pass=$((pass+1)); }

MLO_SAFETY_MODE=strict
check "$(mlo_classify_client 00:11:22:33:44:55 wl0 'wl0 wl1 wl2')" unknown-strict strict-unlisted-is-safe

echo '00:11:22:33:44:55' > "$NON_MLO_ALLOW_FILE"
check "$(mlo_classify_client 00:11:22:33:44:55 wl0 'wl0 wl1 wl2')" nonmlo-explicit explicit-nonmlo-allowed

echo '00:11:22:33:44:55' > "$MLO_IGNORE_FILE"
check "$(mlo_classify_client 00:11:22:33:44:55 wl0 'wl0 wl1 wl2')" mlo-explicit mlo-ignore-overrides-allow
: > "$MLO_IGNORE_FILE"

MAP="$TMP/map"; printf '00:11:22:33:44:55 wl0\n00:11:22:33:44:55 wl1\n00:11:22:33:44:55 wl2\n' > "$MAP"
RD_ASSOC_MAP="$MAP"
check "$(mlo_classify_client 00:11:22:33:44:55 wl0 'wl0 wl1 wl2')" mlo-multilink-same-mac three-link-same-mac-protected
: > "$MAP"

WL_CASE=mlo-sta
check "$(mlo_classify_client aa:bb:cc:dd:ee:ff wl0 'wl0 wl1 wl2')" mlo-sta-info sta-info-mlo-protected
WL_CASE=mlo-table
check "$(mlo_classify_client 02:00:00:00:00:02 wl1 'wl0 wl1 wl2')" mlo-status-table three-link-table-mac-protected


MLO_SAFETY_MODE=strict
WL_CASE=eht
echo '20:30:40:50:60:70' >> "$NON_MLO_ALLOW_FILE"
check "$(mlo_classify_client 20:30:40:50:60:70 wl0 'wl0 wl1 wl2')" unknown-eht-allowlisted accidental-eht-allowlist-still-protected

MLO_SAFETY_MODE=auto
WL_CASE=eht
check "$(mlo_classify_client 10:20:30:40:50:60 wl0 'wl0 wl1 wl2')" unknown-eht-capable eht-without-mapping-still-protected
WL_CASE=legacy
check "$(mlo_classify_client 10:20:30:40:50:61 wl0 'wl0 wl1 wl2')" nonmlo-auto-legacy positively-legacy-can-heal

MLO_SAFETY_MODE=strict
WL_CASE=none
: > "$NON_MLO_ALLOW_FILE"
if mlo_heal_allowed 10:20:30:40:50:62 wl0 'wl0 wl1 wl2' test; then echo 'FAIL unknown client was allowed'; exit 1; fi
echo '10:20:30:40:50:62' > "$NON_MLO_ALLOW_FILE"
mlo_heal_allowed 10:20:30:40:50:62 wl0 'wl0 wl1 wl2' test || { echo 'FAIL allowlisted non-MLO was blocked'; exit 1; }
echo "ok heal-gate-fail-closed"
pass=$((pass+1))


FLUSH_COUNT=0
fcctl() { FLUSH_COUNT=$((FLUSH_COUNT+1)); }
try_flush() { mlo_heal_allowed "$1" wl0 'wl0 wl1 wl2' simulated && fcctl flush --mac "$1"; }
MLO_SAFETY_MODE=auto
WL_CASE=mlo-sta
try_flush aa:bb:cc:dd:ee:ff || :
check "$FLUSH_COUNT" 0 mlo-never-reaches-fcctl
MLO_SAFETY_MODE=strict
WL_CASE=none
try_flush 12:34:56:78:9a:bc || :
check "$FLUSH_COUNT" 0 unknown-never-reaches-fcctl

echo "PASS: $pass MLO safety checks"
