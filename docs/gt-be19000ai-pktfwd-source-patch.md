# GT-BE19000AI PKTFWD reassociation invalidation patch

This is a source-level patch for the GT-BE19000AI Broadcom DHD/PKTFWD path. It is **not** a runtime `fcctl` workaround.

## Why it exists

The DHD connect path handles association/reassociation events including `WLC_E_ASSOC`, `WLC_E_ASSOC_IND`, `WLC_E_REASSOC`, and `WLC_E_REASSOC_IND`. The shared PKTFWD request handler currently removes potentially stale D3LUT state only for `WLC_E_ASSOC`.

On an AP/MLO client, `ASSOC_IND`/`REASSOC_IND` are normal lifecycle events. If an old station/link incarnation remains in D3LUT, the new association can reuse stale PKTFWD radio/flowring state, which FlowCache/Runner may then accelerate.

The patch makes that cleanup idempotently run for all association/reassociation request and indication events.

Patch file:

`patches/gt-be19000ai-pktfwd-reassoc-invalidation.patch`

## Important

You cannot apply this to the running router filesystem. `dhd_pktfwd.c` is firmware/driver source. The patched code must be compiled into a custom GT-BE19000AI Asuswrt-Merlin image and that image flashed normally.

For GT-BE19000AI, Merlin's current build script uses:

- branch: `asuswrt6`
- SDK: `release/src-rt-5.04behnd.4916`
- make target: `gt-be19000ai`
- image: `image/*_emmc_squashfs.pkgtb`

## Apply the patch to a Merlin source tree

Run this on an x86-64 Linux machine/VM with a working Asuswrt-Merlin build environment and GitHub CLI installed:

```sh
gh repo clone RMerl/asuswrt-merlin.ng merlin -- --branch asuswrt6 --single-branch
cd merlin

gh api repos/Eabusham2/asuswrt-merlin-flowcache-doctor/contents/patches/gt-be19000ai-pktfwd-reassoc-invalidation.patch \
  --jq .content | base64 -d > /tmp/gt-be19000ai-pktfwd.patch

git apply --check /tmp/gt-be19000ai-pktfwd.patch
git apply /tmp/gt-be19000ai-pktfwd.patch
git diff --check
git diff -- release/src-rt-5.04behnd.4916/bcmdrivers/broadcom/net/wl/shared/impl1/dhd_pktfwd.c
```

The expected source change is that the stale D3LUT deletion gate changes from only `WLC_E_ASSOC` to:

```c
if ((param2 == WLC_E_ASSOC) ||
    (param2 == WLC_E_ASSOC_IND) ||
    (param2 == WLC_E_REASSOC) ||
    (param2 == WLC_E_REASSOC_IND)) {
    dhd_pktfwd_lut_del((uint8_t *) param0, (struct net_device *)NULL);
}
```

## Build GT-BE19000AI

From the patched tree:

```sh
cd release/src-rt-5.04behnd.4916
make gt-be19000ai
```

If successful, locate the image with:

```sh
ls -lh image/*_emmc_squashfs.pkgtb
sha256sum image/*_emmc_squashfs.pkgtb
```

## Flash

1. Save the current router configuration/JFFS backup first.
2. Open ASUS/Merlin **Administration > Firmware Upgrade**.
3. Manually upload the generated `*_emmc_squashfs.pkgtb` image.
4. Let the router reboot normally.
5. Do not restore an unrelated/older settings backup unless needed.

A normal same-codebase custom Merlin build should preserve settings, but keep a recovery path available because this is an experimental driver/datapath source change.

## Verify the patch is in the source before flashing

```sh
grep -A10 -B3 'case dhd_pktfwd_req_assoc_sta_e' \
  release/src-rt-5.04behnd.4916/bcmdrivers/broadcom/net/wl/shared/impl1/dhd_pktfwd.c
```

You should see all four `WLC_E_*ASSOC*` checks above.

## Revert the source patch

Before building, if you want to undo only this source change:

```sh
git apply -R /tmp/gt-be19000ai-pktfwd.patch
```

Or discard the source file change:

```sh
git restore release/src-rt-5.04behnd.4916/bcmdrivers/broadcom/net/wl/shared/impl1/dhd_pktfwd.c
```

## Scope

This patch prevents stale PKTFWD/D3LUT station state from surviving association/reassociation events. It does not modify RF settings, MLO policy, Runner enablement, QoS, DynBQ, or the proprietary Broadcom Wi-Fi firmware blob itself.
