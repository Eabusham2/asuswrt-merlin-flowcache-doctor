#!/bin/sh
set -eu
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export FCD_ROOT="$T/root" FCD_STATE="$T/state" FCD_CONF="$T/none" FCD_LOG_SYSLOG=0
mkdir -p "$T/bin" "$FCD_STATE"
PATH="$T/bin:$PATH"; export PATH
CASE=unknown
cat > "$T/bin/wl" <<'EOS'
#!/bin/sh
case "$CASE:$*" in
  one-mlo:*sta_info*) echo 'phy type: be'; echo 'peer_mld_addr 02:11:22:33:44:55';;
  one-eht:*sta_info*) echo 'phy type: be'; echo 'EHT capable';;
  legacy:*sta_info*) echo 'phy type: ax'; echo 'HE Capable';;
  separate:*mlo*) echo 'MLD 02:00:00:00:00:01 link addr aa:aa:aa:aa:aa:01 link addr aa:aa:aa:aa:aa:02 link addr aa:aa:aa:aa:aa:03';;
  separate:*mlo_status*) echo 'MLD 02:00:00:00:00:01 link addr aa:aa:aa:aa:aa:01 link addr aa:aa:aa:aa:aa:02 link addr aa:aa:aa:aa:aa:03';;
  *) :;;
esac
EOS
chmod +x "$T/bin/wl"
cat > "$T/bin/logger" <<'EOS'
#!/bin/sh
:
EOS
chmod +x "$T/bin/logger"
cat > "$T/bin/fcctl" <<EOS
#!/bin/sh
echo "\$*" >> "$T/fcctl.calls"
EOS
chmod +x "$T/bin/fcctl"
. ./scripts/fcd-lib.sh
fcd_mkdirs
check(){ [ "$1" = "$2" ] || { echo "FAIL $3: got '$1' expected '$2'"; exit 1; }; echo "ok $3"; }

FCD_ASSOC_MAP="$T/map"; export FCD_ASSOC_MAP
printf 'aa:bb:cc:dd:ee:01 wl0\n' > "$T/map"; CASE=one-mlo; export CASE
c=$(fcd_classify aa:bb:cc:dd:ee:01 wl0 'wl0 wl1 wl2'); check "$c" mlo-sta-info one-link-mlo
fcd_observe_class aa:bb:cc:dd:ee:01 "$c" wl0
CASE=legacy; export CASE
check "$(fcd_classify aa:bb:cc:dd:ee:01 wl0 'wl0 wl1 wl2')" mlo-sticky sticky-mlo-protection
printf 'aa:bb:cc:dd:ee:02 wl0\n' > "$T/map"; CASE=one-eht; export CASE
check "$(fcd_classify aa:bb:cc:dd:ee:02 wl0 'wl0 wl1 wl2')" mlo-or-eht one-link-eht-protected
printf 'aa:bb:cc:dd:ee:03 wl0\naa:bb:cc:dd:ee:03 wl1\n' > "$T/map"; CASE=unknown; export CASE
check "$(fcd_classify aa:bb:cc:dd:ee:03 wl0 'wl0 wl1 wl2')" mlo-multiradio two-link-same-mac
printf 'aa:bb:cc:dd:ee:04 wl0\naa:bb:cc:dd:ee:04 wl1\naa:bb:cc:dd:ee:04 wl2\n' > "$T/map"
check "$(fcd_classify aa:bb:cc:dd:ee:04 wl0 'wl0 wl1 wl2')" mlo-multiradio three-link-same-mac
printf 'aa:aa:aa:aa:aa:02 wl1\n' > "$T/map"; CASE=separate; export CASE
check "$(fcd_classify aa:aa:aa:aa:aa:02 wl1 'wl0 wl1 wl2')" mlo-table separate-link-mac-table
printf 'aa:bb:cc:dd:ee:05 wl1\n' > "$T/map"; CASE=unknown; export CASE
check "$(fcd_classify aa:bb:cc:dd:ee:05 wl1 'wl0 wl1 wl2')" unknown-no-sta-info unknown-protected

: > "$T/fcctl.calls"
fcd_safe_flush aa:bb:cc:dd:ee:01 wl0 'wl0 wl1 wl2' test >/dev/null 2>&1 || true
CASE=unknown; export CASE; fcd_safe_flush aa:bb:cc:dd:ee:05 wl1 'wl0 wl1 wl2' test >/dev/null 2>&1 || true
[ ! -s "$T/fcctl.calls" ] || { echo 'FAIL protected client reached fcctl'; exit 1; }
echo 'ok protected-never-reaches-fcctl'

printf 'aa:bb:cc:dd:ee:06 wl1\n' > "$T/map"; CASE=legacy; export CASE
for n in 1 2 3 4 5; do c=$(fcd_classify aa:bb:cc:dd:ee:06 wl1 'wl0 wl1 wl2'); fcd_observe_class aa:bb:cc:dd:ee:06 "$c" wl1; sleep 1; done
fcd_confirmed_nonmlo aa:bb:cc:dd:ee:06 wl1
FCD_AUTOFIX=1; FCD_MIN_GAP=0
fcd_safe_flush aa:bb:cc:dd:ee:06 wl1 'wl0 wl1 wl2' test
[ "$(wc -l < "$T/fcctl.calls")" -eq 1 ] || { echo 'FAIL legacy flush count'; exit 1; }
echo 'ok auto-legacy-heals'
echo 'PASS MLO safety'
