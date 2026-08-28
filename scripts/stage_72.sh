#!/bin/bash
# ==========================================================
# stage_72.sh — assemble the 7.2 / ROCKNIX 20260901 kernel-lane staging
# ==========================================================
# Runs ON THE BUILD NODE (etk-cloud: git + internet + docker). Populates the
# kernel build volume's /kernel/staging with everything build_72.sh consumes,
# from a PINNED ROCKNIX ref + this repo's patches-7.2/ + rig ground truth.
# This is a TOOL, not a one-off: it re-runs verbatim for the official 20260901
# tag (just bump ROCKNIX_REF) — the drop becomes a diff, not a re-derivation.
#
# It does NOT build. Assembling inputs is prep (bytes-to-atoms: staging is
# allowed); the mint itself (forge.sh kernel / build_72.sh) stays the operator's.
#
# ROCKNIX-sourced inputs (this script fetches):
#   patches-72/01-mainline (4)  <- packages/linux/patches/mainline
#   patches-72/02-72      (3)   <- packages/linux/patches/7.2
#   patches-72/03-device  (28)  <- devices/SM8250/patches/linux
#   patches-72/04-etk     (6)   <- THIS repo's patches-7.2/  (the ETK stack)
#   dts-device-<date>/qcom      <- devices/SM8250/linux/dts/qcom
#   linux-7.2.tar.xz            <- kernel.org (sha-pinned)
# Rig-GROUND-TRUTH inputs (pre-place in $GT before running — pulled from the
# MIGRATED rig, they are truth, never repo-derived):
#   config-7.2-rig.txt          (/proc/config.gz on the 7.2 rig)
#   initramfs-stock-<date>.cpio (carved from the new stock KERNEL)
#   external-firmware-<date>/   (the 8 CONFIG_EXTRA_FIRMWARE blobs)
set -u

ROCKNIX_REF="${ROCKNIX_REF:-13e18947}"           # next @ nightly-20260827; bump for the official tag
BASEDATE="${BASEDATE:-20260901}"                 # staging identity (nightly == 20260901 RC)
GT="${GT:-$HOME/gt72}"                            # ground-truth inputs, pre-placed
REPO="${REPO:-$HOME/rocknix-gtk}"                 # this fork (for patches-7.2/)
CONTAINER="${CONTAINER:-rocknix-gtk-kernel-sid}"
WORK="${WORK:-$HOME/stage72-work}"
KTAR_SHA="f9fef3d14c0df53819026f4be74459835c2a0b0dcbf5b5bbd9ea19f0829402b3"
RAW="https://raw.githubusercontent.com/ROCKNIX/distribution/$ROCKNIX_REF"
API="https://api.github.com/repos/ROCKNIX/distribution/contents"

# log to stderr so command substitution capturing a function's numeric return
# (fetch_patches) never swallows a progress line (the count-capture bug that
# printed false "count != expected" WARNs on the first run — 2026-08-28).
log() { printf '[stage_72] %s\n' "$*" >&2; }
die() { printf '[stage_72] FATAL: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker not found (run on the build node)"
docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container $CONTAINER not present"
[ -d "$REPO/patches-7.2" ] || die "$REPO/patches-7.2 missing — pull the K1 commits (git -C $REPO fetch && reset --hard origin/main)"

# --- ground truth present? (fail LOUD with the step that produces each) ---
[ -f "$GT/config-7.2-rig.txt" ] \
  || die "$GT/config-7.2-rig.txt missing — scp the MIGRATED rig's /proc/config.gz (gunzip'd)"
[ -f "$GT/initramfs-stock-$BASEDATE.cpio" ] \
  || die "$GT/initramfs-stock-$BASEDATE.cpio missing — carve from the new stock KERNEL (scripts/extract_initramfs.py)"
[ -d "$GT/external-firmware-$BASEDATE" ] \
  || die "$GT/external-firmware-$BASEDATE/ missing — pull the 8 CONFIG_EXTRA_FIRMWARE blobs from the rig /usr/lib/firmware"
FWN=$(find "$GT/external-firmware-$BASEDATE" -type f | wc -l)
[ "$FWN" -ge 8 ] || die "external-firmware-$BASEDATE has $FWN files, need >=8 (regulatory.db + .p7s are new in 20260901)"
head -c6 "$GT/initramfs-stock-$BASEDATE.cpio" | grep -q 070701 \
  || die "initramfs-stock-$BASEDATE.cpio is not a newc cpio (070701) — re-carve"

# --- fetch helper: list a ROCKNIX dir, curl each .patch into a numbered dir ---
fetch_patches() { # $1=api-subpath  $2=dest-dir
    local sub="$1" dest="$2" names
    mkdir -p "$dest"
    names=$(curl -fsSL "$API/$sub?ref=$ROCKNIX_REF" \
        | grep '"name"' | sed 's/.*"name": *"//;s/".*//' | grep '\.patch$') \
        || die "listing $sub failed (GitHub API)"
    [ -n "$names" ] || die "no .patch files under $sub @ $ROCKNIX_REF"
    local n=0
    for f in $names; do
        curl -fsSL "$RAW/$sub/$f" -o "$dest/$f" || die "fetch $sub/$f failed"
        n=$((n+1))
    done
    log "  $dest: $n patches"
    printf '%s' "$n"
}

log "ROCKNIX_REF=$ROCKNIX_REF  BASEDATE=$BASEDATE"
rm -rf "$WORK"; mkdir -p "$WORK/staging/patches-72" "$WORK/staging/dts-device-$BASEDATE/qcom"
S="$WORK/staging"

# --- 1. ROCKNIX patch stacks ---
NM=$(fetch_patches "projects/ROCKNIX/packages/linux/patches/mainline" "$S/patches-72/01-mainline")
N7=$(fetch_patches "projects/ROCKNIX/packages/linux/patches/7.2"      "$S/patches-72/02-72")
ND=$(fetch_patches "projects/ROCKNIX/devices/SM8250/patches/linux"    "$S/patches-72/03-device")
[ "$NM" = "4" ]  || log "WARN: mainline patch count $NM != expected 4 (upstream drift — re-verify)"
[ "$N7" = "3" ]  || log "WARN: 7.2 patch count $N7 != expected 3 (upstream drift — re-verify)"
[ "$ND" = "28" ] || log "WARN: SM8250 device patch count $ND != expected 28 (upstream drift — re-verify)"

# --- 2. ETK stack (this repo) -> 04-etk ---
mkdir -p "$S/patches-72/04-etk"
cp "$REPO"/patches-7.2/*.patch "$S/patches-72/04-etk/" || die "copy patches-7.2 failed"
NE=$(find "$S/patches-72/04-etk" -name '*.patch' | wc -l)
[ "$NE" = "6" ] || log "WARN: ETK patch count $NE != expected 6 (#6 dropped on 7.2)"
log "  04-etk: $NE ETK patches"

# --- 3. device DTS overlay ---
DNAMES=$(curl -fsSL "$API/projects/ROCKNIX/devices/SM8250/linux/dts/qcom?ref=$ROCKNIX_REF" \
    | grep '"name"' | sed 's/.*"name": *"//;s/".*//' | grep -E '\.(dts|dtsi)$') \
    || die "listing dts/qcom failed"
for f in $DNAMES; do
    curl -fsSL "$RAW/projects/ROCKNIX/devices/SM8250/linux/dts/qcom/$f" \
        -o "$S/dts-device-$BASEDATE/qcom/$f" || die "fetch dts $f failed"
done
log "  dts-device-$BASEDATE/qcom: $(find "$S/dts-device-$BASEDATE/qcom" -type f | wc -l) files"

# --- 4. ground truth into staging ---
cp "$GT/config-7.2-rig.txt"                 "$S/config-7.2-rig.txt"
cp "$GT/initramfs-stock-$BASEDATE.cpio"     "$S/initramfs-stock-$BASEDATE.cpio"
cp -r "$GT/external-firmware-$BASEDATE"      "$S/external-firmware-$BASEDATE"
log "  ground truth: config + initramfs + $(find "$S/external-firmware-$BASEDATE" -type f | wc -l) firmware blobs"

# --- 5. kernel tarball (sha-pinned) ---
KTAR="$WORK/linux-7.2.tar.xz"
if [ ! -f "$KTAR" ]; then
    log "downloading linux-7.2.tar.xz ..."
    curl -fsSL "https://www.kernel.org/pub/linux/kernel/v7.x/linux-7.2.tar.xz" -o "$KTAR" \
        || die "kernel.org tarball download failed"
fi
GOT=$(sha256sum "$KTAR" | cut -d' ' -f1)
[ "$GOT" = "$KTAR_SHA" ] || die "linux-7.2.tar.xz sha MISMATCH: got $GOT want $KTAR_SHA"
log "  linux-7.2.tar.xz sha OK"

# --- 6. push into the container volume (/kernel) ---
log "copying into $CONTAINER:/kernel ..."
docker exec "$CONTAINER" sh -c 'rm -rf /kernel/staging/patches-72 /kernel/staging/dts-device-'"$BASEDATE"' /kernel/staging/external-firmware-'"$BASEDATE"'' 2>/dev/null
docker cp "$S/patches-72"                    "$CONTAINER:/kernel/staging/patches-72"
docker cp "$S/dts-device-$BASEDATE"          "$CONTAINER:/kernel/staging/dts-device-$BASEDATE"
docker cp "$S/config-7.2-rig.txt"            "$CONTAINER:/kernel/staging/config-7.2-rig.txt"
docker cp "$S/initramfs-stock-$BASEDATE.cpio" "$CONTAINER:/kernel/staging/initramfs-stock-$BASEDATE.cpio"
docker cp "$S/external-firmware-$BASEDATE"    "$CONTAINER:/kernel/staging/external-firmware-$BASEDATE"
docker cp "$KTAR"                            "$CONTAINER:/kernel/linux-7.2.tar.xz"

# --- 7. in-container completeness gate (what build_72.sh will read) ---
log "=== staging verification (in-container) ==="
docker exec "$CONTAINER" sh -c '
  set -e
  cd /kernel
  echo "patches: mainline=$(ls staging/patches-72/01-mainline/*.patch 2>/dev/null | wc -l) 7.2=$(ls staging/patches-72/02-72/*.patch 2>/dev/null | wc -l) device=$(ls staging/patches-72/03-device/*.patch 2>/dev/null | wc -l) etk=$(ls staging/patches-72/04-etk/*.patch 2>/dev/null | wc -l)"
  echo "dts: $(find staging/dts-device-'"$BASEDATE"'/qcom -type f 2>/dev/null | wc -l) files"
  echo "config: $([ -f staging/config-7.2-rig.txt ] && echo present || echo MISSING) ($(grep -c . staging/config-7.2-rig.txt 2>/dev/null) lines)"
  echo "initramfs: $([ -f staging/initramfs-stock-'"$BASEDATE"'.cpio ] && echo present || echo MISSING) ($(stat -c %s staging/initramfs-stock-'"$BASEDATE"'.cpio 2>/dev/null) B)"
  echo "firmware: $(find staging/external-firmware-'"$BASEDATE"' -type f 2>/dev/null | wc -l) files"
  echo "tarball: $([ -f linux-7.2.tar.xz ] && echo present || echo MISSING)"
  echo "LSUI parity note: build_72.sh drops the ARM64_LSUI disable (stock 7.2 ships =y); config has: $(grep "^CONFIG_ARM64_LSUI" staging/config-7.2-rig.txt || echo "not set")"
'
log "STAGING ASSEMBLED. Next: the OPERATOR mints (bytes-to-atoms):"
log "  FORGE_KERNEL_BUILD=72 FORGE_KERNEL_DATE=<date> FORGE_KERNEL_VER=0.5 ./forge.sh kernel"
