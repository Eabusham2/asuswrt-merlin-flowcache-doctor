#!/bin/sh
# Reversible GT-BE19000AI range A/B for Broadcom ACPHY interference mitigation.
# The current mode can enable glitch-based RX desense / packet-gain limiting.
# This script changes only the runtime interference_override on wl1/wl2.
# No channel change, radio restart, MLO change, FlowCache flush, or persistence.

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

save()
{
    : > "$STATE" || exit 1
    for IF in $RADIOS; do
        V="$(get_override "$IF")"
        case "$V" in ''|*[!0-9-]*) rm -f "$STATE"; echo "ERROR: cannot read $IF override" >&2; exit 1;; esac
        printf '%s %s\n' "$IF" "$V" >> "$STATE"
    done
}

apply_zero()
{
    save
    for IF in $RADIOS; do
        wl -i "$IF" interference_override 0 >/dev/null 2>&1 || {
            echo "ERROR: $IF rejected override 0; restoring" >&2
            "$0" restore >/dev/null 2>&1 || true
            exit 1
        }
    done
    for IF in $RADIOS; do
        V="$(get_override "$IF")"
        [ "$V" = 0 ] || {
            echo "ERROR: verification failed on $IF; restoring" >&2
            "$0" restore >/dev/null 2>&1 || true
            exit 1
        }
    done
    echo "APPLIED: interference mitigation override=0 on wl1/wl2"
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
    test|off) apply_zero ;;
    restore) restore ;;
    *) echo "usage: $0 status|test|restore" >&2; exit 1 ;;
esac
