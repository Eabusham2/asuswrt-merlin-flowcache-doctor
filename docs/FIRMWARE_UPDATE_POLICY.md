# GT-BE19000AI firmware update policy

This is the project rule for future compiled firmware changes.

## Permanent workflow

1. Build firmware in GitHub Actions, not on the router or ASUS AI Board.
2. Keep JFFS add-ons and compiled firmware changes distinct. A source edit only counts if it reaches a binary that the GT-BE19000AI image actually packages.
3. Use Merlin's GT-BE19000AI `asuswrt6` lineage and the real target `make gt-be19000ai` from `release/src-rt-5.04behnd.4916`.
4. Resolve the newest stable compatible release automatically, reject alpha/beta/RC/development versions, and pin the selected immutable upstream commit for the entire run.
5. Record version, lineage, upstream commit, expected firmware filename, build exit code, source diff, and firmware SHA-256 in the artifact.
6. Run only the Broadcom/Merlin `make` command as non-root `docker`; retain root for GitHub Actions/container plumbing.
7. Do not destructively replace the toolchain directory; use the known working `/opt/toolchains` mapping.
8. GT-BE19000AI DHD is prebuilt. Never treat an edit to `shared/impl1/dhd_pktfwd.c` as proof that `dhd.ko` changed.
9. Do not rewrite the proprietary DHD prebuilt merely to force the open-source reference change into it when a supported source-built integration point exists.
10. For the current stale PKTFWD/D3LUT problem, the effective repair point is source-built `shared/impl1/wlshared_linux.c`. It owns the exported `dhd_pktc_del_hook`, while the prebuilt DHD provides the actual D3LUT delete implementation.
11. The D3LUT repair uses `dhd_pktc_del_hook(mac, NULL)` for DHD bridge FDB add/delete events. `NULL` deliberately invokes the prebuilt DHD's global-pool lookup, avoiding stale device/radio pool selection.
12. Preserve the real `make` result in `MAKE_EXIT_CODE.txt`, but allow salvage steps to run before the final green/red decision.
13. Always salvage the build log, log tail, target-directory listing, PKGTB outputs, firmware SHA-256, source diff, and compiled wlshared evidence.
14. The normal image is under `targets/96813GW/` and ends in `_emmc_squashfs.pkgtb`. `_loader.pkgtb` is not the normal firmware-upgrade image.
15. A firmware patch must contain a deterministic marker or equivalent proof in the compiled binary that should carry the change. For D3LUT repair v1 the marker is `FCD_DHD_D3LUT_REPAIR_V1` in source-built `wlshared.o`/`wlshared.ko`.
16. The final gate requires `MAKE_EXIT_CODE=0`, exact firmware presence, SHA-256 round-trip, resolved release identity, expected source diff, built wlshared output, and compiled repair marker.
17. Emit `FLASH_MANIFEST.txt` only after those gates pass. For the current repair it must include:

```text
VERIFIED_FOR_FLASH=YES
FIX=FCD_DHD_D3LUT_REPAIR_V1
PATCH_PATH=source-built-wlshared
DHD_PATH=prebuilt-unmodified
```

18. A failed run should still upload diagnostics whenever Actions itself is functioning.
19. Start a brand-new workflow run after workflow/patch code changes; do not re-run an old run whose workflow revision is stale.
20. Before flashing, back up router configuration and JFFS. Flash only the normal `.pkgtb` through the ASUS/Merlin firmware page and do not force a rejected image.
21. After flashing, validate the original reproduced failure before changing unrelated settings. Keep Runner/WFD/FlowCache enabled unless a temporary diagnostic toggle is specifically required.
22. Do not add speculative validation gates. A gate must establish model identity, effective patch inclusion, build integrity, or artifact integrity.

## Automatic release selection

The workflow has no manual version input. A fresh run walks stable release-version commits on `asuswrt6`, newest first, and requires the GT-BE19000AI target plus the exact build-path prerequisites used by the repair.

The established `3006.102.8_4` base is upstream commit:

`e6ec7e95706d321c50d1b4b2f912b26323f6163e`

At the time that base was established, the development branch had already moved beyond it; the stable selector intentionally rejects that development head. Future stable versions may be selected automatically only when their tree still exposes the required model/build integration points.

## Lessons that must not regress

- A generic or wrong Merlin lineage can contain a similar version string while lacking the GT-BE19000AI target. Model compatibility is a tree/build property, not just a version label.
- Broadcom's build rejects running the actual compile as root; Actions still needs root-capable plumbing around it.
- Successful firmware output can exist even when a later artifact-search step is wrong. Judge the compile by its exit code and causal error, then fix packaging separately.
- Run #7 proved that a green build plus a visible source diff is insufficient: GT-BE19000AI linked a prebuilt DHD while `dhd_pktfwd.c` was never compiled.
- The later DHD binary-patcher experiment was removed from the production path. The current design reaches the required semantics through source-built `wlshared` and the DHD-exported delete hook instead of modifying the opaque DHD object.
- `dhd_pktfwd_lut_del(mac, NULL)` is not an invented behavior: the Broadcom implementation explicitly treats `net_device == NULL` as a global-pool lookup, and stock integration code already uses the delete hook with `NULL` in another path.
- Bridge FDB lifecycle events are an appropriate repair trigger because `wlshared` already consumes switchdev FDB notifications. The JFFS healer can additionally force a single-client FDB relearn after an MLO lifecycle event when no natural source move occurs.
- The repair must remain narrow: one client MAC, global D3LUT invalidation for that MAC, then one-client hardware FlowCache invalidation. No automatic global FlowCache flush, Runner cycle, Wi-Fi restart, or deauthentication.
