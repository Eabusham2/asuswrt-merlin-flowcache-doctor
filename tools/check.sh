#!/bin/sh
# Run the same checks locally and in release CI; no router or root access needed.
set -eu
cd "$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
command -v busybox >/dev/null 2>&1 || { echo 'BusyBox is required' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo 'Python 3 is required' >&2; exit 1; }
sh tests/audit-static.sh
python3 tests/audit-line-by-line-1.py
python3 tests/audit-line-by-line-2.py
for test in tests/test-*.sh; do
    printf '\nRunning %s\n' "$test"
    sh "$test"
done
python3 -m py_compile tools/patch-wlshared-d3lut.py tools/package-release.py
printf '\nAll script checks passed.\n'
