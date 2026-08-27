#!/bin/bash
# ROCKNIX-GTK Tier-K kernel pipeline — 7.1.2 / ROCKNIX 20260801 rebase lane.
# Same contract as build_stock.sh (7.0.11 lane, kept intact): mainline tarball
# + ROCKNIX patch stack (20260801) + rig-ground-truth config + ETK patches.
# LAW: gate every stage on real exit codes; never pipe make to tail.
# LAW: build in the sid container (gcc 15.x / binutils >=2.44) — gcc-14
#      black-screens pre-userspace on this target (proven 2026-07-05).
set -u
cd /kernel

log() { echo "[build_712] $*"; }
die() { echo "[build_712] FATAL: $*"; exit 1; }

SRC=/kernel/linux-7.1.2
OUT="${OUT:-/kernel/out712}"

# gcc-15 is the VALIDATED compiler (15.3.0 built every shipping artifact). Do not
# default to gcc-14: it produces a kernel that compiles clean, verifies clean, and
# black-screens the rig pre-userspace (BUILDING.md "Toolchain law"). Do not default
# to the container's bare `gcc` either — sid's default moved to 16.1.0 on 2026-08-05
# and is unvalidated here. Override deliberately or not at all.
KCC_EXPLICIT="${KCC:+yes}"
KCC="${KCC:-gcc-15}"

# The law above is stated in this file's header and in build_stock.sh, but until
# now nothing enforced it — and the failure is SILENT (clean build, clean verify,
# black screen). Gate the DEFAULT path; an explicit KCC is the operator's call.
if [ -z "$KCC_EXPLICIT" ]; then
  KCC_VER="$($KCC -dumpfullversion 2>/dev/null || echo none)"
  case "$KCC_VER" in
    15.*) ;;
    *) die "default compiler $KCC is $KCC_VER, not the validated 15.x. Install gcc-15 in the container, or set KCC=... deliberately." ;;
  esac
fi

# --- 1. Extract pristine tarball (tarball, NEVER git: LOCALVERSION_AUTO=y
#        would append +g<hash> and break the module-ABI law) ---
if [ ! -d "$SRC" ]; then
  log "extracting linux-7.1.2.tar.xz ..."
  tar xf linux-7.1.2.tar.xz || die "tarball extract failed"
fi
grep -q "^VERSION = 7$" "$SRC/Makefile" || die "unexpected kernel VERSION"
grep -q "^PATCHLEVEL = 1$" "$SRC/Makefile" || die "unexpected kernel PATCHLEVEL"
grep -q "^SUBLEVEL = 2$" "$SRC/Makefile" || die "unexpected kernel SUBLEVEL"

# --- 2. Device DTS overlay (mirrors package.mk DTS_SOURCE_DIR rsync;
#        20260801 dts carries DP-audio + panel-timing + fan + RTC changes) ---
cp -r /kernel/staging/dts-device/* "$SRC/arch/arm64/boot/dts/" || die "dts copy failed"

# --- 3. Patch stack in scripts/unpack order: mainline(5) -> 7.0(3) ->
#        device SM8250(28) -> 04-etk (kgsl-parity keepalive + q6afe race) ---
if [ ! -f "$SRC/.etk-patches-applied" ]; then
  for d in 01-mainline 02-70 03-device 04-etk; do
    [ -d /kernel/staging/patches/$d ] || continue
    for p in /kernel/staging/patches/$d/*.patch; do
      [ -e "$p" ] || continue
      if patch -p1 -N --no-backup-if-mismatch -d "$SRC" < "$p" > /tmp/patch.log 2>&1; then
        log "applied: $d/$(basename "$p")"
      else
        cat /tmp/patch.log
        die "patch FAILED: $d/$(basename "$p")"
      fi
    done
  done
  touch "$SRC/.etk-patches-applied"
else
  log "patches already applied (stamp present)"
fi

# --- 4. Config = live-rig 20260801 /proc/config.gz ground truth, with only
#        the two build-local path substitutions ---
mkdir -p "$OUT"
cp /kernel/staging/config-7.1.2-rig.txt "$OUT/.config"
"$SRC/scripts/config" --file "$OUT/.config" \
  --set-str CONFIG_INITRAMFS_SOURCE "/kernel/staging/initramfs-stock-20260801.cpio" \
  --set-str CONFIG_EXTRA_FIRMWARE_DIR "/kernel/staging/external-firmware"
# Parity: kernel 7.1 gates ARM64_LSUI on an AS probe that our binutils 2.46
# passes but the release's 2.44 fails — stock ships it compiled OUT. Disable
# so the only deltas vs stock are toolchain-version strings (zero functional
# drift, the recipe's whole contract). Inert on SM8250 either way (no FEAT_LSUI).
"$SRC/scripts/config" --file "$OUT/.config" --disable CONFIG_ARM64_LSUI
# GTK wdt-bark (2026-08-27): enable the watchdog pretimeout governor
# framework, panic as the default governor. CONFIG_QCOM_WDT=y and the sm8250
# bark IRQ (GIC_SPI 0) are already in the rig ground truth; this adds ONLY
# the governor plumbing. DARK AT RUNTIME: nothing on the rig opens
# /dev/watchdog0 today, so the kernel behaves bit-for-bit identically until
# the operator arms it (systemd RuntimeWatchdogUSec property — a separate,
# harness-validated step). Purpose: the fast PANIC class (ETK census
# 2026-08-27) dies with ZERO kmsg on a SoC with no pstore and no logged PON
# reason; a bark->panic converts that silent death into logged stacks the
# ETK blackbox can fsync within ~1 s.
"$SRC/scripts/config" --file "$OUT/.config" \
  --enable CONFIG_WATCHDOG_PRETIMEOUT_GOV \
  --enable CONFIG_WATCHDOG_PRETIMEOUT_DEFAULT_GOV_PANIC \
  --enable CONFIG_WATCHDOG_PRETIMEOUT_GOV_NOOP \
  --enable CONFIG_WATCHDOG_PRETIMEOUT_GOV_PANIC

MAKE="make -C $SRC O=$OUT ARCH=arm64 CC=$KCC HOSTCC=$KCC KBUILD_BUILD_HOST=rocknix-gtk -j6"

# --- 5. olddefconfig + drift check against ground truth ---
$MAKE olddefconfig > /tmp/olddefconfig.log 2>&1 || { cat /tmp/olddefconfig.log; die "olddefconfig failed"; }
diff /kernel/staging/config-7.1.2-rig.txt "$OUT/.config" > /kernel/config712.drift
log "config drift vs rig ground truth (expect only INITRAMFS/FIRMWARE paths + toolchain-probe lines + the wdt pretimeout governor block):"
cat /kernel/config712.drift

# --- 6. The build (Image + modules) ---
log "building Image + modules with $($KCC --version | head -1) ..."
if $MAKE Image modules > /kernel/build712.log 2>&1; then
  log "BUILD OK"
else
  echo "=== last 60 lines of build712.log ==="
  tail -60 /kernel/build712.log
  die "kernel build FAILED (full log: /kernel/build712.log)"
fi

# --- 7. Verification summary ---
echo "=== VERIFY ==="
echo "kernel.release: $(cat "$OUT/include/config/kernel.release")"
ls -la "$OUT/arch/arm64/boot/Image"
echo "modules built: $(find "$OUT" -name '*.ko' | wc -l)"
strings "$OUT/arch/arm64/boot/Image" | grep -m1 "Linux version"
