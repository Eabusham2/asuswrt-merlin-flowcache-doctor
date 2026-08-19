#!/bin/sh
# tests/mac-filter.sh — regression fixtures for roam-events.sh's is_unicast().
#
# The event listener parses MACs out of wlceventd lines with a permissive
# regex. The driver emits `Deauth_ind FF:FF:FF:FF:FF:FF` every time a BSS
# goes down (radio toggled, band disabled, restart_wireless), so without a
# group-address guard that line is healed as if a client had departed —
# burning a flush plus a full settle ladder on a MAC that owns no flows and
# leaving ffffffffffff.* state that reads like a real client. Observed live
# twice on 2026-08-19.
#
# is_unicast() is extracted verbatim from the shipped script, so this fails
# if the guard is weakened or removed.
#
# Run from the repo root:  sh tests/mac-filter.sh
# Runs on macOS and on the router. Exits non-zero if any fixture regresses.

SRC=${SRC:-scripts/roam-events.sh}
[ -f "$SRC" ] || { echo "ERROR: $SRC not found — run from the repo root" >&2; exit 1; }

T=${TMPDIR:-/tmp}/roam-macfilter.$$
mkdir -p "$T" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

sed -n '/^is_unicast() {/,/^}/p' "$SRC" > "$T/fn.sh"
[ -s "$T/fn.sh" ] || { echo "ERROR: could not extract is_unicast() from $SRC" >&2; exit 1; }
. "$T/fn.sh"

pass=0; fail=0
check() { # $1 = mac, $2 = expected (unicast|group), $3 = why
  if is_unicast "$1"; then got=unicast; else got=group; fi
  if [ "$got" = "$2" ]; then
    pass=$((pass + 1)); printf 'PASS  %-20s %-8s %s\n' "$1" "$got" "$3"
  else
    fail=$((fail + 1)); printf 'FAIL  %-20s got=%-8s want=%-8s %s\n' "$1" "$got" "$2" "$3"
  fi
}

echo; echo "is_unicast() from $SRC"; echo

# The incident: a BSS going down emits a broadcast deauth.
check "ff:ff:ff:ff:ff:ff" group   "broadcast — the 2026-08-19 incident"
check "FF:FF:FF:FF:FF:FF" group   "broadcast, upper case (regex feeds either)"

# Other group addresses seen on a live bridge.
check "01:00:5e:00:00:01" group   "IPv4 multicast"
check "33:33:00:00:00:01" group   "IPv6 multicast"
check "01:80:c2:00:00:00" group   "STP/LLDP reserved"

# Real clients from this deployment must still pass.
check "1c:f6:4c:96:7d:b7" unicast "MacBook Air"
check "60:3e:5f:87:5f:ed" unicast "MacBook Pro"
check "bc:fc:e7:bf:a0:d4" unicast "RP-BE58 STA"
check "b0:4a:39:02:83:f5" unicast "Roborock"
check "c2:3d:c7:b9:49:77" unicast "iPhone, locally-administered — MUST still pass"

# The bit tested is the LSB of octet 1, not the U/L bit (bit 2) — c2 above
# is locally administered and unicast, and these pin the boundary.
check "02:00:00:00:00:00" unicast "U/L set, group clear"
check "03:00:00:00:00:00" group   "U/L set AND group set"
check "fe:ff:ff:ff:ff:ff" unicast "one bit from broadcast"

# Malformed input must not be treated as a client.
check "not-a-mac"         group   "garbage rejected"
check ""                  group   "empty rejected"
check "ff:ff:ff:ff:ff"    group   "too short rejected"

echo; echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
