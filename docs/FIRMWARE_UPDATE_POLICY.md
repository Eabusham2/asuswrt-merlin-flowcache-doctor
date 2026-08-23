# GT-BE19000AI firmware update policy

This is the project rule for future source-level firmware changes.

## Permanent workflow

1. **Do not compile firmware on the router or ASUS AI Board.** Use GitHub Actions so a Mac only needs to start the workflow and download the result.
2. **Do not treat JFFS add-ons and firmware source patches as the same thing.** Shell/add-on code under `/jffs` can be installed without flashing. Changes to compiled Broadcom/ASUS/Merlin C code must be built into firmware.
3. **Use the model's actual Merlin source lineage.** GT-BE19000AI is maintained from Merlin's `asuswrt6` lineage; a same-named generic release tag on another lineage is not sufficient.
4. **Pin an immutable upstream commit SHA. Never build a moving branch head for a production test.** Record the branch/lineage only for provenance.
5. **Verify the release identity before compiling.** CI must check `release/src-rt/version.conf`, the GT-BE19000AI entry in `target.mak`, chip profile, model configuration, and required model-specific prebuilts.
6. **Run Broadcom/Merlin compilation as the image's non-root `docker` user.** The Broadcom prebuild checks intentionally reject root builds. Use `sudo` only for one-time ownership/toolchain setup such as `/project` and `/opt/toolchains`, then verify `id -u != 0` before `make`.
7. **Apply only the intended source change and record its diff/hash.** Fail if the expected source pattern is missing or appears more than once.
8. **Build the real target:** `make gt-be19000ai` from `release/src-rt-5.04behnd.4916`. Do not rename the target to work around an error.
9. **Require one GT-BE19000AI eMMC firmware image:** `*_emmc_squashfs.pkgtb`. Record its SHA-256 and upstream source commit.
10. **Start a fresh workflow run after changing workflow code.** Do not use `Re-run jobs` from an older run because it can execute the old workflow revision.
11. **Flash only after CI succeeds and the artifact is checked.** Back up router configuration/JFFS first, unzip the GitHub artifact on the Mac, then upload the `.pkgtb` through Administration > Firmware Upgrade. Never upload the artifact ZIP itself.

## Current pinned baseline

For the current GT-BE19000AI `3006.102.8_4` build:

- lineage: `asuswrt6`
- upstream commit: `e6ec7e95706d321c50d1b4b2f912b26323f6163e`
- `SERIALNO=102.8`
- `EXTENDNO=4`
- SDK/build directory: `release/src-rt-5.04behnd.4916`
- make target: `gt-be19000ai`
- build user: non-root `docker`
- output format: `*_emmc_squashfs.pkgtb`

Upstream's commit subject incorrectly says `3006.102.8_2`; the commit itself changes `EXTENDNO` from `3` to `4`, and it is the Aug. 20, 2026 release point on the GT-BE19000AI `asuswrt6` lineage.

## Why this rule exists

An earlier CI attempt cloned the generic `3006.102.8_4` tag. That tree contained some GT-BE19000AI files but lacked the GT-BE19000AI model variable in the relevant `target.mak`, so Merlin correctly stopped with:

`NO THIS TARGET gt-be19000ai`

The target name was never wrong; the source lineage was wrong. Future workflows must detect that in preflight instead of discovering it after a large checkout/build attempt.

A later build reached Broadcom's `prebuild_checks` but the workflow had forced the container to run as `root`. Broadcom intentionally aborts root builds, so the permanent workflow follows the known-working Gnuton pattern: container user `docker`, `sudo chown` only for setup, and a hard non-root assertion before compilation.
