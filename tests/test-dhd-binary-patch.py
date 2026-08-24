#!/usr/bin/env python3
from importlib.util import module_from_spec, spec_from_file_location
from pathlib import Path
import json
import struct
import subprocess
import sys
import tempfile

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


def align(value, boundary):
    return (value + boundary - 1) & ~(boundary - 1)


def synthetic_elf():
    """Build a tiny ELF64/AArch64 ET_REL with the audited function signature."""
    text_size = max(mod.ORIGINAL) + 4
    text = bytearray(text_size)
    for rel, word in mod.ORIGINAL.items():
        struct.pack_into("<I", text, rel, word)

    strtab = b"\0dhd_pktfwd_request\0"
    shstr = b"\0.text\0.symtab\0.strtab\0.shstrtab\0"
    text_off = 0x100
    symtab_off = align(text_off + len(text), 8)

    # ELF64 symbol table: null symbol + one global function symbol.
    symtab = bytearray(48)
    struct.pack_into("<IBBHQQ", symtab, 24, 1, 0x12, 0, 1, 0, text_size)

    strtab_off = symtab_off + len(symtab)
    shstr_off = strtab_off + len(strtab)
    shoff = align(shstr_off + len(shstr), 8)
    out = bytearray(shoff + 5 * 64)

    ident = bytearray(16)
    ident[:4] = b"\x7fELF"
    ident[4] = 2  # ELFCLASS64
    ident[5] = 1  # little-endian
    ident[6] = 1  # EV_CURRENT
    struct.pack_into(
        "<16sHHIQQQIHHHHHH",
        out,
        0,
        bytes(ident),
        1,      # ET_REL
        183,    # EM_AARCH64
        1,
        0,
        0,
        shoff,
        0,
        64,
        0,
        0,
        64,
        5,
        4,
    )

    out[text_off:text_off + len(text)] = text
    out[symtab_off:symtab_off + len(symtab)] = symtab
    out[strtab_off:strtab_off + len(strtab)] = strtab
    out[shstr_off:shstr_off + len(shstr)] = shstr

    shfmt = "<IIQQQQIIQQ"
    names = {".text": 1, ".symtab": 7, ".strtab": 15, ".shstrtab": 23}
    headers = [
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        (names[".text"], 1, 0x6, 0, text_off, len(text), 0, 0, 4, 0),
        (names[".symtab"], 2, 0, 0, symtab_off, len(symtab), 3, 1, 8, 24),
        (names[".strtab"], 3, 0, 0, strtab_off, len(strtab), 0, 0, 1, 0),
        (names[".shstrtab"], 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0),
    ]
    for i, header in enumerate(headers):
        struct.pack_into(shfmt, out, shoff + i * 64, *header)
    return bytes(out)


# Exercise the actual CLI/parser/writer end to end without storing Broadcom binaries.
with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)
    elf = tmp / "dhd.o"
    patch_report = tmp / "patch.json"
    verify_report = tmp / "verify.json"
    original = synthetic_elf()
    elf.write_bytes(original)

    subprocess.run(
        [sys.executable, str(mod_path), "patch", str(elf), "--report", str(patch_report)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    patched = elf.read_bytes()
    assert len(patched) == len(original), "binary patch must not change object size"

    patch = json.loads(patch_report.read_text())
    assert patch["patch_revision"] == 2
    assert patch["state_before"] == "original"
    assert patch["state_after"] == "patched"
    assert patch["changed"] is True

    subprocess.run(
        [sys.executable, str(mod_path), "verify", str(elf), "--report", str(verify_report)],
        check=True,
        stdout=subprocess.DEVNULL,
    )
    verify = json.loads(verify_report.read_text())
    assert verify["patch_revision"] == 2
    assert verify["state_before"] == "patched"
    assert verify["state_after"] == "patched"
    assert verify["changed"] is False

    function_off, _, _ = mod.locate_symbol(patched)
    assert mod.state_of(mod.read_words(patched, function_off)) == "patched"

    # Fail closed: an unknown instruction signature must be rejected byte-for-byte.
    unknown = tmp / "unknown.o"
    bad = bytearray(original)
    original_off, _, _ = mod.locate_symbol(original)
    struct.pack_into("<I", bad, original_off + 0x160, 0)
    unknown.write_bytes(bad)
    before = unknown.read_bytes()
    proc = subprocess.run(
        [sys.executable, str(mod_path), "patch", str(unknown)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    assert proc.returncode != 0, "unknown binary signature must be rejected"
    assert "signature is unknown" in proc.stdout
    assert unknown.read_bytes() == before, "refused patch must not mutate the object"

print("PASS DHD binary patch revision 2 control-flow + synthetic ELF patch/verify/refusal contract")
