#!/bin/sh
# GT-BE19000AI / BCM6813 WFD RX interrupt-coalescing A/B controller.
# Uses Broadcom BDMF read-modify-write on existing WLAN CPU RX queues.
# No Wi-Fi restart, no Runner/WFD disable, no queue resize, no IRQ pinning.
#
# Usage:
#   fcd-wfd-coalesce.sh status
#   fcd-wfd-coalesce.sh lowlat     # 100 us / 1 packet
#   fcd-wfd-coalesce.sh restore    # restore snapshot taken by lowlat
#   fcd-wfd-coalesce.sh stock      # source default 500 us / 32 packets

set -u

BDMF=/jffs/bin/bdmf_shell
SIDFILE=/var/bdmf_sh_id
BACKUP=/tmp/fcd-wfd-coalesce.backup
LOWLAT_TIMEOUT=100
LOWLAT_PKTS=1
STOCK_TIMEOUT=500
STOCK_PKTS=32
# BCM6813: rdpa_cpu_wlan0/1/2 = cpu4/5/6. WFD uses qid 0/1 per radio.
CPUS="4 5 6"
QUEUES="0 1"

fail() { echo "ERROR: $*" >&2; exit 1; }

new_bdmf()
{
    [ -x "$BDMF" ] || return 1
    OUT="$($BDMF -c init 2>/dev/null || true)"
    SID="$(printf '%s\n' "$OUT" | awk '
        /Session/ {
            for (i=1; i<=NF; i++) if ($i ~ /^[0-9]+$/) id=$i
        }
        END { if (id != "") print id }')"
    [ -n "$SID" ] || return 1
    printf '%s\n' "$SID" > "$SIDFILE"
}

ensure_bdmf()
{
    if [ -s "$SIDFILE" ]; then
        SID="$(cat "$SIDFILE" 2>/dev/null)"
        "$BDMF" -c "$SID" -cmd "/Bdmf/types" >/dev/null 2>&1 && return 0
    fi
    rm -f "$SIDFILE"
    new_bdmf
}

bs()
{
    ensure_bdmf || return 1
    SID="$(cat "$SIDFILE")"
    "$BDMF" -c "$SID" -cmd "$@" && return 0
    rm -f "$SIDFILE"
    new_bdmf || return 1
    "$BDMF" -c "$(cat "$SIDFILE")" -cmd "$@"
}

cpu_obj()
{
    case "$1" in
        4) echo "cpu/index=wlan0" ;;
        5) echo "cpu/index=wlan1" ;;
        6) echo "cpu/index=wlan2" ;;
        *) echo "cpu/index=$1" ;;
    esac
}

read_q()
{
    CPU="$1" Q="$2"
    OBJ="$(cpu_obj "$CPU")"
    OUT="$(bs /Bdmf/e "$OBJ" "rxq_cfg[$Q]" format:input 2>/dev/null || true)"
    # Some SDKs accept the numeric discriminator but not the enum name.
    if ! printf '%s\n' "$OUT" | grep -q "rxq_cfg\[$Q\]"; then
        OUT="$(bs /Bdmf/e "cpu/index=$CPU" "rxq_cfg[$Q]" format:input 2>/dev/null || true)"
    fi
    printf '%s\n' "$OUT"
}

field()
{
    KEY="$1"
    sed -n "s/.*${KEY}=\([^,}]*\).*/\1/p" | tail -n 1 | tr -d '[:space:]'
}

active_q()
{
    CFG="$1"
    SZ="$(printf '%s\n' "$CFG" | field size)"
    case "$SZ" in ''|*[!0-9]*) return 1;; esac
    [ "$SZ" -gt 0 ]
}

read_ic()
{
    CFG="$1"
    EN="$(printf '%s\n' "$CFG" | field ic_enable)"
    CNT="$(printf '%s\n' "$CFG" | field ic_max_pktcnt)"
    TO="$(printf '%s\n' "$CFG" | field ic_timeout_us)"
    [ -n "$EN" ] && [ -n "$CNT" ] && [ -n "$TO" ] || return 1
    printf '%s %s %s\n' "$EN" "$CNT" "$TO"
}

set_ic()
{
    CPU="$1" Q="$2" EN="$3" CNT="$4" TO="$5"
    OBJ="$(cpu_obj "$CPU")"
    VAL="rxq_cfg[$Q]={ic_cfg={ic_enable=$EN,ic_max_pktcnt=$CNT,ic_timeout_us=$TO}}"
    OUT="$(bs /Bdmf/configure "$OBJ" "$VAL" 2>&1)" && return 0
    # Numeric fallback for SDK object-discriminator differences.
    OUT="$(bs /Bdmf/configure "cpu/index=$CPU" "$VAL" 2>&1)" && return 0
    printf '%s\n' "$OUT" >&2
    return 1
}

show_status()
{
    ensure_bdmf || fail "bdmf_shell session unavailable"
    echo "WFD RX coalescing (BCM6813 WLAN CPU ports)"
    FOUND=0
    for CPU in $CPUS; do
        case "$CPU" in 4) RADIO=wl0;; 5) RADIO=wl1;; 6) RADIO=wl2;; esac
        echo "=== $RADIO / cpu$CPU ==="
        for Q in $QUEUES; do
            CFG="$(read_q "$CPU" "$Q")"
            if active_q "$CFG"; then
                IC="$(read_ic "$CFG" 2>/dev/null || true)"
                SZ="$(printf '%s\n' "$CFG" | field size)"
                if [ -n "$IC" ]; then
                    set -- $IC
                    echo "  q$Q size=$SZ ic_enable=$1 packets=$2 timeout_us=$3"
                else
                    echo "  q$Q size=$SZ ic_cfg=UNPARSED"
                    printf '%s\n' "$CFG" | sed 's/^/    /'
                fi
                FOUND=$((FOUND+1))
            else
                echo "  q$Q inactive"
            fi
        done
    done
    [ "$FOUND" -gt 0 ] || fail "no active WFD WLAN RX queues found"
}

backup_current()
{
    TMP="$BACKUP.$$"
    : > "$TMP" || return 1
    FOUND=0
    for CPU in $CPUS; do
        for Q in $QUEUES; do
            CFG="$(read_q "$CPU" "$Q")"
            active_q "$CFG" || continue
            IC="$(read_ic "$CFG" 2>/dev/null || true)"
            [ -n "$IC" ] || { rm -f "$TMP"; return 1; }
            set -- $IC
            printf '%s %s %s %s %s\n' "$CPU" "$Q" "$1" "$2" "$3" >> "$TMP"
            FOUND=$((FOUND+1))
        done
    done
    [ "$FOUND" -gt 0 ] || { rm -f "$TMP"; return 1; }
    mv "$TMP" "$BACKUP"
}

apply_profile()
{
    NAME="$1" EN="$2" CNT="$3" TO="$4"
    case "$CNT" in ''|*[!0-9]*) fail "invalid packet threshold";; esac
    case "$TO" in ''|*[!0-9]*) fail "invalid timeout";; esac
    [ "$CNT" -ge 1 ] && [ "$CNT" -le 63 ] || fail "packet threshold must be 1..63"
    [ "$TO" -ge 100 ] && [ "$TO" -le 1023 ] || fail "timeout must be 100..1023 us"

    CHANGED=0
    for CPU in $CPUS; do
        for Q in $QUEUES; do
            CFG="$(read_q "$CPU" "$Q")"
            active_q "$CFG" || continue
            read_ic "$CFG" >/dev/null 2>&1 || fail "cannot safely parse cpu$CPU q$Q ic_cfg"
            set_ic "$CPU" "$Q" "$EN" "$CNT" "$TO" || fail "BDMF rejected cpu$CPU q$Q update"
            NEW="$(read_q "$CPU" "$Q")"
            IC="$(read_ic "$NEW" 2>/dev/null || true)"
            set -- $IC
            [ "${2:-}" = "$CNT" ] && [ "${3:-}" = "$TO" ] || fail "verification failed on cpu$CPU q$Q"
            CHANGED=$((CHANGED+1))
        done
    done
    [ "$CHANGED" -gt 0 ] || fail "no active WFD queues changed"
    echo "APPLIED: $NAME on $CHANGED active WFD RX queues"
    echo "Runner/WFD remain enabled; no radio restart performed."
}

restore_backup()
{
    [ -s "$BACKUP" ] || fail "no saved pre-test snapshot at $BACKUP"
    while read CPU Q EN CNT TO; do
        [ -n "$CPU" ] || continue
        set_ic "$CPU" "$Q" "$EN" "$CNT" "$TO" || fail "restore failed on cpu$CPU q$Q"
    done < "$BACKUP"
    echo "RESTORED: saved pre-test WFD coalescing values"
    show_status
}

case "${1:-status}" in
    status)
        show_status
        ;;
    lowlat)
        backup_current || fail "could not safely snapshot every active queue; nothing changed"
        echo "snapshot: $BACKUP"
        apply_profile "LOWLAT" yes "$LOWLAT_PKTS" "$LOWLAT_TIMEOUT"
        show_status
        ;;
    restore)
        restore_backup
        ;;
    stock)
        apply_profile "SOURCE-STOCK" yes "$STOCK_PKTS" "$STOCK_TIMEOUT"
        show_status
        ;;
    *)
        echo "usage: $0 status|lowlat|restore|stock" >&2
        exit 1
        ;;
esac
