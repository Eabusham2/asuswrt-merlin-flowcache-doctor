# GT-BE19000AI firmware update policy

This is the project rule for future source-level firmware changes.

## Permanent workflow

1. **Do not compile firmware on the router or ASUS AI Board.** Use GitHub Actions so a Mac only needs to start the workflow and download the result.
2. **Do not treat JFFS add-ons and firmware source patches as the same thing.** Shell/add-on code under `/jffs` can be installed without flashing. Changes to compiled Broadcom/ASUS/Merlin code must be represented in the binary that the firmware actually links.
3. **Use the model's actual Merlin source lineage.** GT-BE19000AI is maintained from Merlin's `asuswrt6` lineage; a same-named generic release tag on another lineage is not sufficient.
4. **Automatically select the newest stable GT-BE19000AI-compatible Merlin release.** The workflow inspects `asuswrt6` release-version commits newest-to-oldest and selects the first stable release (`SERIALNO` numeric, `EXTENDNO` numeric, `RCNO=0`) whose tree contains the GT-BE19000AI target, chip profile, model configuration, required model prebuilts, PKTFWD reference source, and the model's prebuilt DHD object. Alpha, beta, RC, and development heads are rejected automatically.
5. **Pin the selected release to its immutable upstream commit SHA for that run.** Never compile a moving branch head. Record the resolved version, lineage, commit, and expected firmware filename in `RELEASE_RESOLUTION.txt` and the final manifest.
6. **Verify the resolved release identity before compiling.** CI checks `release/src-rt/version.conf`, the GT-BE19000AI entry in `target.mak`, chip profile, model configuration, required model-specific prebuilts, and the exact selected commit.
7. **Run only the Broadcom/Merlin compile as non-root `docker`.** Broadcom's `prebuild_checks.mk` intentionally rejects root builds. Keep the surrounding GitHub Actions container as root so Actions such as `upload-artifact` can write runner command files; explicitly drop to `docker` for `make`.
8. **Do not destructively replace the toolchain directory.** Use the known working non-destructive `/opt/toolchains` mapping; never `rm -rf /opt/toolchains` as build setup.
9. **Treat the open `dhd_pktfwd.c` edit as reference/provenance, not binary proof.** On GT-BE19000AI 3006.102.8_4, Merlin's DHD Makefile selects `REBUILD_DHD_MODULE=0` and links a model-specific prebuilt whole `dhd.o`. Therefore editing `shared/impl1/dhd_pktfwd.c` alone does not put the change into `dhd.ko`.
10. **Patch the exact prebuilt DHD object that Merlin actually links.** The effective PKTFWD fix is applied to `router-sysdep.gt-be19000ai/hnd_extra/prebuilt/dhd.o` with `tools/patch_dhd_pktfwd_prebuilt.py`. The tool must locate `dhd_pktfwd_request` through ELF metadata, require the exact known AArch64 instruction signature, refuse unknown binaries, make only the verified same-size instruction changes, and verify the patched signature immediately afterward.
11. **Unknown future DHD binaries fail early.** Automatic latest-stable selection does not authorize blind binary patching. If a future stable release changes the DHD instruction signature, CI must stop before the hour-long compile so the patch can be re-audited for that release.
12. **Build the real target:** `make gt-be19000ai` from `release/src-rt-5.04behnd.4916`. Do not rename the target to work around an error.
13. **Preserve the real `make` result without immediately killing the job.** Capture the exit status in `MAKE_EXIT_CODE.txt`; the build step itself must allow evidence-salvage steps to run afterward.
14. **Always salvage evidence before deciding green/red.** On every run, capture `BUILD.log`, a short tail, target-directory listing, all PKGTB outputs, the exact normal firmware if present, SHA-256 data, the prebuilt-DHD patch reports, and final-module inspection data. This salvage step runs with `if: always()`.
15. **Use the real GT-BE19000AI output directory.** The completed build writes eMMC PKGTB files under `release/src-rt-5.04behnd.4916/targets/96813GW/`, not the generic `image/` directory.
16. **Derive the expected normal firmware name from the resolved stable release.** Current naming is `GT-BE19000AI_3006_<SERIALNO>_<EXTENDNO>_emmc_squashfs.pkgtb`. Require the exact normal file and never substitute `_loader.pkgtb` for a normal firmware update.
17. **Verify the final linked DHD module, not just the input object.** After `make`, locate exactly one `targets/96813GW/fs/lib/modules/*/extra/dhd.ko` and run the same ELF/signature verifier against it. This is the proof that the firmware filesystem contains the effective PKTFWD patch.
18. **The final verifier is the post-build gate.** Require `MAKE_EXIT_CODE=0`, the exact normal firmware, successful SHA-256 round-trip, resolved upstream commit/version, source-reference diff, patched prebuilt DHD report, exactly one final `dhd.ko`, and a successful patched-signature verification of that final module.
19. **Emit `FLASH_MANIFEST.txt` only after every gate passes.** It must contain both `VERIFIED_FOR_FLASH=YES` and `DHD_BINARY_PATCH_VERIFIED=YES`, plus `PATCH_METHOD=verified-prebuilt-dhd-binary`, resolved release data, firmware hash, and final DHD-module hash. A green run without those exact manifest claims is not approved for flashing.
20. **A red run must still produce diagnostics whenever GitHub Actions itself is functioning.** The failure artifact should contain the build exit code and available reports/logs so the next fix is based on the actual failing command.
21. **Start a fresh workflow run after changing workflow code.** Do not use `Re-run jobs` from an older run because it can execute the old workflow revision.
22. **Flash only after CI succeeds and the artifact is checked.** Back up router configuration/JFFS first, unzip the GitHub artifact on the Mac, verify both manifest gates, then upload the normal `.pkgtb` through Administration > Firmware Upgrade. Never upload the artifact ZIP itself.

## Automatic release selection

The workflow intentionally has **no version input box**. Each fresh run resolves the newest stable compatible GT-BE19000AI release from Merlin's `asuswrt6` lineage.

As of August 23, 2026:

- `asuswrt6` development head is `3006.102.9 alpha1`, so it is automatically rejected.
- the newest stable compatible release resolves to `3006.102.8_4`.
- that release resolves to upstream commit `e6ec7e95706d321c50d1b4b2f912b26323f6163e`.
- its normal flash image is `GT-BE19000AI_3006_102.8_4_emmc_squashfs.pkgtb`.

When Merlin publishes a newer stable release that still passes the model/source gates, the resolver may select it automatically. The DHD binary patcher is a separate, stricter compatibility gate: a changed binary signature is rejected before compilation rather than being patched by assumption.

## Known lessons from the failed CI iterations

- The generic `3006.102.8_4` lineage was wrong for this model and produced `NO THIS TARGET gt-be19000ai`; the target name itself was correct.
- Running the entire job container as `docker` avoided Broadcom's root check but broke GitHub Actions command-file permissions. The stable split is Actions plumbing as root and only Merlin `make` as `docker`.
- Run #5 completed the full firmware build and produced both GT-BE19000AI PKGTBs, but the workflow searched the wrong `image/` directory afterward. Packaging failure did not mean the compile failed.
- Broadcom `buildFS` can print noisy missing-file messages such as `bcm96813/*.bin`, `patch.version`, `rt_tables`, and `targets/fs.bin`. Those exact messages also occurred in run #5 before Merlin successfully produced the final GT-BE19000AI images. Do **not** infer that proprietary blobs must be extracted from stock firmware from those messages alone; judge the build by the actual `make` exit status and final causal error.
- Run #7 was the first fully green packaging/provenance build, and its firmware SHA-256 and `MAKE_EXIT_CODE=0` were valid. However, artifact audit showed the build log reported `module : 0`, then linked `hnd_dhd/dhd.o` and `dhd.ko` without compiling `dhd_pktfwd.c`. The model's `platform.mak` copies `router-sysdep.gt-be19000ai/hnd_extra/prebuilt/dhd.o` into the DHD prebuilt path, and the DHD Makefile uses that whole object when source is unavailable. Therefore run #7 must **not** be flashed as the PKTFWD fix: the source diff alone did not prove the effective binary changed.
- The effective fix now targets the actual linked prebuilt DHD object and independently verifies the final installed `dhd.ko`. This binary-level proof is mandatory before flashing.
- Do not add speculative validation rules merely because they sound safer. A check is allowed to gate flashing only when it directly establishes model/source/patch/build/artifact integrity.
