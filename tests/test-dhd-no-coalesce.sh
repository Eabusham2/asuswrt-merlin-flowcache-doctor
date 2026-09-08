#!/bin/sh
set -eu

SCRIPT="scripts/dhd-no-coalesce.sh"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 1; }

grep -q 'int_coalescing_amount=0,int_coalescing_timeout=1' "$SCRIPT"
! grep -q 'int_coalescing_amount=64' "$SCRIPT"
grep -q 'lbr_aggr_release_timeout 1' "$SCRIPT"
grep -q 'lbr_aggr_len 16' "$SCRIPT"
grep -q 'ampdu_release 64' "$SCRIPT"

echo "PASS: DHD interrupt coalescing stays disabled while LBR keepers remain intact"
