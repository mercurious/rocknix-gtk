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
#
# THE KIT DTB SPLICE (2026-10-08): under qcom-abl the DTBs ride INSIDE the boot.img,
# so the Flip 2 kit deltas (internal mic; USB-C VBUS when the stock DT lacks it) are
# applied HERE, at mint, by the same splicer install.sh used on the grub slot:
#   KIT_DTB_TOOL=<etk bin/etk_dtb_mic.py>   (unset = pure parity, no splice)
#   KIT_DTB_MODELS="Retroid Pocket Flip2|Retroid Pocket Flip2 Visionox"  (root model)
#   KIT_DTB_FLAGS="--no-mic"                 (the ETK_INTERNAL_MIC=0 kill-switch)
# Each matching DTB is derived into a temp copy (the splicer refuses anything it is
# not sure of and stands down per delta); the gate then REQUIRES those models to
# differ from stock and verify DTB_MIC_PATCHED, and every other DTB to be byte-
# identical. The parity gate stays the proof -- never the build log.
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
KIT_DTB_TOOL="${KIT_DTB_TOOL:-}"
KIT_DTB_MODELS="${KIT_DTB_MODELS:-Retroid Pocket Flip2|Retroid Pocket Flip2 Visionox}"
KIT_DTB_FLAGS="${KIT_DTB_FLAGS:-}"
KIT_SPLICED=""     # models the splicer actually changed -> the gate's kit list
if [ -n "$KIT_DTB_TOOL" ]; then
    [ -f "$KIT_DTB_TOOL" ] || die "KIT_DTB_TOOL $KIT_DTB_TOOL missing (lane_kernel.sh stages etk bin/etk_dtb_mic.py)"
fi
dtb_model() { python3 -I - "$1" <<'PY'
import sys; sys.path.insert(0, __import__('os').path.dirname(sys.argv[0]) if False else '')
import struct
b = open(sys.argv[1], 'rb').read()
_, total, off_s, off_str = struct.unpack_from('>4I', b, 0); strings = b[off_str:]
p, depth = off_s, 0
while p < total:
    tok = struct.unpack_from('>I', b, p)[0]; p += 4
    if tok == 1: e = b.index(b'\0', p); p = (e + 4) & ~3; depth += 1
    elif tok == 2: depth -= 1
    elif tok == 3:
        ln, no = struct.unpack_from('>II', b, p); p += 8
        name = strings[no:strings.index(b'\0', no)].decode()
        if depth == 1 and name == 'model': print(b[p:p + ln].rstrip(b'\0').decode()); break
        p = (p + ln + 3) & ~3
    elif tok == 9: break
PY
}
gzip -n -c "$IMG" > "$T/kernel.gz" || die "gzip failed"
n=0
for d in "$@"; do
    [ -f "$d" ] || die "DTB $d missing"
    use="$d"
    if [ -n "$KIT_DTB_TOOL" ]; then
        model=$(dtb_model "$d")
        case "|$KIT_DTB_MODELS|" in *"|$model|"*)
            out=$(python3 -I "$KIT_DTB_TOOL" derive $KIT_DTB_FLAGS "$d" "$T/kit$n.dtb" 2>&1); rc=$?
            case "$rc" in
                0) echo "[pack_bootimg] kit DTB: $model -> $out"; use="$T/kit$n.dtb"; KIT_SPLICED="${KIT_SPLICED:+$KIT_SPLICED|}$model" ;;
                3) echo "[pack_bootimg] kit DTB: $model STOCK (splicer stood down: $out)" ;;
                *) die "kit DTB splice FAILED for $model: $out" ;;
            esac ;;
        esac
    fi
    cat "$use" >> "$T/kernel.gz" || die "append $d failed"
    n=$((n + 1))
done
printf 'dummy' > "$T/ramdisk"

"$MKBOOTIMG" --kernel "$T/kernel.gz" --ramdisk "$T/ramdisk" \
    --base "$REF_BASE" --kernel_offset 0x00000000 \
    --ramdisk_offset "$REF_RAMDISK_OFFSET" --tags_offset "$REF_TAGS_OFFSET" \
    --pagesize "$REF_PAGESIZE" --header_version 0 \
    --os_version "$REF_OS_VERSION" --os_patch_level "$REF_OS_PATCH" \
    --cmdline "$REF_CMDLINE${EXTRA:+ $EXTRA}" \
    -o "$OUTF" || die "mkbootimg failed"

GATE_KIT=()
[ -n "$KIT_SPLICED" ] && GATE_KIT=(--kit-models "$KIT_SPLICED" --kit-check "$KIT_DTB_TOOL")
python3 -I "$HERE/bootimg_parity.py" check "$REF" "$OUTF" --extra "$EXTRA" "${GATE_KIT[@]}" || {
    mv "$OUTF" "$OUTF.PARITY-FAILED"
    die "parity gate FAILED — kept as $OUTF.PARITY-FAILED for inspection; do not boot it"
}
echo "[pack_bootimg] $OUTF ($(stat -c %s "$OUTF") B)"
