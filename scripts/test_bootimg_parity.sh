#!/bin/bash
# test_bootimg_parity.sh — pins the K2 boot.img packer + parity gate
# (scripts/pack_bootimg.sh, scripts/bootimg_parity.py).
#
# WHY: under ROCKNIX's qcom-abl boot (20261001+) /flash/KERNEL is an Android boot.img
# and the ABL appends nothing to the cmdline, so the GTK kernel's keepalive has to be
# baked in at mint, and a wrong DTB order or a raw Image in that slot is a no-boot.
# The gate must accept a faithful repack and refuse every one of those defects.
#
# HOW: splits the REAL stock KERNEL (groundtruth/KERNEL.stock-20261001 — local, not
# published) into its raw Image + 9 DTBs, repacks via pack_bootimg.sh (must PASS),
# then hand-builds defective images with mkbootimg and runs the gate on each (must
# FAIL). Needs mkbootimg on PATH (Fedora: android-tools). No rig, no network.
#
# DISCRIMINATION: `--against <rev>` takes both scripts from that revision; against
# 3733f60 (before the gate existed) every case FAILS.
#
#   scripts/test_bootimg_parity.sh                 # working tree — must PASS
#   scripts/test_bootimg_parity.sh --against 3733f60   # pre-gate — must FAIL

set -u
cd "$(dirname "$0")/.." || exit 1
REV=""
[ "${1:-}" = "--against" ] && REV="${2:?--against needs a revision}"
REF="${REF:-groundtruth/KERNEL.stock-20261001}"
[ -f "$REF" ] || { echo "SKIP: $REF missing (ground truth is local-only; pull car12's /flash/KERNEL)"; exit 0; }
command -v mkbootimg >/dev/null || { echo "SKIP: mkbootimg not on PATH"; exit 0; }

TD=$(mktemp -d); [ -n "${KEEP:-}" ] || trap 'rm -rf "$TD"' EXIT; [ -n "${KEEP:-}" ] && echo "sandbox: $TD"
mkdir -p "$TD/scripts" "$TD/dtb"
for f in pack_bootimg.sh bootimg_parity.py; do
    if [ -n "$REV" ]; then git show "$REV:scripts/$f" > "$TD/scripts/$f" 2>/dev/null || rm -f "$TD/scripts/$f"
    else cp "scripts/$f" "$TD/scripts/$f"; fi
done
PACK="$TD/scripts/pack_bootimg.sh"; GATE="$TD/scripts/bootimg_parity.py"
EXTRA="msm.context_keepalive=1 panic=30"

# split the stock image with a standalone parser (not the code under test)
python3 -I - "$REF" "$TD" <<'PY'
import struct, sys, zlib
ref, td = sys.argv[1], sys.argv[2]
b = open(ref, 'rb').read()
ks, ps = struct.unpack_from('<I', b, 8)[0], struct.unpack_from('<I', b, 36)[0]
d = zlib.decompressobj(31); img = d.decompress(b[ps:ps + ks]); tail = d.unused_data
open(f'{td}/Image', 'wb').write(img)
p = n = 0
while p + 8 <= len(tail) and struct.unpack_from('>I', tail, p)[0] == 0xd00dfeed:
    t = struct.unpack_from('>I', tail, p + 4)[0]
    open(f'{td}/dtb/{n:02d}.dtb', 'wb').write(tail[p:p + t]); p += t; n += 1
print(f'split: Image {len(img)} B + {n} DTBs')
PY
DTBS=$(ls "$TD"/dtb/*.dtb)

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
# expect <label> <want-rc> <want-substring> <cmd...>
expect() {
    local label="$1" wrc="$2" wsub="$3"; shift 3
    local out rc; out=$("$@" 2>&1); rc=$?
    if [ "$rc" = "$wrc" ] && printf '%s' "$out" | grep -qF -- "$wsub"; then ok "$label"
    else bad "$label (rc=$rc want $wrc; out: $(printf '%s' "$out" | tail -2 | head -c 200))"; fi
}
gate() { [ -f "$GATE" ] || { echo "no bootimg_parity.py"; return 99; }; python3 -I "$GATE" check "$REF" "$1" --extra "$EXTRA"; }
pack() { [ -f "$PACK" ] || { echo "no pack_bootimg.sh"; return 99; }; bash "$PACK" "$@"; }

# raw mkbootimg with stock fields, for building defective candidates
mk() {  # mk <out> <cmdline> <pagesize> <ramdisk-bytes> <dtb...>
    local out="$1" cl="$2" pg="$3" rd="$4"; shift 4
    gzip -n -c "$TD/Image" > "$TD/k.gz"; for d in "$@"; do cat "$d" >> "$TD/k.gz"; done
    printf '%s' "$rd" > "$TD/rd"
    mkbootimg --kernel "$TD/k.gz" --ramdisk "$TD/rd" --base 0x10000000 --kernel_offset 0 \
        --ramdisk_offset 0 --tags_offset 0 --pagesize "$pg" --header_version 0 \
        --os_version 12.0.0 --os_patch_level 2026-10 --cmdline "$cl" -o "$out" >/dev/null 2>&1
}
STOCKCL="boot=LABEL=ROCKNIX disk=LABEL=STORAGE quiet rootwait console=tty0 video=efifb:off gpt"
set -- $DTBS; D0=$1; D1=$2; D2=$3; D3=$4; D4=$5; D5=$6; D6=$7; D7=$8; D8=$9

# --- the packer ------------------------------------------------------------------
expect "pack: faithful repack + ETK cmdline passes the gate" 0 "PARITY OK" pack "$TD/Image" "$REF" "$EXTRA" "$TD/good.img" $DTBS
expect "pack: result carries the keepalive on the cmdline"   0 "msm.context_keepalive=1" python3 -I "$GATE" show "$TD/good.img"
expect "pack: all 9 DTBs byte-identical to stock"            0 "9/9 byte-identical" gate "$TD/good.img"
expect "pack: refuses a wrong DTB count"                     1 "stock packs 9" pack "$TD/Image" "$REF" "$EXTRA" "$TD/x.img" $D0 $D1
gzip -n -c "$TD/Image" > "$TD/Image.gz"
expect "pack: refuses a gzip'd Image (needs the raw one)"    1 "not a raw arm64 Image" pack "$TD/Image.gz" "$REF" "$EXTRA" "$TD/x.img" $DTBS

# --- the gate refuses each defect -------------------------------------------------
mk "$TD/nokeep.img" "$STOCKCL" 2048 dummy $DTBS
expect "gate: missing keepalive (stock cmdline) -> FAIL"     1 "PARITY FAIL: cmdline" gate "$TD/nokeep.img"
mk "$TD/stray.img" "$STOCKCL $EXTRA foo=1" 2048 dummy $DTBS
expect "gate: stray extra param -> FAIL"                     1 "PARITY FAIL: cmdline" gate "$TD/stray.img"
mk "$TD/order.img" "$STOCKCL $EXTRA" 2048 dummy $D0 $D1 $D2 $D4 $D3 $D5 $D6 $D7 $D8
expect "gate: Flip2/Flip2-Visionox order swapped -> FAIL"    1 "ORDER differs" gate "$TD/order.img"
mk "$TD/drop.img" "$STOCKCL $EXTRA" 2048 dummy $D0 $D1 $D2 $D3 $D4 $D5 $D6 $D7
expect "gate: a DTB dropped -> FAIL"                         1 "ORDER differs" gate "$TD/drop.img"
mk "$TD/page.img" "$STOCKCL $EXTRA" 4096 dummy $DTBS
expect "gate: page size 4096 -> FAIL"                        1 "PARITY FAIL: page_size" gate "$TD/page.img"
mk "$TD/rd.img" "$STOCKCL $EXTRA" 2048 x $DTBS
expect "gate: different ramdisk -> FAIL"                     1 "PARITY FAIL: ramdisk" gate "$TD/rd.img"
expect "gate: raw Image in the KERNEL slot -> refused"       2 "not an Android boot image" gate "$TD/Image"

echo "---- $PASS passed, $FAIL failed${REV:+ (against $REV)}"
[ "$FAIL" -eq 0 ]
