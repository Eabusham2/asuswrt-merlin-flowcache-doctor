# Build the patched GT-BE19000AI firmware with GitHub Actions

You do not need Linux on your Mac.

The repository contains a manual GitHub Actions workflow:

`.github/workflows/build-gt-be19000ai-patched.yml`

By default it builds the exact Asuswrt-Merlin release tag `3006.102.8_4`, patches the verified `dhd_pktfwd.c` association/reassociation cleanup gate directly, verifies the resulting Git diff, builds `gt-be19000ai`, and uploads the resulting firmware as an Actions artifact.

The direct source edit is intentional: the first workflow version used a hand-written patch file whose unified-diff hunk was malformed and `git apply` rejected it. The workflow now requires exactly one matching source gate and aborts if upstream source no longer matches that expectation.

## Run it

1. Open this repository on GitHub.
2. Click **Actions**.
3. Click **Build patched GT-BE19000AI firmware** in the left sidebar.
4. Click **Run workflow**.
5. Leave `merlin_ref` as `3006.102.8_4`.
6. Click the green **Run workflow** button.
7. Open the new run once it appears.
8. When it finishes successfully, scroll to **Artifacts**.
9. Download `GT-BE19000AI-pktfwd-patched-<run number>`.
10. Unzip it on the Mac.

Do **not** use **Re-run jobs** on an older failed workflow run after the workflow itself has been changed. Start a brand-new manual run from current `main` so GitHub uses the current workflow definition.

The artifact contains:

- the generated `*_emmc_squashfs.pkgtb` firmware image;
- `FIRMWARE_SHA256.txt`;
- `MERLIN_COMMIT.txt`;
- `PATCH_REPO_COMMIT.txt`;
- `PATCH_SHA256.txt`;
- `APPLIED_SOURCE_DIFF.patch`;
- `PATCHED_SOURCE_SNIPPET.txt`;
- `BUILD.log`.

## What file do I upload to the router?

GitHub gives you a ZIP **artifact**. The ZIP itself is not router firmware.

Unzip the artifact on the Mac, then upload only the generated file ending in:

`_emmc_squashfs.pkgtb`

The Merlin build system uses this PKGTB image format for the GT-BE19000AI. Do not rename it to `.w`, `.trx`, or anything else. If the ASUS firmware page rejects the generated PKGTB, stop rather than forcing it.

## Flash

Before flashing, back up the router configuration and JFFS.

In the router UI open **Administration > Firmware Upgrade**, manually upload the generated `*_emmc_squashfs.pkgtb`, and let the router reboot normally.

This is an experimental custom firmware build. The workflow records the exact upstream Merlin commit and applied source diff so the image can be audited/reproduced.
