# FlowCache Doctor contributor instructions

Follow [the canonical contributor guide](../AGENTS.md). This repository contains
GT-BE19000AI / Asuswrt-Merlin JFFS scripts and a separate experimental firmware
build; keep current source, historical research, and device validation distinct.

Use POSIX/BusyBox `sh` for router runtime code. Preserve fail-closed MLO identity
checks, targeted family recovery, unrelated hooks/files, and `FCD_REF` pinning.
Do not introduce global flushes, synthetic FDB deletion, Runner cycles, radio
restarts, steering, or deauthentication into the MLO healer.

Run `sh tools/check.sh` from the repository root for runtime, installer, or
packaging changes; it requires Python 3 and BusyBox and uses isolated fixtures.
For documentation-only changes, verify local links/anchors and `git diff --check`.
Use the isolated installer test rather than the host's real `/jffs`, and do not
present a passing simulated test as physical-router validation.
