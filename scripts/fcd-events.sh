#!/bin/sh
LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] || exit 1
. "$LIB"
[ "$FCD_EVENT_HEAL" = "1" ] || exit 0
EVLOG=/jffs/wifi_wlc.log
[ -f "$EVLOG" ] || exit 0
fcd_mkdirs
LOCK="$FCD_STATE/events.lock"; PIDFILE="$FCD_STATE/events.pid"
if ! mkdir "$LOCK" 2>/dev/null; then
  _p=$(cat "$PIDFILE" 2>/dev/null)
  [ -n "$_p" ] && [ -d "/proc/$_p" ] && exit 0
  rm -rf "$LOCK" 2>/dev/null
  mkdir "$LOCK" 2>/dev/null || exit 1
fi
printf '%s\n' $$ > "$PIDFILE"
FIFO="$FCD_STATE/events.fifo"; TAILPID=
cleanup(){ [ -n "$TAILPID" ] && kill "$TAILPID" 2>/dev/null; rm -f "$FIFO" "$PIDFILE"; rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT INT TERM
rm -f "$FIFO"
mkfifo "$FIFO" 2>/dev/null || mknod "$FIFO" p 2>/dev/null || exit 1
tail -n 0 -F "$EVLOG" > "$FIFO" 2>/dev/null & TAILPID=$!
fcd_log START "event-listener pid=$$"
while IFS= read -r _line; do
  _type=
  case "$_line" in
    *": Assoc "*Successful*) _type=assoc;;
    *": ReAssoc "*Successful*) _type=reassoc;;
    *": Deauth_ind "*) _type=deauth;;
    *": Disassoc "*) _type=disassoc;;
  esac
  [ -n "$_type" ] || continue
  _bss=$(printf '%s\n' "$_line" | awk -F': ' '{print $2}')
  _mac=$(printf '%s\n' "$_line" | grep -oE '([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}' | head -1 | tr 'A-F' 'a-f')
  fcd_valid_mac "$_mac" || continue
  printf '%s|%s|%s|%s\n' "$(fcd_now)" "$_type" "$_mac" "$_bss" >> "$FCD_EVENT_QUEUE"
done < "$FIFO"
