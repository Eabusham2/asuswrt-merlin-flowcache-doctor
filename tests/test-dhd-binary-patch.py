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


def align(value, boundary):
    return (value + boundary - 1) & ~(boundary - 1)


def synthetic_elf(section_name=".text", with_symtab=True):
    """Create minimal ELF64/AArch64 ET_REL with one executable audited signature."""
    text_size = max(mod.ORIGINAL) + 4
    text = bytearray(text_size)
    for rel, word in mod.ORIGINAL.items():
        struct.pack_into("<I", text, rel, word)

    shstr = b"\0" + section_name.encode() + b"\0"
    text_name = 1
    text_off = 0x100
    pos = align(text_off + len(text), 8)

    headers = [
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        (text_name, 1, 0x6, 0, text_off, len(text), 0, 0, 4, 0),
    ]

    if with_symtab:
        symtab_name = len(shstr)
        shstr += b".whatever-symbols\0"
        strtab_name = len(shstr)
        shstr += b".whatever-strings\0"
        symtab_off = pos
        symtab = bytearray(48)
        struct.pack_into("<IBBHQQ", symtab, 24, 1, 0x12, 0, 1, 0, 0)
        pos = symtab_off + len(symtab)
        strtab_off = pos
        strtab = b"\0dhd_pktfwd_request\0"
        pos = strtab_off + len(strtab)
        headers += [
            (symtab_name, 2, 0, 0, symtab_off, len(symtab), 3, 1, 8, 24),
            (strtab_name, 3, 0, 0, strtab_off, len(strtab), 0, 0, 1, 0),
        ]
    else:
        symtab = b""
        strtab = b""

    shstr_name = len(shstr)
    shstr += b".shstrtab\0"
    shstr_off = pos
    shoff = align(shstr_off + len(shstr), 8)
    shstr_index = len(headers)
    headers.append((shstr_name, 3, 0, 0, shstr_off, len(shstr), 0, 0, 1, 0))

    out = bytearray(shoff + len(headers) * 64)
    ident = bytearray(16)
    ident[:4] = b"\x7fELF"
    ident[4] = 2
    ident[5] = 1
    ident[6] = 1
    struct.pack_into(
        "<16sHHIQQQIHHHHHH", out, 0, bytes(ident), 1, 183, 1,
        0, 0, shoff, 0, 64, 0, 0, 64, len(headers), shstr_index,
    )
    out[text_off:text_off + len(text)] = text
    if with_symtab:
        out[symtab_off:symtab_off + len(symtab)] = symtab
        out[strtab_off:strtab_off + len(strtab)] = strtab
    out[shstr_off:shstr_off + len(shstr)] = shstr
    for i, header in enumerate(headers):
        struct.pack_into("<IIQQQQIIQQ", out, shoff + i * 64, *header)
    return bytes(out)


def patch_verify_case(tmp, name, data):
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
    assert patch["match_method"] == "unique-executable-signature"
    assert patch["state_before"] == "original"
    assert patch["state_after"] == "patched"
    assert patch["changed"] is True

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

    patch_verify_case(tmp, "normal.o", synthetic_elf(".text", with_symtab=True))
    patch_verify_case(tmp, "odd-section.o", synthetic_elf(".code.hot", with_symtab=True))
    patch_verify_case(tmp, "no-symbol-table.o", synthetic_elf(".vendor_exec", with_symtab=False))

    unknown = tmp / "unknown.o"
    original = synthetic_elf(".vendor_exec", with_symtab=False)
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
    assert unknown.read_bytes() == before

    one = synthetic_elf(".text", with_symtab=False)
    sections = mod.parse_executable_sections(one)
    first = sections[0]
    payload = one[first["offset"]:first["offset"] + first["size"]]

    def two_exec_elf():
        text_size = len(payload)
        off1 = 0x100
        off2 = align(off1 + text_size, 8)
        shoff = align(off2 + text_size, 8)
        out = bytearray(shoff + 3 * 64)
        ident = bytearray(16)
        ident[:4] = b"\x7fELF"
        ident[4] = 2
        ident[5] = 1
        ident[6] = 1
        struct.pack_into(
            "<16sHHIQQQIHHHHHH", out, 0, bytes(ident), 1, 183, 1,
            0, 0, shoff, 0, 64, 0, 0, 64, 3, 0,
        )
        out[off1:off1 + text_size] = payload
        out[off2:off2 + text_size] = payload
        headers = [
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
            (0, 1, 0x6, 0, off1, text_size, 0, 0, 4, 0),
            (0, 1, 0x6, 0, off2, text_size, 0, 0, 4, 0),
        ]
        for i, header in enumerate(headers):
            struct.pack_into("<IIQQQQIIQQ", out, shoff + i * 64, *header)
        return bytes(out)

    duplicate = tmp / "duplicate.o"
    duplicate.write_bytes(two_exec_elf())
    proc = subprocess.run(
        [sys.executable, str(mod_path), "patch", str(duplicate)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    assert proc.returncode != 0
    assert "found 2" in proc.stdout

print("PASS DHD revision-2 control flow + unique executable-signature patch/verify/fail-closed contract")
