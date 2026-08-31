#!/bin/sh
set -eu
for f in install.sh uninstall.sh install-airiq-guard.sh uninstall-airiq-guard.sh install-wifi-dropwatch.sh scripts/*.sh scripts/roamctl tests/*.sh; do busybox sh -n "$f"; done
! grep -R -nE '(^|[[:space:]])eval([[:space:]]|$)' scripts install.sh uninstall.sh
! grep -R -nE 'rm -rf /jffs([[:space:]]|$)' scripts install.sh uninstall.sh
[ "$(grep -R '^[[:space:]]*if fcctl flush --mac' scripts | wc -l)" -eq 1 ]
grep -q 'Fresh classification immediately before' scripts/fcd-lib.sh
grep -q 'mlo-or-eht' scripts/fcd-lib.sh
grep -q 'unknown-unclassified' scripts/fcd-lib.sh
grep -q 'FCD_CONFIRMATIONS=5' install.sh
grep -q 'FCD_STEER_MODE=advisor' install.sh
grep -q 'never force-steers' scripts/roamctl
grep -q 'mtime +"$FCD_LOG_RETENTION_DAYS"' scripts/fcd-lib.sh
grep -q 'FCD_DROPWATCH_FAIL_CONFIRMATIONS' scripts/fcd-wifi-dropwatch.sh
grep -q 'FCD_DROPWATCH_PROBE_IP2' scripts/fcd-wifi-dropwatch.sh
grep -q 'FCD_DROPWATCH_RETENTION_DAYS:-14' scripts/fcd-wifi-dropwatch.sh
grep -q 'connectivity-wan-gateway-and-public-down' scripts/fcd-wifi-dropwatch.sh
grep -q 'kernel-network-error' scripts/fcd-wifi-dropwatch.sh
! grep -n 'command -v' scripts/fcd-wifi-dropwatch.sh scripts/fcd-wired-incident.sh
echo 'PASS static audit'
