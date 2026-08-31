#!/bin/sh
# Passive start/stop flight recorder for transient GT-BE19000AI MLO range faults.
# Usage: fcd-range-flight.sh start <MLD> [interval_s] | stop | status | latest
# Writes only to /tmp. No steering, deauth, queue changes, flushes, or restarts.

set -u

PIDFILE=/tmp/fcd-range-flight.pid
LATEST=/tmp/fcd-range-flight.latest
META=/tmp/fcd-range-flight.meta

valid_mld() {
    printf '%s\n' "$1" | grep -Eq '^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$'
}

alive() {
    [ -n "${1:-}" ] && [ -d "/proc/$1" ]
}

find_mld_sta() {
    _if=$1
    _mld=$2
    for _mac in $(wl -i "$_if" assoclist 2>/dev/null | awk '{print $2}'); do
        _s=$(wl -i "$_if" sta_info "$_mac" 2>/dev/null)
        printf '%s\n' "$_s" | grep -qi "$_mld" || continue
        printf '%s\n' "$_mac"
        return 0
    done
    return 1
}

sta_snapshot() {
    _if=$1
    _mld=$2
    _mac=$(find_mld_sta "$_if" "$_mld" 2>/dev/null || true)
    if [ -z "$_mac" ]; then
        echo "--- $_if MLD NOT PRESENT ---"
        return 0
    fi
    echo "--- $_if $_mac ---"
    wl -i "$_if" sta_info "$_mac" 2>/dev/null |
        grep -E 'STA |aid:|chanspec|idle |state:|connection:|MLO: peer|link_id|rate of last tx|rate of last rx|per antenna rssi of last|per antenna average|smoothed rssi|tx pkts retries|tx pkts retry exhausted|rx total pkts retried|tx nrate|rx nrate|link bandwidth|Max Rate'
}

sample() {
    _mld=$1
    _n=$2
    echo
    echo "========== SAMPLE $_n $(date '+%Y-%m-%d %H:%M:%S %z') =========="

    echo "--- MLO INFO ---"
    wl -i wl2.1 mlo info 2>/dev/null |
        grep -E 'MLO_ACTIVE|MLD1::|link0:|link1:|link2:|MLO SCB:|active_link_map|assoc_link_bmp|Tid Map|Client Mode' |
        grep -Ei "MLO_ACTIVE|MLD1::|link0:|link1:|link2:|${_mld}|Tid Map|Client Mode"

    echo "--- MLO COUNTERS ---"
    wl -i wl2.1 mlo scb_stats "$_mld" 2>/dev/null |
        grep -E 'STA |link_id|tx_pkts_acked|phy_tx_errors|tx_pkts_total|rx_pkts'

    echo "--- CLIENT LINKS ---"
    sta_snapshot wl2.1 "$_mld"
    sta_snapshot wl1.1 "$_mld"
    sta_snapshot wl0.1 "$_mld"

    echo "--- BE FLOWRINGS ---"
    for _r in 1 2; do
        echo "wl$_r:"
        dhd -i "wl$_r" flowring_ids_dump 2>/dev/null |
            awk '$2~/^[0-9]+$/ && ($3==0 || $3==3) && $4!~/^33:33:/ {print $2,$3,tolower($4)}'
    done

    echo "--- DYNBQ ---"
    if [ -x /jffs/dynbq/dynbq-controller.sh ]; then
        /jffs/dynbq/dynbq-controller.sh status 2>/dev/null |
            grep -E '^DynBQ|^wl[012] target=|^wl[012]: seq=' |
            head -n 8
    fi

    if [ $((_n % 5)) -eq 0 ]; then
        echo "--- RUNNER ---"
        fcctl status 2>/dev/null |
            grep -E 'Acceleration Mode|HW Acceleration|Flow Ucast|TCP Ack'
        echo "--- CHANIM ---"
        for _r in 1 2; do
            wl -i "wl$_r" chanim_stats 2>/dev/null | tail -n 1
        done
    fi
}

run_daemon() {
    _mld=$1
    _interval=$2
    _log=$3
    echo $$ > "$PIDFILE"
    printf '%s\n' "$_log" > "$LATEST"
    {
        echo "Flowcache Doctor range flight recorder"
        echo "started: $(date '+%Y-%m-%d %H:%M:%S %z')"
        echo "mld: $_mld"
        echo "interval_s: $_interval"
        echo "note: passive/read-only; output is /tmp only"
    } > "$META"
    cleanup() {
        echo >> "$_log"
        echo "========== STOP $(date '+%Y-%m-%d %H:%M:%S %z') ==========" >> "$_log"
        rm -f "$PIDFILE"
    }
    trap 'cleanup; exit 0' INT TERM HUP
    _n=0
    while :; do
        _n=$((_n + 1))
        sample "$_mld" "$_n" >> "$_log" 2>&1
        sleep "$_interval"
    done
}

case "${1:-}" in
    start)
        MLD=${2:-}
        INTERVAL=${3:-2}
        valid_mld "$MLD" || { echo "usage: $0 start <MLD> [interval_s]" >&2; exit 1; }
        case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=2;; esac
        [ "$INTERVAL" -ge 1 ] || INTERVAL=1
        [ "$INTERVAL" -le 10 ] || INTERVAL=10
        OLD=$(cat "$PIDFILE" 2>/dev/null || true)
        if alive "$OLD"; then
            echo "already running pid=$OLD log=$(cat "$LATEST" 2>/dev/null)"
            exit 0
        fi
        STAMP=$(date '+%Y%m%d-%H%M%S')
        LOG="/tmp/fcd-range-flight-$STAMP.log"
        "$0" daemon "$MLD" "$INTERVAL" "$LOG" >/dev/null 2>&1 &
        sleep 1
        P=$(cat "$PIDFILE" 2>/dev/null || true)
        alive "$P" || { echo "failed to start" >&2; exit 1; }
        echo "started pid=$P log=$LOG"
        ;;
    stop)
        P=$(cat "$PIDFILE" 2>/dev/null || true)
        if alive "$P"; then
            kill "$P" 2>/dev/null
            sleep 2
        fi
        P=$(cat "$PIDFILE" 2>/dev/null || true)
        alive "$P" && kill -9 "$P" 2>/dev/null
        rm -f "$PIDFILE"
        echo "stopped log=$(cat "$LATEST" 2>/dev/null || echo none)"
        ;;
    status)
        P=$(cat "$PIDFILE" 2>/dev/null || true)
        if alive "$P"; then
            echo "running pid=$P log=$(cat "$LATEST" 2>/dev/null)"
        else
            echo "stopped log=$(cat "$LATEST" 2>/dev/null || echo none)"
        fi
        ;;
    latest)
        L=$(cat "$LATEST" 2>/dev/null || true)
        [ -n "$L" ] && [ -f "$L" ] || { echo "no flight log"; exit 1; }
        echo "$L"
        ;;
    daemon)
        shift
        run_daemon "$1" "$2" "$3"
        ;;
    *)
        echo "usage: $0 start <MLD> [interval_s] | stop | status | latest"
        exit 1
        ;;
esac
