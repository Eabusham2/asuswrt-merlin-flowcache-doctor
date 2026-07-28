#!/bin/sh
# roam-lib.sh — flowcache-doctor shared helpers (sourced, never executed).
#
# Home of the BSSLIST=auto resolver, used by both daemons (startup), the
# cron watchdog (drift detection), and roamctl health. Keep this file plain
# busybox sh with no side effects at source time beyond variable/function
# definitions — everything sources it.
#
# Resolution pipeline (field-validated on an RT-BE92U router and both of a
# tester's AiMesh nodes — see GitHub issue #2):
#   1. enumerate br0 bridge members, minus wds* (VLANed guest networks live
#      in other bridges and are deliberately out of scope)
#   2. ask each member its SSID — the PROBE decides what is a radio, never
#      the name. Switch ports, bonds and VLAN members error out of `wl`, as
#      do radio primaries (wlX.0) and BE-class AiMesh backhaul VAPs
#      (wlX.1.0), which thereby SELF-EXCLUDE.
#
#      Interface naming is NOT portable and must never be pattern-matched:
#      BE-class exposes radios as wlX.Y, but AX-class models expose them as
#      ethX (field data, issue #5) — and it is per model, not per class: an
#      RT-AX3000 node is wl-named while an RT-AX88U Pro is eth-named. The
#      original wl*-only filter was silently blind on every eth-named unit.
#
#      wds* is the ONE name-based exclusion, and it is load-bearing: AX-class
#      WDS backhaul interfaces answer with the REAL main SSID rather than
#      erroring, so the probe cannot distinguish them. Left in, they join the
#      main SSID's group and the doctor watches — and flushes against — the
#      mesh backhaul. (wds is a stable kernel prefix, unlike radio naming.)
#   3. group interfaces by SSID
#   4. keep SSIDs spanning >=2 interfaces — the roamability criterion (a
#      single-band network cannot band-roam); also drops AiMesh onboarding
#      singletons
#   5. drop 32-hex-char SSIDs (AiMesh-internal naming) — belt-and-suspenders
#   6. sorted, space-separated, stable output for fingerprint comparison

RD_STATE_DIR=/tmp/roam-detect
RD_FPRINT=$RD_STATE_DIR/bsslist

# Bridge-member directory. Overridable ONLY so tests/resolver-fixtures.sh can
# point the resolver at captured hardware layouts; always the real path in
# production (nothing in the addon ever sets it).
RD_BRIF=${RD_BRIF:-/sys/class/net/br0/brif}

resolve_bsslist() {
  for _b in $(ls "$RD_BRIF" 2>/dev/null | grep -v '^wds'); do
    _s=$(wl -i "$_b" ssid 2>/dev/null | sed 's/Current SSID: //;s/"//g')
    [ -n "$_s" ] && echo "$_s|$_b"
  done | awk -F'|' '
    { n[$1]++; ifs[$1] = ifs[$1] " " $2 }
    END { for (s in n) if (n[s] >= 2 && s !~ /^[0-9A-F]{32}$/) printf "%s", ifs[s] }
  ' | tr ' ' '\n' | grep . | sort | tr '\n' ' ' | sed 's/ $//'
}

# Effective BSSLIST honoring the conf value ($1): an explicit list passes
# through untouched (full back-compat); "auto" resolves live, falling back
# to the last fingerprint (the live resolution can be empty mid
# restart_wireless), else the classic static default.
effective_bsslist() {
  if [ "$1" != "auto" ]; then echo "$1"; return; fi
  _r=$(resolve_bsslist)
  if [ -n "$_r" ]; then echo "$_r"; return; fi
  if [ -s "$RD_FPRINT" ]; then cat "$RD_FPRINT"; return; fi
  echo "wl0.1 wl1.1 wl2.1"
}

# Atomic fingerprint write (temp + mv): the watchdog compares against this
# while the daemons run — a torn read must be impossible.
write_bsslist_fingerprint() {
  mkdir -p "$RD_STATE_DIR"
  echo "$1" > "$RD_FPRINT.tmp" && mv "$RD_FPRINT.tmp" "$RD_FPRINT"
}
