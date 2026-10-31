#!/bin/bash
# test_bls_gate.sh — pins the BLS-era kernel-lane gate (scripts/bls_gate.sh), the offline
# ground-truth carve (scripts/ikconfig.py + scripts/extract_initramfs.py) and the
# stage_72.sh BLS branch (GT_CHECK mode), against the banked nightly-20261030 set.
#
# WHY: under ROCKNIX 20261101 (OpenABL + Boot Loader Spec) /flash/KERNEL is the raw PE
# Image, the cmdline lives in the entry and the DTBs are files the OS ships. The old proof
# (boot.img header parity) has no object; the new one must accept the real stock set and
# refuse: a boot.img in the Image or reference slot, a release/vermagic that is not the
# stock modules dir's, a DTB that is not byte-identical to the image's, a splicer that no
# longer fits the Flip 2 trees, a drift that re-grows the retired GPIO_SBU knob, a baked
# CONFIG_CMDLINE, a lost keepalive. The carve must REPRODUCE the banked SHA256SUMS on the
# PE KERNEL and car12's /proc/config.gz + cpio on the 20261001 boot.img.
#
# DISCRIMINATION: `--against <rev>` takes the scripts from that revision; against b13c11d
# (the UPSTREAM_20261101 read, before the lane branched) every gate/stage case FAILS.
#
#   scripts/test_bls_gate.sh                     # working tree — must PASS
#   scripts/test_bls_gate.sh --against b13c11d   # pre-change — must FAIL
#
# Inputs (local-only, gitignored): groundtruth/nightly-20261030/ (KERNEL.stock-20261030,
# bootloader-20261030/dtbs, config, cpio, SHA256SUMS), groundtruth/KERNEL.stock-20261001 +
# config-7.2-rig-20261001.txt + initramfs-stock-20261001.cpio (the boot.img negatives), and
# etk's splicer (ETK_DTB_MIC, default ~/etk/bin/etk_dtb_mic.py). No rig, no network, no docker.
set -u
cd "$(dirname "$0")/.." || exit 1
REV=""
[ "${1:-}" = "--against" ] && REV="${2:?--against needs a revision}"
GT="${GT:-groundtruth/nightly-20261030}"
PE="$GT/KERNEL.stock-20261030"; DTBS="$GT/bootloader-20261030/dtbs"
BOOTIMG="groundtruth/KERNEL.stock-20261001"
KIT="${ETK_DTB_MIC:-$HOME/etk/bin/etk_dtb_mic.py}"
for f in "$PE" "$DTBS/sm8250-retroidpocket-flip2.dtb" "$GT/SHA256SUMS" "$BOOTIMG" groundtruth/config-7.2-rig-20261001.txt groundtruth/initramfs-stock-20261001.cpio; do
    [ -e "$f" ] || { echo "SKIP: $f missing (ground truth is local-only; UPSTREAM_20261101.md §1a / §0 re-check)"; exit 0; }
done
[ -f "$KIT" ] || { echo "SKIP: no splicer at $KIT (set ETK_DTB_MIC)"; exit 0; }

TD=$(mktemp -d); [ -n "${KEEP:-}" ] || trap 'rm -rf "$TD"' EXIT; [ -n "${KEEP:-}" ] && echo "sandbox: $TD"
mkdir -p "$TD/scripts"
for f in bls_gate.sh ikconfig.py extract_initramfs.py stage_72.sh stock_gcc.sh; do
    if [ -n "$REV" ]; then git show "$REV:scripts/$f" > "$TD/scripts/$f" 2>/dev/null || rm -f "$TD/scripts/$f"
    else cp "scripts/$f" "$TD/scripts/$f"; fi
done
GATE="$TD/scripts/bls_gate.sh"; IKC="$TD/scripts/ikconfig.py"; CARVE="$TD/scripts/extract_initramfs.py"; STAGE="$TD/scripts/stage_72.sh"

PASS=0; FAIL=0
ok()  { echo "PASS: $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
# expect <label> <want-rc> <want-substring> <cmd...>
expect() {
    local label="$1" wrc="$2" wsub="$3"; shift 3
    local out rc; out=$("$@" 2>&1); rc=$?
    if [ "$rc" = "$wrc" ] && printf '%s' "$out" | grep -qF -- "$wsub"; then ok "$label"
    else bad "$label (rc=$rc want $wrc; out: $(printf '%s' "$out" | grep -E 'FAIL|FATAL|OK' | tail -2 | head -c 240))"; fi
}
gate() { [ -f "$GATE" ] || { echo "no bls_gate.sh at this revision"; return 99; }
    bash "$GATE" --image "$1" --release "$2" --stock "$3" --stock-dtbs "$4" --built-dtbs "$5" --splicer "$KIT" "${@:6}"; }
want() { grep -F -- " ./$1" "$GT/SHA256SUMS" | cut -d' ' -f1; }   # banked hash of a GT file

# --- the carve reproduces the banked ground truth (PE) and the rig's truth (boot.img) ----
if [ -f "$IKC" ]; then
    python3 -I "$IKC" "$PE" "$TD/pe.config" >/dev/null 2>&1
    [ "$(sha256sum "$TD/pe.config" 2>/dev/null | cut -d' ' -f1)" = "$(want config-7.2-rig-20261030.txt)" ] \
        && ok "carve: ikconfig.py on the PE KERNEL == banked config-7.2-rig-20261030.txt" \
        || bad "carve: ikconfig.py on the PE KERNEL differs from the banked config"
    python3 -I "$IKC" "$BOOTIMG" "$TD/abl.config" >/dev/null 2>&1
    cmp -s "$TD/abl.config" groundtruth/config-7.2-rig-20261001.txt \
        && ok "carve: ikconfig.py on the 20261001 boot.img == car12's /proc/config.gz (the carve IS the rig's truth)" \
        || bad "carve: ikconfig.py on the 20261001 boot.img != car12's /proc/config.gz"
else bad "carve: no ikconfig.py at this revision"; fi
python3 -I "$CARVE" "$PE" "$TD/pe.cpio" >/dev/null 2>&1
[ "$(sha256sum "$TD/pe.cpio" 2>/dev/null | cut -d' ' -f1)" = "$(want initramfs-stock-20261030.cpio)" ] \
    && ok "carve: extract_initramfs.py on the PE KERNEL == banked initramfs-stock-20261030.cpio" \
    || bad "carve: extract_initramfs.py on the PE KERNEL differs from the banked cpio"
python3 -I "$CARVE" "$BOOTIMG" "$TD/abl.cpio" >/dev/null 2>&1
cmp -s "$TD/abl.cpio" groundtruth/initramfs-stock-20261001.cpio \
    && ok "carve: extract_initramfs.py on the 20261001 boot.img == initramfs-stock-20261001.cpio (one carver, both formats)" \
    || bad "carve: extract_initramfs.py on the 20261001 boot.img differs"

printf 'CONFIG_CMDLINE=""\n' > "$TD/good.config"
# --- the toolchain law reads itself out of stock (stock_gcc.sh) ---------------------------
SG="$TD/scripts/stock_gcc.sh"
sg() { [ -f "$SG" ] || { echo "no stock_gcc.sh at this revision"; return 99; }; bash "$SG" "$@"; }
expect "toolchain: 20261001 stock config -> gcc-15"                         0 "gcc-15" sg groundtruth/config-7.2-rig-20261001.txt
expect "toolchain: 20261101 (nightly-20261030) stock config -> gcc-16"      0 "gcc-16" sg "$GT/config-7.2-rig-20261030.txt"
printf '#!/bin/sh\necho 16.2.0\n' > "$TD/fake-gcc-16"; printf '#!/bin/sh\necho 15.3.0\n' > "$TD/fake-gcc-15"; chmod +x "$TD/fake-gcc-16" "$TD/fake-gcc-15"
expect "toolchain: --check passes a gcc of stock's major"                   0 "parity holds" sg "$GT/config-7.2-rig-20261030.txt" --check "$TD/fake-gcc-16"
expect "toolchain: --check FAILS a gcc-15 against gcc-16 stock"             1 "parity BROKEN" sg "$GT/config-7.2-rig-20261030.txt" --check "$TD/fake-gcc-15"
expect "toolchain: --check FAILS a gcc-16 against gcc-15 stock (20261001 remints stay on 15)" 1 "parity BROKEN" sg groundtruth/config-7.2-rig-20261001.txt --check "$TD/fake-gcc-16"
expect "toolchain: a config without CONFIG_GCC_VERSION is rc 2"             2 "no CONFIG_GCC_VERSION" sg "$TD/good.config"

# --- the gate accepts the real stock set ("built" == stock: the stock KERNEL plays the Image) --
: > "$TD/empty.drift"
printf '2c2\n< CONFIG_INITRAMFS_SOURCE="/x"\n---\n> CONFIG_INITRAMFS_SOURCE="/y"\n5c5\n< CONFIG_CC_VERSION_TEXT="gcc 16"\n---\n> CONFIG_CC_VERSION_TEXT="gcc 15"\n' > "$TD/tool.drift"
expect "gate: stock PE set passes (release 7.2.0, 9/9 DTBs, splicer dry-run PATCHED)" 0 "BLS GATE OK" \
    gate "$PE" 7.2.0 "$PE" "$DTBS" "$DTBS" --modules-dir 7.2.0 --config "$TD/good.config" --drift "$TD/tool.drift" --cmdline-extra "msm.context_keepalive=1 panic=30"
expect "gate: both Flip 2 trees derive and report DTB_MIC_PATCHED"  0 "sm8250-retroidpocket-flip2-visionox.dtb: derived tree reports DTB_MIC_PATCHED" gate "$PE" 7.2.0 "$PE" "$DTBS" "$DTBS"
expect "gate: paths + toolchain drift is classified as expected"     0 "drift is paths + toolchain probes only" gate "$PE" 7.2.0 "$PE" "$DTBS" "$DTBS" --drift "$TD/tool.drift"
printf '7.2.0\n' > "$TD/kernel.release"
printf '5c5\n< CONFIG_CC_VERSION_TEXT="aarch64-rocknix-linux-gnu-gcc-16.2.0 (GCC) 16.2.0"\n---\n> CONFIG_CC_VERSION_TEXT="gcc-16 (Debian 16.2.0-4) 16.2.0"\n10c10\n< CONFIG_AS_VERSION=20285426\n---\n> CONFIG_AS_VERSION=24750\n885d884\n< # CONFIG_GCC_PLUGINS is not set\n8061d8059\n< CONFIG_OPENSSL_SUPPORTS_ML_DSA=y\n' > "$TD/debian.drift"
expect "gate: the real 0.6.9 drift (Debian gcc-16: vendor string, binutils, GCC_PLUGINS hidden, host OpenSSL) is toolchain-only" 0 "drift is paths + toolchain probes only" gate "$PE" 7.2.0 "$PE" "$DTBS" "$DTBS" --drift "$TD/debian.drift"
expect "gate: --release accepts the kernel.release FILE"             0 "BLS GATE OK" gate "$PE" "$TD/kernel.release" "$PE" "$DTBS" "$DTBS"

# --- and refuses each defect -------------------------------------------------------------
expect "gate: boot.img in the Image slot -> FAIL (the 20261001 format)"     1 "Image is an Android boot.img" gate "$BOOTIMG" 7.2.0 "$PE" "$DTBS" "$DTBS"
expect "gate: boot.img as the stock reference -> FAIL"                      1 "stock reference is an Android boot.img" gate "$PE" 7.2.0 "$BOOTIMG" "$DTBS" "$DTBS"
expect "gate: release 7.2.1 != stock modules dir -> FAIL"                   1 "!= kernel.release '7.2.1'" gate "$PE" 7.2.1 "$PE" "$DTBS" "$DTBS"
expect "gate: --modules-dir not the release -> FAIL"                        1 "stock modules dir '7.1.2' != kernel.release" gate "$PE" 7.2.0 "$PE" "$DTBS" "$DTBS" --modules-dir 7.1.2
# vermagic: flip one byte of the literal the kernel compares every module against
python3 -I - "$PE" "$TD/vm.Image" <<'PY'
import sys; b = bytearray(open(sys.argv[1], 'rb').read()); i = b.find(b'7.2.0 SMP preempt mod_unload aarch64\0'); assert i > 0
b[i + 6:i + 9] = b'UMP'; open(sys.argv[2], 'wb').write(bytes(b))
PY
expect "gate: vermagic differs from stock -> FAIL"                          1 "(b) vermagic ours=" gate "$TD/vm.Image" 7.2.0 "$PE" "$DTBS" "$DTBS"
# DTBs: a tampered twin, a missing twin, an empty built set
mkdir -p "$TD/built-tamper" "$TD/built-missing" "$TD/built-empty" "$TD/spliced"
cp "$DTBS"/*.dtb "$TD/built-tamper/"; cp "$DTBS"/*.dtb "$TD/built-missing/"; rm "$TD/built-missing/sm8250-retroidpocket-rp5.dtb"
python3 -I - "$TD/built-tamper/sm8250-retroidpocket-flip2.dtb" <<'PY'
import sys; b = bytearray(open(sys.argv[1], 'rb').read()); i = b.find(b'Retroid Pocket Flip2 '); b[i] = ord('r'); open(sys.argv[1], 'wb').write(bytes(b))
PY
expect "gate: one built DTB differs from the image's -> FAIL"               1 "differ: sm8250-retroidpocket-flip2.dtb" gate "$PE" 7.2.0 "$PE" "$DTBS" "$TD/built-tamper"
expect "gate: one built DTB missing -> FAIL (8/9)"                          1 "DTBs 8/9 byte-identical; missing: sm8250-retroidpocket-rp5.dtb" gate "$PE" 7.2.0 "$PE" "$DTBS" "$TD/built-missing"
expect "gate: no stock DTBs staged -> FAIL"                                 1 "(c) no .dtb in" gate "$PE" 7.2.0 "$PE" "$TD/built-empty" "$TD/built-empty"
# splicer: a set already spliced (stock == built, so parity passes) -> derive stands down
for d in "$DTBS"/*.dtb; do n=$(basename "$d"); python3 -I "$KIT" derive "$d" "$TD/spliced/$n" >/dev/null 2>&1 || cp "$d" "$TD/spliced/$n"; done
expect "gate: artifact set already spliced -> FAIL (must stay STOCK; splicer stands down)" 1 "expected DTB_MIC_STOCK rc 3 on the built tree" gate "$PE" 7.2.0 "$PE" "$TD/spliced" "$TD/spliced"
expect "gate: splicer not staged -> FAIL"                                   1 "kit DTB splicer not staged" bash "$GATE" --image "$PE" --release 7.2.0 --stock "$PE" --stock-dtbs "$DTBS" --built-dtbs "$DTBS"
# config / cmdline / drift
printf 'CONFIG_CMDLINE="msm.context_keepalive=1"\n' > "$TD/baked.config"
expect "gate: baked CONFIG_CMDLINE -> FAIL (the entry is the only cmdline source)" 1 "CONFIG_CMDLINE is 'CONFIG_CMDLINE=\"msm.context_keepalive=1\"'" gate "$PE" 7.2.0 "$PE" "$DTBS" "$DTBS" --config "$TD/baked.config"
expect "gate: cmdline_extra without the keepalive -> FAIL"                  1 "lacks msm.context_keepalive=1" gate "$PE" 7.2.0 "$PE" "$DTBS" "$DTBS" --cmdline-extra "panic=30"
printf '5667c5667\n< CONFIG_TYPEC_MUX_GPIO_SBU=y\n---\n> CONFIG_TYPEC_MUX_GPIO_SBU=m\n' > "$TD/sbu.drift"
expect "gate: drift touches the retired GPIO_SBU knob -> FAIL"              1 "drift touches CONFIG_TYPEC_MUX_GPIO_SBU" gate "$PE" 7.2.0 "$PE" "$DTBS" "$DTBS" --drift "$TD/sbu.drift"
printf '100c100\n< CONFIG_DETECT_HUNG_TASK=y\n---\n> # CONFIG_DETECT_HUNG_TASK is not set\n' > "$TD/abi.drift"
expect "gate: drift beyond paths/toolchain is SURFACED for review, not fatal by default" 0 "REVIEW" gate "$PE" 7.2.0 "$PE" "$DTBS" "$DTBS" --drift "$TD/abi.drift"
expect "gate: ... and fatal under BLS_DRIFT_STRICT=1"                       1 "BLS_DRIFT_STRICT=1" env BLS_DRIFT_STRICT=1 bash "$GATE" --image "$PE" --release 7.2.0 --stock "$PE" --stock-dtbs "$DTBS" --built-dtbs "$DTBS" --splicer "$KIT" --drift "$TD/abi.drift"
expect "gate: missing input is rc 2, not a verdict"                         2 "missing" gate "$TD/nope.Image" 7.2.0 "$PE" "$DTBS" "$DTBS"

# --- stage_72.sh BLS branch, GT_CHECK mode (no docker, no network) -------------------------
stage() { [ -f "$STAGE" ] || { echo "no stage_72.sh at this revision"; return 99; }; env GT_CHECK=1 "$@" bash "$STAGE"; }
rm -rf "$TD/gt"; cp -r "$GT" "$TD/gt"
expect "stage: banked nightly set accepted (BLS=1 BASEDATE=20261030): MZ/ARMd branch, config + cpio REPRODUCED" 0 "GT_CHECK done" \
    stage BLS=1 BASEDATE=20261030 GT="$TD/gt" WORK="$TD/w" REPO="$PWD"
expect "stage: ... config carve reproduced the banked file"                 0 "config: pre-placed == derived" stage BLS=1 BASEDATE=20261030 GT="$TD/gt" WORK="$TD/w" REPO="$PWD"
expect "stage: ... initramfs carve reproduced the banked file"              0 "initramfs: pre-placed == derived" stage BLS=1 BASEDATE=20261030 GT="$TD/gt" WORK="$TD/w" REPO="$PWD"
rm -f "$TD/gt/config-7.2-rig-20261030.txt" "$TD/gt/initramfs-stock-20261030.cpio"
expect "stage: config + cpio absent -> DERIVED from the KERNEL"             0 "initramfs: DERIVED from the KERNEL" stage BLS=1 BASEDATE=20261030 GT="$TD/gt" WORK="$TD/w" REPO="$PWD"
[ "$(sha256sum "$TD/gt/config-7.2-rig-20261030.txt" 2>/dev/null | cut -d' ' -f1)" = "$(want config-7.2-rig-20261030.txt)" ] \
  && [ "$(sha256sum "$TD/gt/initramfs-stock-20261030.cpio" 2>/dev/null | cut -d' ' -f1)" = "$(want initramfs-stock-20261030.cpio)" ] \
  && ok "stage: the derived config + cpio carry the banked SHA256SUMS" || bad "stage: derived config/cpio hashes differ from SHA256SUMS"
cp groundtruth/config-7.2-rig-20261001.txt "$TD/gt/config-7.2-rig-20261030.txt"
expect "stage: a pre-placed config from another build -> FAIL (not what the KERNEL carries)" 1 "is NOT what KERNEL.stock-20261030 carries" stage BLS=1 BASEDATE=20261030 GT="$TD/gt" WORK="$TD/w" REPO="$PWD"
rm -rf "$TD/gt2"; cp -r "$GT" "$TD/gt2"; cp "$BOOTIMG" "$TD/gt2/KERNEL.stock-20261030"
expect "stage: a boot.img staged as the BLS KERNEL -> FAIL (previous format)" 1 "is an Android boot.img" stage BLS=1 BASEDATE=20261030 GT="$TD/gt2" WORK="$TD/w" REPO="$PWD"
rm -rf "$TD/gt3"; cp -r "$GT" "$TD/gt3"; rm -rf "$TD/gt3/bootloader-20261030"
expect "stage: no stock DTBs -> FAIL"                                       1 "no stock DTBs" stage BLS=1 BASEDATE=20261030 GT="$TD/gt3" WORK="$TD/w" REPO="$PWD"
rm -rf "$TD/gt4"; cp -r "$GT" "$TD/gt4"; mv "$TD/gt4/bootloader-20261030/dtbs" "$TD/gt4/stock-dtbs-20261030"
expect "stage: stock-dtbs-<date>/ layout accepted too"                      0 "stock DTBs: 9 in" stage BLS=1 BASEDATE=20261030 GT="$TD/gt4" WORK="$TD/w" REPO="$PWD"
expect "stage: BASEDATE 20261101 is BLS by date (no override needed)"       1 "KERNEL.stock-20261101 missing — the release .tar's target/KERNEL" stage BASEDATE=20261101 GT="$TD/gt" WORK="$TD/w" REPO="$PWD"

echo "---- $PASS passed, $FAIL failed${REV:+ (against $REV)}"
[ "$FAIL" -eq 0 ]
