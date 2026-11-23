# FlowCache Doctor for Asuswrt-Merlin

FlowCache Doctor is a collection of router diagnostics and targeted Broadcom
FlowCache recovery scripts, developed for the **ASUS GT-BE19000AI running
Asuswrt-Merlin**. It helps investigate cases where a Wi-Fi client remains
associated but routed traffic becomes slow or unavailable.

The repository contains two separate products:

| Product | What it does | Where to start |
| --- | --- | --- |
| JFFS scripts | Classify clients, capture incidents, and clear hardware flow entries for a positively identified MLO client family after a relevant event | [Install the scripts](#install-the-scripts) |
| Experimental custom firmware | Adds a D3LUT invalidation hook to source-built `wlshared` on natural bridge FDB events | [Firmware build guide](docs/build-patched-firmware-with-github-actions.md) |

The scripts do not require flashing custom firmware. A script release archive
is not firmware and cannot be uploaded to the router's firmware upgrade page.

## Requirements and scope

- ASUS GT-BE19000AI with Asuswrt-Merlin and **JFFS custom scripts and configs** enabled.
- SSH access to the router and enough free JFFS space for scripts, backups, and logs.
- The firmware's Broadcom `wl`, `fcctl`, NVRAM, and `cru` utilities, plus `curl`.
- Internet access to GitHub during installation and updates.

Other Broadcom models and firmware versions are not covered by the current
model-specific parser and low-latency settings. Read the changes below before
installing: this package includes active recovery and radio tuning, as well as
passive diagnostics. It does not establish that a forwarding problem has the
same cause on every router, and it is not a general RF-range or ISP-loss fix.

## Install the scripts

Download a **script release** from [Releases](https://github.com/Eabusham2/asuswrt-merlin-flowcache-doctor/releases)
and use its exact `v…` tag. For example, to install `v1.0.9`, run in the router's
SSH session:

```sh
curl -fL https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/v1.0.9/install.sh -o /tmp/fcd-install.sh
sh -n /tmp/fcd-install.sh
FCD_REF=v1.0.9 sh /tmp/fcd-install.sh
```

Inspect the downloaded installer before running it. `FCD_REF` selects the same
tag or full commit for all files fetched by that installation. Omitting it
selects development `main`.

The installer backs up the previous core installation, checks downloaded shell
syntax, installs the core scripts, updates its own startup/cron hooks, starts
the components, and runs a health check. It replaces the core configuration
with the release defaults; save any custom settings first and reapply them
after reviewing the new defaults. Backups are under
`/jffs/flowcache-doctor/backup-<timestamp>/`.

Check the result with absolute paths, which also work before opening a new SSH
session for the `roamctl` alias:

```sh
/jffs/scripts/roamctl status
/jffs/scripts/roamctl health
/jffs/scripts/roamctl clients
/jffs/scripts/fcd-mlo-runner-heal.sh status
```

To update to a chosen release:

```sh
FCD_REF=v1.0.9 /jffs/scripts/roamctl update
```

`roamctl update` without `FCD_REF` installs development `main`. Installing a
release does not change that default for future update commands.

## What the core installation changes

| Component | Installed behavior |
| --- | --- |
| Core daemon | Polls client and channel state. Broad legacy-client automatic repair and the separate legacy event listener default off. |
| MLO Runner healer | Watches supported reassociation/disconnect/reinitialization events. After settling, it clears only hardware FlowCache entries for positively identified MLO/EHT identities, including affiliated link MACs in a proven MLD family. |
| Low-latency keeper | At installation and boot, disables DHD interrupt coalescing and WMM APSD; sets the existing 5/6 GHz LBR aggregation and AMPDU-release profile. WMM remains enabled. |
| Incident capture | Manual captures are available. Lightweight utilization logging stays on; automatic utilization-triggered full captures default off. |
| Persistence | Adds project-specific entries to `/jffs/scripts/services-start`, two minute-by-minute cron watchdogs, and a `roamctl` shell alias. |

The MLO healer does not synthesize bridge FDB deletion. It does not globally
flush FlowCache, cycle Runner, restart Wi-Fi, force-steer, or deauthenticate a
client. Unknown identities do not authorize a hardware flush. A previously
observed MLD family may be retained in the runtime cache for lifecycle events.

The default core settings in `/jffs/scripts/flowcache-doctor.conf` include:

```sh
FCD_AUTOFIX=0
FCD_EVENT_HEAL=0
FCD_MLO_HW_HEAL=1
FCD_MLO_HW_SETTLE=3
FCD_MLO_HW_COOLDOWN=60
FCD_MLO_KERNEL_EVENTS=1
FCD_INCIDENT_CAPTURE=0
FCD_LOG_RETENTION_DAYS=7
```

Old instructions mentioning `FCD_MLO_D3LUT_RELEARN` describe a superseded
runtime design. That setting is not used by the current healer.

## Diagnostics and optional components

```sh
/jffs/scripts/roamctl advise
/jffs/scripts/roamctl util
/jffs/scripts/roamctl capture before-reconnect
/jffs/scripts/roamctl incidents 10
/jffs/scripts/roamctl incident latest
/jffs/scripts/roamctl log 100
```

Incident captures live under `/jffs/flowcache-doctor/incidents/`. They may contain
LAN addresses, device MAC addresses, and system logs; review a capture before
posting it publicly. Capture an intermittent failure before reconnecting the
client when possible, and compare gateway, public-IP, and DNS reachability.

These optional installers are separate from the core installation. Download
them from the **same release tag** and run them with the same `FCD_REF` value:

| Installer or tool | Purpose and effect |
| --- | --- |
| `install-wifi-dropwatch.sh` | Adds Wi-Fi Dropwatch, connectivity/kernel-event captures, a startup hook, and a cron watchdog. New installs default to 14-day capture retention. |
| `install-airiq-guard.sh` | Adds AirIQ policy enforcement and utilization detail. AirIQ is capped at 600 seconds by default; the timeout persists Off with an NVRAM commit. This is an active policy change. |
| `scripts/fcd-wired-incident.sh` | Optional manual wired-client capture; accepts an affected LAN IP and optional MAC. It is not installed by the core installer. |
| `scripts/fcd-range-profile.sh`, `fcd-range-flight.sh`, `fcd-mlo-link-health.sh` | Additional investigation tools retained in the source archive; read each script's usage before running. |
| `scripts/fcd-range-desense.sh`, `fcd-rf-chain-guard.sh` | Advanced diagnostic/tuning tools. Review their runtime changes and restore behavior before use. |

For example, install Dropwatch from the selected release:

```sh
curl -fL https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/v1.0.9/install-wifi-dropwatch.sh -o /tmp/fcd-dropwatch-install.sh
sh -n /tmp/fcd-dropwatch-install.sh
FCD_REF=v1.0.9 sh /tmp/fcd-dropwatch-install.sh
/jffs/scripts/fcd-wifi-dropwatch.sh status
```

## Remove the core installation

```sh
/jffs/scripts/roamctl uninstall
```

This stops the core components, removes their installed files and managed
startup/cron entries, and removes their generated logs and incident captures.
Core backups remain under `/jffs/flowcache-doctor/`. Optional AirIQ and Dropwatch
installations are separate: AirIQ has `uninstall-airiq-guard.sh`; the current
repository does not provide a Dropwatch uninstaller. Core removal does not
restore radio tuning already applied in the running session.

## Custom firmware

The [firmware guide](docs/build-patched-firmware-with-github-actions.md) explains
the GT-BE19000AI-only build and its proof files. The current workflow is pinned
to Merlin **3006.102.9_0** at upstream commit
`9b25e55ca5c56a6f01d6a56264c0f6c47459ada0`; it does not automatically select a
newer Merlin release. Firmware outputs are published as separate prereleases.

See the [patch design](docs/gt-be19000ai-pktfwd-source-patch.md) and
[firmware maintenance policy](docs/FIRMWARE_UPDATE_POLICY.md). The
[August 2026 investigation](docs/GT_BE19000AI_ROOT_CAUSE_RESEARCH_2026-08-25.md)
is historical research, not a statement of current installation behavior.

## Development and releases

On Linux with Python 3 and BusyBox installed, run:

```sh
sh tools/check.sh
```

The suite covers parsing/safety assertions, simulated MLO-family healing,
incident captures, daemon behavior, and an isolated installer lifecycle. The
installer simulation uses a temporary filesystem tree and needs no root access.
These checks do not replace testing on a physical router.

The **Release scripts** workflow accepts a release tag and full commit SHA,
verifies that the commit belongs to `main`, runs the test suite on that exact
commit, and publishes a source archive, SHA-256 checksums, and a provenance
manifest. It never builds or flashes router firmware. See [CHANGELOG.md](CHANGELOG.md)
for release notes and [LICENSE](LICENSE) for the MIT license.
