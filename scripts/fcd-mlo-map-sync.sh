#!/bin/sh
# Keep ASUS userspace MLO metadata aligned with Broadcom's wl_mlo_config roles.
# This changes metadata only. It does not restart Wi-Fi, MLO, hostapd, or the driver.

set -u

usage(){ echo "usage: $0 {status|sync}" >&2; exit 2; }

CONF="$(nvram get wl_mlo_config 2>/dev/null)"
[ -n "$CONF" ] || CONF="$(nvram kget wl_mlo_config 2>/dev/null)"
set -- $CONF
[ "$#" -eq 4 ] || { echo "ERROR: invalid wl_mlo_config: <$CONF>" >&2; exit 1; }

MAP=-1
AAP1=-1
AAP2=-1
UNIT=0
for ROLE in "$@"; do
    case "$ROLE" in
        0) MAP=$UNIT ;;
        1) AAP1=$UNIT ;;
        2) AAP2=$UNIT ;;
        -1) : ;;
        *) echo "ERROR: invalid MLO role $ROLE in <$CONF>" >&2; exit 1 ;;
    esac
    UNIT=$((UNIT + 1))
done

[ "$MAP" -ge 0 ] || { echo "ERROR: no MAP role (0) in <$CONF>" >&2; exit 1; }
[ "$AAP1" -ge 0 ] || { echo "ERROR: no AAP1 role (1) in <$CONF>" >&2; exit 1; }

EXP_MAP="wl$MAP"
EXP_MAP_UNIT="$MAP"
EXP_AAP1="wl$AAP1"
EXP_AAP2=""
[ "$AAP2" -ge 0 ] && EXP_AAP2="wl$AAP2"
EXP_SDN_MAP="${EXP_MAP}.1"

show(){
    echo "wl_mlo_config=$CONF"
    echo "expected: mlo_map=$EXP_MAP mlo_map_unit=$EXP_MAP_UNIT mlo_aap1=$EXP_AAP1 mlo_aap2=${EXP_AAP2:-none} sdn_mlo_map=$EXP_SDN_MAP"
    for K in mlo_map mlo_map_unit mlo_aap1 mlo_aap2 sdn_mlo_map; do
        echo "$K=$(nvram get "$K" 2>/dev/null)"
    done
}

case "${1:-status}" in
    status)
        show
        ;;
    sync)
        CHANGED=0
        set_nv(){
            K=$1; V=$2
            CUR="$(nvram get "$K" 2>/dev/null)"
            [ "$CUR" = "$V" ] && return 0
            nvram set "$K=$V"
            CHANGED=1
        }
        set_nv mlo_map "$EXP_MAP"
        set_nv mlo_map_unit "$EXP_MAP_UNIT"
        set_nv mlo_aap1 "$EXP_AAP1"
        set_nv mlo_aap2 "$EXP_AAP2"
        set_nv sdn_mlo_map "$EXP_SDN_MAP"
        if [ "$CHANGED" -eq 1 ]; then
            nvram commit
            echo "SYNCHRONIZED ASUS MLO metadata to wl_mlo_config roles"
        else
            echo "ASUS MLO metadata already synchronized"
        fi
        show
        ;;
    *) usage ;;
esac
