#!/usr/bin/env python3
"""Apply the GT-BE19000AI source-built wlshared D3LUT/Runner repair."""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = "FCD_DHD_D3LUT_REPAIR_V1"

STOCK = """\t/* function is for dhd device */
\t/* dhd or eth devices */
\tif (dhd_pktc_req_hook && (is_netdev_wlan_dhd(dev) || !is_netdev_wlan(dev)))
\t\tdhd_pktc_req_hook(PKTC_TBL_BRIDGE_EVENT, (unsigned long)(fdb_info->addr),
\t\t\t(unsigned long)dev, (unsigned long)event);"""

PATCHED = """\t/* function is for dhd device */
\t/* dhd or eth devices */
\tif (dhd_pktc_req_hook && (is_netdev_wlan_dhd(dev) || !is_netdev_wlan(dev))) {
\t\t/*
\t\t * FCD_DHD_D3LUT_REPAIR_V1
\t\t * Purge stale radio-pool ownership globally, then preserve the
\t\t * original Broadcom PKTC_TBL_BRIDGE_EVENT bookkeeping below.
\t\t */
\t\tif (is_netdev_wlan_dhd(dev) && dhd_pktc_del_hook &&
\t\t    ((event == SWITCHDEV_FDB_ADD_TO_DEVICE) ||
\t\t     (event == SWITCHDEV_FDB_DEL_TO_DEVICE))) {
\t\t\tdhd_pktc_del_hook((unsigned long)(fdb_info->addr), NULL);
\t\t}

\t\tdhd_pktc_req_hook(PKTC_TBL_BRIDGE_EVENT, (unsigned long)(fdb_info->addr),
\t\t\t(unsigned long)dev, (unsigned long)event);
\t}"""

STOCK_LOAD = 'printk("Loading wlshared Module...\\n");'
PATCHED_LOAD = f'printk("Loading wlshared Module ({MARKER})...\\n");'


def patch(path: Path) -> None:
    text = path.read_text()
    if MARKER in text:
        raise SystemExit(f"{MARKER} already present; refusing a double patch")
    if text.count(STOCK) != 1:
        raise SystemExit(f"expected one stock DHD switchdev block, found {text.count(STOCK)}")
    if text.count(STOCK_LOAD) != 1:
        raise SystemExit(f"expected one stock wlshared load printk, found {text.count(STOCK_LOAD)}")

    text = text.replace(STOCK, PATCHED, 1)
    text = text.replace(STOCK_LOAD, PATCHED_LOAD, 1)
    path.write_text(text)

    check = path.read_text()
    required = (
        MARKER,
        "dhd_pktc_del_hook((unsigned long)(fdb_info->addr), NULL)",
        "SWITCHDEV_FDB_ADD_TO_DEVICE",
        "SWITCHDEV_FDB_DEL_TO_DEVICE",
        "dhd_pktc_req_hook(PKTC_TBL_BRIDGE_EVENT",
    )
    for token in required:
        if token not in check:
            raise SystemExit(f"post-patch verification failed: {token}")

    # The repair must not short-circuit Broadcom's original bridge-event path.
    repaired_block = check[check.index(MARKER):check.index(MARKER) + 1200]
    if "return 0;" in repaired_block:
        raise SystemExit("post-patch verification failed: early return still suppresses bridge bookkeeping")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} /path/to/wlshared_linux.c")
    patch(Path(sys.argv[1]))
