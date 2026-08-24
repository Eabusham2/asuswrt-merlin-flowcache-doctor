#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct

SYMBOL = "dhd_pktfwd_request"
EM_AARCH64 = 183
ET_REL = 1
SHT_PROGBITS = 1
SHF_EXECINSTR = 0x4
PATCH_REVISION = 2

ORIGINAL = {
    0x160: 0xF1001C7F,
    0x164: 0x540006C0,
    0x168: 0xF100207F,
    0x16C: 0x540005C0,
    0x170: 0xF100307F,
    0x174: 0xD2800014,
    0x178: 0x54FFFE61,
    0x17C: 0xB9401A60,
    0x180: 0x51000400,
    0x184: 0xB9001A60,
    0x188: 0xA9425BF5,
    0x18C: 0x17FFFFE3,
    0x224: 0xB9401A60,
    0x228: 0xD2800014,
    0x22C: 0x11000400,
    0x230: 0xB9001A60,
    0x234: 0xA9425BF5,
    0x238: 0x17FFFFB8,
}

PATCHED = {
    0x160: 0xD2800014,
    0x164: 0xD1001C60,
    0x168: 0xF1000C1F,
    0x16C: 0x540005C9,
    0x170: 0xF100307F,
    0x174: 0x54FFFE81,
    0x178: 0xB9401A60,
    0x17C: 0x51000400,
    0x180: 0xB9001A60,
    0x184: 0xA9425BF5,
    0x188: 0x17FFFFE4,
    0x18C: 0xD503201F,
    0x224: 0xF100207F,
    0x228: 0x540000A1,
    0x22C: 0xB9401A60,
    0x230: 0x11000400,
    0x234: 0xB9001A60,
    0x238: 0x14000001,
}

SEMANTICS = (
    "assoc/reassoc events 7,8,9,10 delete stale PKTFWD D3LUT; "
    "event 8 also increments station count; event 12 decrements station count; "
    "all request-5 paths preserve the original zero return value"
)


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def cstr(buf: bytes, off: int) -> str:
    end = buf.find(b"\0", off)
    if end < 0:
        raise ValueError("unterminated ELF string")
    return buf[off:end].decode("utf-8", "strict")


def locate_symbol(data: bytes):
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise ValueError("expected ELF64 little-endian")

    hdr = struct.unpack_from("<16sHHIQQQIHHHHHH", data, 0)
    (_, e_type, e_machine, _, _, _, e_shoff, _, _, _, _, e_shentsize,
     e_shnum, e_shstrndx) = hdr
    if e_type != ET_REL:
        raise ValueError(f"expected ET_REL ({ET_REL}), got {e_type}")
    if e_machine != EM_AARCH64:
        raise ValueError(f"expected AArch64 ELF machine {EM_AARCH64}, got {e_machine}")
    if e_shentsize != 64 or e_shnum == 0 or e_shstrndx >= e_shnum:
        raise ValueError("invalid ELF section table")

    shfmt = "<IIQQQQIIQQ"
    sections = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        if off + 64 > len(data):
            raise ValueError("ELF section table extends past EOF")
        f = struct.unpack_from(shfmt, data, off)
        sections.append({
            "name_off": f[0], "type": f[1], "flags": f[2],
            "addr": f[3], "offset": f[4], "size": f[5],
            "link": f[6], "info": f[7], "align": f[8], "entsize": f[9],
        })

    shstr = sections[e_shstrndx]
    shstr_data = data[shstr["offset"]:shstr["offset"] + shstr["size"]]
    for sec in sections:
        sec["name"] = cstr(shstr_data, sec["name_off"])

    symtabs = [s for s in sections if s["type"] == 2 and s["name"] == ".symtab"]
    if len(symtabs) != 1:
        raise ValueError(f"expected exactly one .symtab, found {len(symtabs)}")
    symtab = symtabs[0]
    if not (0 <= symtab["link"] < len(sections)):
        raise ValueError("invalid .symtab string-table link")

    strsec = sections[symtab["link"]]
    strdata = data[strsec["offset"]:strsec["offset"] + strsec["size"]]
    entsize = symtab["entsize"] or 24
    if entsize != 24:
        raise ValueError(f"unexpected ELF64 symbol size {entsize}")

    found = []
    for pos in range(symtab["offset"], symtab["offset"] + symtab["size"], entsize):
        st_name, st_info, _, st_shndx, st_value, st_size = struct.unpack_from(
            "<IBBHQQ", data, pos
        )
        if st_name >= len(strdata):
            continue
        if cstr(strdata, st_name) == SYMBOL:
            found.append((st_shndx, st_value, st_size, st_info))

    if len(found) != 1:
        raise ValueError(f"expected exactly one {SYMBOL} symbol, found {len(found)}")

    st_shndx, st_value, st_size, _ = found[0]
    if not (0 < st_shndx < len(sections)):
        raise ValueError(f"{SYMBOL} has invalid section index {st_shndx}")
    sec = sections[st_shndx]

    if sec["type"] != SHT_PROGBITS or not (sec["flags"] & SHF_EXECINSTR):
        raise ValueError(
            f"{SYMBOL} is in non-executable section {sec['name']} "
            f"(type={sec['type']} flags=0x{sec['flags']:x})"
        )

    rel = st_value - sec["addr"]
    if rel < 0 or rel + st_size > sec["size"]:
        raise ValueError(f"{SYMBOL} bounds are outside {sec['name']}")
    fileoff = sec["offset"] + rel
    if fileoff + st_size > len(data):
        raise ValueError(f"{SYMBOL} extends past EOF")
    if st_size < max(PATCHED) + 4:
        raise ValueError(f"{SYMBOL} is too small ({st_size} bytes)")
    return fileoff, st_value, st_size, sec["name"]


def read_words(data: bytes, function_file_offset: int):
    return {
        rel: struct.unpack_from("<I", data, function_file_offset + rel)[0]
        for rel in ORIGINAL
    }


def state_of(words):
    if words == ORIGINAL:
        return "original"
    if words == PATCHED:
        return "patched"
    return "unknown"


def fmt_words(words):
    return {f"0x{k:03x}": f"0x{v:08x}" for k, v in sorted(words.items())}


def main():
    ap = argparse.ArgumentParser(
        description="Patch/verify GT-BE19000AI prebuilt DHD PKTFWD reassociation invalidation"
    )
    ap.add_argument("mode", choices=("patch", "verify", "inspect"))
    ap.add_argument("elf")
    ap.add_argument("--report")
    args = ap.parse_args()

    path = Path(args.elf)
    raw = path.read_bytes()
    before_sha = sha256(raw)
    function_off, _, _, _ = locate_symbol(raw)
    before_words = read_words(raw, function_off)
    before_state = state_of(before_words)

    result = bytearray(raw)
    changed = False
    if args.mode == "patch":
        if before_state == "original":
            for rel, word in PATCHED.items():
                struct.pack_into("<I", result, function_off + rel, word)
            changed = True
        elif before_state != "patched":
            raise SystemExit(
                "Refusing binary patch: dhd_pktfwd_request instruction signature is unknown.\n"
                + json.dumps(fmt_words(before_words), indent=2)
            )
    elif args.mode == "verify" and before_state != "patched":
        raise SystemExit(
            f"DHD PKTFWD binary verification failed: state={before_state}\n"
            + json.dumps(fmt_words(before_words), indent=2)
        )

    if changed:
        tmp = path.with_name(path.name + ".tmp-fcd")
        tmp.write_bytes(result)
        os.chmod(tmp, path.stat().st_mode & 0o7777)
        os.replace(tmp, path)

    after = path.read_bytes()
    after_sha = sha256(after)
    after_off, after_symbol_value, after_symbol_size, after_section_name = locate_symbol(after)
    after_words = read_words(after, after_off)
    after_state = state_of(after_words)

    if args.mode in ("patch", "verify") and after_state != "patched":
        raise SystemExit(f"post-operation verification failed: state={after_state}")

    report = {
        "tool": "FlowCache Doctor DHD PKTFWD prebuilt patcher",
        "patch_revision": PATCH_REVISION,
        "file": str(path),
        "mode": args.mode,
        "symbol": SYMBOL,
        "symbol_value": f"0x{after_symbol_value:x}",
        "symbol_size": after_symbol_size,
        "symbol_section": after_section_name,
        "function_file_offset": f"0x{after_off:x}",
        "state_before": before_state,
        "state_after": after_state,
        "changed": changed,
        "sha256_before": before_sha,
        "sha256_after": after_sha,
        "semantics": SEMANTICS,
        "instruction_words_before": fmt_words(before_words),
        "instruction_words_after": fmt_words(after_words),
    }
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.report:
        Path(args.report).write_text(text)
    print(text, end="")


if __name__ == "__main__":
    main()