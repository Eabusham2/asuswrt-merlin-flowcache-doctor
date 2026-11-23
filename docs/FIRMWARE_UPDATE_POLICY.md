# GT-BE19000AI firmware maintenance policy

This document describes the maintained firmware path. JFFS script releases use
a separate workflow and do not trigger a firmware build.

## Source and compatibility

1. Build in GitHub Actions using the GT-BE19000AI target from Merlin's
   `release/src-rt-5.04behnd.4916` tree.
2. Keep the upstream commit, expected version, expected firmware filename, and
   model prerequisites together in the workflow. The current base is
   `3006.102.9_0` at `9b25e55ca5c56a6f01d6a56264c0f6c47459ada0`.
3. The present workflow uses this fixed pin. Earlier documentation described an
   automatic stable-release selector; that is not the implemented path.
4. When changing the base, verify the GT-BE19000AI chip profile, prebuilt DHD
   location, source-built `wlshared` integration, and expected normal image.
   Similar version labels on another Merlin lineage are insufficient.
5. Keep JFFS changes and firmware changes distinct. The current JFFS healer uses
   MLD-family hardware FlowCache invalidation and does not delete bridge FDB entries.

## Patch and build

- Preserve the proprietary DHD prebuilt. GT-BE19000AI does not compile the open
  `dhd_pktfwd.c` reference source into that object.
- Apply the supported repair through source-built `wlshared_linux.c` and the
  exported DHD delete hook. `dhd_pktc_del_hook(mac, NULL)` requests global-pool
  handling for one station MAC on DHD bridge FDB events.
- Run the actual Broadcom compile as non-root `docker`; retain the known
  toolchain mapping. The workflow currently uses an upstream toolchain image
  tagged `latest`, so output checksums and source identity must be retained.
- Preserve the compile's failure status with shell `pipefail` when logging.
- After build success, require a compiled `wlshared` repair-marker hit, the exact
  normal firmware output, and a successful SHA-256 check before publishing.
- Emit `FLASH_MANIFEST.txt` only after those checks. Retain the source diff,
  upstream identity, prebuilt-DHD checksum, firmware checksum, and marker evidence.
- Upload available diagnostic artifacts even after a failed run. A failed run's
  artifact directory must not be treated as a verified firmware release.

## Publication and device validation

Firmware releases remain prereleases, separately named
`gt-be19000ai-<version>-runner-d3lut-r<run>`. Preserve the original build evidence;
never substitute a scripts archive or an older source-only patch artifact.

Use a fresh workflow run after workflow/patch changes. Before flashing, back up
configuration and JFFS and use only the exact model's normal
`*_emmc_squashfs.pkgtb` image through the firmware upgrade page. Do not force a
rejected image.

Build checks establish source/build/output evidence. Actual flashing, booting,
and reproduction of the routed-upload failure remain separate device checks.
The repair targets stale forwarding state; it does not establish a cure for
independent RF weakness, wiring, DNS, or ISP path loss.

## Historical lessons retained

A visible DHD source diff once failed to reach the packaged model-specific DHD
prebuilt. A later binary-patcher experiment was removed. The maintained path
therefore uses source-built `wlshared` and requires a marker in a compiled output.
The human-readable patch and the Python patch tool are both retained: the tool
applies the build change, while the patch provides a reviewable source reference.
