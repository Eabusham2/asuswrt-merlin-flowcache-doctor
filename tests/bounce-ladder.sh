#!/bin/sh
# tests/bounce-ladder.sh — regression fixtures for the settle/bounce ladder
# arming logic in heal().
#
# heal() is deliberately duplicated in roam-detect.sh and roam-events.sh (both
# daemons share the same /tmp state; see AGENTS.md's heal()-sync rule). That
# duplication is the risk this file exists to cover: every case below runs
# against BOTH copies, extracted verbatim from the shipped scripts, so a fix
# applied to one and forgotten in the other fails here.
#
# `date`, `logger`, `fcctl` and the flush flag are stubbed; the clock is
# driven from a file so bounce windows are exact and the suite is instant.
#
# Run from the repo root:  sh tests/bounce-ladder.sh
# Runs on macOS and on the router. Exits non-zero if any fixture regresses.

pass=0; fail=0

T=${TMPDIR:-/tmp}/roam-bounce.$$
mkdir -p "$T/bin" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

cat > "$T/bin/date" <<'STUB'
#!/bin/sh
[ "$1" = "+%s" ] && { cat "$RD_NOW"; exit 0; }
exit 1
STUB
cat > "$T/bin/logger" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$T/bin/fcctl" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod 755 "$T/bin"/*
PATH="$T/bin:$PATH"; export PATH
RD_NOW="$T/now"; export RD_NOW

# Load heal() verbatim from a shipped script (the daemons run an infinite
# loop at the bottom, so they cannot simply be sourced).
load_heal() {
  sed -n '/^heal() {/,/^}/p' "$1" > "$T/heal.sh"
  [ -s "$T/heal.sh" ] || { echo "ERROR: could not extract heal() from $1" >&2; exit 1; }
  . "$T/heal.sh"
}

reset() {
  rm -rf "$T/state"; mkdir -p "$T/state"
  STATE="$T/state"
  FLUSHFLAG="$T/flushon"; : > "$FLUSHFLAG"
  TAG=test
  COOLDOWN=60; MIN_GAP=8
  SETTLE_FLUSHES="20 60 300 600"
  BOUNCE_FLUSHES="10 20 60 300 600"
  echo 1000 > "$RD_NOW"
}

at() { echo "$1" > "$RD_NOW"; }

# Rung list currently armed for a mac (field 4 of mac|base|bss|rungs).
rungs_of() { awk -F'|' '{print $4}' "$STATE/$(echo "$1" | tr -d :).settle" 2>/dev/null; }

check() { # $1 = label, $2 = expected, $3 = actual
  if [ "$2" = "$3" ]; then
    pass=$((pass + 1)); printf 'PASS  %-34s -> %s\n' "$1" "$3"
  else
    fail=$((fail + 1)); printf 'FAIL  %-34s -> got [%s] want [%s]\n' "$1" "$3" "$2"
  fi
}

MAC=aa:bb:cc:dd:ee:ff

for script in scripts/roam-detect.sh scripts/roam-events.sh; do
  [ -f "$script" ] || { echo "ERROR: $script not found — run from the repo root" >&2; exit 1; }
  echo
  echo "heal() from $script"
  echo
  load_heal "$script"

  # A first heal, with no ladder running, arms the ordinary settle rungs.
  reset
  heal "$MAC" "roam" wl1.1
  check "cold-arm" "20 60 300 600" "$(rungs_of $MAC)"

  # The incident this change is for: the client hops to a different radio
  # while the previous heal's ladder is still running. Compressed rungs.
  reset
  heal "$MAC" "roam" wl2.1
  at 1031; heal "$MAC" "stale-radio deauth" wl1.1 force
  check "bounce-different-radio" "10 20 60 300 600" "$(rungs_of $MAC)"

  # stale-fdb on ONE radio is not a bounce — a forwarding-table correction
  # on a client that never moved. The flush rate for these must not change.
  reset
  heal "$MAC" "roam" wl1.1
  at 1031; heal "$MAC" "stale-fdb port 3" wl1.1 force
  check "same-radio-stale-fdb-not-bounce" "20 60 300 600" "$(rungs_of $MAC)"

  # ...and the deferred form carries the original reason as a suffix, so it
  # must classify the same way.
  reset
  heal "$MAC" "roam" wl1.1
  at 1031; heal "$MAC" "deferred: stale-fdb port 3" wl1.1 force
  check "deferred-stale-fdb-not-bounce" "20 60 300 600" "$(rungs_of $MAC)"

  # The 2026-08-19 15:35 regression: the client roamed wl2.1 -> wl1.1, but
  # BOTH heals named wl1.1 as current, so the radio-change tell alone missed
  # it and recovery ran the full 20 s. A transition trigger re-arming a live
  # ladder must compress even when the radio matches.
  reset
  heal "$MAC" "event assoc on wl1.1" wl1.1
  at 1031; heal "$MAC" "stale-radio deauth on wl2.1 (client on wl1.1)" wl1.1 force
  check "same-radio-transition-compresses" "10 20 60 300 600" "$(rungs_of $MAC)"

  # Other transition classes re-arming a live ladder compress too.
  reset
  heal "$MAC" "roam wl2.1->wl1.1" wl1.1
  at 1031; heal "$MAC" "dual-settle on wl1.1" wl1.1 force
  check "same-radio-dual-settle-compresses" "10 20 60 300 600" "$(rungs_of $MAC)"

  # A transition with no ladder running is a fresh incident, not a bounce.
  reset
  heal "$MAC" "event assoc on wl1.1" wl1.1
  rm -f "$STATE/$(echo $MAC | tr -d :).settle"
  at 1031; heal "$MAC" "stale-radio deauth on wl2.1 (client on wl1.1)" wl1.1 force
  check "transition-no-ladder-not-bounce" "20 60 300 600" "$(rungs_of $MAC)"

  # Ladder already drained (marker gone): a later hop is a fresh incident,
  # not a bounce, and must not inherit compressed rungs.
  reset
  heal "$MAC" "roam" wl2.1
  rm -f "$STATE/$(echo $MAC | tr -d :).settle"
  at 1031; heal "$MAC" "roam" wl1.1 force
  check "drained-ladder-not-bounce" "20 60 300 600" "$(rungs_of $MAC)"

  # Opt-out: BOUNCE_FLUSHES="" falls back to the ordinary ladder.
  reset
  BOUNCE_FLUSHES=""
  heal "$MAC" "roam" wl2.1
  at 1031; heal "$MAC" "roam" wl1.1 force
  check "bounce-disabled-falls-back" "20 60 300 600" "$(rungs_of $MAC)"

  # A bounce re-bases the ladder on the new heal, so the first rung is
  # measured from the LAST hop — the whole point of the change.
  reset
  heal "$MAC" "roam" wl2.1
  at 1031; heal "$MAC" "roam" wl1.1 force
  check "bounce-rebases-to-last-hop" "1031|wl1.1" \
    "$(awk -F'|' '{print $2"|"$3}' "$STATE/$(echo $MAC | tr -d :).settle")"

  # Ladders are per-client: one client bouncing must not compress another's.
  reset
  OTHER=11:22:33:44:55:66
  heal "$MAC" "roam" wl2.1
  heal "$OTHER" "roam" wl1.1
  at 1031; heal "$MAC" "roam" wl1.1 force
  check "other-client-unaffected" "20 60 300 600" "$(rungs_of $OTHER)"

  # With auto-flush off nothing is armed at all (no marker to drain).
  reset
  rm -f "$FLUSHFLAG"
  heal "$MAC" "roam" wl1.1
  check "no-arm-when-flush-off" "" "$(rungs_of $MAC)"
done

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
