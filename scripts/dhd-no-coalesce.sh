#!/bin/sh

# Low-latency DHD/RDPA keeper for GT-BE19000AI.
# Broadcom defines int_coalescing_amount=0 as interrupt coalescing disabled.
# Keep timeout=1 in place; with amount=0 the coalescing path is disabled.

sleep 20

for I in 0 1 2; do
    /jffs/bin/bdmf_shell \
        -c init \
        -close \
        -cmd "/Bdmf/Configure dhd_helper/radio_idx=$I int_coalescing_amount=0,int_coalescing_timeout=1" \
        >/dev/null 2>&1
done

# LBR KNOWN-GOOD BEGIN
# Measured winner: LBR length 16, release timeout 1 ms.
for IF in wl1 wl2; do
    dhd -i "$IF" lbr_aggr_release_timeout 1 >/dev/null 2>&1
    dhd -i "$IF" lbr_aggr_len 16 >/dev/null 2>&1
    wl -i "$IF" ampdu_release 64 >/dev/null 2>&1
done
# LBR KNOWN-GOOD END
