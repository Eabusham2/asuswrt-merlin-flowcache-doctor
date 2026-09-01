#!/bin/sh
# Read-only per-link health inspector for one MLD on GT-BE19000AI.
# Finds the current randomized link MAC on each MLO BSS by matching the MLD
# inside sta_info, then prints only link/RF/retry fields needed for range work.
# Usage: fcd-mlo-link-health.sh [auto|MLD]
# `auto` selects the sole MLD currently listed by wl2.1 (6 GHz).

set -u
MLD=${1:-auto}

if [ "$MLD" = auto ]; then
  MLDS=$(wl -i wl2.1 mlo info 2>/dev/null |
    sed -n 's/.*\/MLD-\(([0-9A-Fa-f:]*)\).*/\1/p' 2>/dev/null)
  # BusyBox sed does not support every extended form; use awk fallback.
  [ -n "$MLDS" ] || MLDS=$(wl -i wl2.1 mlo info 2>/dev/null |
    awk '/MLO SCB:/ && /\/MLD-/ {x=$0; sub(/^.*\/MLD-/,"",x); sub(/[[:space:]].*$/,"",x); print x}' |
    sort -u)
  COUNT=$(printf '%s\n' "$MLDS" | awk 'NF{n++} END{print n+0}')
  [ "$COUNT" -eq 1 ] || {
    echo "ERROR: auto expected exactly one 6-GHz MLD, found $COUNT" >&2
    printf '%s\n' "$MLDS" >&2
    echo "usage: $0 [auto|MLD]" >&2
    exit 1
  }
  MLD=$(printf '%s\n' "$MLDS" | awk 'NF{print; exit}')
fi

case "$MLD" in
  '') echo "usage: $0 [auto|MLD]" >&2; exit 1;;
  *[!0-9A-Fa-f:]*) echo "invalid MLD: $MLD" >&2; exit 1;;
esac

norm(){ printf '%s\n' "$1" | tr 'A-F' 'a-f'; }
TARGET=$(norm "$MLD")

echo "MLD=$MLD"
echo "direct_wl1=$(wl -i wl1 chanspec 2>/dev/null)"
echo "direct_wl2=$(wl -i wl2 chanspec 2>/dev/null)"
echo

FOUND=0
for IF in wl2.1 wl1.1 wl0.1; do
  echo "================ $IF ================"
  MATCH=0
  for MAC in $(wl -i "$IF" assoclist 2>/dev/null | awk '{print $2}'); do
    [ -n "$MAC" ] || continue
    S=$(wl -i "$IF" sta_info "$MAC" 2>/dev/null)
    [ -n "$S" ] || continue
    printf '%s\n' "$S" | tr 'A-F' 'a-f' | grep -q "$TARGET" || continue
    MATCH=1
    FOUND=1
    echo "link_mac=$MAC"
    printf '%s\n' "$S" | grep -E \
      'STA |MLO: peer|link_id|chanspec|idle |smoothed rssi|per antenna rssi of last|per antenna average|rate of last tx pkt|rate of last rx pkt|tx pkts retries|tx pkts retry exhausted|rx total pkts retried|tx failures:|link bandwidth|Max Rate|tx nrate|rx nrate'
  done
  [ "$MATCH" -eq 1 ] || echo "MLD not present on this BSS"
  echo
 done

echo "================ MLO COUNTERS ================"
wl -i wl2.1 mlo scb_stats "$MLD" 2>/dev/null |
  grep -E 'STA |link_id|tx_pkts_acked|phy_tx_errors|tx_pkts_total|rx_pkts'

echo

echo "================ MLO CHANSPEC CONSISTENCY ================"
for VIEW in wl2.1 wl1.1; do
  echo "[$VIEW]"
  wl -i "$VIEW" mlo info 2>/dev/null |
    grep -E 'link0:|link1:|link2:|MLO SCB:|active_link_map|assoc_link_bmp|Tid Map|Client Mode'
done

echo

echo "================ INTERFERENCE MODE ================"
for IF in wl1 wl2; do
  printf '%s: ' "$IF"
  wl -i "$IF" interference_override 2>/dev/null | head -n 2 | tr '\n' ' '
  echo
 done

[ "$FOUND" -eq 1 ] || {
  echo "WARNING: MLD was not found in current sta_info on wl2.1/wl1.1/wl0.1" >&2
  exit 2
}
