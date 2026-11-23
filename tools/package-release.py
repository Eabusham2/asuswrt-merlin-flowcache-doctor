#!/usr/bin/env python3
"""Package exactly one committed script revision, without host-generated files."""
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import subprocess


def git(*args: str) -> bytes:
    return subprocess.check_output(["git", *args])


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"v\d+\.\d+\.\d+", args.tag):
        parser.error("tag must be vMAJOR.MINOR.PATCH")
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("commit must be a full lower-case SHA")
    commit = git("rev-parse", f"{args.commit}^{{commit}}").decode().strip()
    if commit != args.commit:
        parser.error("commit did not resolve exactly")
    installer = git("show", f"{commit}:install.sh").decode()
    version = re.search(r"^VERSION=(.+)$", installer, re.MULTILINE)
    if not version or version.group(1) != args.tag[1:]:
        parser.error("tag does not match the committed installer version")
    args.output.mkdir(parents=True, exist_ok=True)
    archive = args.output / f"flowcache-doctor-{args.tag}.tar.gz"
    source_tar = git("archive", "--format=tar", f"--prefix=flowcache-doctor-{args.tag}/", commit)
    with archive.open("wb") as target:
        with gzip.GzipFile(filename="", mode="wb", fileobj=target, mtime=0) as zipped:
            zipped.write(source_tar)
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest = args.output / "release-manifest.json"
    manifest.write_text(json.dumps({
        "project": "Eabusham2/asuswrt-merlin-flowcache-doctor",
        "product": "JFFS scripts and source; not router firmware",
        "tag": args.tag,
        "source_commit": commit,
        "installer_ref": args.tag,
        "archive": archive.name,
        "archive_sha256": digest,
        "compatibility": "ASUS GT-BE19000AI / Asuswrt-Merlin",
        "validation_scope": "CI shell and simulated behavior; no physical-router claim",
    }, indent=2) + "\n")
    checksums = args.output / "SHA256SUMS"
    checksums.write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n"
        for path in (archive, manifest)
    ))
    print(f"Packaged {commit} as {archive.name}")


if __name__ == "__main__":
    main()
