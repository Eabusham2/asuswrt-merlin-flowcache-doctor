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
assert mod.PATCHED[0x160] == 0xD2800014
assert mod.ORIGINAL[0x174] == 0xD2800014
assert mod.ORIGINAL[0x228] == 0xD2800014


def sign_extend(value, bits):
    sign = 1 << (bits - 1)
    return value - (1 << bits) if value & sign else value


def b_target(pc, word):
    assert word & 0x7C000000 == 0x14000000
    return pc + sign_extend(word & 0x03FFFFFF, 26) * 4


def bcond_target(pc, word, expected_cond):
    assert word & 0xFF000010 == 0x54000000
    assert word & 0xF == expected_cond
    return pc + sign_extend((word >> 5) & 0x7FFFF, 19) * 4


assert bcond_target(0x16C, mod.PATCHED[0x16C], 0x9) == 0x224
assert bcond_target(0x174, mod.PATCHED[0x174], 0x1) == 0x144
assert b_target(0x188, mod.PATCHED[0x188]) == 0x118
assert bcond_target(0x228, mod.PATCHED[0x228], 0x1) == 0x23C
assert b_target(0x238, mod.PATCHED[0x238]) == 0x23C
for phrase in ["events 7,8,9,10", "event 8", "event 12", "zero return value"]:
    assert phrase in mod.SEMANTICS


def elf_with_signature(copies=1, elf_type=1):
    """Minimal ELF64/AArch64 file; deliberately no section/symbol tables."""
    function_size = mod.PATCH_END
    chunk_size = ((function_size + 0x3ff) // 0x400) * 0x400
    total = 0x400 + copies * chunk_size
    out = bytearray(total)
    ident = bytearray(16)
    ident[:4] = b"\x7fELF"
    ident[4] = 2
    ident[5] = 1
    ident[6] = 1
    struct.pack_into(
        "<16sHHIQQQIHHHHHH", out, 0, bytes(ident), elf_type, 183, 1,
        0, 0, 0, 0, 64, 0, 0, 0, 0, 0,
    )
    for n in range(copies):
        base = 0x400 + n * chunk_size
        for rel, word in mod.ORIGINAL.items():
            struct.pack_into("<I", out, base + rel, word)
    return bytes(out)


def patch_verify(tmp, name, data):
    elf = tmp / name
    patch_report = tmp / f"{name}.patch.json"
    verify_report = tmp / f"{name}.verify.json"
    elf.write_bytes(data)
    before = elf.read_bytes()

    subprocess.run(
        [sys.executable, str(mod_path), "patch", str(elf), "--report", str(patch_report)],
        check=True,
    )
    after = elf.read_bytes()
    assert len(after) == len(before)

    patch = json.loads(patch_report.read_text())
    assert patch["patch_revision"] == 2
    assert patch["match_method"] == "unique-full-instruction-signature"
    assert patch["elf_metadata_dependency"] == "architecture-header-only"
    assert patch["state_before"] == "original"
    assert patch["state_after"] == "patched"
    assert patch["changed"] is True

    subprocess.run(
        [sys.executable, str(mod_path), "verify", str(elf), "--report", str(verify_report)],
        check=True,
    )
    verify = json.loads(verify_report.read_text())
    assert verify["state_before"] == "patched"
    assert verify["state_after"] == "patched"
    assert verify["changed"] is False

    off, *_ = mod.locate_symbol(after)
    assert mod.state_of(mod.read_words(after, off)) == "patched"


with tempfile.TemporaryDirectory() as td:
    tmp = Path(td)
    patch_verify(tmp, "rel.o", elf_with_signature(elf_type=1))
    patch_verify(tmp, "dyn.elf", elf_with_signature(elf_type=3))

    unknown = tmp / "unknown.o"
    raw = bytearray(elf_with_signature())
    off, *_ = mod.locate_symbol(raw)
    struct.pack_into("<I", raw, off + 0x164, 0)
    unknown.write_bytes(raw)
    before = unknown.read_bytes()
    proc = subprocess.run(
        [sys.executable, str(mod_path), "patch", str(unknown)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    assert proc.returncode != 0
    assert "found 0" in proc.stdout
    assert unknown.read_bytes() == before

    duplicate = tmp / "duplicate.o"
    duplicate.write_bytes(elf_with_signature(copies=2))
    before = duplicate.read_bytes()
    proc = subprocess.run(
        [sys.executable, str(mod_path), "patch", str(duplicate)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    assert proc.returncode != 0
    assert "found 2" in proc.stdout
    assert duplicate.read_bytes() == before

print("PASS DHD revision-2 architecture-only unique-signature patch/verify/fail-closed contract")
