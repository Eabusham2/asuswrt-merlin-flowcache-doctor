# Contributor guidance

## Scope and source of truth

This repository provides GT-BE19000AI / Asuswrt-Merlin JFFS diagnostics and
recovery scripts, plus a separate experimental firmware build. Keep the public
README grounded in current source and verified results. Historical research in
`docs/GT_BE19000AI_ROOT_CAUSE_RESEARCH_2026-08-25.md` is dated evidence, not current
installation policy or proof of wider hardware compatibility.

## Source map

| Area | Files |
| --- | --- |
| Core installation and removal | `install.sh`, `uninstall.sh`, `scripts/roamctl` |
| Classification and policy | `scripts/fcd-lib.sh`, `scripts/fcd-platform-gtbe19000ai.sh` |
| MLO recovery | `scripts/fcd-mlo-runner-heal.sh` |
| Optional components | `install-airiq-guard.sh`, `install-wifi-dropwatch.sh`, documented tools in `scripts/` |
| Script checks | `tools/check.sh`, `tests/` |
| Script packaging | `.github/workflows/release.yml`, `tools/package-release.py` |
| Firmware build and patch | `.github/workflows/build-gt-be19000ai-patched.yml`, `tools/patch-wlshared-d3lut.py`, `patches/` |

## Runtime invariants

- Keep router runtime scripts compatible with POSIX/BusyBox `sh`.
- Preserve fail-closed client classification: unknown identities must not
  authorize a hardware-flow flush. Retain settle/cooldown behavior and the
  proven MLD-family relationship used for affiliated link MACs.
- Keep recovery targeted. Do not broaden the MLO healer into synthetic bridge-FDB
  deletion, global FlowCache flushes, Runner cycles, Wi-Fi restarts, steering,
  or deauthentication.
- Preserve unrelated startup hooks, cron entries, and user files during
  installation, updates, and removal. Verify ownership and references before
  consolidating files; optional installation does not mean a tool is unused.
- Keep private network values and client identities out of production defaults.
  Use synthetic fixtures for tests and configurable values for deployments.
- Preserve `FCD_REF` pinning for release downloads and keep installer/CLI version
  labels consistent. Document configuration replacement and actual removal limits.

## Verification

From the repository root on Linux with Python 3 and BusyBox:

```sh
sh tools/check.sh
```

The suite uses simulated commands and an isolated temporary installer tree.
Use that simulation for development; do not run the production installer
against the development host's real `/jffs`. Test fixture changes must retain
meaningful checks for the affected behavior and existing recovery boundaries.

For documentation-only edits, check links, anchors, source claims, and
`git diff --check`. For runtime, installer, or packaging changes, run the
relevant behavior checks and the suite before release. Validate workflow edits
with actionlint when available. Report source checks, CI results, and physical
router testing separately; a passing simulation is not hardware certification.

## Documentation and releases

Preserve MIT notices and upstream attribution when moving or packaging files.
Keep public guidance free of personal deployment assumptions. Explain separate
script and firmware deliverables and the supported model. Related repositories
have independent requirements; cross-links do not establish combined validation.

Script releases use a full source SHA, version-matched tag, checksums, and a
provenance manifest after the tests pass. Preserve existing release assets.
Firmware changes retain their separate upstream pin, compiled-marker checks,
proof files, and prerelease status. Keep the source patch and patch tool aligned,
and do not infer new firmware compatibility from a matching version label alone.
