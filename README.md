# Flowcache Doctor — GT-BE19000AI MLO / Runner stale-state repair

This fork diagnoses and heals Broadcom per-client forwarding/offload failures while staying fail-closed around uncertain Wi-Fi 7/MLO state.

The current GT-BE19000AI work has two complementary paths:

- **Compiled firmware repair:** source-built `wlshared` globally invalidates DHD PKTFWD D3LUT state for a station MAC on DHD bridge-FDB lifecycle events. The proprietary DHD prebuilt remains unmodified.
- **JFFS runtime healer:** after a positively identified MLO/EHT lifecycle event, it forces a bridge relearn for only that client and then invalidates only that client's hardware FlowCache entries.

This specifically targets the reproduced failure where local Wi-Fi remains fast but routed WAN upload collapses until Runner hardware acceleration is reset.

## GT-BE19000AI D3LUT / Runner repair

GT-BE19000AI links a prebuilt DHD object, so editing `dhd_pktfwd.c` alone does not change the shipped DHD module. The firmware workflow instead patches source-built `shared/impl1/wlshared_linux.c` to call the DHD-exported delete hook with a `NULL` net device:

```c
dhd_pktc_del_hook((unsigned long)(fdb_info->addr), NULL);
```

The DHD PKTFWD implementation explicitly interprets `NULL` as a global D3LUT-pool lookup. That avoids trusting a stale radio/device mapping—the same failure family suggested by historical pool/unit mismatch logs.

The compiled repair marker is:

```text
FCD_DHD_D3LUT_REPAIR_V1
```

See:

- `docs/gt-be19000ai-pktfwd-source-patch.md`
- `docs/build-patched-firmware-with-github-actions.md`
- `docs/FIRMWARE_UPDATE_POLICY.md`

## MLO runtime safety model

- One-, two-, and three-link MLO are treated as protected identities.
- Active EHT/802.11be evidence is MLO-positive evidence even if only one link is currently visible.
- Unknown output stays fail-closed; it is never silently treated as legacy Wi-Fi.
- Legacy/pre-EHT healing still requires repeated positive evidence before a normal per-client flush can occur.
- Production runtime contains no hard-coded client MAC addresses.
- The MLO healer operates only on a positively identified MLO/EHT client after a lifecycle/reinit event.
- Its repair is narrow: one client FDB relearn plus `fcctl flush --hw --mac <client>`.
- It never automatically performs a global FlowCache flush, Runner cycle, Wi-Fi restart, force-steer, or deauthentication.

No shell parser can mathematically guarantee behavior against undocumented future Broadcom output. Ambiguity therefore disables the special action rather than broadening it.

## Install or update JFFS component

```sh
curl -fsSL https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main/install.sh | sh
```

Existing installations can also use:

```sh
roamctl update
```

Current installer release: `1.0.5-d3lut-relearn`.

The installer backs up the previous installation, replaces files atomically, removes obsolete runtime files, installs safe defaults, starts the daemons, and runs a health check.

## Default MLO repair configuration

```sh
FCD_MLO_HW_HEAL=1
FCD_MLO_D3LUT_RELEARN=1
FCD_MLO_HW_SETTLE=3
FCD_MLO_HW_COOLDOWN=60
FCD_MLO_KERNEL_EVENTS=1
```

On an eligible event the sequence is:

```text
MLO/EHT lifecycle event
  -> settle/debounce
  -> positive MLO/EHT classification
  -> delete only that MAC's bridge FDB entry
  -> patched wlshared calls DHD global D3LUT delete hook
  -> bridge/D3LUT relearn on subsequent traffic
  -> fcctl flush --hw --mac <same MAC>
```

If the router lacks the `bridge` userspace command, the script degrades safely to the existing per-client FlowCache hardware flush. The firmware-side repair still applies to natural bridge FDB lifecycle events.

## Utilization/drop diagnosis

The add-on passively monitors Broadcom CHANIM telemetry and records high/spiking airtime plus incident snapshots. Captures can include:

- all-band CHANIM/channel state;
- per-client classification, RSSI, rates and retry/failure counters;
- retry deltas over the incident window;
- WAN-gateway, public-IP and configured LAN-DNS reachability;
- bridge FDB, FlowCache status, selected Broadcom counters, kernel messages and recent syslog.

These captures are evidence gathering only. They do not force channel changes or radio restarts.

Useful commands:

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

Incident directories are stored under:

```text
/jffs/flowcache-doctor/incidents/
```

## Build custom firmware

Use GitHub Actions workflow:

```text
Build patched GT-BE19000AI firmware
```

Start a **fresh** run from current `main`. A successful artifact must contain a `FLASH_MANIFEST.txt` with:

```text
VERIFIED_FOR_FLASH=YES
FIX=FCD_DHD_D3LUT_REPAIR_V1
PATCH_PATH=source-built-wlshared
DHD_PATH=prebuilt-unmodified
```

The workflow also checks that the repair marker exists in compiled `wlshared.o`/`wlshared.ko`, preventing the earlier mistake where a source diff existed but the GT-BE19000AI image actually linked a prebuilt DHD.

Flash only the normal generated `*_emmc_squashfs.pkgtb`, never the GitHub artifact ZIP or `_loader.pkgtb` for a normal upgrade.

## Tests and audits

The push CI executes the shell/runtime suite, including the dedicated MLO Runner+D3LUT healer test and installer lifecycle test.

Key direct tests include:

```sh
tests/audit-static.sh
python3 tests/audit-line-by-line-1.py
python3 tests/audit-line-by-line-2.py
tests/test-runtime.sh
tests/test-mlo-safety.sh
tests/test-mlo-runner-heal.sh
tests/test-gtbe19000ai-live-format.sh
tests/test-incident-capture.sh
tests/test-airiq-guard.sh
tests/test-airiq-time-cap.sh
tests/test-no-runtime-macs.sh
tests/test-daemon-sim.sh
```

## Scope

The current compiled fix is for stale host-side DHD PKTFWD D3LUT / Runner hardware state. It intentionally keeps Runner/WFD/FlowCache enabled.

It is not presented as a fix for independent far-range RF/FEM/antenna weakness, AT&T/BGW/public-route loss, or every loaded-latency issue. Those remain separate investigation phases after the routed-upload bug is validated.
