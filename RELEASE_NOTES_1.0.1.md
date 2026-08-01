# 1.0.1-mlo-safe-auto

- Adds GT-BE19000AI Broadcom VER 8 parsing for `N_CAP`, `VHT_CAP`, `HE_CAP`, and `EHT_CAP`.
- Keeps EHT, MLO, multi-radio, nonzero EML, and unknown clients fail-closed.
- Adds working TX/RX parsing from `rate of last tx/rx pkt`.
- Adds working congestion parsing from `wl chanim_stats` busy percentage.
- Adds a fixture based on the user's live GT-BE19000AI output.
