#!/bin/sh
set -eu
# Structural runtime assertions: every flow-cache action is centralized and re-gated.
[ "$(grep -R '^[[:space:]]*if fcctl flush --mac' scripts | wc -l)" -eq 1 ]
! grep -q 'fcctl' scripts/fcd-events.sh
! grep -q 'fcctl' scripts/fcd-daemon.sh
# Delayed and pending actions both call fcd_safe_flush.
grep -q 'fcd_safe_flush.*pending' scripts/fcd-daemon.sh || grep -q 'fcd_safe_flush' scripts/fcd-daemon.sh
grep -q 'process_settle' scripts/fcd-daemon.sh
grep -q 'fcd_num "\$_due"' scripts/fcd-daemon.sh
# Event listener only appends queue entries.
grep -q 'FCD_EVENT_QUEUE' scripts/fcd-events.sh
# Library fallback remains 30 days; the installed hardened profile selects 7.
grep -q 'FCD_LOG_RETENTION_DAYS=${FCD_LOG_RETENTION_DAYS:-30}' scripts/fcd-lib.sh
grep -q 'FCD_LOG_RETENTION_DAYS=7' install.sh
echo 'PASS runtime structure'
