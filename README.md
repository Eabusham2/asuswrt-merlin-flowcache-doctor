# Flowcache Doctor — automatic MLO-safe fork

This fork heals Broadcom per-client flow-cache blackholes for **positively identified non-MLO associations** while protecting active Wi-Fi 7/MLO and uncertain clients.

## Safety model

- **One-, two-, and three-link MLO are protected.** Same-MAC multi-radio membership, MLO/MLD/link metadata, nonzero EML capability, and MLO tables are treated as MLO evidence.
- **Every active EHT/802.11be/Wi-Fi 7 station is protected**, including an MLO device currently using only one visible link.
- **Unknown is treated as an MLO-safe fallback.** Missing, unfamiliar, or temporarily unavailable Broadcom output never becomes permission to flush.
- The fallback is not permanently sticky: if later polls positively prove a current pre-EHT association, the client can qualify automatically without a device list.
- Non-MLO healing is automatic only after five consecutive current observations explicitly report a negotiated pre-EHT mode such as `N_CAP`, `VHT_CAP`, or `HE_CAP` and no MLO/EHT evidence is present.
- There is exactly one executable `fcctl flush --mac` path. It performs a fresh classification, confirmation, and single-radio check immediately before each initial or delayed flush.
- The event listener never flushes; it only queues events for the safety-gated poller.
- Production runtime contains no concrete client MAC addresses. Clients are discovered dynamically from Broadcom association and bridge state.
- Generated event logs are kept for 30 days and then deleted automatically.

No shell workaround can provide a mathematical guarantee against undocumented Broadcom output changing. This implementation is fail-closed: ambiguity disables healing for that client instead of risking an MLO flush.

## Utilization/drop correlation

The daemon passively reads Broadcom `chanim_stats` and records:

- `UTIL-SPIKE` when busy utilization changes by at least 25 percentage points.
- `UTIL-HIGH` when utilization crosses 85%.
- `UTIL-RECOVER` when it falls back to 65% or lower.
- Radio utilization snapshots alongside roam, stale-FDB, and flush events.

This monitoring never steers clients, restarts Wi-Fi, changes channels, or flushes an entire radio.

## Band selection

The add-on does **not force-steer** clients. ASUS Smart Connect/BSD owns steering and has information the shell does not, while target-band RSSI cannot be measured before a client associates. `roamctl advise` reports current RSSI, rates, congestion, and classification without disconnecting anything.

## Install or update

```sh
curl -fsSL https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main/install.sh | sh
```

Existing installations can use:

```sh
roamctl update
```

The installer stops and backs up the old version, replaces it atomically, removes obsolete upstream runtime files, installs safe defaults, starts the daemons, and runs a health check.

## Commands

```sh
roamctl status
roamctl health
roamctl clients
roamctl advise
roamctl util
roamctl log 100
roamctl update
roamctl uninstall
```

`roamctl clients` shows the current automatic classification and confirmation progress, such as `3/5` or `5/5`.

## Default configuration

```sh
FCD_INTERVAL=2
FCD_CONFIRMATIONS=5
FCD_CONFIRM_MAX_AGE=8
FCD_AUTOFIX=1
FCD_EVENT_HEAL=1
FCD_MIN_GAP=8
FCD_COOLDOWN=60
FCD_PENDING_TTL=60
FCD_SETTLE_FLUSHES="20 60 300"
FCD_LOG_RETENTION_DAYS=30
FCD_STEER_MODE=advisor
FCD_LOG_SYSLOG=0
FCD_BSSLIST=auto
FCD_UTIL_HIGH=85
FCD_UTIL_RECOVER=65
FCD_UTIL_SPIKE_DELTA=25
FCD_UTIL_LOG_COOLDOWN=60
```

## Tests and audits

```sh
tests/audit-static.sh
python3 tests/audit-line-by-line-1.py
python3 tests/audit-line-by-line-2.py
tests/test-runtime.sh
tests/test-mlo-safety.sh
tests/test-gtbe19000ai-live-format.sh
tests/test-no-runtime-macs.sh
tests/test-daemon-sim.sh
```
