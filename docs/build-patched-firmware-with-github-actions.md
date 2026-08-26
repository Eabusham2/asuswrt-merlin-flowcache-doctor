# Build the GT-BE19000AI D3LUT-repair firmware with GitHub Actions

You do not need Linux on your Mac. Use the manual workflow:

`.github/workflows/build-gt-be19000ai-patched.yml`

## What is fixed

The strongest reproduced failure is a routed-upload collapse with healthy local Wi-Fi/RF where toggling Runner hardware acceleration off and back on immediately restores WAN upload. The source evidence points to stale DHD PKTFWD/D3LUT state after MLO association/reassociation churn, followed by stale FlowCache/Runner hardware programming.

The intended DHD behavior would globally invalidate the station MAC on association and reassociation lifecycle events. GT-BE19000AI, however, links a model-specific **prebuilt DHD object**, so editing `dhd_pktfwd.c` alone does not reach the shipped module.

The current fix therefore patches the source-built Broadcom `wlshared` layer. On DHD bridge FDB add/delete events, patched `wlshared_linux.c` calls:

```c
dhd_pktc_del_hook((unsigned long)(fdb_info->addr), NULL);
```

The prebuilt DHD registers that hook to `dhd_pktfwd_lut_del()`. Passing `NULL` intentionally makes PKTFWD search the **global D3LUT pool**, avoiding a stale/wrong radio or unit mapping.

This is paired with the JFFS MLO healer. After a positively identified MLO/EHT lifecycle event it deletes only that client's bridge FDB entry, allowing patched firmware to globally purge the D3LUT mapping, then runs the existing per-client hardware FlowCache invalidation:

```text
bridge FDB delete for one MAC
        -> patched wlshared
        -> dhd_pktc_del_hook(MAC, NULL)
        -> global DHD D3LUT purge
        -> normal bridge/D3LUT relearn on next frame
        -> fcctl flush --hw --mac MAC
```

It does not globally flush FlowCache, cycle Runner, restart Wi-Fi, or deauthenticate the client.

## Why the old DHD-source/binary-patcher artifacts are obsolete

GT-BE19000AI's DHD Makefile uses `prebuilt/dhd.o`. Earlier builds that only edited `shared/impl1/dhd_pktfwd.c` did not put that edit into `dhd.ko`.

A later experimental binary-patcher path was also removed. The current build does **not** rewrite the proprietary DHD object. It changes the open/source-built `wlshared_linux.c`, which already exports the supported `dhd_pktc_del_hook` used by Broadcom's own code.

Do not flash an older artifact just because it was once labeled `pktfwd-patched` or `VERIFIED_FOR_FLASH`. Start a fresh run from current `main`.

## Release selection

The workflow has no manual version box. Each new run resolves the newest stable GT-BE19000AI-compatible release on Merlin's `asuswrt6` lineage and pins that immutable commit for the build. Alpha, beta, RC, and development versions are rejected.

For the currently established base, Merlin `3006.102.8_4` corresponds to upstream commit:

`e6ec7e95706d321c50d1b4b2f912b26323f6163e`

A later stable release is accepted only if the model target, source-built `wlshared` repair point, GT-BE19000AI prebuilt DHD path, and required model prebuilts are present.

## Run it

1. Open this repository on GitHub.
2. Open **Actions**.
3. Select **Build patched GT-BE19000AI firmware**.
4. Click **Run workflow** and start a brand-new run from `main`.
5. When it completes successfully, open the run's **Artifacts** section.
6. Download `GT-BE19000AI-<resolved version>-d3lut-repair-<run number>` and unzip it.

Do not use **Re-run jobs** from an older run after workflow code changed.

## Required artifact proof

Before flashing, `FLASH_MANIFEST.txt` must contain at least:

```text
VERIFIED_FOR_FLASH=YES
FIX=FCD_DHD_D3LUT_REPAIR_V1
PATCH_PATH=source-built-wlshared
DHD_PATH=prebuilt-unmodified
```

The workflow also requires:

- Merlin `make` exit code `0`;
- the exact normal GT-BE19000AI PKGTB to exist;
- a successful firmware SHA-256 round trip;
- the expected stable release/version/commit;
- the `wlshared_linux.c` source diff containing the global D3LUT hook call;
- built `wlshared.o`/`wlshared.ko` output;
- the marker `FCD_DHD_D3LUT_REPAIR_V1` inside the compiled wlshared binary.

This last check is important: it proves the edited source reached a built binary instead of repeating the old source-only DHD mistake.

## File to flash

The GitHub ZIP is not router firmware. Unzip it and upload only the normal file ending in:

`_emmc_squashfs.pkgtb`

Do not use `_loader.pkgtb` for a normal firmware upgrade and do not rename the file to another extension.

Before flashing, back up router configuration and JFFS. Then use **Administration > Firmware Upgrade** and let the router reboot normally.

## After flashing

Install/update the current JFFS component so the per-client forced FDB relearn is active:

```sh
curl -fsSL https://raw.githubusercontent.com/Eabusham2/asuswrt-merlin-flowcache-doctor/main/install.sh | sh
```

Then validate the original failure first: strong-RF close-range routed upload, normal MLO reassociation/lifecycle activity, and no unexplained 2-8 Mbps WAN-upload state. The fix is targeted at stale D3LUT/Runner state; it is not claimed to solve independent far-range RF/antenna problems or ISP/BGW packet loss.

For permanent build rules, see `docs/FIRMWARE_UPDATE_POLICY.md`.
