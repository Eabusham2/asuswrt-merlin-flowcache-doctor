# Build the patched GT-BE19000AI firmware with GitHub Actions

You do not need Linux on your Mac.

The repository contains a manual GitHub Actions workflow:

`.github/workflows/build-gt-be19000ai-patched.yml`

## What the workflow selects

GT-BE19000AI is maintained on Merlin's `asuswrt6` lineage. The workflow has **no manual version box**: every fresh run resolves the newest stable GT-BE19000AI-compatible release from `asuswrt6`, rejects alpha/beta/RC/development versions, and pins the selected release to its immutable commit SHA for that run.

As of August 23, 2026, the newest stable selection is `3006.102.8_4` at upstream commit:

`e6ec7e95706d321c50d1b4b2f912b26323f6163e`

That upstream commit's subject mistakenly says `_8_2`, but its actual `version.conf` change is `EXTENDNO=3` to `EXTENDNO=4`.

## Important: GT-BE19000AI DHD is prebuilt

A normal GT-BE19000AI Merlin build does **not** compile `dhd_pktfwd.c` into DHD. The model DHD Makefile reports `REBUILD_DHD_MODULE=0` and links a prebuilt whole `dhd.o` copied from:

`release/src-rt-5.04behnd.4916/router-sysdep.gt-be19000ai/hnd_extra/prebuilt/dhd.o`

Therefore a source-only `dhd_pktfwd.c` edit is reference/provenance, not proof that the firmware contains the fix.

The effective workflow now:

1. records the intended `dhd_pktfwd.c` source diff;
2. uses `tools/patch_dhd_pktfwd_prebuilt.py` to locate `dhd_pktfwd_request` in the exact AArch64 ELF prebuilt `dhd.o`;
3. refuses to patch unless the known instruction signature matches exactly;
4. applies the verified same-size PKTFWD instruction change to the actual prebuilt `dhd.o` that Merlin links;
5. runs the normal `make gt-be19000ai` build;
6. locates the final installed `targets/96813GW/fs/lib/modules/*/extra/dhd.ko`;
7. verifies the same patched PKTFWD signature inside that final `dhd.ko`;
8. emits a flash manifest only if the firmware and final DHD binary both pass.

A future stable release with an unknown DHD binary signature fails **before the long compile** rather than being patched by assumption.

## Run it

1. Open this repository on GitHub.
2. Click **Actions**.
3. Click **Build patched GT-BE19000AI firmware**.
4. Click **Run workflow**.
5. Click the green **Run workflow** button. There is no version/source-ref field.
6. Open the new run once it appears.
7. When it finishes successfully, open the run **Summary** and scroll to **Artifacts**.
8. Download `GT-BE19000AI-<resolved version>-pktfwd-patched-<run number>`.
9. Unzip it on the Mac.

Do **not** use **Re-run jobs** on an older workflow run after the workflow file itself has changed. Start a brand-new manual run from current `main`.

## Required artifact proof

Do not approve an artifact merely because the workflow badge is green. Open `FLASH_MANIFEST.txt` and require both:

```text
VERIFIED_FOR_FLASH=YES
DHD_BINARY_PATCH_VERIFIED=YES
```

It must also identify:

```text
PATCH_METHOD=verified-prebuilt-dhd-binary
```

The artifact includes the normal firmware PKGTB, firmware SHA-256, release resolution/provenance, source-reference diff, prebuilt-DHD binary patch reports, final `dhd.ko` inspection/verification reports, build exit code, and build log.

Run #7 (`GT-BE19000AI-3006.102.8_4-pktfwd-patched-7`) must **not** be flashed as the PKTFWD fix. Its build and firmware hash were valid, but artifact audit proved the normal build linked prebuilt DHD while the workflow had only edited the source file. It predates the mandatory final-DHD binary verification gate.

## What file do I upload to the router?

GitHub gives you a ZIP **artifact**. The ZIP itself is not router firmware.

Unzip it, verify the manifest gates above, then upload only the normal generated file ending in:

`_emmc_squashfs.pkgtb`

Do not upload `_loader.pkgtb` for a normal firmware upgrade. Do not rename the image to `.w`, `.trx`, or anything else. If the ASUS firmware page rejects the generated PKGTB, stop rather than forcing it.

## Flash

Before flashing, back up the router configuration and JFFS.

Only after the artifact passes both manifest gates, open **Administration > Firmware Upgrade**, manually upload the normal `*_emmc_squashfs.pkgtb`, and let the router reboot normally.

This remains an experimental custom datapath patch. CI proves exactly what binary was built; live router behavior must still be validated after flashing.

For the permanent project rules, see `docs/FIRMWARE_UPDATE_POLICY.md`.
