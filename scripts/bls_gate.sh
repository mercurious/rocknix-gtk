#!/bin/bash
# bls_gate.sh — the BLS-era KERNEL parity gate (ROCKNIX 20261101+, UPSTREAM_20261101.md §1c).
#
# Under OpenABL + Boot Loader Spec entries the artifact is the raw PE `Image` the build
# makes (`arch/arm64/boot/Image`): no boot.img, no cmdline baked in, no DTBs inside. The
# cmdline is the entry's `options` line and the DTB is a file under /flash/dtbs, both
# rendered at DEPLOY time by the kit. So the lane's proof is no longer "the repack equals
# stock in every header field" (bootimg_parity.py) but:
#
#   (a) Image is a raw arm64 PE Image (MZ at 0, ARMd at 0x38) and its `Linux version`
#       release token == kernel.release == the STOCK KERNEL's release token
#   (b) vermagic string == the stock KERNEL's (the stock modules dir is named after it:
#       /usr/lib/kernel-overlays/base/lib/modules/<release>; MODVERSIONS is off, so this
#       string is the ONLY module-ABI check the kernel makes at insmod)
#   (c) every built DTB byte-identical to the image's /flash/dtbs/*.dtb (9/9) — the OS
#       ships them, the rig derives the kit DTB from them, our DTS staging is parity only
#   (d) the kit DTB splicer (etk bin/etk_dtb_mic.py) DRY-RUNS on both Flip 2 trees and
#       reports DTB_MIC_PATCHED on its output, while the artifact set itself stays STOCK:
#       the rig re-derives at deploy; this is the lane's early warning that the splicer
#       still fits the new trees
#   (e) config drift vs ground truth SURFACED (whole diff printed), with the retired
#       TYPEC_MUX_GPIO_SBU knob asserted GONE and CONFIG_CMDLINE asserted empty (the
#       cmdline has exactly one source now: the entry)
#
#   bls_gate.sh --image <Image> --release <kernel.release> --stock <stock KERNEL>
#               --stock-dtbs <dir of the image's dtbs> --built-dtbs <dir of built .dtb>
#               --splicer <etk_dtb_mic.py>
#              [--modules-dir <name>]   the stock modules dir name, if known (== release)
#              [--modules-out <OUT>]    a built tree: the first .ko in modules.order must
#                                       carry the same vermagic
#              [--config <.config>]     the BUILT config: CONFIG_CMDLINE must be ""
#              [--drift <diff>]         the config drift file to surface
#              [--cmdline-extra <str>]  the lane's record of the entry's extra options;
#                                       must carry msm.context_keepalive=1
#              [--kit-dtbs "<a.dtb> <b.dtb>"]  default: both Flip 2 trees
#
# Every check runs; exit 0 only if all pass ("BLS GATE OK"), 1 on any FAIL, 2 when an
# input is unreadable. A boot.img in --image or --stock is a FAIL, not a parse error:
# that is the 20261001 format, and shipping it on a BLS rig is a dark boot.
set -u

IMAGE=""; RELEASE=""; STOCK=""; SDTBS=""; BDTBS=""; SPLICER=""; MODDIR=""; MODOUT=""
CONFIG=""; DRIFT=""; CMDX=""; KIT="sm8250-retroidpocket-flip2.dtb sm8250-retroidpocket-flip2-visionox.dtb"
while [ $# -gt 0 ]; do
  case "$1" in
    --image) IMAGE="$2"; shift 2 ;;      --release) RELEASE="$2"; shift 2 ;;
    --stock) STOCK="$2"; shift 2 ;;      --stock-dtbs) SDTBS="$2"; shift 2 ;;
    --built-dtbs) BDTBS="$2"; shift 2 ;; --splicer) SPLICER="$2"; shift 2 ;;
    --modules-dir) MODDIR="$2"; shift 2 ;; --modules-out) MODOUT="$2"; shift 2 ;;
    --config) CONFIG="$2"; shift 2 ;;    --drift) DRIFT="$2"; shift 2 ;;
    --cmdline-extra) CMDX="$2"; shift 2 ;; --kit-dtbs) KIT="$2"; shift 2 ;;
    *) echo "[bls_gate] usage: see header ($1 unknown)" >&2; exit 2 ;;
  esac
done
usage_die() { echo "[bls_gate] FATAL: $*" >&2; exit 2; }
[ -n "$IMAGE" ] && [ -n "$RELEASE" ] && [ -n "$STOCK" ] && [ -n "$SDTBS" ] && [ -n "$BDTBS" ] \
  || usage_die "--image, --release, --stock, --stock-dtbs and --built-dtbs are required"
[ -f "$IMAGE" ] || usage_die "Image $IMAGE missing"
[ -f "$STOCK" ] || usage_die "stock KERNEL $STOCK missing (stage it: KERNEL.stock-<date>)"
[ -d "$SDTBS" ] || usage_die "stock dtbs dir $SDTBS missing (the image's /flash/dtbs: stage it as stock-dtbs-<date>/)"
[ -d "$BDTBS" ] || usage_die "built dtbs dir $BDTBS missing"
[ -f "$RELEASE" ] && RELEASE="$(cat "$RELEASE")"

PASS=0; FAIL=0
ok()  { echo "[bls_gate] PASS $*"; PASS=$((PASS+1)); }
bad() { echo "[bls_gate] FAIL $*"; FAIL=$((FAIL+1)); }

# --- magic: raw arm64 PE Image = MZ at 0, ARMd at 0x38 (arm64 header magic), PE\0\0 at e_lfanew
magic() {  # <file> -> prints pe | bootimg | gzip | other
  python3 -I - "$1" <<'PY'
import struct, sys
b = open(sys.argv[1], 'rb').read(0x1000)
if b[:8] == b'ANDROID!': print('bootimg')
elif b[:3] == b'\x1f\x8b\x08': print('gzip')
elif b[:2] == b'MZ' and b[0x38:0x3c] == b'ARMd' and b[struct.unpack_from('<I', b, 0x3c)[0]:][:4] == b'PE\0\0': print('pe')
else: print('other')
PY
}
describe() { case "$1" in bootimg) echo "an Android boot.img (the 20261001 qcom-abl format; OpenABL cannot load it)";; gzip) echo "a gzip stream (the lane ships the raw Image, as stock does)";; other) echo "neither MZ/ARMd nor a known wrapper";; esac; }

M=$(magic "$IMAGE")
if [ "$M" = pe ]; then ok "(a) Image is a raw arm64 PE Image (MZ, ARMd@0x38, PE header)"; else bad "(a) Image is $(describe "$M") — not a raw arm64 PE Image"; fi
MS=$(magic "$STOCK")
if [ "$MS" = pe ]; then ok "(a) stock KERNEL reference is a raw arm64 PE Image"; else bad "(a) stock reference is $(describe "$MS") — stage the 20261101 /flash/KERNEL, not the 20261001 boot.img"; fi

# --- Linux version: token 3 of the banner is the release (= kernel.release = modules dir)
banner() { strings -n 12 "$1" | grep -m1 '^Linux version ' || true; }
rel_of() { printf '%s' "$1" | awk '{print $3}'; }
IB=$(banner "$IMAGE"); SB=$(banner "$STOCK")
IR=$(rel_of "$IB"); SR=$(rel_of "$SB")
if [ -n "$IB" ] && [ "$IR" = "$RELEASE" ]; then ok "(a) Image banner release '$IR' == kernel.release '$RELEASE'"; else bad "(a) Image banner '${IB:-<none>}' release '${IR:-<none>}' != kernel.release '$RELEASE'"; fi
if [ -n "$SB" ] && [ "$SR" = "$RELEASE" ]; then ok "(a) stock banner release '$SR' == ours (the OS's modules dir is named after it)"; else bad "(a) stock banner release '${SR:-<none>}' != kernel.release '$RELEASE': this kernel would not load the OS's modules"; fi
echo "[bls_gate]   ours : ${IB:-<no banner>}"
echo "[bls_gate]   stock: ${SB:-<no banner>}"

# --- vermagic: the literal the kernel compares every module's vermagic= against
vermagic() { strings -n 12 "$1" | grep -m1 -E "^${RELEASE//./\\.} .*mod_unload" || true; }
IV=$(vermagic "$IMAGE"); SV=$(vermagic "$STOCK")
if [ -n "$IV" ] && [ "$IV" = "$SV" ]; then ok "(b) vermagic '$IV' == stock"; else bad "(b) vermagic ours='${IV:-<none>}' stock='${SV:-<none>}'"; fi
if [ -n "$MODDIR" ]; then
  if [ "$MODDIR" = "$RELEASE" ]; then ok "(b) stock modules dir '$MODDIR' == kernel.release"; else bad "(b) stock modules dir '$MODDIR' != kernel.release '$RELEASE'"; fi
fi
if [ -n "$MODOUT" ]; then
  KO=""
  if [ -f "$MODOUT/modules.order" ]; then
    first=$(head -1 "$MODOUT/modules.order" | sed 's/\.o$/.ko/')
    [ -f "$MODOUT/$first" ] && KO="$MODOUT/$first"
  fi
  if [ -n "$KO" ]; then
    KV=$(strings -n 8 "$KO" | grep -m1 '^vermagic=' | sed 's/^vermagic=//')
    if [ "$KV" = "$IV" ]; then ok "(b) built module $(basename "$KO") vermagic == Image"; else bad "(b) built module $(basename "$KO") vermagic='$KV' != Image '$IV'"; fi
  else
    bad "(b) --modules-out $MODOUT: no built .ko from modules.order to read vermagic from"
  fi
fi

# --- DTB parity: every stock tree has a byte-identical built twin
N=0; SAME=0; MISS=""; DIFF=""
for s in "$SDTBS"/*.dtb; do
  [ -e "$s" ] || continue
  N=$((N+1)); n=$(basename "$s")
  if [ ! -f "$BDTBS/$n" ]; then MISS="$MISS $n"
  elif cmp -s "$s" "$BDTBS/$n"; then SAME=$((SAME+1))
  else DIFF="$DIFF $n"; fi
done
if [ "$N" -eq 0 ]; then bad "(c) no .dtb in $SDTBS"
elif [ "$SAME" -eq "$N" ]; then ok "(c) DTBs $SAME/$N byte-identical to the image's /flash/dtbs"
else bad "(c) DTBs $SAME/$N byte-identical${MISS:+; missing:$MISS}${DIFF:+; differ:$DIFF}"; fi
EXTRA=$(for b in "$BDTBS"/*.dtb; do [ -e "$b" ] || continue; [ -e "$SDTBS/$(basename "$b")" ] || printf ' %s' "$(basename "$b")"; done)
[ -n "$EXTRA" ] && echo "[bls_gate]   note: built but not in the stock set:$EXTRA"

# --- splicer dry-run on the kit trees (built set; (c) just proved built == stock)
if [ -z "$SPLICER" ] || [ ! -f "$SPLICER" ]; then
  bad "(d) kit DTB splicer not staged (${SPLICER:-no --splicer}): lane_kernel.sh docker-cps etk bin/etk_dtb_mic.py into staging"
else
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  for k in $KIT; do
    if [ ! -f "$BDTBS/$k" ]; then bad "(d) kit tree $k not among the built DTBs"; continue; fi
    pre=$(python3 -I "$SPLICER" check "$BDTBS/$k" 2>&1); prc=$?
    if [ "$prc" = 3 ] && [ "$pre" = DTB_MIC_STOCK ]; then ok "(d) $k: artifact set is STOCK (no splice at mint)"; else bad "(d) $k: expected DTB_MIC_STOCK rc 3 on the built tree, got '$pre' rc $prc"; fi
    out=$(python3 -I "$SPLICER" derive "$BDTBS/$k" "$T/$k" 2>&1); rc=$?
    case "$rc" in
      0) case "$out" in *"mic=applied"*) ok "(d) $k: derive -> $out";; *) bad "(d) $k: derive wrote a tree but the mic delta did not apply: $out";; esac ;;
      3) bad "(d) $k: splicer stood down: $out" ;;
      *) bad "(d) $k: splicer FAILED rc $rc: $out" ;;
    esac
    if [ -f "$T/$k" ]; then
      chk=$(python3 -I "$SPLICER" check "$T/$k" 2>&1); crc=$?
      if [ "$crc" = 0 ] && [ "$chk" = DTB_MIC_PATCHED ]; then ok "(d) $k: derived tree reports DTB_MIC_PATCHED"; else bad "(d) $k: derived tree check='$chk' rc $crc"; fi
    fi
  done
fi

# --- config: one cmdline source, the entry
if [ -n "$CONFIG" ]; then
  if [ ! -f "$CONFIG" ]; then bad "(e) --config $CONFIG missing"
  elif grep -q '^CONFIG_CMDLINE=""$' "$CONFIG"; then ok "(e) CONFIG_CMDLINE is empty (the entry's options line is the only cmdline source)"
  else bad "(e) CONFIG_CMDLINE is '$(grep '^CONFIG_CMDLINE=' "$CONFIG" || echo '<absent>')' — a baked cmdline would double the entry's"; fi
fi
if [ -n "$CMDX" ]; then
  case " $CMDX " in *" msm.context_keepalive=1 "*) ok "(e) cmdline_extra record carries msm.context_keepalive=1: '$CMDX' (rendered into the entry at deploy, NOT baked)";;
    *) bad "(e) cmdline_extra record '$CMDX' lacks msm.context_keepalive=1 — the anti-lock would be lost at deploy";; esac
fi

# --- drift: surfaced whole; retired knob asserted gone; the rest classified for the reader
if [ -n "$DRIFT" ]; then
  if [ ! -f "$DRIFT" ]; then bad "(e) --drift $DRIFT missing"
  else
    echo "[bls_gate] ---- config drift vs ground truth ($DRIFT, $(grep -c '^[<>]' "$DRIFT") changed lines) ----"
    cat "$DRIFT"
    echo "[bls_gate] ---- end drift ----"
    if grep -q 'CONFIG_TYPEC_MUX_GPIO_SBU' "$DRIFT"; then bad "(e) drift touches CONFIG_TYPEC_MUX_GPIO_SBU — stock 20261101 ships =y, the ETK_GPIO_SBU_BUILTIN delta is retired and must be GONE"
    else ok "(e) drift has no TYPEC_MUX_GPIO_SBU line (retired knob gone)"; fi
    # toolchain/host probes: compiler + binutils versions and capability probes, GCC_PLUGINS (hidden
    # when the host gcc lacks plugin headers -- Debian gcc-16, 2026-10-31 -- and off in stock anyway),
    # OPENSSL_SUPPORTS_* (the host OpenSSL; module signing is off)
    REVIEW=$(grep '^[<>]' "$DRIFT" | grep -vE 'CONFIG_(INITRAMFS_SOURCE|EXTRA_FIRMWARE_DIR|CC_VERSION_TEXT|GCC_VERSION|AS_VERSION|LD_VERSION|LLD_VERSION|CLANG_VERSION|RUSTC[A-Z_]*|PAHOLE_VERSION|CC_HAS_[A-Z0-9_]+|CC_CAN_[A-Z0-9_]+|AS_HAS_[A-Z0-9_]+|AS_IS_[A-Z]+|LD_IS_[A-Z]+|LD_CAN_[A-Z0-9_]+|TOOLS_SUPPORT_RELR|CC_IS_[A-Z]+|CC_IMPLICIT_FALLTHROUGH|CC_NO_[A-Z0-9_]+|GCC_PLUGINS|HAVE_GCC_PLUGINS|OPENSSL_SUPPORTS_[A-Z0-9_]+)' || true)
    if [ -n "$REVIEW" ]; then
      echo "[bls_gate] drift lines beyond paths + toolchain probes (REVIEW — expected only for a FORENSICS mint; the MODULE-ABI guard in build_72.sh already vetted the struct-layout symbols):"
      printf '%s\n' "$REVIEW" | sed 's/^/[bls_gate]   /'
      [ "${BLS_DRIFT_STRICT:-0}" = 1 ] && bad "(e) BLS_DRIFT_STRICT=1: drift beyond paths + toolchain probes"
    else
      ok "(e) drift is paths + toolchain probes only"
    fi
  fi
fi

echo "[bls_gate] ---- $PASS passed, $FAIL failed ----"
if [ "$FAIL" -eq 0 ]; then echo "BLS GATE OK: $IMAGE ($(stat -c %s "$IMAGE") B, release $RELEASE, vermagic '$IV', DTBs $SAME/$N) — COLD-BOOT GATED, the lane only builds it"; exit 0; fi
echo "BLS GATE FAIL: $FAIL check(s) — do not ship $IMAGE"; exit 1
