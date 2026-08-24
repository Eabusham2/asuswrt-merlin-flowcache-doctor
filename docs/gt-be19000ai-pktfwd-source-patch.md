# GT-BE19000AI PKTFWD reassociation invalidation fix

This project fixes the GT-BE19000AI Broadcom DHD/PKTFWD association/reassociation invalidation gap. It is **not** a runtime `fcctl` workaround.

## Why it exists

The DHD connect path handles association/reassociation events including `WLC_E_ASSOC`, `WLC_E_ASSOC_IND`, `WLC_E_REASSOC`, and `WLC_E_REASSOC_IND`. The shared PKTFWD request handler removes potentially stale D3LUT state only for `WLC_E_ASSOC`.

On an AP/MLO client, `ASSOC_IND`/`REASSOC_IND` are normal lifecycle events. If an old station/link incarnation remains in D3LUT, a new association can reuse stale PKTFWD radio/flowring state that FlowCache/Runner may then accelerate.

The intended semantics are:

```c
if ((param2 == WLC_E_ASSOC) ||
    (param2 == WLC_E_ASSOC_IND) ||
    (param2 == WLC_E_REASSOC) ||
    (param2 == WLC_E_REASSOC_IND)) {
    dhd_pktfwd_lut_del((uint8_t *) param0, (struct net_device *)NULL);
}
```

`WLC_E_ASSOC_IND` must still increment PKTFWD's station count, and `WLC_E_DISASSOC_IND` must still decrement it.

## Critical GT-BE19000AI build detail

For the current GT-BE19000AI Merlin codebase, editing `dhd_pktfwd.c` is **not sufficient** to change the firmware.

The model's `hnd_dhd/Makefile` selects `REBUILD_DHD_MODULE=0` when full DHD source is unavailable and links a prebuilt whole `dhd.o`. Merlin's platform preparation copies that object from:

`release/src-rt-5.04behnd.4916/router-sysdep.gt-be19000ai/hnd_extra/prebuilt/dhd.o`

into the DHD prebuilt build path. A normal build then links `dhd.ko` from that object without compiling `shared/impl1/dhd_pktfwd.c`.

This was proven by auditing green firmware run #7: its build log showed `module : 0`, then `LD ... hnd_dhd/dhd.o` and `LD ... hnd_dhd/dhd.ko`, with no compile of `dhd_pktfwd.c`.

Therefore:

- `patches/gt-be19000ai-pktfwd-reassoc-invalidation.patch` is the human-readable source-reference patch;
- `tools/patch_dhd_pktfwd_prebuilt.py` is the effective current GT-BE19000AI build patcher;
- final firmware is approved only after the final installed `dhd.ko` independently verifies the patched instruction signature.

## Effective binary patch

`tools/patch_dhd_pktfwd_prebuilt.py` parses the AArch64 ELF metadata, locates the `dhd_pktfwd_request` symbol, and checks an exact set of instruction words at function-relative offsets. It has three modes:

```sh
python3 tools/patch_dhd_pktfwd_prebuilt.py inspect dhd.o
python3 tools/patch_dhd_pktfwd_prebuilt.py patch dhd.o
python3 tools/patch_dhd_pktfwd_prebuilt.py verify dhd.o
```

The patcher refuses `unknown` signatures. It does not pattern-scan arbitrary bytes, change file size, or blindly apply offsets to an unrecognized future DHD build.

For the verified current signature, the resulting control flow is:

- event 7 / `WLC_E_ASSOC` → stale D3LUT delete;
- event 8 / `WLC_E_ASSOC_IND` → station-count increment, then stale D3LUT delete;
- event 9 / `WLC_E_REASSOC` → stale D3LUT delete;
- event 10 / `WLC_E_REASSOC_IND` → stale D3LUT delete;
- event 12 / `WLC_E_DISASSOC_IND` → station-count decrement;
- other event types retain the original path.

## GitHub Actions build

Use `.github/workflows/build-gt-be19000ai-patched.yml` rather than manually applying the source patch and assuming it was compiled.

The workflow:

1. resolves the latest stable compatible GT-BE19000AI `asuswrt6` release;
2. verifies model/source/prebuilt prerequisites;
3. records the source-reference diff;
4. patches and verifies the model-specific prebuilt `dhd.o`;
5. runs `make gt-be19000ai`;
6. captures the normal PKGTB from `targets/96813GW/`;
7. finds `targets/96813GW/fs/lib/modules/*/extra/dhd.ko`;
8. verifies the patched PKTFWD signature in that final module;
9. emits `FLASH_MANIFEST.txt` only if all checks pass.

The manifest must contain:

```text
VERIFIED_FOR_FLASH=YES
DHD_BINARY_PATCH_VERIFIED=YES
PATCH_METHOD=verified-prebuilt-dhd-binary
```

If those lines are absent, do not flash the artifact as this fix.

## Source-reference patch

The human-readable source patch can still be inspected or applied to a source tree for review:

`patches/gt-be19000ai-pktfwd-reassoc-invalidation.patch`

It documents the intended C behavior, but **source presence is not binary proof on this model**.

## Output and flash

A completed GT-BE19000AI build writes the normal firmware under:

`release/src-rt-5.04behnd.4916/targets/96813GW/GT-BE19000AI_*_emmc_squashfs.pkgtb`

Do not use the GitHub ZIP itself or `_loader.pkgtb` for a normal upgrade.

After the artifact passes both manifest gates:

1. back up router configuration and JFFS;
2. open ASUS/Merlin **Administration > Firmware Upgrade**;
3. upload only the normal `*_emmc_squashfs.pkgtb`;
4. let the router reboot normally;
5. validate Runner/WAN upload behavior live.

## Scope

The fix targets stale host-side DHD/PKTFWD D3LUT lifecycle state. It does not modify RF settings, MLO steering policy, Runner enablement, QoS, DynBQ, or the proprietary Wi-Fi dongle firmware (`rtecdc.bin`).
