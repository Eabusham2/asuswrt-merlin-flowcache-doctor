# Changelog

## 1.0.9

- Rework the public setup guide around the actual installed components, defaults,
  optional tools, update behavior, and removal limits.
- Correct stale descriptions of forced FDB relearn and automatic firmware version
  selection. The current runtime uses MLD-family hardware-only invalidation;
  the separate firmware builder remains pinned to Merlin 3006.102.9_0.
- Allow `FCD_REF` to pin every installer download and an explicit `roamctl update`
  to one release tag or full source commit.
- Add script release packaging with exact-commit validation, checksums, and a
  provenance manifest. Preserve the independent custom-firmware workflow.
- Run the complete existing shell suite through one CI entry point, align stale
  assertions with the hardened defaults, and isolate the installer simulation
  from the host filesystem.
- Replace RF chain-mask parsing through `eval` with literal last-field extraction,
  preserving parenthesized mask support and validating it with simulated driver output.
- Consolidate the former standalone 1.0.1 notes below. Existing recovery,
  diagnostics, and firmware patch implementations are retained.

## 1.0.8-hardened (prior installer version)

The source before 1.0.9 already supplied the hardened configuration: seven-day
core retention, automatic full utilization captures disabled, MLD-family
hardware-only healing, and the low-latency keeper. This heading records the
upgrade baseline; it does not claim a historical GitHub release existed.

## 1.0.1-mlo-safe-auto (historical notes)

- Add GT-BE19000AI Broadcom VER 8 parsing for `N_CAP`, `VHT_CAP`, `HE_CAP`, and `EHT_CAP`.
- Keep EHT, MLO, multi-radio, nonzero EML, and unknown clients fail-closed.
- Add TX/RX parsing from `rate of last tx/rx pkt`.
- Add congestion parsing from `wl chanim_stats` busy percentage.
- Add a fixture based on captured GT-BE19000AI output.
