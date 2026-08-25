#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct

EM_AARCH64 = 183
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


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def validate_elf(data: bytes):
    if len(data) < 64 or data[:4] != b"\x7fELF":
        raise ValueError("not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise ValueError("expected ELF64 little-endian")
    _, _, e_machine = struct.unpack_from("<16sHH", data, 0)
    if e_machine != EM_AARCH64:
        raise ValueError(f"expected AArch64 ELF machine {EM_AARCH64}, got {e_machine}")


def read_words(data: bytes, function_file_offset: int):
    if function_file_offset < 0 or function_file_offset + PATCH_END > len(data):
        raise ValueError("DHD signature window is outside the file")
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


def anchor_bytes(words):
    return b"".join(struct.pack("<I", words[rel]) for rel in (0x160, 0x164, 0x168))


ANCHORS = {
    "original": anchor_bytes(ORIGINAL),
    "patched": anchor_bytes(PATCHED),
}


def _find_all(data: bytes, needle: bytes):
    pos = 0
    while True:
        pos = data.find(needle, pos)
        if pos < 0:
            return
        yield pos
        pos += 1


def locate_signature(data: bytes):
    validate_elf(data)
    matches = []
    near = []
    seen_candidates = set()

    for anchor_state, needle in ANCHORS.items():
        for anchor_pos in _find_all(data, needle):
            function_off = anchor_pos - ANCHOR_REL
            if function_off < 0 or (function_off & 3):
                continue
            if function_off + PATCH_END > len(data):
                continue
            if function_off in seen_candidates:
                continue
            seen_candidates.add(function_off)

            words = read_words(data, function_off)
            state = state_of(words)
            rec = {
                "file_offset": function_off,
                "anchor_state": anchor_state,
                "state": state,
                "words": fmt_words(words),
            }
            if state in ("original", "patched"):
                matches.append(rec)
            else:
                score = sum(
                    words[rel] in (ORIGINAL[rel], PATCHED[rel])
                    for rel in ORIGINAL
                )
                if score >= 10:
                    rec["matching_words"] = score
                    near.append(rec)

    if len(matches) != 1:
        raise ValueError(
            "expected exactly one audited DHD PKTFWD instruction signature; "
            f"found {len(matches)}\n"
            + json.dumps({"matches": matches, "near_matches": near[:8]}, indent=2, sort_keys=True)
        )
    return matches[0]


def locate_symbol(data: bytes):
    match = locate_signature(data)
    return (
        match["file_offset"],
        0,
        0,
        "whole-file-aarch64-scan",
        "unique-full-instruction-signature",
        1,
    )


def patch_bytes(raw: bytes, function_off: int) -> bytes:
    result = bytearray(raw)
    for rel, word in PATCHED.items():
        struct.pack_into("<I", result, function_off + rel, word)
    return bytes(result)


def verify_only_expected_bytes_changed(before: bytes, after: bytes, function_off: int):
    if len(before) != len(after):
        raise ValueError("binary patch changed file size")
    allowed = set()
    for rel in PATCHED:
        base = function_off + rel
        allowed.update(range(base, base + 4))
    unexpected = [i for i, (a, b) in enumerate(zip(before, after)) if a != b and i not in allowed]
    if unexpected:
        raise ValueError(f"binary patch changed unexpected byte offset 0x{unexpected[0]:x}")


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

    changed = False
    if args.mode == "patch":
        if before_state == "original":
            after = patch_bytes(raw, function_off)
            verify_only_expected_bytes_changed(raw, after, function_off)
            changed = True
        elif before_state == "patched":
            after = raw
        else:
            raise SystemExit("Refusing binary patch: audited DHD instruction signature is unknown")
    else:
        after = raw
        if args.mode == "verify" and before_state != "patched":
            raise SystemExit(
                f"DHD PKTFWD binary verification failed: state={before_state}\n"
                + json.dumps(fmt_words(before_words), indent=2)
            )

    if changed:
        tmp = path.with_name(path.name + ".tmp-fcd")
        tmp.write_bytes(after)
        os.chmod(tmp, path.stat().st_mode & 0o7777)
        os.replace(tmp, path)

    final = path.read_bytes()
    after_sha = sha256(final)
    after_match = locate_signature(final)
    after_off = after_match["file_offset"]
    after_words = read_words(final, after_off)
    after_state = state_of(after_words)

    if after_off != function_off:
        raise SystemExit(
            f"post-operation signature moved: before=0x{function_off:x} after=0x{after_off:x}"
        )
    if changed:
        verify_only_expected_bytes_changed(raw, final, function_off)
    if args.mode in ("patch", "verify") and after_state != "patched":
        raise SystemExit(f"post-operation verification failed: state={after_state}")

    report = {
        "tool": "FlowCache Doctor DHD PKTFWD prebuilt patcher",
        "patch_revision": PATCH_REVISION,
        "match_method": "unique-full-instruction-signature",
        "elf_metadata_dependency": "architecture-header-only",
        "file": str(path),
        "mode": args.mode,
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
