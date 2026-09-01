#!/bin/sh
# Reversible GT-BE19000AI range A/B for Broadcom ACPHY interference mitigation.
# Changes only runtime interference_override on wl1/wl2.
# No channel change, radio restart, MLO change, FlowCache flush, or persistence.
#
# Current production mode observed on this router: 75 = 1+2+8+64
#   1  glitch-based receiver desense
#   2  HW-ACI packet-gain limiting
#   8  preemption
#   64 OBSS detection/mitigation
# `nodesense` uses 74, preserving everything except bit 1.

set -u
STATE=/tmp/fcd-range-desense.state
RADIOS="wl1 wl2"

get_override()
{
    wl -i "$1" interference_override 2>/dev/null |
      sed -n 's/^Mode = \(-\{0,1\}[0-9][0-9]*\).*/\1/p' | head -n1
}

show()
{
    for IF in $RADIOS; do
        echo "=== $IF ==="
        wl -i "$IF" interference 2>&1
        wl -i "$IF" interference_override 2>&1
        printf 'rxiq: '
        wl -i "$IF" phy_rxiqest 2>&1
    done
}

save_once()
{
    # Never overwrite the original pre-test state while switching profiles.
    [ -s "$STATE" ] && return 0
    TMP="$STATE.$$"
    : > "$TMP" || exit 1
    for IF in $RADIOS; do
        V="$(get_override "$IF")"
        case "$V" in ''|*[!0-9-]*) rm -f "$TMP"; echo "ERROR: cannot read $IF override" >&2; exit 1;; esac
        printf '%s %s\n' "$IF" "$V" >> "$TMP"
    done
    mv "$TMP" "$STATE"
}

apply_mode()
{
    MODE="$1"
    LABEL="$2"
    save_once
    for IF in $RADIOS; do
        wl -i "$IF" interference_override "$MODE" >/dev/null 2>&1 || {
            echo "ERROR: $IF rejected override $MODE; restoring original state" >&2
            "$0" restore >/dev/null 2>&1 || true
            exit 1
        }
    done
    for IF in $RADIOS; do
        V="$(get_override "$IF")"
        [ "$V" = "$MODE" ] || {
            echo "ERROR: verification failed on $IF; restoring original state" >&2
            "$0" restore >/dev/null 2>&1 || true
            exit 1
        }
    done
    echo "APPLIED: $LABEL (interference_override=$MODE) on wl1/wl2"
    echo "Runtime only; no restart and no persistent setting was written."
    show
}

restore()
{
    [ -s "$STATE" ] || { echo "ERROR: no saved state at $STATE" >&2; exit 1; }
    while read IF V; do
        [ -n "${IF:-}" ] || continue
        wl -i "$IF" interference_override "$V" >/dev/null 2>&1 || {
            echo "ERROR: failed restoring $IF to $V" >&2
            exit 1
        }
    done < "$STATE"
    rm -f "$STATE"
    echo "RESTORED: original interference overrides"
    show
}

case "${1:-status}" in
    status) show ;;
    test|off) apply_mode 0 "ALL MITIGATION OFF" ;;
    nodesense) apply_mode 74 "DESENSE OFF; HW-ACI/PREEMPTION/OBSS KEPT" ;;
    restore) restore ;;
    *) echo "usage: $0 status|test|nodesense|restore" >&2; exit 1 ;;
esac
