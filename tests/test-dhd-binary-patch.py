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


# Revision-2 control-flow contract.
assert bcond_target(0x16C, mod.PATCHED[0x16C], 0x9) == 0x224
assert bcond_target(0x174, mod.PATCHED[0x174], 0x1) == 0x144
assert b_target(0x188, mod.PATCHED[0x188]) == 0x118
assert bcond_target(0x228, mod.PATCHED[0x228], 0x1) == 0x23C
assert b_target(0x238, mod.PATCHED[0x238]) == 0x23C
for phrase in ["events 7,8,9,10", "event 8", "event 12", "zero return value"]:
    assert phrase in mod.SEMANTICS


def align(value, boundary):
    return (value + boundary - 1) & ~(boundary - 1)


def synthetic_elf(section_name=".text", symtab_name=".symtab", symbol_size=None,
                  duplicate_undefined=False):
    """Create a minimal ELF64/AArch64 ET_REL carrying the audited signature."""
    text_size = max(mod.ORIGINAL) + 4
    text = bytearray(text_size)
    for rel, word in mod.ORIGINAL.items():
        struct.pack_into("<I", text, rel, word)

    strtab = b"\0dhd_pktfwd_request\0"
    names = [section_name, symtab_name, ".strtab", ".shstrtab"]
    shstr = b"\0"
    name_off = {}
    for name in names:
        name_off[name] = len(shstr)
        shstr += name.encode() + b"\0"

    text_off = 0x100
    entries = [bytes(24)]
    if duplicate_undefined:
        entry = bytearray(24)
        struct.pack_into("<IBBHQQ", entry, 0, 1, 0x12, 0, 0, 0, 0)
        entries.append(bytes(entry))
    entry = bytearray(24)
    size = text_size if symbol_size is None else symbol_size
    struct.pack_into("<IBBHQQ", entry, 0, 1, 0x12, 0, 1, 0, size)
    entries.append(bytes(entry))
    symtab = b"".join(entries)

    symtab_off = align(text_off + len(text), 8)
    strtab_off = symtab_off + len(symtab)
    shstr_off = strtab_off + len(strtab)
    shoff = align(shstr_off + len(shstr), 8)
    out = bytearray(shoff + 5 * 64)

    ident = bytearray(16)
    ident[:4] = b"\x7fELF"
    ident[4] = 2
    ident[5] = 1
    ident[6] = 1
    struct.pack_into(
        "<16sHHIQQQIHHHHHH", out, 0, bytes(ident), 1, 183, 1,
        0, 0, shoff, 0, 64, 0, 0, 64, 5, 4,
    )
    out[text_off:text_off + len(text)] = text
    out[symtab_off:symtab_off + len(symtab)] = symtab
    out[strtab_off:strtab_off + len(strtab)] = strtab
    out[shstr_off:shstr_off + len(shstr)] = shstr

    headers = [
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        (name_off[section_name], 1, 0x6, 0, text_off, len(text), 0, 0, 4, 0),
        (name_off[symtab_name], 2, 0, 0, symtab_off, len(symtab), 3, 1, 8, 24),
        (name_off[".strtab"], 3, 0, 0, strtab_off, len(strtab), 0, 0, 1, 0),
        (name_off[".shstrtab"], 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0),
    ]
    for i, header in enumerate(headers):
        struct.pack_into("<IIQQQQIIQQ", out, shoff + i * 64, *header)
    return bytes(out)


def patch_verify_case(tmp, name, data, expected_section, expected_symtab,
                      expected_records):
    elf = tmp / name
    patch_report = tmp / f"{name}.patch.json"
    verify_report = tmp / f"{name}.verify.json"
    elf.write_bytes(data)
    original_len = len(data)

    subprocess.run(
        [sys.executable, str(mod_path), "patch", str(elf), "--report", str(patch_report)],
        check=True, stdout=subprocess.DEVNULL,
    )
    assert len(elf.read_bytes()) == original_len
    patch = json.loads(patch_report.read_text())
    assert patch["patch_revision"] == 2
    assert patch["state_before"] == "original"
    assert patch["state_after"] == "patched"
    assert patch["changed"] is True
    assert patch["symbol_section"] == expected_section
    assert patch["symbol_table"] == expected_symtab
    assert patch["matching_symbol_records"] == expected_records

    subprocess.run(
        [sys.executable, str(mod_path), "verify", str(elf), "--report", str(verify_report)],
        check=True, stdout=subprocess.DEVNULL,
    )
    verify = json.loads(verify_report.read_text())
    assert verify["state_before"] == "patched"
    assert verify["state_after"] == "patched"
    assert verify["changed"] is False


with tempfile.TemporaryDirectory() as tmpdir:
    tmp = Path(tmpdir)

    # Standard ELF metadata.
    patch_verify_case(tmp, "normal.o", synthetic_elf(), ".text", ".symtab", 1)

    # Function-specific executable section.
    patch_verify_case(
        tmp, "subsection.o", synthetic_elf(".text.dhd_pktfwd_request"),
        ".text.dhd_pktfwd_request", ".symtab", 1,
    )

    # Real-world linked/prebuilt variations: arbitrary executable section name,
    # nonstandard SYMTAB section name, zero-sized function symbol, and an
    # additional undefined symbol record with the same name.
    patch_verify_case(
        tmp, "prebuilt-shape.o",
        synthetic_elf(".code.hot", ".symbols", symbol_size=0, duplicate_undefined=True),
        ".code.hot", ".symbols", 2,
    )

    # Fail closed: unknown machine code must never be modified.
    unknown = tmp / "unknown.o"
    original = synthetic_elf()
    bad = bytearray(original)
    original_off, *_ = mod.locate_symbol(original)
    struct.pack_into("<I", bad, original_off + 0x160, 0)
    unknown.write_bytes(bad)
    before = unknown.read_bytes()
    proc = subprocess.run(
        [sys.executable, str(mod_path), "patch", str(unknown)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    assert proc.returncode != 0
    assert "found 0" in proc.stdout
    assert '"state": "unknown"' in proc.stdout
    assert unknown.read_bytes() == before

print("PASS DHD revision-2 control flow + robust ELF metadata + fail-closed contract")
