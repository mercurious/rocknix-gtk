#!/bin/bash
# ROCKNIX-GTK Tier-K kernel pipeline — stock-identical build
# Replicates ROCKNIX 20260701 (BUILD_ID 3e4ee585) SM8250 kernel 7.0.11 from
# mainline tarball + ROCKNIX patch stack + rig-ground-truth config.
# LAW: gate every stage on real exit codes; never pipe make/ninja to tail.
set -u
cd /kernel

log() { echo "[build_stock] $*"; }
die() { echo "[build_stock] FATAL: $*"; exit 1; }

SRC=/kernel/linux-7.0.11
OUT="${OUT:-/kernel/out}"
KCC="${KCC:-gcc-14}"

# --- 1. Extract pristine tarball (tarball, NEVER git: LOCALVERSION_AUTO=y
#        would append +g<hash> and break the module-ABI law) ---
if [ ! -d "$SRC" ]; then
  log "extracting linux-7.0.11.tar.xz ..."
  tar xf linux-7.0.11.tar.xz || die "tarball extract failed"
fi
grep -q "^VERSION = 7$" "$SRC/Makefile" || die "unexpected kernel VERSION"
grep -q "^SUBLEVEL = 11$" "$SRC/Makefile" || die "unexpected kernel SUBLEVEL"

# --- 2. Device DTS overlay (mirrors package.mk DTS_SOURCE_DIR rsync) ---
cp -r /kernel/staging/dts-device/* "$SRC/arch/arm64/boot/dts/" || die "dts copy failed"

# --- 3. Patch stack: mainline(5) -> 7.0(2) -> device SM8250(27),
#        the order scripts/unpack applies them in ---
if [ ! -f "$SRC/.etk-patches-applied" ]; then
  # 01-03 = ROCKNIX's own stack (kept pristine/separate); 04-etk = ETK patches
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

# --- 4. Config = rig /proc/config.gz ground truth, with only the two
#        build-local path substitutions ---
mkdir -p "$OUT"
cp /kernel/staging/config-7.0.11-rig.txt "$OUT/.config"
"$SRC/scripts/config" --file "$OUT/.config" \
  --set-str CONFIG_INITRAMFS_SOURCE "/kernel/staging/initramfs-stock.cpio" \
  --set-str CONFIG_EXTRA_FIRMWARE_DIR "/kernel/staging/external-firmware"

MAKE="make -C $SRC O=$OUT ARCH=arm64 CC=$KCC HOSTCC=$KCC KBUILD_BUILD_HOST=rocknix-gtk -j6"

# --- 5. olddefconfig + drift check against ground truth ---
$MAKE olddefconfig > /tmp/olddefconfig.log 2>&1 || { cat /tmp/olddefconfig.log; die "olddefconfig failed"; }
diff /kernel/staging/config-7.0.11-rig.txt "$OUT/.config" > /kernel/config.drift
log "config drift vs rig ground truth (expect only INITRAMFS/FIRMWARE paths + toolchain-probe lines):"
cat /kernel/config.drift

# --- 6. The build (Image + modules; dtbs proven separately) ---
log "building Image + modules with $($KCC --version | head -1) ..."
if $MAKE Image modules > /kernel/build.log 2>&1; then
  log "BUILD OK"
else
  echo "=== last 60 lines of build.log ==="
  tail -60 /kernel/build.log
  die "kernel build FAILED (full log: /kernel/build.log)"
fi

# --- 7. Verification summary ---
echo "=== VERIFY ==="
echo "kernel.release: $(cat "$OUT/include/config/kernel.release")"
ls -la "$OUT/arch/arm64/boot/Image"
echo "modules built: $(find "$OUT" -name '*.ko' | wc -l) (rig ships 236 .ko)"
strings "$OUT/arch/arm64/boot/Image" | grep -m1 "Linux version"
