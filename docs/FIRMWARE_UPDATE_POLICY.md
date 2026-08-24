# GT-BE19000AI firmware update policy

This is the project rule for future source-level firmware changes.

## Permanent workflow

1. **Do not compile firmware on the router or ASUS AI Board.** Use GitHub Actions so a Mac only needs to start the workflow and download the result.
2. **Do not treat JFFS add-ons and firmware source patches as the same thing.** Shell/add-on code under `/jffs` can be installed without flashing. Changes to compiled Broadcom/ASUS/Merlin C code must be built into firmware.
3. **Use the model's actual Merlin source lineage.** GT-BE19000AI is maintained from Merlin's `asuswrt6` lineage; a same-named generic release tag on another lineage is not sufficient.
4. **Pin an immutable upstream commit SHA. Never build a moving branch head for a production test.** Record the branch/lineage for provenance.
5. **Verify the release identity before compiling.** CI checks `release/src-rt/version.conf`, the GT-BE19000AI entry in `target.mak`, chip profile, model configuration, and required model-specific prebuilts.
6. **Run only the Broadcom/Merlin compile as non-root `docker`.** Broadcom's `prebuild_checks.mk` intentionally rejects root builds. Keep the surrounding GitHub Actions container as root so Actions such as `upload-artifact` can write runner command files; explicitly drop to `docker` for `make`.
7. **Do not destructively replace the toolchain directory.** Use the known working non-destructive `/opt/toolchains` mapping; never `rm -rf /opt/toolchains` as build setup.
8. **Apply only the intended source change and record its diff.** Fail before the expensive compile if the expected source pattern is missing or appears more than once.
9. **Build the real target:** `make gt-be19000ai` from `release/src-rt-5.04behnd.4916`. Do not rename the target to work around an error.
10. **Preserve the real `make` result without immediately killing the job.** Capture the exit status in `MAKE_EXIT_CODE.txt`; the build step itself must allow the evidence-salvage steps to run afterward.
11. **Always salvage evidence before deciding green/red.** On every run, capture `BUILD.log`, a short tail, the target-directory listing, all PKGTB outputs, the exact normal firmware if it exists, its SHA-256, and useful DHD/PKTFWD build-object paths. This salvage step runs with `if: always()`.
12. **Use the real GT-BE19000AI output directory.** The completed build writes eMMC PKGTB files under `release/src-rt-5.04behnd.4916/targets/96813GW/`, not the generic `image/` directory.
13. **The final verifier is the post-build gate.** Require `MAKE_EXIT_CODE=0`, the exact normal firmware file, a successful SHA-256 round-trip, the pinned upstream commit, release identity, and the recorded PKTFWD source diff. Avoid arbitrary image-size, loader-size, generic compiler, or log-string gates that can turn a valid build red for unrelated reasons.
14. **Emit `FLASH_MANIFEST.txt` only after the final verifier passes.** `VERIFIED_FOR_FLASH=YES` means the CI checks passed; it does not replace actual router testing of an experimental source patch.
15. **A red run must still produce diagnostics whenever GitHub Actions itself is functioning.** The failure artifact should contain the build exit code and logs so the next fix is based on the actual failing command rather than the final wrapper error.
16. **Start a fresh workflow run after changing workflow code.** Do not use `Re-run jobs` from an older run because it can execute the old workflow revision.
17. **Flash only after CI succeeds and the artifact is checked.** Back up router configuration/JFFS first, unzip the GitHub artifact on the Mac, verify `FLASH_MANIFEST.txt`, then upload the normal `.pkgtb` through Administration > Firmware Upgrade. Never upload the artifact ZIP itself.

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
- loader image also produced by a complete build: `GT-BE19000AI_3006_102.8_4_emmc_squashfs_loader.pkgtb`

Upstream's commit subject incorrectly says `3006.102.8_2`; the commit itself changes `EXTENDNO` from `3` to `4`, and it is the Aug. 20, 2026 release point on the GT-BE19000AI `asuswrt6` lineage.

## Known lessons from the failed CI iterations

- The generic `3006.102.8_4` lineage was wrong for this model and produced `NO THIS TARGET gt-be19000ai`; the target name itself was correct.
- Running the entire job container as `docker` avoided Broadcom's root check but broke GitHub Actions command-file permissions. The stable split is Actions plumbing as root and only Merlin `make` as `docker`.
- Run #5 completed the full firmware build and produced both GT-BE19000AI PKGTBs, but the workflow searched the wrong `image/` directory afterward. Packaging failure did not mean the compile failed.
- Broadcom `buildFS` can print noisy missing-file messages such as `bcm96813/*.bin`, `patch.version`, `rt_tables`, and `targets/fs.bin`. Those exact messages also occurred in run #5 before Merlin successfully produced the final GT-BE19000AI images. Do **not** infer that proprietary blobs must be extracted from stock firmware from those messages alone; judge the build by the actual `make` exit status and final causal error.
- Do not add speculative validation rules merely because they sound safer. A check is allowed to gate flashing only when it directly establishes model/source/patch/build/artifact integrity.
