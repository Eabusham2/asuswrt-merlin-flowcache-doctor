#!/bin/sh
# tests/resolver-fixtures.sh — regression fixtures for roam-lib.sh's
# BSSLIST=auto resolver.
#
# There is no router emulator, and the resolver is the one piece of the addon
# whose correctness depends entirely on hardware-specific interface naming —
# which differs by chip generation (BE vs AX), by unit role (router vs AiMesh
# node), and by firmware. Every fixture below is a REAL layout captured from a
# real unit (see the source note on each), replayed against a stubbed bridge
# directory and a stubbed `wl`.
#
# SSID values are placeholders per AGENTS.md (never ship a real SSID); only
# the GROUPING is meaningful — which interfaces share an SSID is what the
# resolver keys on.
#
# Run from the repo root:  sh tests/resolver-fixtures.sh
# Runs on macOS and on the router. Exits non-zero if any fixture regresses.

LIB=${LIB:-scripts/roam-lib.sh}
[ -f "$LIB" ] || { echo "ERROR: $LIB not found — run from the repo root" >&2; exit 1; }

T=${TMPDIR:-/tmp}/roam-fixtures.$$
mkdir -p "$T/bin" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

# Stub `wl`: called as `wl -i <iface> ssid`. Answers from the fixture map;
# non-radio members error out exactly as the real tool does.
cat > "$T/bin/wl" <<'STUB'
#!/bin/sh
_if=""
while [ $# -gt 0 ]; do
  case $1 in -i) _if=$2; shift 2 ;; *) shift ;; esac
done
_v=$(sed -n "s/^$_if|//p" "$RD_FIXTURE_MAP" 2>/dev/null)
if [ -z "$_v" ] || [ "$_v" = "ERR" ]; then
  echo "wl: wl driver adapter not found" >&2
  exit 1
fi
echo "Current SSID: \"$_v\""
STUB
chmod 755 "$T/bin/wl"
PATH="$T/bin:$PATH"
export PATH

PASS=0; FAIL=0

# fixture <name> <expected> <<EOF ... map ... EOF
fixture() {
  _name=$1; _expect=$2
  _dir="$T/case.$_name"
  rm -rf "$_dir"; mkdir -p "$_dir/brif"
  RD_FIXTURE_MAP="$_dir/map"; export RD_FIXTURE_MAP
  cat > "$RD_FIXTURE_MAP"
  # Bridge membership is the set of interfaces in the map, in kernel order
  # (the resolver must not depend on it — it sorts).
  while IFS='|' read -r _i _rest; do
    [ -n "$_i" ] && mkdir -p "$_dir/brif/$_i"
  done < "$RD_FIXTURE_MAP"

  RD_BRIF="$_dir/brif"; export RD_BRIF
  # Re-source per fixture so each case starts from the shipped definitions.
  . "$LIB"
  _got=$(resolve_bsslist)

  if [ "$_got" = "$_expect" ]; then
    PASS=$((PASS + 1))
    printf 'PASS  %-18s -> %s\n' "$_name" "${_got:-<nothing>}"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL  %-18s\n        expected: %s\n        got:      %s\n' \
      "$_name" "${_expect:-<nothing>}" "${_got:-<nothing>}"
  fi
}

echo "resolve_bsslist() fixtures — lib: $LIB"
echo

# --- BE-class: the validated baseline. These must never change. ------------

# Source: live capture from the maintainer's RT-BE92U (AiMesh controller),
# 2026-07-28 — the only unit we can test on directly, and it is a production
# home gateway, so this fixture is the guard against breaking it.
# MAIN spans 2.4/5/6 GHz; IOT spans 2.4/5; wl0.4 is the AiMesh backhaul VAP
# (32-hex SSID); wlX.0 primaries and the wired/VLAN members refuse wl queries.
fixture be92u-router "wl0.1 wl0.2 wl1.1 wl1.2 wl2.1" <<'EOF'
eth1|ERR
vlan4094|ERR
wl0.0|ERR
wl0.1|placeholder-main
wl0.2|placeholder-iot
wl0.4|0123456789ABCDEF0123456789ABCDEF
wl1.0|ERR
wl1.1|placeholder-main
wl1.2|placeholder-iot
wl2.0|ERR
wl2.1|placeholder-main
EOF

# Source: Adnan008's RT-BE92U AiMesh NODE (thread 97561, post-998233 / issue
# #2). Node VAP indices differ from the router's; backhaul VAPs are wlX.1.0
# and self-exclude by refusing wl queries. IOT is single-band here, so the
# >=2-interface roamability rule correctly drops it.
fixture be92u-node "wl1.2 wl2.2" <<'EOF'
wl0.1.0|ERR
wl0.2|placeholder-iot
wl0.5|0123456789ABCDEF0123456789ABCDEF
wl1.1.0|ERR
wl1.2|placeholder-main
wl2.1.0|ERR
wl2.2|placeholder-main
EOF

# --- AX-class: wl-named. Already worked; must keep working. ----------------

# Source: jksmurf's RT-AX3000 AiMesh node, 3004.388.12 (thread 97561,
# post-998524) — the first fully-green zero-config node install. Proof that
# "AX" does not imply eth-named radios; the split is per model, not per class.
fixture ax3000-node "wl0.1 wl1.1" <<'EOF'
wl0.0|ERR
wl0.1|placeholder-main
wl1.0|ERR
wl1.1|placeholder-main
EOF

# --- AX-class: eth-named. The issue #5 bug. --------------------------------

# Source: jksmurf's RT-AX88U Pro, 3006.102.8 — probe output in thread 97561,
# post-998568. Radios are eth6/eth7. CRITICAL: the wds* backhaul interfaces
# answer with the REAL main SSID (they do NOT self-exclude the way BE-class
# backhaul VAPs do), so without an explicit wds exclusion they join the SSID
# group and the doctor would watch — and flush against — the mesh backhaul.
fixture ax88u-pro "eth6 eth7" <<'EOF'
eth3|ERR
eth4|ERR
eth5|ERR
eth6|placeholder-main
eth7|placeholder-main
wds0.0.1|placeholder-main
wds1.0.1|placeholder-main
EOF

# Source: Squall Leonhart's RT-AX88U (thread 97561, post-998514). br0 member
# list is verbatim from their health dump; the per-interface SSID answers are
# INFERRED from the AX88U Pro pattern above — they have not posted a probe.
# If their real output ever contradicts this, fix the fixture, not the code.
fixture ax88u-inferred "eth6 eth7" <<'EOF'
bond0|ERR
eth1|ERR
eth2|ERR
eth5|ERR
eth6|placeholder-main
eth7|placeholder-main
wds0.0.1|placeholder-main
wds1.0.2|placeholder-main
EOF

# --- Guards on the grouping rules themselves -------------------------------

# A single-band network cannot band-roam: the >=2 rule must drop it. (Whether
# mesh-roaming singletons deserve inclusion is an open question — see AGENTS.md
# "Known open problems"; this fixture pins today's deliberate behavior.)
fixture singleton-dropped "" <<'EOF'
wl0.0|ERR
wl0.1|placeholder-single-band
EOF

# A 32-hex SSID spanning two interfaces is AiMesh-internal, never a user
# network — the hex filter must drop it even though it passes the >=2 rule.
fixture hex32-dropped "" <<'EOF'
wl0.0|ERR
wl0.4|0123456789ABCDEF0123456789ABCDEF
wl1.4|0123456789ABCDEF0123456789ABCDEF
EOF

# Nothing resolvable (stock/unsupported layout): must return empty so
# effective_bsslist() can fall back to the fingerprint or the static default.
fixture no-radios "" <<'EOF'
eth1|ERR
eth2|ERR
EOF

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
