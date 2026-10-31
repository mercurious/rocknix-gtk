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
#   patches-72/01-mainline      <- packages/linux/patches/mainline  (4 / 4 / 3 by chassis)
#   patches-72/02-72            <- packages/linux/patches/7.2       (3 / 6 / 12)
#   patches-72/03-device        <- devices/SM8250/patches/linux     (28 / 36 / 43)
#   patches-72/04-etk           <- THIS repo's patches-7.2/  (the ETK stack, minus ABSORBED)
#   dts-device-<date>/qcom      <- devices/SM8250/linux/dts/qcom
#   linux-7.2.tar.xz            <- kernel.org (sha-pinned)
# Rig-GROUND-TRUTH inputs (pre-place in $GT before running — pulled from the
# MIGRATED rig, they are truth, never repo-derived):
#   config-7.2-rig.txt          (/proc/config.gz on the 7.2 rig)
#   initramfs-stock-<date>.cpio (carved from the new stock KERNEL)
#   external-firmware-<date>/   (the 8 CONFIG_EXTRA_FIRMWARE blobs)
#   KERNEL.stock-<date>         (20261001+: the image's /flash/KERNEL — boot.img parity
#                                reference on the qcom-abl lane, PE reference on BLS)
#   stock-dtbs-<date>/          (BLS, 20261101+: the image's /flash/dtbs/*.dtb, 9 trees —
#                                the DTB parity reference; also accepted at
#                                bootloader-<date>/dtbs/ as UPSTREAM_20261101.md §1a banks it)
#
# BLS lane (BASEDATE >= 20261101, UPSTREAM_20261101.md §1a/§1c): the ground truth can be
# built OFFLINE from the release .tar, before any car takes the update. KERNEL.stock-<date>
# is the raw PE Image (MZ at 0, ARMd at 0x38 — the ANDROID! gate BRANCHES, it does not die);
# the config is carved from the Image's own IKCONFIG (scripts/ikconfig.py == extract-ikconfig)
# and the initramfs by the unchanged scripts/extract_initramfs.py. When config-7.2-rig-<date>.txt
# or initramfs-stock-<date>.cpio is absent this script DERIVES it from the KERNEL; when present,
# the derivation must REPRODUCE it byte-for-byte (a mismatch = the two came from different
# builds, stop). Firmware: external-firmware-<date>/ pre-placed, or carved from SYSTEM-<date>
# (the tar's SYSTEM squashfs, unsquashfs -n) along CONFIG_EXTRA_FIRMWARE's own list; the SYSTEM
# image also yields the stock modules dir name (stock-modules-dir-<date>.txt, asserted ==
# kernel.release by bls_gate.sh). A car's later /proc/config.gz must diff EMPTY against the
# carve — that empty diff is the proof the offline truth is the rig's truth.
#
# GT_CHECK=1: validate + derive the ground truth into $WORK/staging and STOP (no network, no
# docker) — the harness mode (scripts/test_bls_gate.sh) and a dry run for a new set.
set -u

ROCKNIX_REF="${ROCKNIX_REF:-13e18947}"           # next @ nightly-20260827; bump for the official tag
BASEDATE="${BASEDATE:-20260901}"                 # staging identity (nightly == 20260901 RC)
# One rule shared with build_72.sh: 20260901 keeps its historic un-suffixed staging;
# a newer chassis stages side by side (-<BASEDATE>) so the certified lane stays mintable.
if [ "$BASEDATE" = 20260901 ]; then SFX=""; else SFX="-$BASEDATE"; fi
PD="patches-72$SFX"; CFG="config-7.2-rig$SFX.txt"
# BLS era (20261101+): raw PE KERNEL + /flash/dtbs + Boot Loader Spec entries (OpenABL).
# BLS=1 overrides the date rule for a NIGHTLY rehearsal of the BLS lane (the banked
# nightly-20261030 set is BLS-format but dated before the tag).
BLS="${BLS:-$([ "$BASEDATE" -ge 20261101 ] && echo 1 || echo 0)}"
# qcom-abl era (20261001 only): the recipe packs a boot.img against the STOCK KERNEL.
BOOTIMG="$([ "$BASEDATE" -ge 20261001 ] && [ "$BLS" = 0 ] && echo 1 || echo 0)"
GT_CHECK="${GT_CHECK:-0}"
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

if [ "$GT_CHECK" != 1 ]; then
  command -v docker >/dev/null || die "docker not found (run on the build node)"
  docker inspect "$CONTAINER" >/dev/null 2>&1 || die "container $CONTAINER not present"
  # RUNNING, not just present: on a stopped container the old-staging wipe below
  # failed silently and `docker cp` of each dir onto its surviving predecessor
  # NESTED the new set (patches-72/patches-72/...) under the stale one, while the
  # script still printed STAGING ASSEMBLED (2026-09-26, node restarted).
  [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ] \
    || die "container $CONTAINER is present but NOT RUNNING — docker start $CONTAINER, then re-run"
fi
[ -d "$REPO/patches-7.2" ] || die "$REPO/patches-7.2 missing — pull the K1 commits (git -C $REPO fetch && reset --hard origin/main)"
[ -f "$REPO/scripts/extract_initramfs.py" ] && [ -f "$REPO/scripts/ikconfig.py" ] \
  || die "$REPO/scripts/{extract_initramfs,ikconfig}.py missing — pull the repo"

# --- stock KERNEL reference: format gate BRANCHES on the lane ---
#     qcom-abl (20261001): an Android boot.img, ANDROID! at 0
#     BLS (20261101+):     the raw arm64 PE Image, MZ at 0 + ARMd at 0x38 (NOT ANDROID!:
#                          a boot.img staged here is the previous format — refuse it)
STOCK="$GT/KERNEL.stock-$BASEDATE"
if [ "$BOOTIMG" = 1 ]; then
  [ -f "$STOCK" ] \
    || die "$STOCK missing — copy the migrated rig's /flash/KERNEL (the boot.img parity reference)"
  head -c8 "$STOCK" | grep -q 'ANDROID!' \
    || die "KERNEL.stock-$BASEDATE is not an Android boot.img — wrong file"
elif [ "$BLS" = 1 ]; then
  [ -f "$STOCK" ] \
    || die "$STOCK missing — the release .tar's target/KERNEL (== the image's /flash/KERNEL): the PE reference for bls_gate.sh (release token, vermagic) and the source of the config + initramfs carve"
  if head -c8 "$STOCK" | grep -q 'ANDROID!'; then
    die "KERNEL.stock-$BASEDATE is an Android boot.img — that is the 20261001 format; BASEDATE=$BASEDATE is the BLS lane (raw PE KERNEL). Wrong file."
  fi
  { [ "$(head -c2 "$STOCK")" = MZ ] && [ "$(dd if="$STOCK" bs=1 skip=56 count=4 2>/dev/null)" = ARMd ]; } \
    || die "KERNEL.stock-$BASEDATE is not a raw arm64 PE Image (MZ at 0, ARMd at 0x38) — wrong file"
  log "KERNEL.stock-$BASEDATE: raw PE Image, $(stat -c %s "$STOCK") B, sha256 $(sha256sum "$STOCK" | cut -c1-16)…"
  log "  $(strings -n 12 "$STOCK" | grep -m1 '^Linux version ' | cut -c1-120)"
fi

# --- ground truth: present, or (BLS) DERIVED from the stock KERNEL / SYSTEM and cross-checked ---
DER="$WORK/derived"; rm -rf "$DER"; mkdir -p "$DER"
# derive_or_check <label> <gt-file> <derive-cmd...>: derive into $DER; if the GT file exists it
# must be byte-identical (two builds mixed = stop); if absent, the derivation becomes the GT.
derive_or_check() {
  local label="$1" gtf="$2" out="$DER/$(basename "$2")"; shift 2
  "$@" "$out" >/dev/null 2>"$DER/$label.err" || { cat "$DER/$label.err" >&2; die "$label: derivation from KERNEL.stock-$BASEDATE failed"; }
  if [ -f "$gtf" ]; then
    cmp -s "$gtf" "$out" || die "$label: $gtf is NOT what KERNEL.stock-$BASEDATE carries ($(sha256sum "$gtf" | cut -c1-16) vs derived $(sha256sum "$out" | cut -c1-16)) — the pre-placed file and the KERNEL come from different builds"
    log "  $label: pre-placed == derived from the KERNEL (sha $(sha256sum "$out" | cut -c1-16)…) REPRODUCED"
  else
    cp "$out" "$gtf" || die "$label: could not write $gtf"
    log "  $label: DERIVED from the KERNEL -> $gtf (sha $(sha256sum "$out" | cut -c1-16)…)"
  fi
}
if [ "$BLS" = 1 ]; then
  derive_or_check config    "$GT/$CFG"                          python3 -I "$REPO/scripts/ikconfig.py" "$STOCK"
  derive_or_check initramfs "$GT/initramfs-stock-$BASEDATE.cpio" python3 -I "$REPO/scripts/extract_initramfs.py" "$STOCK"
  # firmware: pre-placed, or carved from the SYSTEM squashfs along CONFIG_EXTRA_FIRMWARE's list
  FWLIST=$(sed -n 's/^CONFIG_EXTRA_FIRMWARE="\(.*\)"$/\1/p' "$GT/$CFG")
  [ -n "$FWLIST" ] || die "config has no CONFIG_EXTRA_FIRMWARE list — not the SM8250 config"
  SYSIMG="$GT/SYSTEM-$BASEDATE"
  if [ ! -d "$GT/external-firmware-$BASEDATE" ] && [ -f "$SYSIMG" ]; then
    command -v unsquashfs >/dev/null || die "unsquashfs missing (squashfs-tools) — needed to carve the firmware from $SYSIMG"
    FWROOT="usr/lib/kernel-overlays/base/lib/firmware"
    # shellcheck disable=SC2086
    unsquashfs -n -q -d "$DER/sys" "$SYSIMG" $(for f in $FWLIST; do printf '%s ' "$FWROOT/$f"; done) >/dev/null \
      || die "unsquashfs of the firmware set from $SYSIMG failed"
    mkdir -p "$GT/external-firmware-$BASEDATE"
    for f in $FWLIST; do
      mkdir -p "$GT/external-firmware-$BASEDATE/$(dirname "$f")"
      cp "$DER/sys/$FWROOT/$f" "$GT/external-firmware-$BASEDATE/$f" || die "firmware $f missing in $SYSIMG"
    done
    log "  firmware: $(echo $FWLIST | wc -w) blobs carved from SYSTEM-$BASEDATE along CONFIG_EXTRA_FIRMWARE"
  fi
  if [ -f "$SYSIMG" ] && [ ! -f "$GT/stock-modules-dir-$BASEDATE.txt" ]; then
    command -v unsquashfs >/dev/null || die "unsquashfs missing (squashfs-tools)"
    MD=$(unsquashfs -n -q -d "$DER/mods" "$SYSIMG" usr/lib/kernel-overlays/base/lib/modules >/dev/null \
         && ls "$DER/mods/usr/lib/kernel-overlays/base/lib/modules" | head -1)
    [ -n "$MD" ] || die "no modules dir under SYSTEM:/usr/lib/kernel-overlays/base/lib/modules"
    printf '%s\n' "$MD" > "$GT/stock-modules-dir-$BASEDATE.txt"
    log "  stock modules dir (SYSTEM): $MD"
  fi
  # every CONFIG_EXTRA_FIRMWARE name must be present, at its relative path
  for f in $FWLIST; do
    [ -f "$GT/external-firmware-$BASEDATE/$f" ] || die "external-firmware-$BASEDATE/$f missing (CONFIG_EXTRA_FIRMWARE names it) — pre-place the blob, or place SYSTEM-$BASEDATE (the tar's SYSTEM squashfs) for the carve"
  done
  # the image's DTBs: stock-dtbs-<date>/ or bootloader-<date>/dtbs/ (UPSTREAM_20261101.md §1a layout)
  STOCK_DTBS=""
  for d in "$GT/stock-dtbs-$BASEDATE" "$GT/bootloader-$BASEDATE/dtbs"; do
    [ -n "$(ls "$d"/*.dtb 2>/dev/null)" ] && { STOCK_DTBS="$d"; break; }
  done
  [ -n "$STOCK_DTBS" ] || die "no stock DTBs: place the image's /flash/dtbs/*.dtb (the tar's 3rdparty/bootloader/dtbs) as $GT/stock-dtbs-$BASEDATE/ — the DTB parity reference"
  NDTB=$(ls "$STOCK_DTBS"/*.dtb | wc -l)
  for k in sm8250-retroidpocket-flip2.dtb sm8250-retroidpocket-flip2-visionox.dtb; do
    [ -f "$STOCK_DTBS/$k" ] || die "$STOCK_DTBS/$k missing — both Flip 2 trees are required (kit models)"
  done
  log "  stock DTBs: $NDTB in $STOCK_DTBS (both Flip 2 trees present)"
fi
[ -f "$GT/$CFG" ] \
  || die "$GT/$CFG missing — scp the MIGRATED rig's /proc/config.gz (gunzip'd)"
[ -f "$GT/initramfs-stock-$BASEDATE.cpio" ] \
  || die "$GT/initramfs-stock-$BASEDATE.cpio missing — carve from the new stock KERNEL (scripts/extract_initramfs.py)"
[ -d "$GT/external-firmware-$BASEDATE" ] \
  || die "$GT/external-firmware-$BASEDATE/ missing — pull the 8 CONFIG_EXTRA_FIRMWARE blobs from the rig /usr/lib/firmware"
FWN=$(find "$GT/external-firmware-$BASEDATE" -type f | wc -l)
[ "$FWN" -ge 8 ] || die "external-firmware-$BASEDATE has $FWN files, need >=8 (regulatory.db + .p7s are new in 20260901)"
head -c6 "$GT/initramfs-stock-$BASEDATE.cpio" | grep -q 070701 \
  || die "initramfs-stock-$BASEDATE.cpio is not a newc cpio (070701) — re-carve"
if [ "$GT_CHECK" = 1 ]; then
  log "GT_CHECK: ground truth for BASEDATE=$BASEDATE complete and self-consistent (BLS=$BLS BOOTIMG=$BOOTIMG):"
  ( cd "$GT" && sha256sum "$CFG" "initramfs-stock-$BASEDATE.cpio" $( [ -f "KERNEL.stock-$BASEDATE" ] && echo "KERNEL.stock-$BASEDATE" ) $( [ -n "${STOCK_DTBS:-}" ] && ls "${STOCK_DTBS#"$GT"/}"/*.dtb ) $(find "external-firmware-$BASEDATE" -type f | LC_ALL=C sort) ) | sed 's/^/[stage_72]   /' >&2
  log "GT_CHECK done — no fetch, no docker (drop GT_CHECK=1 on the build node to stage)"
  exit 0
fi

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
rm -rf "$WORK"; mkdir -p "$WORK/staging/$PD" "$WORK/staging/dts-device-$BASEDATE/qcom"
S="$WORK/staging"

# --- 1. ROCKNIX patch stacks ---
NM=$(fetch_patches "projects/ROCKNIX/packages/linux/patches/mainline" "$S/$PD/01-mainline")
N7=$(fetch_patches "projects/ROCKNIX/packages/linux/patches/7.2"      "$S/$PD/02-72")
ND=$(fetch_patches "projects/ROCKNIX/devices/SM8250/patches/linux"    "$S/$PD/03-device")
# expected stack sizes per chassis (UPSTREAM_<date>.md); a mismatch is drift to re-verify, not a stop
case "$BASEDATE" in
  20260901) XM=4; X7=3;  XD=28 ;;
  20261001) XM=4; X7=6;  XD=36 ;;
  *)        XM=3; X7=12; XD=43 ;;   # 20261101 (read on nightly-20261030, UPSTREAM_20261101.md §1b)
esac
[ "$NM" = "$XM" ] || log "WARN: mainline patch count $NM != expected $XM (upstream drift — re-verify)"
[ "$N7" = "$X7" ] || log "WARN: 7.2 patch count $N7 != expected $X7 (upstream drift — re-verify)"
[ "$ND" = "$XD" ] || log "WARN: SM8250 device patch count $ND != expected $XD (upstream drift — re-verify)"
log "  stacks: mainline=$NM 7.2=$N7 device=$ND -> $(ls "$S/$PD"/0[1-3]-*/*.patch | xargs -n1 basename | tr '\n' ' ' | cut -c1-400)…"

# --- 2. ETK stack (this repo) -> 04-etk ---
mkdir -p "$S/$PD/04-etk"
cp "$REPO"/patches-7.2/*.patch "$S/$PD/04-etk/" || die "copy patches-7.2 failed"
# patches-7.2/ABSORBED: "<first-basedate> <patch> <evidence>" — upstream carries it from
# that chassis on, so carrying ours too fails as "previously applied" (20261001: #9).
NABS=0
if [ -f "$REPO/patches-7.2/ABSORBED" ]; then
    while read -r since pf evidence; do
        case "$since" in ''|\#*) continue ;; esac
        if [ "$BASEDATE" -ge "$since" ] && [ -f "$S/$PD/04-etk/$pf" ]; then
            rm -f "$S/$PD/04-etk/$pf"; NABS=$((NABS+1))
            log "  04-etk: skipping $pf (absorbed upstream since $since: $evidence)"
        fi
    done < "$REPO/patches-7.2/ABSORBED"
fi
NE=$(find "$S/$PD/04-etk" -name '*.patch' | wc -l)
[ "$NE" = "$((9 - NABS))" ] || log "WARN: ETK patch count $NE != expected $((9 - NABS)) (9 carried on 7.2, minus $NABS absorbed upstream)"
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
cp "$GT/$CFG"                               "$S/$CFG"
{ [ "$BOOTIMG" = 1 ] || [ "$BLS" = 1 ]; } && cp "$GT/KERNEL.stock-$BASEDATE" "$S/KERNEL.stock-$BASEDATE"
if [ "$BLS" = 1 ]; then
  mkdir -p "$S/stock-dtbs-$BASEDATE" && cp "$STOCK_DTBS"/*.dtb "$S/stock-dtbs-$BASEDATE/"
  [ -f "$GT/stock-modules-dir-$BASEDATE.txt" ] && cp "$GT/stock-modules-dir-$BASEDATE.txt" "$S/stock-modules-dir-$BASEDATE.txt"
fi
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
dcp() { docker cp "$1" "$2" || die "docker cp $1 -> $2 failed"; }
# mkdir -p: on a FRESH volume /kernel/staging does not exist, and docker cp to
# a path under a missing parent fails ("Could not find the file /kernel/staging")
docker exec "$CONTAINER" mkdir -p /kernel/staging || die "could not create /kernel/staging in $CONTAINER"
docker exec "$CONTAINER" sh -c 'rm -rf /kernel/staging/'"$PD"' /kernel/staging/dts-device-'"$BASEDATE"' /kernel/staging/external-firmware-'"$BASEDATE"' /kernel/staging/stock-dtbs-'"$BASEDATE"'' \
  || die "could not clear the old staging in $CONTAINER (a surviving dir makes docker cp nest the new one inside it)"
dcp "$S/$PD"                           "$CONTAINER:/kernel/staging/$PD"
dcp "$S/dts-device-$BASEDATE"          "$CONTAINER:/kernel/staging/dts-device-$BASEDATE"
dcp "$S/$CFG"                          "$CONTAINER:/kernel/staging/$CFG"
{ [ "$BOOTIMG" = 1 ] || [ "$BLS" = 1 ]; } && dcp "$S/KERNEL.stock-$BASEDATE" "$CONTAINER:/kernel/staging/KERNEL.stock-$BASEDATE"
if [ "$BLS" = 1 ]; then
  dcp "$S/stock-dtbs-$BASEDATE" "$CONTAINER:/kernel/staging/stock-dtbs-$BASEDATE"
  [ -f "$S/stock-modules-dir-$BASEDATE.txt" ] && dcp "$S/stock-modules-dir-$BASEDATE.txt" "$CONTAINER:/kernel/staging/stock-modules-dir-$BASEDATE.txt"
fi
dcp "$S/initramfs-stock-$BASEDATE.cpio" "$CONTAINER:/kernel/staging/initramfs-stock-$BASEDATE.cpio"
dcp "$S/external-firmware-$BASEDATE"    "$CONTAINER:/kernel/staging/external-firmware-$BASEDATE"
dcp "$KTAR"                            "$CONTAINER:/kernel/linux-7.2.tar.xz"

# --- 7. in-container completeness gate (what build_72.sh will read) ---
log "=== staging verification (in-container) ==="
docker exec "$CONTAINER" sh -c '
  set -e
  cd /kernel
  for d in staging/'"$PD"'/'"$PD"' staging/dts-device-'"$BASEDATE"'/dts-device-'"$BASEDATE"' staging/external-firmware-'"$BASEDATE"'/external-firmware-'"$BASEDATE"'; do
    [ ! -e "$d" ] || { echo "NESTED staging dir: $d"; exit 1; }
  done
  echo "patches: mainline=$(ls staging/'"$PD"'/01-mainline/*.patch 2>/dev/null | wc -l) 7.2=$(ls staging/'"$PD"'/02-72/*.patch 2>/dev/null | wc -l) device=$(ls staging/'"$PD"'/03-device/*.patch 2>/dev/null | wc -l) etk=$(ls staging/'"$PD"'/04-etk/*.patch 2>/dev/null | wc -l)"
  echo "dts: $(find staging/dts-device-'"$BASEDATE"'/qcom -type f 2>/dev/null | wc -l) files"
  echo "config: $([ -f staging/'"$CFG"' ] && echo present || echo MISSING) ($(grep -c . staging/'"$CFG"' 2>/dev/null) lines)"
  echo "initramfs: $([ -f staging/initramfs-stock-'"$BASEDATE"'.cpio ] && echo present || echo MISSING) ($(stat -c %s staging/initramfs-stock-'"$BASEDATE"'.cpio 2>/dev/null) B)"
  echo "firmware: $(find staging/external-firmware-'"$BASEDATE"' -type f 2>/dev/null | wc -l) files"
  echo "tarball: $([ -f linux-7.2.tar.xz ] && echo present || echo MISSING)"
  [ '"$BOOTIMG"' = 1 ] && echo "stock KERNEL (boot.img reference): $([ -f staging/KERNEL.stock-'"$BASEDATE"' ] && echo present || echo MISSING)"
  [ '"$BLS"' = 1 ] && echo "stock KERNEL (PE reference): $([ -f staging/KERNEL.stock-'"$BASEDATE"' ] && echo present || echo MISSING); stock dtbs: $(ls staging/stock-dtbs-'"$BASEDATE"'/*.dtb 2>/dev/null | wc -l); modules dir: $(cat staging/stock-modules-dir-'"$BASEDATE"'.txt 2>/dev/null || echo unknown-offline)"
  [ '"$BLS"' = 1 ] && [ -e staging/stock-dtbs-'"$BASEDATE"'/stock-dtbs-'"$BASEDATE"' ] && { echo "NESTED staging dir: stock-dtbs"; exit 1; }
  echo "LSUI parity note: build_72.sh drops the ARM64_LSUI disable (stock 7.2 ships =y); config has: $(grep "^CONFIG_ARM64_LSUI" staging/'"$CFG"' || echo "not set")"
' || die "in-container staging verification FAILED — nothing above is trustworthy"
log "STAGING ASSEMBLED. Next: the OPERATOR mints (bytes-to-atoms):"
log "  FORGE_KERNEL_BUILD=72 FORGE_KERNEL_BASEDATE=$BASEDATE FORGE_KERNEL_DATE=<date> FORGE_KERNEL_VER=<ver> ./forge.sh kernel"
