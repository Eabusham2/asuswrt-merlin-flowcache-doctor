# Build the GT-BE19000AI D3LUT-repair firmware

The custom firmware build runs in GitHub Actions. It is separate from the JFFS
script releases and applies only to the **ASUS GT-BE19000AI**.

## Build inputs

The workflow `.github/workflows/build-gt-be19000ai-patched.yml` is pinned to:

| Input | Value |
| --- | --- |
| Merlin version | `3006.102.9_0` |
| Upstream commit | `9b25e55ca5c56a6f01d6a56264c0f6c47459ada0` |
| Build target | `make gt-be19000ai` |
| Target directory | `release/src-rt-5.04behnd.4916/targets/96813GW/` |
| Firmware file | `GT-BE19000AI_3006_102.9_0_emmc_squashfs.pkgtb` |
| Compiled repair marker | `FCD_DHD_D3LUT_REPAIR_V1` |

It does **not** discover the latest Merlin release. Updating the upstream base
requires reviewing and changing the pinned version, commit, expected image,
and compatibility checks together. The toolchain container currently uses its
upstream `latest` tag; the source pin and output hashes identify the source and
result, but do not make the entire build environment immutable.

## Repair design

The GT-BE19000AI build links a proprietary prebuilt DHD object. Editing the
open `dhd_pktfwd.c` reference source alone does not change that object.

The current patch instead changes source-built `wlshared_linux.c`. For DHD
bridge FDB add/delete events it calls:

```c
dhd_pktc_del_hook((unsigned long)(fdb_info->addr), NULL);
```

The hook requests D3LUT lookup/invalidation across pools for that station MAC.
The DHD prebuilt remains unmodified. See the [patch design](gt-be19000ai-pktfwd-source-patch.md)
for the source path and scope.

The separate current JFFS healer performs MLD-family hardware FlowCache
invalidation after supported MLO/EHT events. It does not force a bridge FDB
delete. Firmware-side D3LUT invalidation applies to natural FDB lifecycle events.

## Start a build

1. Open the repository's **Actions** tab.
2. Choose **BUILD THIS - GT-BE19000AI firmware (Runner fix)**.
3. Select **Run workflow** on the reviewed `main` revision.
4. After success, open the firmware prerelease linked by the publishing step,
   or download the artifact `GT-BE19000AI-3006.102.9_0-Runner-D3LUT-repair`.
5. Record the run URL and check its commit before using the output.

Changes to the workflow or patch tool also trigger a new build on `main`.
Start a fresh run after changing the workflow; retrying an old run uses its old
workflow revision.

## Verify the output

A successful build checks the pinned source and model prerequisites, runs the
Broadcom build as the non-root `docker` user, looks for the repair marker in a
built `wlshared.o` or `wlshared.ko`, and checks the normal firmware image and its
SHA-256.

The release includes the firmware, checksums, source diff, source/version
identity, DHD prebuilt hash, and compiled-marker evidence. Check that
`FLASH_MANIFEST.txt` contains:

```text
VERIFIED_FOR_FLASH=YES
MODEL=GT-BE19000AI
VERSION=3006.102.9_0
FIX=FCD_DHD_D3LUT_REPAIR_V1
PATCH_PATH=source-built-wlshared
DHD_PATH=prebuilt-unmodified
FLASH_FILE=GT-BE19000AI_3006_102.9_0_emmc_squashfs.pkgtb
```

From the directory containing the image and checksum file, run:

```sh
sha256sum -c FIRMWARE_SHA256.txt
```

On macOS, use `shasum -a 256 -c FIRMWARE_SHA256.txt`.

The manifest records the workflow's build checks. It is not evidence that the
firmware was flashed or that a particular router's symptoms were resolved.
The workflow uploads its artifact directory after failure when possible, so
an artifact's presence alone does not establish a valid firmware build.

## Flash and validate

Back up the router configuration and JFFS. Use the ASUS/Merlin firmware upgrade
page and the normal `*_emmc_squashfs.pkgtb` image for the exact model. The GitHub
artifact ZIP and script release archive are not firmware. Do not use a
`_loader.pkgtb` file for a normal upgrade or force an image rejected by the router.

After the normal reboot, reproduce the original failure conditions and compare
local LAN traffic with routed WAN traffic. Keep the build identity with the
results. A successful compile or a checksum does not establish that unrelated
RF-range, antenna, DNS, or ISP-path problems have been fixed.

For script installation and current runtime behavior, use the [main README](../README.md).
For maintenance rules, see the [firmware policy](FIRMWARE_UPDATE_POLICY.md).
