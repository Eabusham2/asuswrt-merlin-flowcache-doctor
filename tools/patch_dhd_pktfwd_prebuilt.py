#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct

EM_AARCH64 = 183
ET_REL = 1
SHT_PROGBITS = 1
SHF_EXECINSTR = 0x4
PATCH_REVISION = 2

ORIGINAL = {
    0x160: 0xF1001C7F, 0x164: 0x540006C0, 0x168: 0xF100207F,
    0x16C: 0x540005C0, 0x170: 0xF100307F, 0x174: 0xD2800014,
    0x178: 0x54FFFE61, 0x17C: 0xB9401A60, 0x180: 0x51000400,
    0x184: 0xB9001A60, 0x188: 0xA9425BF5, 0x18C: 0x17FFFFE3,
    0x224: 0xB9401A60, 0x228: 0xD2800014, 0x22C: 0x11000400,
    0x230: 0xB9001A60, 0x234: 0xA9425BF5, 0x238: 0x17FFFFB8,
}

PATCHED = {
    0x160: 0xD2800014, 0x164: 0xD1001C60, 0x168: 0xF1000C1F,
    0x16C: 0x540005C9, 0x170: 0xF100307F, 0x174: 0x54FFFE81,
    0x178: 0xB9401A60, 0x17C: 0x51000400, 0x180: 0xB9001A60,
    0x184: 0xA9425BF5, 0x188: 0x17FFFFE4, 0x18C: 0xD503201F,
    0x224: 0xF100207F, 0x228: 0x540000A1, 0x22C: 0xB9401A60,
    0x230: 0x11000400, 0x234: 0xB9001A60, 0x238: 0x14000001,
}

SEMANTICS = (
    "assoc/reassoc events 7,8,9,10 delete stale PKTFWD D3LUT; "
    "event 8 also increments station count; event 12 decrements station count; "
    "all request-5 paths preserve the original zero return value"
)

PATCH_END = max(PATCHED) + 4
ANCHOR_REL = 0x160
ANCHOR_WORDS = {ORIGINAL[ANCHOR_REL], PATCHED[ANCHOR_REL]}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


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


def parse_executable_sections(data: bytes):
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise ValueError("expected ELF64 little-endian")

    hdr = struct.unpack_from("<16sHHIQQQIHHHHHH", data, 0)
    (_, e_type, e_machine, _, _, _, e_shoff, _, _, _, _, e_shentsize,
     e_shnum, _) = hdr
    if e_type != ET_REL:
        raise ValueError(f"expected ET_REL ({ET_REL}), got {e_type}")
    if e_machine != EM_AARCH64:
        raise ValueError(f"expected AArch64 ELF machine {EM_AARCH64}, got {e_machine}")
    if e_shentsize != 64 or e_shnum == 0:
        raise ValueError("invalid ELF section table")
    if e_shoff + e_shnum * e_shentsize > len(data):
        raise ValueError("ELF section table extends past EOF")

    executable = []
    for i in range(e_shnum):
        f = struct.unpack_from("<IIQQQQIIQQ", data, e_shoff + i * e_shentsize)
        sec_type, flags, offset, size = f[1], f[2], f[4], f[5]
        if sec_type != SHT_PROGBITS or not (flags & SHF_EXECINSTR) or size == 0:
            continue
        if offset > len(data) or offset + size > len(data):
            raise ValueError(f"executable section {i} extends past EOF")
        executable.append({
            "index": i,
            "offset": offset,
            "size": size,
            "flags": flags,
        })

    if not executable:
        raise ValueError("no executable PROGBITS sections found")
    return executable


def locate_signature(data: bytes):
    sections = parse_executable_sections(data)
    matches = []
    near = []

    for sec in sections:
        start = sec["offset"]
        end = start + sec["size"]
        anchor_start = start + ANCHOR_REL
        if anchor_start >= end:
            continue

        pos = anchor_start + ((4 - (anchor_start & 3)) & 3)
        while pos + 4 <= end:
            word = struct.unpack_from("<I", data, pos)[0]
            if word in ANCHOR_WORDS:
                function_off = pos - ANCHOR_REL
                if function_off >= start and function_off + PATCH_END <= end:
                    words = read_words(data, function_off)
                    state = state_of(words)
                    if state in ("original", "patched"):
                        matches.append({
                            "file_offset": function_off,
                            "section_index": sec["index"],
                            "section_offset": start,
                            "section_size": sec["size"],
                            "state": state,
                            "words": fmt_words(words),
                        })
                    else:
                        score = sum(
                            words[rel] in (ORIGINAL[rel], PATCHED[rel])
                            for rel in ORIGINAL
                        )
                        if score >= 10:
                            near.append({
                                "file_offset": function_off,
                                "section_index": sec["index"],
                                "matching_words": score,
                                "words": fmt_words(words),
                            })
            pos += 4

    unique = {}
    for match in matches:
        unique[(match["file_offset"], match["state"])] = match
    matches = list(unique.values())

    if len(matches) != 1:
        raise ValueError(
            "expected exactly one audited DHD PKTFWD instruction signature "
            f"in executable code; found {len(matches)}\n"
            + json.dumps(
                {"matches": matches, "near_matches": near[:8], "executable_sections": sections},
                indent=2,
                sort_keys=True,
            )
        )
    return matches[0]


# Backward-compatible helper used by repo tests; symbol metadata is intentionally ignored.
def locate_symbol(data: bytes):
    match = locate_signature(data)
    return (
        match["file_offset"],
        0,
        0,
        f"section[{match['section_index']}]",
        "unique-executable-signature",
        1,
    )


def main():
    ap = argparse.ArgumentParser(
        description="Patch/verify GT-BE19000AI DHD PKTFWD reassociation invalidation"
    )
    ap.add_argument("mode", choices=("patch", "verify", "inspect"))
    ap.add_argument("elf")
    ap.add_argument("--report")
    args = ap.parse_args()

    path = Path(args.elf)
    raw = path.read_bytes()
    before_sha = sha256(raw)
    before_match = locate_signature(raw)
    function_off = before_match["file_offset"]
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
                "Refusing binary patch: audited DHD instruction signature is unknown.\n"
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
    after_match = locate_signature(after)
    after_off = after_match["file_offset"]
    after_words = read_words(after, after_off)
    after_state = state_of(after_words)

    if after_off != function_off:
        raise SystemExit(
            f"post-operation signature moved: before=0x{function_off:x} after=0x{after_off:x}"
        )
    if args.mode in ("patch", "verify") and after_state != "patched":
        raise SystemExit(f"post-operation verification failed: state={after_state}")

    report = {
        "tool": "FlowCache Doctor DHD PKTFWD prebuilt patcher",
        "patch_revision": PATCH_REVISION,
        "match_method": "unique-executable-signature",
        "file": str(path),
        "mode": args.mode,
        "function_file_offset": f"0x{after_off:x}",
        "section_index": after_match["section_index"],
        "section_offset": f"0x{after_match['section_offset']:x}",
        "section_size": after_match["section_size"],
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
