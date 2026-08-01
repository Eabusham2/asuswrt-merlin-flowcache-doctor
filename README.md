# Flowcache Doctor — automatic MLO-safe fork

This fork heals Broadcom per-client flow-cache blackholes for **positively identified non-MLO clients** while protecting active Wi-Fi 7/MLO and uncertain clients.

## Safety model

- **One-, two-, and three-link MLO are protected.** Same-MAC multi-radio membership, MLO/MLD/link metadata, and MLO tables are treated as MLO evidence.
- **Every active EHT/802.11be/Wi-Fi 7 station is protected**, including an MLO device currently using only one link.
- **Unknown means protected.** Missing or unfamiliar Broadcom output never becomes permission to flush.
- Non-MLO healing is automatic only after five consecutive current observations explicitly report a pre-EHT PHY such as Wi-Fi 4/5/6 (`n`, `ac`, or `ax`).
- There is exactly one executable `fcctl flush --mac` path. It performs a fresh classification and confirmation check immediately before each initial or delayed flush.
- The event listener never flushes; it only queues events for the safety-gated poller.
- Generated event logs are kept for 30 days and then deleted automatically.

No shell workaround can provide a mathematical guarantee against undocumented Broadcom output changing. This implementation is fail-closed: ambiguity disables healing for that client instead of risking an MLO flush.

## Band selection

The add-on does **not force-steer** clients. ASUS Smart Connect/BSD already owns steering and has information the shell does not, while target-band RSSI cannot be measured before a client associates. `roamctl advise` reports current RSSI, rates, congestion, and classification without disconnecting anything.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main/install.sh | sh
```

The installer stops and backs up the old version, replaces it atomically, removes the old upstream runtime files, installs safe defaults, starts the daemons, and runs a health check.

## Commands

```sh
roamctl status
roamctl health
roamctl clients
roamctl advise
roamctl log 100
roamctl update
roamctl uninstall
```

## Default configuration

```sh
FCD_INTERVAL=2
FCD_CONFIRMATIONS=5
FCD_AUTOFIX=1
FCD_EVENT_HEAL=1
FCD_SETTLE_FLUSHES="20 60 300"
FCD_LOG_RETENTION_DAYS=30
FCD_STEER_MODE=advisor
FCD_LOG_SYSLOG=0
FCD_BSSLIST=auto
```

## Tests and audits

```sh
tests/audit-static.sh
tests/test-runtime.sh
tests/test-mlo-safety.sh
```
