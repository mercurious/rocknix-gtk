#!/bin/bash
# ROCKNIX-GTK Tier-K kernel pipeline — 7.2 / ROCKNIX 20260901 rebase lane.
# Same contract as build_712.sh (7.1.2 lane, kept intact until the 7.2 kernel
# is cold-boot validated + certified): mainline tarball + ROCKNIX patch stack
# + rig-ground-truth config + ETK patches (patches-7.2/, SIX active — #6
# dp-bounded-enable-lock is DROPPED on 7.2: upstream removed event_mutex from
# dp_display.c entirely, the lock this patch bounds no longer exists; #4 is
# switch-side only, upstream removed the buggy mux-side dedup loop).
# LAW: gate every stage on real exit codes; never pipe make to tail.
# LAW: build in the sid container (gcc 15.x / binutils >=2.44) — gcc-14
#      black-screens pre-userspace on this target (proven 2026-07-05).
# LAW: staging inputs are GROUND TRUTH from the post-update rig (config.gz,
#      carved initramfs, firmware blobs) — never repo-derived approximations.
set -u
cd /kernel

log() { echo "[build_72] $*"; }
die() { echo "[build_72] FATAL: $*"; exit 1; }

KVER="${KVER:-7.2}"
SRC=/kernel/linux-$KVER
OUT="${OUT:-/kernel/out72}"

# gcc-15 is the VALIDATED compiler (15.3.0 built every shipping artifact). Do not
# default to gcc-14: it produces a kernel that compiles clean, verifies clean, and
# black-screens the rig pre-userspace (BUILDING.md "Toolchain law"). Do not default
# to the container's bare `gcc` either — sid's default moved to 16.1.0 on 2026-08-05
# and is unvalidated here. Override deliberately or not at all.
KCC_EXPLICIT="${KCC:+yes}"
KCC="${KCC:-gcc-15}"
if [ -z "$KCC_EXPLICIT" ]; then
  KCC_VER="$($KCC -dumpfullversion 2>/dev/null || echo none)"
  case "$KCC_VER" in
    15.*) ;;
    *) die "default compiler $KCC is $KCC_VER, not the validated 15.x. Install gcc-15 in the container, or set KCC=... deliberately." ;;
  esac
fi

# --- 0. Staging inputs exist? Fail LOUDLY with the step that produces each.
#        (The 20260901 groundtruth refresh happens AFTER the rig is migrated —
#        UPSTREAM_20260901.md "K1 execution order".)
[ -f /kernel/linux-$KVER.tar.xz ] || [ -d "$SRC" ] \
  || die "linux-$KVER.tar.xz missing — fetch the mainline tarball (NEVER git: LOCALVERSION_AUTO would break the module-ABI law)"
[ -d /kernel/staging/dts-device-20260901 ] \
  || die "staging/dts-device-20260901/ missing — rsync devices/SM8250 DTS from the ROCKNIX 20260901 tag (K1 step 3)"
[ -d /kernel/staging/patches-72/01-mainline ] \
  || die "staging/patches-72/ missing — export mainline/7.2/device stacks from the 20260901 tag + patches-7.2/ as 04-etk (K1 step 3)"
[ -f /kernel/staging/config-7.2-rig.txt ] \
  || die "staging/config-7.2-rig.txt missing — pull /proc/config.gz from the MIGRATED rig (K1 step 2; repo conf is a recipe input, the rig is ground truth)"
[ -f /kernel/staging/initramfs-stock-20260901.cpio ] \
  || die "staging/initramfs-stock-20260901.cpio missing — carve from the new stock KERNEL (scripts/extract_initramfs.py; K1 step 2)"
[ -d /kernel/staging/external-firmware-20260901 ] \
  || die "staging/external-firmware-20260901/ missing — pull the 8 blobs (6 Qualcomm + regulatory.db + regulatory.db.p7s) from the migrated rig's /usr/lib/firmware (K1 step 2)"
FWCOUNT=$(ls /kernel/staging/external-firmware-20260901 | wc -l)
[ "$FWCOUNT" -ge 8 ] || die "external-firmware-20260901 has $FWCOUNT files, expected >=8 (regulatory.db + .p7s are NEW in 20260901 — CONFIG_EXTRA_FIRMWARE includes them when CONFIG_CFG80211=y)"

# --- 1. Extract pristine tarball ---
if [ ! -d "$SRC" ]; then
  log "extracting linux-$KVER.tar.xz ..."
  tar xf linux-$KVER.tar.xz || die "tarball extract failed"
fi
grep -q "^VERSION = 7$" "$SRC/Makefile" || die "unexpected kernel VERSION"
grep -q "^PATCHLEVEL = 2$" "$SRC/Makefile" || die "unexpected kernel PATCHLEVEL"
log "SUBLEVEL: $(grep '^SUBLEVEL' "$SRC/Makefile")"

# --- 2. Device DTS overlay (mirrors package.mk DTS_SOURCE_DIR rsync;
#        20260901 dts carries the 9998-gpu-tuning chassis: 305-925 MHz OPP
#        ladder + ACD + GPU->DDR bandwidth voting — rides the DTB, not Image) ---
cp -r /kernel/staging/dts-device-20260901/* "$SRC/arch/arm64/boot/dts/" || die "dts copy failed"

# --- 3. Patch stack in scripts/unpack order: mainline -> 7.2 -> device
#        SM8250 -> 04-etk (SIX patches; see patches-7.2/ and PATCHES.md) ---
if [ ! -f "$SRC/.etk-patches-applied" ]; then
  for d in 01-mainline 02-72 03-device 04-etk; do
    [ -d /kernel/staging/patches-72/$d ] || continue
    for p in /kernel/staging/patches-72/$d/*.patch; do
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

# --- 4. Config = live-rig 20260901 /proc/config.gz ground truth, with only
#        the two build-local path substitutions. NOTE vs the 712 lane: the
#        ARM64_LSUI parity-disable is GONE — stock 20260901 ships
#        CONFIG_ARM64_LSUI=y (upstream CI binutils passes the AS probe now,
#        ours does too), so the rig ground truth already carries =y and
#        parity means leaving it alone. Inert on this silicon (no FEAT_LSUI).
mkdir -p "$OUT"
cp /kernel/staging/config-7.2-rig.txt "$OUT/.config"
"$SRC/scripts/config" --file "$OUT/.config" \
  --set-str CONFIG_INITRAMFS_SOURCE "/kernel/staging/initramfs-stock-20260901.cpio" \
  --set-str CONFIG_EXTRA_FIRMWARE_DIR "/kernel/staging/external-firmware-20260901"

MAKE="make -C $SRC O=$OUT ARCH=arm64 CC=$KCC HOSTCC=$KCC KBUILD_BUILD_HOST=rocknix-gtk -j6"

# --- 5. olddefconfig + drift check against ground truth ---
$MAKE olddefconfig > /tmp/olddefconfig.log 2>&1 || { cat /tmp/olddefconfig.log; die "olddefconfig failed"; }
diff /kernel/staging/config-7.2-rig.txt "$OUT/.config" > /kernel/config72.drift
log "config drift vs rig ground truth (expect only INITRAMFS/FIRMWARE paths + toolchain-probe lines):"
cat /kernel/config72.drift

# --- 6. The build (Image + modules) ---
log "building Image + modules with $($KCC --version | head -1) ..."
if $MAKE Image modules > /kernel/build72.log 2>&1; then
  log "BUILD OK"
else
  echo "=== last 60 lines of build72.log ==="
  tail -60 /kernel/build72.log
  die "kernel build FAILED (full log: /kernel/build72.log)"
fi

# --- 7. Verification summary ---
echo "=== VERIFY ==="
echo "kernel.release: $(cat "$OUT/include/config/kernel.release")"
ls -la "$OUT/arch/arm64/boot/Image"
echo "modules built: $(find "$OUT" -name '*.ko' | wc -l)"
strings "$OUT/arch/arm64/boot/Image" | grep -m1 "Linux version"
