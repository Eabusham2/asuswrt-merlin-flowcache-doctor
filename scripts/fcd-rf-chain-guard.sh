#!/bin/sh
# GT-BE19000AI 5/6 GHz RF chain guard.
# The model is 4x4 on 5 GHz and 6 GHz. This script only attempts a runtime
# repair if txchain/rxchain are readable and clearly not all four chains.
# It never changes regulatory/AFC power, country, boarddata, channels, MLO,
# or restarts wireless.

set -u

EXPECTED=0xf
RADIOS="wl1 wl2"

normalize_mask() {
    # Broadcom wl on this platform may print masks as "(0xf)".
    printf '%s\n' "$1" | tr -d '()[:space:]'
}

mask_ok() {
    _m=$(normalize_mask "$1")
    case "$_m" in
        15|0xf|0Xf|0x0f|0X0F) return 0 ;;
        *) return 1 ;;
    esac
}

mask_known() {
    _m=$(normalize_mask "$1")
    case "$_m" in
        0|1|2|3|4|5|6|7|8|9|10|11|12|13|14|15|0x[0-9A-Fa-f]*|0X[0-9A-Fa-f]*) return 0 ;;
        *) return 1 ;;
    esac
}

read_mask() {
    _if=$1
    _cmd=$2
    _out=$(wl -i "$_if" "$_cmd" 2>/dev/null | tail -n 1 | tr -d '\r')
    set -- $_out
    eval _v=\${$#:-}
    normalize_mask "${_v:-unknown}"
}

show_power() {
    _if=$1
    echo "  txpwr_target_max:"
    wl -i "$_if" txpwr_target_max 2>/dev/null | sed 's/^/    /'
    echo "  txpwr_adj_est:"
    wl -i "$_if" txpwr_adj_est 2>/dev/null | sed 's/^/    /'
}

RC=0
CHANGED=0

for IF in $RADIOS; do
    echo "=== $IF ==="
    TX=$(read_mask "$IF" txchain)
    RX=$(read_mask "$IF" rxchain)
    echo "  txchain=$TX"
    echo "  rxchain=$RX"
    show_power "$IF"

    if ! mask_known "$TX" || ! mask_known "$RX"; then
        echo "  SAFE-STOP: chain mask unreadable; no change"
        RC=2
        echo
        continue
    fi

    if mask_ok "$TX" && mask_ok "$RX"; then
        echo "  PASS: all four TX/RX chains enabled"
        echo
        continue
    fi

    echo "  FAULT: expected 4x4 mask $EXPECTED"
    echo "  attempting runtime-only chain repair; no radio restart"

    if ! mask_ok "$RX"; then
        wl -i "$IF" rxchain "$EXPECTED" >/tmp/fcd-rf-rx.$$ 2>&1 || true
    fi
    if ! mask_ok "$TX"; then
        wl -i "$IF" txchain "$EXPECTED" >/tmp/fcd-rf-tx.$$ 2>&1 || true
    fi

    NTX=$(read_mask "$IF" txchain)
    NRX=$(read_mask "$IF" rxchain)
    echo "  after: txchain=$NTX rxchain=$NRX"

    if mask_ok "$NTX" && mask_ok "$NRX"; then
        echo "  REPAIRED: all four chains now enabled"
        CHANGED=1
    else
        echo "  NOT REPAIRED LIVE: driver rejected runtime correction"
        [ -s /tmp/fcd-rf-rx.$$ ] && { echo "  rxchain response:"; sed 's/^/    /' /tmp/fcd-rf-rx.$$; }
        [ -s /tmp/fcd-rf-tx.$$ ] && { echo "  txchain response:"; sed 's/^/    /' /tmp/fcd-rf-tx.$$; }
        RC=1
    fi
    rm -f /tmp/fcd-rf-rx.$$ /tmp/fcd-rf-tx.$$
    echo
done

if [ "$CHANGED" -eq 1 ]; then
    echo "RESULT: a software RF-chain mask fault was found and repaired at runtime."
elif [ "$RC" -eq 0 ]; then
    echo "RESULT: 5/6 GHz already have all four TX/RX chains enabled; chain-mask software fault is ruled out."
else
    echo "RESULT: a chain fault may exist but was not safely repairable live; no disruptive action was taken."
fi

exit "$RC"
