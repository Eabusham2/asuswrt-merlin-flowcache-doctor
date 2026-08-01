#!/bin/sh
set -eu
# Production logic must discover clients from wl/bridge state. A concrete MAC
# literal in runtime files would be a regression toward per-device behavior.
if grep -ERin '(^|[^0-9A-Fa-f])([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}([^0-9A-Fa-f]|$)' scripts install.sh uninstall.sh 2>/dev/null; then
  echo 'FAIL concrete MAC literal found in production runtime'
  exit 1
fi
echo 'PASS no concrete MACs in production runtime'
