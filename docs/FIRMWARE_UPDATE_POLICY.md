# GT-BE19000AI firmware update policy

This is the project rule for future source-level firmware changes.

## Permanent workflow

1. **Do not compile firmware on the router or ASUS AI Board.** Use GitHub Actions so a Mac only needs to start the workflow and download the result.
2. **Do not treat JFFS add-ons and firmware source patches as the same thing.** Shell/add-on code under `/jffs` can be installed without flashing. Changes to compiled Broadcom/ASUS/Merlin C code must be built into firmware.
3. **Use the model's actual Merlin source lineage.** GT-BE19000AI is maintained from Merlin's `asuswrt6` lineage; a same-named generic release tag on another lineage is not sufficient.
4. **Pin an immutable upstream commit SHA. Never build a moving branch head for a production test.** Record the branch/lineage only for provenance.
5. **Verify the release identity before compiling.** CI must check `release/src-rt/version.conf`, the GT-BE19000AI entry in `target.mak`, chip profile, model configuration, and required model-specific prebuilts.
6. **Run only the Broadcom/Merlin compile as non-root `docker`.** Broadcom's `prebuild_checks.mk` intentionally rejects root builds. Keep the surrounding GitHub Actions container as root so Actions such as `upload-artifact` can write runner command files; explicitly drop to `docker` for `make` and verify `whoami=docker` there.
7. **Apply only the intended source change and record its diff/hash.** Fail if the expected source pattern is missing or appears more than once.
8. **Build the real target:** `make gt-be19000ai` from `release/src-rt-5.04behnd.4916`. Do not rename the target to work around an error.
9. **Use the real GT-BE19000AI output directory.** The completed build writes the eMMC PKGTB files under `release/src-rt-5.04behnd.4916/targets/96813GW/`, not the generic `image/` directory.
10. **Require Merlin's own successful-build marker as well as exit code 0.** The workflow must find `Done! Image 96813GW has been built` in `BUILD.log` before accepting the output.
11. **Require the exact normal flash image and distinguish it from the loader image.** For 3006.102.8_4 the normal file is `GT-BE19000AI_3006_102.8_4_emmc_squashfs.pkgtb`; the separate `..._loader.pkgtb` is recovery/full-only and is not the normal firmware-upgrade file.
12. **Validate the output before upload.** Require the exact filename, non-loader basename, sane size (>100 MB for this build), a distinct loader image, the correct upstream commit/version, the recorded PKTFWD diff, and a successful SHA-256 round-trip.
13. **Copy and hash the normal firmware immediately after build validation.** This ensures a later CI/upload failure cannot hide or lose the successfully-built flash image.
14. **Emit `FLASH_MANIFEST.txt` only after every provenance/build/hash check passes.** `VERIFIED_FOR_FLASH=YES` is the explicit gate for a usable artifact.
15. **Start a fresh workflow run after changing workflow code.** Do not use `Re-run jobs` from an older run because it can execute the old workflow revision.
16. **Flash only after CI succeeds and the artifact is checked.** Back up router configuration/JFFS first, unzip the GitHub artifact on the Mac, verify `FLASH_MANIFEST.txt`, then upload the normal `.pkgtb` through Administration > Firmware Upgrade. Never upload the artifact ZIP or `_loader.pkgtb` for a normal upgrade.

## Current pinned baseline

For the current GT-BE19000AI `3006.102.8_4` build:

- lineage: `asuswrt6`
- upstream commit: `e6ec7e95706d321c50d1b4b2f912b26323f6163e`
- `SERIALNO=102.8`
- `EXTENDNO=4`
- SDK/build directory: `release/src-rt-5.04behnd.4916`
- make target: `gt-be19000ai`
- compile user: non-root `docker`
- output directory: `release/src-rt-5.04behnd.4916/targets/96813GW/`
- normal flash image: `GT-BE19000AI_3006_102.8_4_emmc_squashfs.pkgtb`
- loader image: `GT-BE19000AI_3006_102.8_4_emmc_squashfs_loader.pkgtb`

Upstream's commit subject incorrectly says `3006.102.8_2`; the commit itself changes `EXTENDNO` from `3` to `4`, and it is the Aug. 20, 2026 release point on the GT-BE19000AI `asuswrt6` lineage.

## Why this rule exists

An earlier CI attempt cloned the generic `3006.102.8_4` tag. That tree contained some GT-BE19000AI files but lacked the GT-BE19000AI model variable in the relevant `target.mak`, so Merlin correctly stopped with `NO THIS TARGET gt-be19000ai`. The target name was never wrong; the source lineage was wrong.

A later build reached Broadcom's prebuild checks while the workflow itself ran as root. Broadcom intentionally rejected that, which established the non-root compile requirement.

Run #5 then completed the full GT-BE19000AI firmware build successfully. Its `BUILD.log` ended with `Done! Image 96813GW has been built in .../targets/96813GW` and showed the exact normal and loader PKGTB files being created there. The workflow nevertheless failed afterward because packaging incorrectly searched `.../image/`. That proved the compile itself had succeeded and the packaging path was wrong. The permanent workflow now captures the exact normal firmware directly from `targets/96813GW`, validates it before upload, and emits an explicit flash manifest only after every check passes.
