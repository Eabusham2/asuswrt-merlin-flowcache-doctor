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
- Generated event logs and utilization incident captures are retained for 30 days.

No shell workaround can provide a mathematical guarantee against undocumented Broadcom output changing. This implementation is fail-closed: ambiguity disables healing for that client instead of risking an MLO flush.

## Utilization/drop diagnosis

Version 1.0.3 passively monitors Broadcom CHANIM telemetry and records:

- `UTIL-SPIKE` when busy utilization changes by at least 20 percentage points.
- `UTIL-HIGH` when utilization crosses 85%.
- `UTIL-RECOVER` when it falls back to 65% or lower.
- The complete CHANIM breakdown: AP transmit duration, own-BSS airtime, other-BSS airtime, uncategorized/non-packet energy, transmit opportunities, good/bad transmit duration, glitches, bad PLCP, noise, idle, and busy.
- Radio utilization snapshots alongside roam, stale-FDB, and per-client healing events.

A spike/high event launches a background incident capture with six samples over roughly ten seconds. It stores:

- All-band CHANIM samples and channel changes.
- Per-client classification, RSSI, rates, sent packets, retries, exhausted retries, and failures.
- Retry deltas/rates over the incident window.
- WAN-gateway reachability, public-IP reachability, and the configured LAN DNS-server probe.
- Bridge FDB, selected Broadcom counters, flow-cache status, process state, NVRAM size, kernel messages, and recent syslog.

The summary classifies the likely family:

- `other-wifi-contention`
- `nonwifi-or-undecodable-energy`
- `local-airtime-or-retries`
- `driver-or-counter-anomaly`
- `mixed-high-airtime`
- `mixed-or-transient`

These labels are conservative heuristics, not proof. The raw capture remains the source of truth.

This monitoring **never** force-steers, deauthenticates, restarts Wi-Fi, changes channels, or flushes an entire radio. That is intentional: an automatic radio restart or channel change could interrupt MLO and destroy the evidence needed to identify the actual cause.

## Using incident captures

```sh
roamctl util
roamctl capture manual-check
roamctl incidents
roamctl incident latest
roamctl log 100
```

Incident directories are under:

```text
/jffs/flowcache-doctor/incidents/
```

The generated summary gives a cause-specific next action:

- Other Wi-Fi contention: use ASUS WiFi Insight at the incident timestamp and choose a quieter channel.
- Non-Wi-Fi energy: check WiFi Insight's non-WiFi layer and nearby emitters.
- Local retries: inspect `retry-analysis.tsv` and address the top retrying client.
- Driver/counter anomaly or simultaneous high utilization on independent bands: correlate with WiFi Insight/Interference Detect and channel-change events. Repeated incidents support disabling Interference Detect for a controlled test and reporting the capture to ASUS/Broadcom.
- Public-IP success plus DNS failure: treat the outage as DNS/service failure, not RF congestion.

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
roamctl capture [reason]
roamctl incidents [count]
roamctl incident [latest|name]
roamctl log 100
roamctl update
roamctl uninstall
```

`roamctl clients` shows automatic classification and confirmation progress, such as `3/5` or `5/5`.

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
FCD_UTIL_SPIKE_DELTA=20
FCD_UTIL_LOG_COOLDOWN=60
FCD_INCIDENT_CAPTURE=1
FCD_INCIDENT_SAMPLES=6
FCD_INCIDENT_SAMPLE_INTERVAL=2
FCD_INCIDENT_COOLDOWN=120
FCD_PROBE_IP=1.1.1.1
```

## Tests and audits

```sh
tests/audit-static.sh
python3 tests/audit-line-by-line-1.py
python3 tests/audit-line-by-line-2.py
tests/test-runtime.sh
tests/test-mlo-safety.sh
tests/test-gtbe19000ai-live-format.sh
tests/test-incident-capture.sh
tests/test-no-runtime-macs.sh
tests/test-daemon-sim.sh
```
