# GT-BE19000AI firmware update policy

This is the project rule for future source-level firmware changes.

## Permanent workflow

1. **Do not compile firmware on the router or ASUS AI Board.** Use GitHub Actions so a Mac only needs to start the workflow and download the result.
2. **Do not treat JFFS add-ons and firmware source patches as the same thing.** Shell/add-on code under `/jffs` can be installed without flashing. Changes to compiled Broadcom/ASUS/Merlin C code must be built into firmware.
3. **Use the model's actual Merlin source lineage.** GT-BE19000AI is maintained from Merlin's `asuswrt6` lineage; a same-named generic release tag on another lineage is not sufficient.
4. **Automatically select the newest stable GT-BE19000AI-compatible Merlin release.** The workflow must inspect `asuswrt6` release-version commits newest-to-oldest and select the first release whose `version.conf` is stable (`SERIALNO` numeric, `EXTENDNO` numeric, `RCNO=0`) and whose tree contains the GT-BE19000AI target, chip profile, model configuration, model-specific prebuilts, and patchable PKTFWD source. Alpha, beta, RC, and development heads are rejected automatically.
5. **Pin the selected release to its immutable upstream commit SHA for that run.** Never compile a moving branch head. Record the resolved version, lineage, commit, and expected firmware filename in `RELEASE_RESOLUTION.txt` and the final manifest.
6. **Verify the resolved release identity before compiling.** CI checks `release/src-rt/version.conf`, the GT-BE19000AI entry in `target.mak`, chip profile, model configuration, required model-specific prebuilts, and the exact selected commit.
7. **Run only the Broadcom/Merlin compile as non-root `docker`.** Broadcom's `prebuild_checks.mk` intentionally rejects root builds. Keep the surrounding GitHub Actions container as root so Actions such as `upload-artifact` can write runner command files; explicitly drop to `docker` for `make`.
8. **Do not destructively replace the toolchain directory.** Use the known working non-destructive `/opt/toolchains` mapping; never `rm -rf /opt/toolchains` as build setup.
9. **Apply only the intended source change and record its diff.** Fail before the expensive compile if the expected source pattern is missing or appears more than once. This is also a compatibility gate: if a future Merlin release changes the PKTFWD source structure, stop rather than applying the old patch blindly.
10. **Build the real target:** `make gt-be19000ai` from `release/src-rt-5.04behnd.4916`. Do not rename the target to work around an error.
11. **Preserve the real `make` result without immediately killing the job.** Capture the exit status in `MAKE_EXIT_CODE.txt`; the build step itself must allow the evidence-salvage steps to run afterward.
12. **Always salvage evidence before deciding green/red.** On every run, capture `BUILD.log`, a short tail, the target-directory listing, all PKGTB outputs, the exact normal firmware if it exists, its SHA-256, and useful DHD/PKTFWD build-object paths. This salvage step runs with `if: always()`.
13. **Use the real GT-BE19000AI output directory.** The completed build writes eMMC PKGTB files under `release/src-rt-5.04behnd.4916/targets/96813GW/`, not the generic `image/` directory.
14. **Derive the expected normal firmware name from the resolved stable release.** Current naming is `GT-BE19000AI_3006_<SERIALNO>_<EXTENDNO>_emmc_squashfs.pkgtb`. The workflow must require the exact normal file for the resolved version and must not substitute the `_loader.pkgtb` image for a normal firmware update.
15. **The final verifier is the post-build gate.** Require `MAKE_EXIT_CODE=0`, the exact normal firmware file, a successful SHA-256 round-trip, the resolved upstream commit/version, and the recorded PKTFWD source diff. Avoid arbitrary image-size, loader-size, generic compiler, or log-string gates that can turn a valid build red for unrelated reasons.
16. **Emit `FLASH_MANIFEST.txt` only after the final verifier passes.** It must include `VERIFIED_FOR_FLASH=YES`, `AUTO_RELEASE_SELECTION=YES`, the resolved version, upstream commit, and flash filename. This means the CI integrity checks passed; it does not replace actual router testing of an experimental source patch.
17. **A red run must still produce diagnostics whenever GitHub Actions itself is functioning.** The failure artifact should contain the build exit code and logs so the next fix is based on the actual failing command rather than the final wrapper error.
18. **Start a fresh workflow run after changing workflow code.** Do not use `Re-run jobs` from an older run because it can execute the old workflow revision.
19. **Flash only after CI succeeds and the artifact is checked.** Back up router configuration/JFFS first, unzip the GitHub artifact on the Mac, verify `FLASH_MANIFEST.txt`, then upload the normal `.pkgtb` through Administration > Firmware Upgrade. Never upload the artifact ZIP itself.

## Automatic release selection

The workflow intentionally has **no version input box**. Each fresh run resolves the newest stable compatible GT-BE19000AI release from Merlin's `asuswrt6` lineage.

As of August 23, 2026:

- `asuswrt6` development head is `3006.102.9 alpha1`, so it is automatically rejected.
- the newest stable compatible release resolves to `3006.102.8_4`.
- that release resolves to upstream commit `e6ec7e95706d321c50d1b4b2f912b26323f6163e`.
- its normal flash image is `GT-BE19000AI_3006_102.8_4_emmc_squashfs.pkgtb`.

When Merlin publishes a newer stable release that still passes the GT-BE19000AI model/source compatibility gates, a new workflow run will automatically select and build it without editing the workflow. If a future release changes the model build path or the PKTFWD source so the current patch is no longer valid, CI must stop before the long compile or before flashing rather than silently forcing compatibility.

## Known lessons from the failed CI iterations

- The generic `3006.102.8_4` lineage was wrong for this model and produced `NO THIS TARGET gt-be19000ai`; the target name itself was correct.
- Running the entire job container as `docker` avoided Broadcom's root check but broke GitHub Actions command-file permissions. The stable split is Actions plumbing as root and only Merlin `make` as `docker`.
- Run #5 completed the full firmware build and produced both GT-BE19000AI PKGTBs, but the workflow searched the wrong `image/` directory afterward. Packaging failure did not mean the compile failed.
- Broadcom `buildFS` can print noisy missing-file messages such as `bcm96813/*.bin`, `patch.version`, `rt_tables`, and `targets/fs.bin`. Those exact messages also occurred in run #5 before Merlin successfully produced the final GT-BE19000AI images. Do **not** infer that proprietary blobs must be extracted from stock firmware from those messages alone; judge the build by the actual `make` exit status and final causal error.
- Do not add speculative validation rules merely because they sound safer. A check is allowed to gate flashing only when it directly establishes model/source/patch/build/artifact integrity.
