# Build the patched GT-BE19000AI firmware with GitHub Actions

You do not need Linux on your Mac.

The repository contains a manual GitHub Actions workflow:

`.github/workflows/build-gt-be19000ai-patched.yml`

For GT-BE19000AI, **do not use the generic `3006.102.8_4` tag**. This model is maintained on Merlin's separate `asuswrt6` lineage. The workflow is pinned to the exact GT-BE19000AI `3006.102.8_4` release commit:

`e6ec7e95706d321c50d1b4b2f912b26323f6163e`

That upstream commit's subject mistakenly says `_8_2`, but its actual `version.conf` change is `EXTENDNO=3` to `EXTENDNO=4`. The workflow verifies `SERIALNO=102.8` and `EXTENDNO=4` before building.

The workflow patches the verified `dhd_pktfwd.c` association/reassociation cleanup gate directly, verifies the resulting Git diff, builds the real Merlin target `gt-be19000ai`, and uploads the resulting firmware as an Actions artifact.

Before compiling, CI also verifies that this source tree actually contains the GT-BE19000AI model definition, BCM6813 chip profile, model config, and model-specific `afcd`/`locpold` prebuilts. This catches the exact source-lineage error that previously produced `NO THIS TARGET gt-be19000ai`.

## Run it

1. Open this repository on GitHub.
2. Click **Actions**.
3. Click **Build patched GT-BE19000AI firmware**.
4. Click **Run workflow**.
5. Click the green **Run workflow** button. There is no source-ref field anymore; the correct immutable release commit is pinned in the workflow.
6. Open the new run once it appears.
7. When it finishes successfully, scroll to **Artifacts**.
8. Download `GT-BE19000AI-3006.102.8_4-pktfwd-patched-<run number>`.
9. Unzip it on the Mac.

Do **not** use **Re-run jobs** on an older failed workflow run after the workflow itself has been changed. Start a brand-new manual run from current `main` so GitHub uses the current workflow definition.

The artifact contains the generated `*_emmc_squashfs.pkgtb`, its SHA-256, the exact upstream Merlin commit/lineage, baseline verification, the applied source diff/hash, the patched source snippet, and the build log.

## What file do I upload to the router?

GitHub gives you a ZIP **artifact**. The ZIP itself is not router firmware.

Unzip the artifact on the Mac, then upload only the generated file ending in:

`_emmc_squashfs.pkgtb`

The Merlin build system uses this PKGTB image format for the GT-BE19000AI. Do not rename it to `.w`, `.trx`, or anything else. If the ASUS firmware page rejects the generated PKGTB, stop rather than forcing it.

## Flash

Before flashing, back up the router configuration and JFFS.

In the router UI open **Administration > Firmware Upgrade**, manually upload the generated `*_emmc_squashfs.pkgtb`, and let the router reboot normally.

This is an experimental custom firmware build. The workflow records enough provenance to audit exactly what was built.

For the permanent project rules used for future firmware changes, see `docs/FIRMWARE_UPDATE_POLICY.md`.
