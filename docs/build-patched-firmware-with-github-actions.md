# Build the patched GT-BE19000AI firmware with GitHub Actions

You do not need Linux on your Mac.

The repository contains a manual GitHub Actions workflow:

`.github/workflows/build-gt-be19000ai-patched.yml`

By default it builds the exact Asuswrt-Merlin release tag `3006.102.8_4`, applies `patches/gt-be19000ai-pktfwd-reassoc-invalidation.patch`, builds `gt-be19000ai`, and uploads the resulting firmware as an Actions artifact.

## Run it

1. Open this repository on GitHub.
2. Click **Actions**.
3. Click **Build patched GT-BE19000AI firmware** in the left sidebar.
4. Click **Run workflow**.
5. Leave `merlin_ref` as `3006.102.8_4`.
6. Click the green **Run workflow** button.
7. Open the run once it appears.
8. When it finishes successfully, scroll to **Artifacts**.
9. Download `GT-BE19000AI-pktfwd-patched-<run number>`.
10. Unzip it on the Mac.

The artifact contains:

- the generated `*_emmc_squashfs.pkgtb` firmware image;
- `FIRMWARE_SHA256.txt`;
- `MERLIN_COMMIT.txt`;
- `PATCH_REPO_COMMIT.txt`;
- `PATCH_SHA256.txt`;
- `APPLIED_SOURCE_DIFF.patch`;
- `PATCHED_SOURCE_SNIPPET.txt`;
- `BUILD.log`.

## Flash

Before flashing, back up the router configuration and JFFS.

In the router UI open **Administration > Firmware Upgrade**, manually upload the generated `*_emmc_squashfs.pkgtb`, and let the router reboot normally.

This is an experimental custom firmware build. The workflow records the exact upstream Merlin commit and source patch used so the image can be audited/reproduced.
