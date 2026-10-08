#!/bin/bash
# pack_bootimg.sh — package a GTK kernel the way ROCKNIX's qcom-abl lane does, then GATE it.
#
#   pack_bootimg.sh <Image> <stock-KERNEL> <extra-cmdline> <out> <dtb>...
#
# Mirrors projects/ROCKNIX/packages/linux/package.mk makeinstall_target (20261001):
# gzip the Image, append the DTBs in the order given (build_72.sh passes the staged
# device DTS set, C-sorted — the stock order), a 5-byte "dummy" ramdisk, mkbootimg
# header v0. Every header value (page size, base, offsets, os_version/patch level)
# and the base cmdline come FROM THE STOCK KERNEL, so the only intended delta is
# <extra-cmdline> (ETK: "msm.context_keepalive=1 panic=30" — the ABL appends
# nothing to the cmdline, so the keepalive must be baked here).
# Ends with bootimg_parity.py check: any mismatch fails the pack (rc 1).
# MKBOOTIMG=<cmd> overrides the packer (default: mkbootimg on PATH).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
die() { echo "[pack_bootimg] FATAL: $*" >&2; exit 1; }

[ $# -ge 5 ] || die "usage: $0 <Image> <stock-KERNEL> <extra-cmdline> <out> <dtb>..."
IMG="$1"; REF="$2"; EXTRA="$3"; OUTF="$4"; shift 4
MKBOOTIMG="${MKBOOTIMG:-mkbootimg}"
command -v "$MKBOOTIMG" >/dev/null || die "$MKBOOTIMG not found (container: apt-get install mkbootimg — provision-build-container.sh)"
[ -f "$IMG" ] || die "Image $IMG missing"
[ -f "$REF" ] || die "stock reference $REF missing (stage it: KERNEL.stock-<date>)"
head -c 64 "$IMG" | tail -c 8 | grep -q 'ARM' || die "$IMG is not a raw arm64 Image (pass the uncompressed Image)"

eval "$(python3 -I "$HERE/bootimg_parity.py" fields "$REF")" || die "could not read stock header fields from $REF"
[ "$#" = "$REF_DTB_COUNT" ] || die "$# DTBs given, stock packs $REF_DTB_COUNT"

T=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$T"' EXIT
gzip -n -c "$IMG" > "$T/kernel.gz" || die "gzip failed"
for d in "$@"; do
    [ -f "$d" ] || die "DTB $d missing"
    cat "$d" >> "$T/kernel.gz" || die "append $d failed"
done
printf 'dummy' > "$T/ramdisk"

"$MKBOOTIMG" --kernel "$T/kernel.gz" --ramdisk "$T/ramdisk" \
    --base "$REF_BASE" --kernel_offset 0x00000000 \
    --ramdisk_offset "$REF_RAMDISK_OFFSET" --tags_offset "$REF_TAGS_OFFSET" \
    --pagesize "$REF_PAGESIZE" --header_version 0 \
    --os_version "$REF_OS_VERSION" --os_patch_level "$REF_OS_PATCH" \
    --cmdline "$REF_CMDLINE${EXTRA:+ $EXTRA}" \
    -o "$OUTF" || die "mkbootimg failed"

python3 -I "$HERE/bootimg_parity.py" check "$REF" "$OUTF" --extra "$EXTRA" || {
    mv "$OUTF" "$OUTF.PARITY-FAILED"
    die "parity gate FAILED — kept as $OUTF.PARITY-FAILED for inspection; do not boot it"
}
echo "[pack_bootimg] $OUTF ($(stat -c %s "$OUTF") B)"
