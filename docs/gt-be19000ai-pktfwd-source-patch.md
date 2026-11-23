# GT-BE19000AI MLO / PKTFWD D3LUT repair

## Failure being fixed

The reproduced close-range failure is not an RF-capacity problem: local Wi-Fi upload can remain hundreds of Mbps while routed WAN upload collapses to single digits. Temporarily disabling Runner hardware acceleration immediately restores upload, and re-enabling it can leave service healthy. This points to stale hardware-offload programming rather than a weak link.

The strongest source-level mechanism is stale DHD PKTFWD D3LUT state during MLO station lifecycle churn. Broadcom's DHD connect path reports association/reassociation event variants, while the open PKTFWD reference source globally deletes stale D3LUT state only for `WLC_E_ASSOC`.

Historical logs such as `dhd_pktfwd_lut_lkup: pool ... and unit 15 mismatched` fit the same stale-radio/domain family.

## Why `dhd_pktfwd.c` is not the effective patch point

GT-BE19000AI's model DHD Makefile uses a model-specific prebuilt whole object:

`release/src-rt-5.04behnd.4916/router-sysdep.gt-be19000ai/hnd_extra/prebuilt/dhd.o`

When that object is present, the model build uses `prebuilt/dhd.o`; `shared/impl1/dhd_pktfwd.c` is not compiled into the shipped DHD module. Therefore the old human-readable association-event source edit remains useful for understanding intended semantics, but a source-only DHD edit is not an effective firmware fix on this model.

## Effective source-built repair point

`shared/impl1/wlshared_linux.c` **is source-built** into `wlshared`. It already exports:

```c
void (*dhd_pktc_del_hook)(unsigned long addr, struct net_device *net_device);
```

The prebuilt DHD assigns that hook to its PKTFWD D3LUT delete routine. Broadcom code already supports calling the hook with `net_device == NULL`; in that case DHD searches `D3LUT_LKUP_GLOBAL_POOL`.

The custom firmware changes the DHD switchdev bridge-event path so DHD-interface FDB add/delete events run:

```c
dhd_pktc_del_hook((unsigned long)(fdb_info->addr), NULL);
```

instead of relying on a possibly stale device/radio-scoped delete. The patch is tagged in the compiled module with:

`FCD_DHD_D3LUT_REPAIR_V1`

The normal DHD prebuilt remains unmodified.

## Why both FDB ADD and DEL are handled

A learned station moving or being recreated can generate bridge FDB lifecycle notifications. Purging the global D3LUT before the mapping is learned/relearned prevents an old radio/domain entry from surviving into the new incarnation.

The source-built bridge layer is therefore a useful choke point even though the proprietary DHD event handler itself is prebuilt.

## Current runtime pairing

The JFFS MLO healer waits for a supported lifecycle/reinitialization event to
settle, verifies MLO/EHT identity, and invalidates hardware FlowCache entries for
the positively identified MLD family. If a live peer-MLD relationship was already
observed, affiliated link MACs can be recovered from its runtime family cache.
A positively identified single-link EHT client can use only its event MAC.

The current runtime never synthesizes bridge FDB deletion. The earlier forced
FDB-relearn design is superseded. Firmware-side D3LUT invalidation still applies
to natural bridge FDB lifecycle notifications; the runtime performs the separate
hardware FlowCache repair. It does not globally flush FlowCache, toggle Runner,
restart Wi-Fi, steer, or deauthenticate the station.

## Firmware build proof

The GitHub Actions workflow patches `wlshared_linux.c`, builds the real GT-BE19000AI target, then requires the marker `FCD_DHD_D3LUT_REPAIR_V1` to be present in a compiled `wlshared.o` or `wlshared.ko` before it emits `VERIFIED_FOR_FLASH=YES`.

A valid manifest identifies:

```text
FIX=FCD_DHD_D3LUT_REPAIR_V1
PATCH_PATH=source-built-wlshared
DHD_PATH=prebuilt-unmodified
```

This avoids both earlier failure modes: assuming an open DHD source edit was compiled, and rewriting an opaque DHD binary by brittle instruction assumptions.

## Scope

This fix targets stale host-side DHD PKTFWD D3LUT and per-client Runner/FlowCache hardware state. It intentionally leaves normal Runner/WFD/FlowCache acceleration enabled.

It does not claim to repair separate physical RF/FEM/antenna weakness, ISP/BGW loss, public-path latency variation, or every far-range bufferbloat condition. Those remain separate phases after the routed-upload failure is validated.
