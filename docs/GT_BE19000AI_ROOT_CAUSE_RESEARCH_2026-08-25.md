# GT-BE19000AI root-cause research and remaining issue plan

Updated: 2026-08-25 CDT

Router: ASUS GT-BE19000AI
Current base: Asuswrt-Merlin 3006.102.8_4
LAN: 192.168.50.1/24
WAN: eth0
ISP: AT&T Fiber / BGW320 passthrough

## Priority order

1. Severe routed-upload collapse / Runner stale state.
2. Selective wired-client Internet failure / packet loss.
3. Random Internet drops, page/Speedtest spinners, first-connect delay.
4. Far-range RSSI / throughput collapse.
5. Far-range loaded-latency / jumpy transfer behavior.
6. Residual close-range baseline-latency regression.
7. Stable throughput regression.
8. Separate AT&T/BGW/public-path variability.
9. 2.4 GHz throughput last.

Do not merge all symptoms into one cause without evidence.

## 1. Routed-upload collapse — strongest current root cause

### Reproduction

During the strongest captured failure, the affected iPhone still had strong RF and high PHY rate, and local Wi-Fi upload to a wired Mac remained hundreds of Mbps. Routed Internet upload simultaneously fell to roughly 2-8 Mbps, with some partial-recovery states around tens or ~100 Mbps.

Stopping DynBQ and restoring native queue values did not repair that close-range routed-upload state.

A temporary:

```sh
fcctl config --hw-accel 0
```

immediately restored routed upload. Re-enabling hardware acceleration then left upload healthy. Flow Ucast population did not disappear when hardware acceleration was disabled, separating software FlowCache population from the broken hardware programming layer.

### Source evidence

Broadcom's open DHD/PKTFWD reference source globally deletes a station's D3LUT entry for `WLC_E_ASSOC`, but not the other association/reassociation event variants seen in AP/MLO lifecycle handling.

Historical logs include D3LUT pool/unit mismatch evidence, consistent with stale station/radio-domain mapping.

### GT-BE19000AI build constraint

The model does not compile the open `dhd_pktfwd.c` into DHD. The model DHD Makefile links a proprietary prebuilt `dhd.o`. Therefore the old direct source edit was not an effective firmware patch.

### Implemented firmware repair

The source-built `wlshared_linux.c` layer receives switchdev bridge FDB lifecycle notifications and exports `dhd_pktc_del_hook`. The prebuilt DHD registers that hook to its PKTFWD D3LUT delete implementation.

Custom firmware changes DHD-interface FDB ADD/DEL handling to call:

```c
dhd_pktc_del_hook((unsigned long)(fdb_info->addr), NULL);
```

The `NULL` device makes DHD search the global D3LUT pool instead of a possibly stale device/radio pool. The compiled marker is:

```text
FCD_DHD_D3LUT_REPAIR_V1
```

### Runtime pairing

The JFFS MLO healer now reacts only to positively identified MLO/EHT lifecycle/reinit events, settles/debounces the event burst, deletes only the affected client's bridge FDB entry, and then runs:

```sh
fcctl flush --hw --mac <client-mac>
```

The FDB delete makes patched `wlshared` invoke the global DHD D3LUT purge. The client remains associated and normal traffic relearns the mapping.

No automatic global FlowCache flush, Runner cycle, Wi-Fi restart, steering, or deauthentication is used.

### Validation after flash

First validate the original failure, before unrelated tuning:

- close-range local Wi-Fi upload remains healthy;
- routed WAN upload stays healthy through normal MLO reassociation/lifecycle churn;
- healer logs show the affected MAC and D3LUT relearn/purge path;
- no manual Wi-Fi reconnect or Runner toggle is needed.

If a failure returns, capture the state before recovery and compare a second client. This distinguishes a per-client mapping failure from a broader Runner instance failure.

## 2. Selective wired-client Internet failure

Historical evidence includes cases where one wired host experienced severe gateway latency/timeouts while other connectivity remained better, and at least one incident recovered after physical replug.

Do not assume this is entirely the same DHD/MLO bug: a wired-only failure can involve bridge FDB, Ethernet switch/port state, Runner/FlowCache, cabling/PHY, or upstream path behavior.

Next investigation should capture, during the failure and before replug/reboot:

- gateway ping from affected and unaffected wired hosts;
- switch/port link state and counters;
- bridge FDB entry for the affected host;
- FlowCache/Runner state and per-host entries if exposed;
- public-IP reachability vs gateway reachability;
- whether another LAN host can reach the affected wired host.

The new DHD-specific firmware patch should not be claimed as a wired-port cure until this is reproduced and compared.

## 3. Random drops / spinning / first-connect delay

Symptoms include intermittent no-Internet states, pages or Speedtest loading for long periods, and newly connected clients taking time before becoming usable.

Potential overlap with the D3LUT/Runner bug is plausible when the event follows Wi-Fi association/reassociation, but DNS, upstream routing, bridge state, and separate radio/driver stalls remain open.

Incident capture should classify each occurrence by:

- LAN gateway reachable?
- local LAN peer reachable?
- public IP reachable?
- DNS server reachable and resolving?
- one client or many clients?
- Wi-Fi only or wired too?
- association/reassociation/SBF event immediately before failure?

## 4. Far-range RSSI / speed collapse

This remains open and may be independent of Runner.

Observed history includes very strong close RSSI but extremely weak far-range RSSI and a large gap versus the BGW at the same location. MLO can also keep useful traffic on a dying 6 GHz link while a stronger 5 GHz association exists.

Possible families:

- physical antenna/feed/FEM/radio-chain weakness on this unit;
- radiation-pattern / placement interaction;
- transmit-power/calibration behavior;
- MLO link-selection pathology at range;
- environmental attenuation/interference.

Do not patch regulatory or transmit-power limits blindly. Compare per-chain RSSI, same-location single-band behavior, orientation, and another known-good AP/router first.

## 5. Far-range loaded latency / jumpy throughput

Likely contributors include weak PHY, retries, airtime inflation, and poor MLO link choice. DynBQ may matter here even though it did not cause the close-range routed-upload collapse.

Resolve the RF/link-selection problem before treating this as a queue-management problem.

## 6. Residual close baseline latency

Historical exact-server baseline was roughly 13 ms on Mac and low-30s ms on iPhone; recent values can sit several milliseconds higher and sometimes jump much more.

Separate stable local/router latency, first upstream hop, speed-test server/path changes, and Wi-Fi airtime before attributing the difference to firmware.

## 7. Stable throughput regression

Historical wired/close performance reached roughly 958-961 Mbps; normal current results are often around 950-953 with intermittent lower states.

A few Mbps can be normal test/path variance. Large drops are not. After Runner stale-state repair is validated, correlate significant throughput drops with link rate, retries, CPU/interrupt load, Runner state, and WAN path.

## 8. AT&T / BGW / public-path variability

There is independent evidence of latency/packet-loss variation even when bypassing the ASUS path in some tests, including gaming observations. Keep this as a separate layer so ASUS firmware is not blamed for upstream events.

## 9. 2.4 GHz

Handle last. Historical throughput is poor, and channel 6 has appeared cleaner than channel 11. Solve the higher-impact forwarding/RF issues first.

## What not to do

- Do not permanently disable Runner/WFD/FlowCache as the solution.
- Do not use MLO-off as the primary fix when the target is working MLO.
- Do not introduce Cake/SQM/QoS as a substitute for fixing a forwarding bug.
- Do not randomly tune DHD queues, IRQ affinity, CPU governors, or regulatory settings without a symptom-specific mechanism.
- Do not reboot/reconnect before capturing a recurrence if connectivity remains usable enough to collect evidence.
- Preserve AdGuard unless DNS-specific evidence points at it.

## Current build status

The production repo now uses the source-built `wlshared` D3LUT repair plus the per-client MLO runtime relearn. Push shell tests passed on the code change before the documentation-only commits. A fresh manual firmware workflow run from current `main` is the required next build; old source-only or binary-patcher artifacts are obsolete for this repair.
