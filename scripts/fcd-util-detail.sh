#!/bin/sh
# Show Broadcom CHANIM airtime buckets and the largest current contributor.
# Values are rounded samples and may overlap, so they do not always sum exactly to BUSY.

set -u
LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] || { echo "missing $LIB" >&2; exit 1; }
. "$LIB"

BSSLIST=$(fcd_resolve_bsslist)
[ -n "$BSSLIST" ] || { echo "no Wi-Fi BSS interfaces found" >&2; exit 1; }

val() {
  _v=$(fcd_kv "$1" "$2")
  case "$_v" in ''|*[!0-9]*) printf '?\n';; *) printf '%s\n' "$_v";; esac
}

top_bucket() {
  _best_name=unknown
  _best_value=-1
  shift 0
  while [ "$#" -ge 2 ]; do
    _name=$1; _value=$2; shift 2
    case "$_value" in ''|*[!0-9]*) continue;; esac
    if [ "$_value" -gt "$_best_value" ]; then
      _best_name=$_name
      _best_value=$_value
    fi
  done
  [ "$_best_value" -ge 0 ] && printf '%s=%s%%\n' "$_best_name" "$_best_value" || printf 'unknown\n'
}

printf '%-10s %5s %5s %6s %5s %6s %6s %5s %-13s %s\n' \
  BSS BUSY TX INBSS OBSS NOCAT NOPKT DOZE TOP CAUSE

for B in $BSSLIST; do
  F=$(fcd_chanim_fields "$B")
  BUSY=$(val "$F" busy)
  TX=$(val "$F" tx)
  INBSS=$(val "$F" inbss)
  OBSS=$(val "$F" obss)
  NOCAT=$(val "$F" nocat)
  NOPKT=$(val "$F" nopkt)
  DOZE=$(val "$F" doze)
  TOP=$(top_bucket tx "$TX" inbss "$INBSS" obss "$OBSS" nocat "$NOCAT" nopkt "$NOPKT")
  CAUSE=$(fcd_chanim_cause_from_fields "$F")
  printf '%-10s %4s%% %4s%% %5s%% %4s%% %5s%% %5s%% %4s%% %-13s %s\n' \
    "$B" "$BUSY" "$TX" "$INBSS" "$OBSS" "$NOCAT" "$NOPKT" "$DOZE" "$TOP" "$CAUSE"
  [ "${1:-}" = "--raw" ] && printf '  raw: %s\n' "$F"
done

cat <<'EOF'

Meaning:
  tx     router transmitting
  inbss  clients on your own Wi-Fi
  obss   other Wi-Fi networks on the channel
  nocat  energy Broadcom could not categorize
  nopkt  undecodable/no-valid-packet airtime
  doze   radio sleep time, not congestion

These are rounded Broadcom sampling buckets and can overlap; TOP means the
largest observed bucket, not a guaranteed exact decomposition of BUSY.
EOF
