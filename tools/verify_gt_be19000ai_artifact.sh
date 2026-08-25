#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_ROOT=${1:-.}
REPORT_DIR=${2:-"$ARTIFACT_ROOT/postbuild-validation"}
PATCHER=${3:-tools/patch_dhd_pktfwd_prebuilt.py}
mkdir -p "$REPORT_DIR"

fail() { echo "FAIL: $*" >&2; exit 1; }

MANIFEST="$ARTIFACT_ROOT/FLASH_MANIFEST.txt"
HASHFILE="$ARTIFACT_ROOT/FIRMWARE_SHA256.txt"
BUILDLOG="$ARTIFACT_ROOT/BUILD.log"
DHD_STAGE_HASH="$ARTIFACT_ROOT/DHD_FINAL_MODULE_SHA256.txt"

for f in "$MANIFEST" "$HASHFILE" "$BUILDLOG" "$DHD_STAGE_HASH"; do
  test -s "$f" || fail "missing required artifact file: $f"
done

grep -qx 'VERIFIED_FOR_FLASH=YES' "$MANIFEST" || fail "build manifest is not flash-approved"
grep -qx 'DHD_BINARY_PATCH_VERIFIED=YES' "$MANIFEST" || fail "build manifest lacks final DHD verification"
grep -qx 'DHD_BINARY_PATCH_REVISION=2' "$MANIFEST" || fail "unexpected DHD patch revision"
grep -qx 'MODEL=GT-BE19000AI' "$MANIFEST" || fail "wrong router model"

FLASH_FILE=$(sed -n 's/^FLASH_FILE=//p' "$MANIFEST")
test -n "$FLASH_FILE" || fail "FLASH_FILE missing from manifest"
[[ "$FLASH_FILE" == GT-BE19000AI_*_emmc_squashfs.pkgtb ]] || fail "unexpected flash filename: $FLASH_FILE"
[[ "$FLASH_FILE" != *loader* ]] || fail "loader image must never be normal flash image"
FW="$ARTIFACT_ROOT/$FLASH_FILE"
test -s "$FW" || fail "firmware file missing: $FLASH_FILE"

mapfile -t PKGTBS < <(find "$ARTIFACT_ROOT" -maxdepth 2 -type f -name '*.pkgtb' -printf '%p\n' | sort)
[[ ${#PKGTBS[@]} -eq 1 ]] || fail "expected exactly one PKGTB in success artifact, found ${#PKGTBS[@]}"
[[ "${PKGTBS[0]}" == "$FW" ]] || fail "success artifact contains unexpected PKGTB"

FW_SIZE=$(stat -c %s "$FW")
(( FW_SIZE > 100000000 )) || fail "firmware is unexpectedly small: $FW_SIZE bytes"
(
  cd "$ARTIFACT_ROOT"
  sha256sum -c "$(basename "$HASHFILE")"
) > "$REPORT_DIR/FIRMWARE_SHA256_CHECK.txt" 2>&1 || fail "firmware SHA256 check failed"

MANIFEST_SHA=$(sed -n 's/^FLASH_SHA256=//p' "$MANIFEST")
ACTUAL_SHA=$(sha256sum "$FW" | awk '{print $1}')
[[ "$MANIFEST_SHA" == "$ACTUAL_SHA" ]] || fail "manifest SHA256 does not match firmware"

grep -Fq 'Done! Image 96813GW has been built' "$BUILDLOG" || fail "Merlin success marker missing from BUILD.log"

python3 - "$FW" "$REPORT_DIR/FIRMWARE_MAGIC_SCAN.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = p.read_bytes()
def all_offsets(needle):
    out = []
    pos = 0
    while True:
        pos = data.find(needle, pos)
        if pos < 0:
            return out
        out.append(pos)
        pos += 1
squash = all_offsets(b'hsqs')
fdt = all_offsets(b'\xd0\x0d\xfe\xed')
json.dump({"file": p.name, "size": len(data), "squashfs_offsets": squash, "fdt_magic_offsets": fdt}, open(sys.argv[2], 'w'), indent=2)
if not squash:
    raise SystemExit('no SquashFS rootfs magic found in firmware')
if not fdt:
    raise SystemExit('no FIT/FDT magic found in firmware')
PY

mapfile -t OFFSETS < <(python3 - "$REPORT_DIR/FIRMWARE_MAGIC_SCAN.json" <<'PY'
import json, sys
for x in json.load(open(sys.argv[1]))['squashfs_offsets']:
    print(x)
PY
)

ROOTFS=""
ROOTFS_OFFSET=""
for off in "${OFFSETS[@]}"; do
  candidate="$REPORT_DIR/rootfs-$off"
  rm -rf "$candidate"
  if unsquashfs -no-progress -d "$candidate" -o "$off" "$FW" >"$REPORT_DIR/unsquashfs-$off.log" 2>&1; then
    if find "$candidate/lib/modules" -type f -path '*/extra/dhd.ko' -print -quit 2>/dev/null | grep -q .; then
      ROOTFS="$candidate"
      ROOTFS_OFFSET="$off"
      break
    fi
  fi
done
[[ -n "$ROOTFS" ]] || fail "could not extract a firmware rootfs containing DHD"
printf '%s\n' "$ROOTFS_OFFSET" > "$REPORT_DIR/ROOTFS_OFFSET.txt"

for d in bin sbin etc lib usr; do
  test -d "$ROOTFS/$d" || fail "packaged rootfs missing /$d"
done

FILE_COUNT=$(find "$ROOTFS" -type f | wc -l | tr -d ' ')
DIR_COUNT=$(find "$ROOTFS" -type d | wc -l | tr -d ' ')
(( FILE_COUNT >= 500 )) || fail "packaged rootfs file count is implausibly low: $FILE_COUNT"
(( DIR_COUNT >= 100 )) || fail "packaged rootfs directory count is implausibly low: $DIR_COUNT"

for name in busybox rc nvram; do
  find "$ROOTFS" -name "$name" -print -quit | grep -q . || fail "packaged rootfs missing core binary: $name"
done

mapfile -t DHD_MODULES < <(find "$ROOTFS/lib/modules" -type f -path '*/extra/dhd.ko' -print | sort)
[[ ${#DHD_MODULES[@]} -eq 1 ]] || fail "expected exactly one packaged dhd.ko, found ${#DHD_MODULES[@]}"
PACKAGED_DHD="${DHD_MODULES[0]}"
file "$PACKAGED_DHD" > "$REPORT_DIR/PACKAGED_DHD_FILE_TYPE.txt"
readelf -h "$PACKAGED_DHD" > "$REPORT_DIR/PACKAGED_DHD_ELF_HEADER.txt"
grep -Eq 'Machine:[[:space:]]+AArch64' "$REPORT_DIR/PACKAGED_DHD_ELF_HEADER.txt" || fail "packaged dhd.ko is not AArch64"

python3 "$PATCHER" verify "$PACKAGED_DHD" --report "$REPORT_DIR/PACKAGED_DHD_VERIFICATION.json" > "$REPORT_DIR/PACKAGED_DHD_VERIFY.stdout"
PACKAGED_DHD_SHA=$(sha256sum "$PACKAGED_DHD" | awk '{print $1}')
STAGED_DHD_SHA=$(awk 'NF{print $1; exit}' "$DHD_STAGE_HASH")
[[ "$PACKAGED_DHD_SHA" == "$STAGED_DHD_SHA" ]] || fail "packaged dhd.ko differs from the DHD module verified before packaging"

find "$ROOTFS" -type f -printf '%P\t%s\n' | sort > "$REPORT_DIR/ROOTFS_FILE_INVENTORY.tsv"
{
  echo "POSTBUILD_VERIFIED_FOR_FLASH=YES"
  echo "PACKAGED_ROOTFS_VERIFIED=YES"
  echo "PACKAGED_DHD_BINARY_PATCH_VERIFIED=YES"
  echo "DHD_BINARY_PATCH_REVISION=2"
  echo "MODEL=GT-BE19000AI"
  echo "FLASH_FILE=$FLASH_FILE"
  echo "FLASH_SHA256=$ACTUAL_SHA"
  echo "FLASH_SIZE_BYTES=$FW_SIZE"
  echo "ROOTFS_OFFSET=$ROOTFS_OFFSET"
  echo "ROOTFS_FILE_COUNT=$FILE_COUNT"
  echo "ROOTFS_DIR_COUNT=$DIR_COUNT"
  echo "PACKAGED_DHD_SHA256=$PACKAGED_DHD_SHA"
  echo "STAGED_DHD_SHA256=$STAGED_DHD_SHA"
} > "$REPORT_DIR/POSTBUILD_FLASH_APPROVAL.txt"

echo "PASS: packaged GT-BE19000AI firmware rootfs and revision-2 DHD verified"
