#!/bin/sh
# Passive incident capture for utilization spikes/high-airtime events.
# It never steers, deauthenticates, restarts Wi-Fi, or calls fcctl.

set -u
LIB=${FCD_LIB:-/jffs/scripts/fcd-lib.sh}
[ -r "$LIB" ] || exit 1
. "$LIB"

EVENT=${1:-MANUAL}
TRIGGER_BSS=${2:-all}
PREVIOUS=${3:-?}
CURRENT=${4:-?}
FCD_INCIDENT_SAMPLES=${FCD_INCIDENT_SAMPLES:-6}
FCD_INCIDENT_SAMPLE_INTERVAL=${FCD_INCIDENT_SAMPLE_INTERVAL:-2}
FCD_INCIDENT_COOLDOWN=${FCD_INCIDENT_COOLDOWN:-120}
FCD_PROBE_IP=${FCD_PROBE_IP:-1.1.1.1}

safe_name() { printf '%s\n' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
num_or_zero() { fcd_num "$1" && printf '%s\n' "$1" || printf '0\n'; }

BSSLIST=$(fcd_resolve_bsslist)
[ -n "$BSSLIST" ] || exit 0
fcd_mkdirs
INCROOT="$FCD_ROOT/incidents"
LOCKROOT="$FCD_STATE/incident-locks"
mkdir -p "$INCROOT" "$LOCKROOT"

KEY=$(safe_name "$TRIGGER_BSS")
LOCK="$LOCKROOT/$KEY"
mkdir "$LOCK" 2>/dev/null || exit 0
cleanup(){ rmdir "$LOCK" 2>/dev/null; }
trap cleanup EXIT INT TERM

NOW=$(fcd_now)
LASTFILE="$FCD_STATE/incident-last.$KEY"
LAST=0
[ -f "$LASTFILE" ] && LAST=$(cat "$LASTFILE" 2>/dev/null)
fcd_num "$LAST" || LAST=0
[ $((NOW - LAST)) -ge "$FCD_INCIDENT_COOLDOWN" ] || exit 0
printf '%s\n' "$NOW" > "$LASTFILE"

STAMP=$(date '+%Y%m%d-%H%M%S')
EVENTKEY=$(safe_name "$EVENT")
DIR="$INCROOT/${STAMP}-${EVENTKEY}-${KEY}"
mkdir -p "$DIR"
CHANIM="$DIR/chanim.tsv"
CLIENTS="$DIR/clients.tsv"
SUMMARY="$DIR/summary.txt"
RAW="$DIR/raw.txt"
: > "$CHANIM"; : > "$CLIENTS"; : > "$RAW"

{
  echo "event=$EVENT"
  echo "trigger_bss=$TRIGGER_BSS"
  echo "previous_util=$PREVIOUS"
  echo "current_util=$CURRENT"
  echo "started=$(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "firmware=$(nvram get firmver 2>/dev/null).$(nvram get buildno 2>/dev/null)_$(nvram get extendno 2>/dev/null)"
  echo "productid=$(nvram get productid 2>/dev/null)"
  echo "uptime=$(uptime 2>/dev/null)"
  echo "bsslist=$BSSLIST"
  echo "nvram_bytes=$(nvram show 2>/dev/null | wc -c | tr -d ' ')"
  echo "smart_connect=$(nvram get smart_connect_x 2>/dev/null)"
  echo "mlo=$(nvram get mld_enable 2>/dev/null)"
  echo "probe_ip=$FCD_PROBE_IP"
} > "$DIR/meta.txt"

{
  echo "=== PROCESS SNAPSHOT ==="
  ps 2>/dev/null | grep -Ei 'airiq|acsd|bsd|dhd|wl|stubby|dnsmasq|docker|adguard' | grep -v grep
  echo
  echo "=== ROUTES ==="
  ip route 2>/dev/null
  echo
  echo "=== BRIDGE FDB ==="
  brctl showmacs br0 2>/dev/null
  echo
  echo "=== FLOW CACHE ==="
  fcctl status 2>/dev/null
  echo
  echo "=== RECENT WIRELESS/KERNEL EVENTS ==="
  dmesg 2>/dev/null | grep -Ei 'dhd|wlc|wl[0-9]|pktfwd|scb|fatal|trap|assert|watchdog|chanim|acs|airiq' | tail -n 300
  echo
  echo "=== RECENT SYSLOG ==="
  tail -n 400 /tmp/syslog.log 2>/dev/null | grep -Ei 'dhd|wlc|wireless|wifi|pktfwd|scb|fatal|trap|assert|watchdog|chanim|acs|airiq|dns|wan'
} >> "$RAW"

WAN_GW=$(nvram get wan0_gateway 2>/dev/null)
[ -n "$WAN_GW" ] || WAN_GW=$(nvram get wan_gateway 2>/dev/null)
PING_WAN=unsupported
PING_PUBLIC=unsupported
if command -v ping >/dev/null 2>&1; then
  [ -n "$WAN_GW" ] && { ping -c 1 -W 2 "$WAN_GW" >/dev/null 2>&1 && PING_WAN=ok || PING_WAN=fail; }
  ping -c 1 -W 2 "$FCD_PROBE_IP" >/dev/null 2>&1 && PING_PUBLIC=ok || PING_PUBLIC=fail
fi

DNS_SERVER=
for V in dhcp_dns1_x lan_dns1_x dhcp_dns2_x lan_dns2_x; do
  D=$(nvram get "$V" 2>/dev/null)
  case "$D" in
    ''|0.0.0.0) :;;
    *.*.*.*) DNS_SERVER=$D; break;;
  esac
done
DNS_PROBE=unsupported
if [ -n "$DNS_SERVER" ] && command -v nslookup >/dev/null 2>&1; then
  nslookup example.com "$DNS_SERVER" > "$DIR/dns-probe.txt" 2>&1 && DNS_PROBE=ok || DNS_PROBE=fail
fi

SAMPLE=1
while [ "$SAMPLE" -le "$FCD_INCIDENT_SAMPLES" ]; do
  EPOCH=$(fcd_now)
  {
    echo
    echo "===== SAMPLE $SAMPLE $(date '+%Y-%m-%d %H:%M:%S %z') ====="
  } >> "$RAW"

  for B in $BSSLIST; do
    FIELDS=$(fcd_chanim_fields "$B")
    CHSPEC=$(fcd_kv "$FIELDS" chspec)
    TX=$(fcd_kv "$FIELDS" tx); INBSS=$(fcd_kv "$FIELDS" inbss); OBSS=$(fcd_kv "$FIELDS" obss)
    NOCAT=$(fcd_kv "$FIELDS" nocat); NOPKT=$(fcd_kv "$FIELDS" nopkt); DOZE=$(fcd_kv "$FIELDS" doze)
    TXOP=$(fcd_kv "$FIELDS" txop); GOODTX=$(fcd_kv "$FIELDS" goodtx); BADTX=$(fcd_kv "$FIELDS" badtx)
    GLITCH=$(fcd_kv "$FIELDS" glitch); BADPLCP=$(fcd_kv "$FIELDS" badplcp); KNOISE=$(fcd_kv "$FIELDS" knoise)
    IDLE=$(fcd_kv "$FIELDS" idle); BUSY=$(fcd_kv "$FIELDS" busy); TS=$(fcd_kv "$FIELDS" timestamp)
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
      "$SAMPLE" "$EPOCH" "$B" "${CHSPEC:-?}" "${TX:-?}" "${INBSS:-?}" "${OBSS:-?}" \
      "${NOCAT:-?}" "${NOPKT:-?}" "${DOZE:-?}" "${TXOP:-?}" "${GOODTX:-?}" \
      "${BADTX:-?}" "${GLITCH:-?}" "${BADPLCP:-?}" "${KNOISE:-?}" "${IDLE:-?}" \
      "${BUSY:-?}" "${TS:-?}" >> "$CHANIM"

    {
      echo "--- $B chanim_stats ---"
      wl -i "$B" chanim_stats 2>&1
      echo "--- $B counters selected ---"
      wl -i "$B" counters 2>&1 | grep -Ei 'txbcn|beacon|txfail|txerror|rxerror|retry|reinit|reset|dma|watchdog|fatal|glitch|badplcp'
      echo "--- $B assoclist ---"
      wl -i "$B" assoclist 2>&1
    } >> "$RAW"

    for M in $(wl -i "$B" assoclist 2>/dev/null | awk '{print tolower($2)}'); do
      fcd_valid_mac "$M" || continue
      SI=$(wl -i "$B" sta_info "$M" 2>/dev/null)
      CLASS=$(fcd_classify "$M" "$B" "$BSSLIST")
      RSSI=$(printf '%s\n' "$SI" | awk '/smoothed rssi:/ {print $NF; exit}')
      SENT=$(printf '%s\n' "$SI" | awk '/tx total pkts sent:/ {print $NF; exit}')
      RETRIES=$(printf '%s\n' "$SI" | awk '/tx pkts retries:/ {print $NF; exit}')
      EXHAUSTED=$(printf '%s\n' "$SI" | awk '/tx pkts retry exhausted:/ {print $NF; exit}')
      FAILURES=$(printf '%s\n' "$SI" | awk '/tx failures:/ {print $NF; exit}')
      TXRATE=$(printf '%s\n' "$SI" | awk '/rate of last tx pkt:/ {for(i=1;i<NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="kbps"){print $i; exit}}')
      RXRATE=$(printf '%s\n' "$SI" | awk '/rate of last rx pkt:/ {for(i=1;i<NF;i++) if($i ~ /^[0-9]+$/ && $(i+1)=="kbps"){print $i; exit}}')
      printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$SAMPLE" "$EPOCH" "$B" "$M" "$CLASS" "${RSSI:-?}" "${SENT:-?}" \
        "${RETRIES:-?}" "${EXHAUSTED:-?}" "${FAILURES:-?}" "${TXRATE:-?}" "${RXRATE:-?}" >> "$CLIENTS"
    done
  done

  [ "$SAMPLE" -lt "$FCD_INCIDENT_SAMPLES" ] && sleep "$FCD_INCIDENT_SAMPLE_INTERVAL"
  SAMPLE=$((SAMPLE + 1))
done

LASTSAMPLE=$FCD_INCIDENT_SAMPLES
TRIGGER_FIRST=$(awk -F'|' -v b="$TRIGGER_BSS" '$1==1 && ($3==b || b=="all"){print; exit}' "$CHANIM")
TRIGGER_LAST=$(awk -F'|' -v s="$LASTSAMPLE" -v b="$TRIGGER_BSS" '$1==s && ($3==b || b=="all"){print; exit}' "$CHANIM")
FIRST_CHSPEC=$(printf '%s\n' "$TRIGGER_FIRST" | awk -F'|' '{print $4}')
LAST_CHSPEC=$(printf '%s\n' "$TRIGGER_LAST" | awk -F'|' '{print $4}')
CHANNEL_CHANGED=no
[ -n "$FIRST_CHSPEC" ] && [ -n "$LAST_CHSPEC" ] && [ "$FIRST_CHSPEC" != "$LAST_CHSPEC" ] && CHANNEL_CHANGED=yes

LAST_FIELDS=$(printf '%s\n' "$TRIGGER_LAST" | awk -F'|' 'NF>=19 {
  printf "chspec=%s tx=%s inbss=%s obss=%s nocat=%s nopkt=%s doze=%s txop=%s goodtx=%s badtx=%s glitch=%s badplcp=%s knoise=%s idle=%s busy=%s timestamp=%s",
  $4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19
}')
CAUSE=$(fcd_chanim_cause_from_fields "$LAST_FIELDS")

HIGH_BANDS=$(awk -F'|' -v s="$LASTSAMPLE" -v h="$FCD_UTIL_HIGH" '$1==s && $18 ~ /^[0-9]+$/ && $18>=h{n++} END{print n+0}' "$CHANIM")
CROSS_BAND=no
[ "$HIGH_BANDS" -ge 2 ] && CROSS_BAND=yes

awk -F'|' '
  {
    k=$3 "|" $4
    sent=$7; retry=$8; exhausted=$9; fail=$10
    if(sent !~ /^[0-9]+$/) sent=0
    if(retry !~ /^[0-9]+$/) retry=0
    if(exhausted !~ /^[0-9]+$/) exhausted=0
    if(fail !~ /^[0-9]+$/) fail=0
    if(!(k in seen)){
      seen[k]=1; fbss[k]=$3; fmac[k]=$4; fclass[k]=$5; frssi[k]=$6
      fsent[k]=sent; fretry[k]=retry; fexh[k]=exhausted; ffail[k]=fail
    }
    lbss[k]=$3; lmac[k]=$4; lclass[k]=$5; lrssi[k]=$6
    lsent[k]=sent; lretry[k]=retry; lexh[k]=exhausted; lfail[k]=fail
  }
  END {
    for(k in seen){
      ds=lsent[k]-fsent[k]; dr=lretry[k]-fretry[k]; de=lexh[k]-fexh[k]; df=lfail[k]-ffail[k]
      if(ds<0) ds=0; if(dr<0) dr=0; if(de<0) de=0; if(df<0) df=0
      ratio=(ds>0 ? (100.0*dr/ds) : 0)
      printf "%s|%s|%s|%s|%s|%s|%.1f\n", lbss[k],lmac[k],lclass[k],lrssi[k],ds,dr,ratio
    }
  }' "$CLIENTS" | sort -t'|' -k7,7nr > "$DIR/retry-analysis.tsv"

TOP_RETRY=$(head -n 1 "$DIR/retry-analysis.tsv" 2>/dev/null)
TOP_RATIO=$(printf '%s\n' "$TOP_RETRY" | awk -F'|' '{print $7+0}')
TOP_MAC=$(printf '%s\n' "$TOP_RETRY" | awk -F'|' '{print $2}')
TOP_BSS=$(printf '%s\n' "$TOP_RETRY" | awk -F'|' '{print $1}')
RETRY_STORM=no
awk -v r="$TOP_RATIO" 'BEGIN{exit !(r>=50)}' && RETRY_STORM=yes

RECOMMENDATION=
case "$CAUSE" in
  other-wifi-contention)
    RECOMMENDATION="Likely neighboring Wi-Fi airtime. Use WiFi Insight at this timestamp to choose a quieter channel; on 2.4 GHz keep 20 MHz and channels 1, 6, or 11."
    ;;
  nonwifi-or-undecodable-energy)
    RECOMMENDATION="Likely non-Wi-Fi or undecodable RF energy. Check WiFi Insight's non-WiFi layer and nearby microwave, USB 3, Bluetooth, camera, or other 2.4 GHz emitters; move affected clients to 5/6 GHz when supported."
    ;;
  local-airtime-or-retries)
    RECOMMENDATION="Likely local airtime or retransmissions. Inspect retry-analysis.tsv; improve the top client's placement or isolate a noisy legacy/IoT client rather than changing every radio."
    ;;
  driver-or-counter-anomaly)
    RECOMMENDATION="Busy airtime is not explained by CHANIM components. Check WiFi Insight/Interference Detect and channel-change events at this timestamp. If repeated, disable Interference Detect for a controlled test; a Broadcom/ASUS firmware fix is the real repair."
    ;;
  mixed-high-airtime)
    RECOMMENDATION="High airtime has mixed sources. Use the raw CHANIM breakdown and retry-analysis.tsv before changing channels or restarting Wi-Fi."
    ;;
  *)
    RECOMMENDATION="Transient or mixed event. Keep monitoring; do not restart or change channels from one sample."
    ;;
esac

if [ "$CROSS_BAND" = yes ]; then
  RECOMMENDATION="$RECOMMENDATION Two or more independent bands were high together, which points more toward an internal scan/driver/telemetry event than one congested RF channel."
fi
if [ "$CHANNEL_CHANGED" = yes ]; then
  RECOMMENDATION="$RECOMMENDATION The channel changed during capture; correlate it with the WiFi Insight event list because ACS/Insight activity may be the trigger."
fi
if [ "$RETRY_STORM" = yes ]; then
  RECOMMENDATION="$RECOMMENDATION A retry storm was measured on $TOP_BSS for client $TOP_MAC (${TOP_RATIO}% retry attempts per newly sent packet during the window)."
fi
if [ "$PING_PUBLIC" = ok ] && [ "$DNS_PROBE" = fail ]; then
  RECOMMENDATION="$RECOMMENDATION Public IP reachability worked while the configured DNS probe failed, so the user-visible outage is DNS-related rather than RF utilization."
fi

{
  echo "Flowcache Doctor utilization incident"
  echo "event: $EVENT"
  echo "trigger: $TRIGGER_BSS ${PREVIOUS}% -> ${CURRENT}%"
  echo "captured: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "samples: $FCD_INCIDENT_SAMPLES every ${FCD_INCIDENT_SAMPLE_INTERVAL}s"
  echo "classification: $CAUSE"
  echo "last_fields: $LAST_FIELDS"
  echo "cross_band_high: $CROSS_BAND ($HIGH_BANDS bands >= ${FCD_UTIL_HIGH}%)"
  echo "channel_changed: $CHANNEL_CHANGED (${FIRST_CHSPEC:-?} -> ${LAST_CHSPEC:-?})"
  echo "wan_gateway_ping: $PING_WAN"
  echo "public_ip_ping: $PING_PUBLIC"
  echo "dns_server: ${DNS_SERVER:-unknown}"
  echo "dns_probe: $DNS_PROBE"
  echo "top_retry: ${TOP_RETRY:-none}"
  echo "recommendation: $RECOMMENDATION"
  echo "raw: $RAW"
  echo "chanim: $CHANIM"
  echo "clients: $CLIENTS"
  echo "retry_analysis: $DIR/retry-analysis.tsv"
} > "$SUMMARY"

fcd_log INCIDENT "event=$EVENT bss=$TRIGGER_BSS cause=$CAUSE cross-band=$CROSS_BAND channel-change=$CHANNEL_CHANGED public-ping=$PING_PUBLIC dns=$DNS_PROBE path=$DIR"
exit 0
