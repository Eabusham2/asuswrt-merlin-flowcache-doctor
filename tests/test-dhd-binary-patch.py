#!/usr/bin/env python3
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path

root = Path(__file__).resolve().parents[1]
mod_path = root / "tools" / "patch_dhd_pktfwd_prebuilt.py"
spec = spec_from_file_location("dhdpatch", mod_path)
mod = module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

assert mod.PATCH_REVISION == 2
assert mod.PATCHED[0x160] == 0xD2800014, "request-5 must initialize x20 return value to zero"
assert mod.ORIGINAL[0x174] == 0xD2800014, "original return-value invariant changed unexpectedly"
assert mod.ORIGINAL[0x228] == 0xD2800014, "original ASSOC_IND path invariant changed unexpectedly"


def sign_extend(value, bits):
    sign = 1 << (bits - 1)
    return value - (1 << bits) if value & sign else value


def b_target(pc, word):
    assert word & 0x7C000000 == 0x14000000
    imm26 = sign_extend(word & 0x03FFFFFF, 26)
    return pc + imm26 * 4


def bcond_target(pc, word, expected_cond):
    assert word & 0xFF000010 == 0x54000000
    assert word & 0xF == expected_cond
    imm19 = sign_extend((word >> 5) & 0x7FFFF, 19)
    return pc + imm19 * 4


# Events 7..10 enter the shared assoc/reassoc block.
assert bcond_target(0x16C, mod.PATCHED[0x16C], 0x9) == 0x224  # b.ls
# Non-assoc, non-disassoc-indication returns through the original zero-return path.
assert bcond_target(0x174, mod.PATCHED[0x174], 0x1) == 0x144  # b.ne
# DISASSOC_IND decrements, then returns through the original common return.
assert b_target(0x188, mod.PATCHED[0x188]) == 0x118
# In the assoc range, only event 8 increments; 7/9/10 skip to stale-D3LUT delete.
assert bcond_target(0x228, mod.PATCHED[0x228], 0x1) == 0x23C  # b.ne
# Event 8 increments and then reaches the exact same stale-D3LUT delete block.
assert b_target(0x238, mod.PATCHED[0x238]) == 0x23C

required = ["events 7,8,9,10", "event 8", "event 12", "zero return value"]
for phrase in required:
    assert phrase in mod.SEMANTICS

print("PASS DHD binary patch revision 2 control-flow contract")
