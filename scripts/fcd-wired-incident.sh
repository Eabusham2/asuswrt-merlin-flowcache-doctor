#!/bin/sh
# Passive GT-BE19000AI wired/LAN incident capture.
# Reads state only: no link reset, FDB deletion, FlowCache flush, Runner cycle, or reboot.

set -u

FCD_ROOT=${FCD_ROOT:-/jffs/addons/flowcache-doctor}
FCD_STATE=${FCD_STATE:-$FCD_ROOT/state}
FCD_PROBE_IP=${FCD_PROBE_IP:-1.1.1.1}
AFFECTED_IP=${1:-}
AFFECTED_MAC=${2:-}
CONTROL_IP=${FCD_WIRED_CONTROL_IP:-}

safe_name() {
  printf '%s\n' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

STAMP=$(date '+%Y%m%d-%H%M%S')
KEY=$(safe_name "${AFFECTED_IP:-unknown}")
DIR="$FCD_ROOT/incidents/${STAMP}-WIRED-${KEY}"
mkdir -p "$DIR" || exit 1
RAW="$DIR/raw.txt"
SUMMARY="$DIR/summary.txt"
: > "$RAW"

WAN_GW=$(nvram get wan0_gateway 2>/dev/null)
[ -n "$WAN_GW" ] || WAN_GW=$(nvram get wan_gateway 2>/dev/null)

probe() {
  _label=$1
  _ip=$2
  _result=unsupported
  if [ -n "$_ip" ] && command -v ping >/dev/null 2>&1; then
    ping -c 3 -W 2 "$_ip" > "$DIR/ping-${_label}.txt" 2>&1 && _result=ok || _result=fail
  fi
  printf '%s\n' "$_result"
}

PING_WAN=$(probe wan-gateway "$WAN_GW")
PING_PUBLIC=$(probe public "$FCD_PROBE_IP")
PING_AFFECTED=$(probe affected "$AFFECTED_IP")
PING_CONTROL=$(probe control "$CONTROL_IP")

{
  echo "Flowcache Doctor wired incident"
  echo "captured: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "productid: $(nvram get productid 2>/dev/null)"
  echo "firmware: $(nvram get firmver 2>/dev/null).$(nvram get buildno 2>/dev/null)_$(nvram get extendno 2>/dev/null)"
  echo "affected_ip: ${AFFECTED_IP:-unknown}"
  echo "affected_mac: ${AFFECTED_MAC:-unknown}"
  echo "control_ip: ${CONTROL_IP:-none}"
  echo "wan_gateway: ${WAN_GW:-unknown}"
  echo "wan_gateway_ping: $PING_WAN"
  echo "public_ip_ping: $PING_PUBLIC"
  echo "router_to_affected_ping: $PING_AFFECTED"
  echo "router_to_control_ping: $PING_CONTROL"
  echo "note: router-to-client ICMP failure is not proof of LAN loss because a client firewall may block ICMP"
  echo "raw: $RAW"
} > "$SUMMARY"

{
  echo "=== META ==="
  date
  uptime 2>/dev/null
  echo

  echo "=== IP ROUTES ==="
  ip route 2>/dev/null
  ip -6 route 2>/dev/null
  echo

  echo "=== NEIGHBORS / ARP ==="
  ip neigh show 2>/dev/null
  cat /proc/net/arp 2>/dev/null
  echo

  echo "=== BRIDGE ==="
  brctl show 2>/dev/null
  echo "--- br0 FDB ---"
  brctl showmacs br0 2>/dev/null
  echo

  if [ -n "$AFFECTED_MAC" ]; then
    echo "=== AFFECTED MAC LOOKUP: $AFFECTED_MAC ==="
    brctl showmacs br0 2>/dev/null | grep -i "$AFFECTED_MAC" || true
    ip neigh show 2>/dev/null | grep -i "$AFFECTED_MAC" || true
    echo
  fi

  echo "=== INTERFACE COUNTERS ==="
  cat /proc/net/dev 2>/dev/null
  echo "--- ip -s link ---"
  ip -s link 2>/dev/null
  echo

  echo "=== BROADCOM PHY MAP ==="
  if command -v ethctl >/dev/null 2>&1; then
    ethctl phy-map 2>&1
  else
    echo "ethctl unavailable"
  fi
  echo

  echo "=== FLOW CACHE STATUS ==="
  if command -v fcctl >/dev/null 2>&1; then
    fcctl status 2>&1
  else
    echo "fcctl unavailable"
  fi
  echo

  echo "=== FLOW CACHE PROC STATS ==="
  for _f in /proc/fcache/stats/* /proc/fcache/misc/*; do
    [ -r "$_f" ] || continue
    echo "--- $_f ---"
    cat "$_f" 2>/dev/null
  done
  echo

  echo "=== BLOG STATS ==="
  if command -v blogctl >/dev/null 2>&1; then
    blogctl stats 2>&1
  else
    echo "blogctl unavailable"
  fi
  echo

  echo "=== RECENT ETHERNET / RUNNER / BRIDGE EVENTS ==="
  dmesg 2>/dev/null | grep -Ei 'eth|phy|link|port|runner|fcache|flow.?cache|blog|bridge|br0|netdev|watchdog|timeout|error|fail' | tail -n 500
  echo

  echo "=== RECENT SYSLOG NETWORK EVENTS ==="
  tail -n 600 /tmp/syslog.log 2>/dev/null | grep -Ei 'eth|phy|link|port|runner|fcache|flow.?cache|blog|bridge|br0|wan|timeout|error|fail'
} >> "$RAW"

printf '%s\n' "$DIR"
exit 0
