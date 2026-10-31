#!/bin/bash
# ROCKNIX-GTK Tier-K kernel pipeline — 7.2 / ROCKNIX 20260901 rebase lane.
# Same contract as build_712.sh (7.1.2 lane, kept intact until the 7.2 kernel
# is cold-boot validated + certified): mainline tarball + ROCKNIX patch stack
# + rig-ground-truth config + ETK patches (patches-7.2/, EIGHT active — #10
# pm8150b-charger-typec-icl added 2026-10-10 (charge from a laptop's USB-C port); #9
# pm8150b-charger-float-voltage added 2026-09-26 (battery safety); #6
# dp-bounded-enable-lock is DROPPED on 7.2: upstream removed event_mutex from
# dp_display.c entirely, the lock this patch bounds no longer exists; #4 is
# switch-side only, upstream removed the buggy mux-side dedup loop).
# THREE ARTIFACT FORMATS, ONE RECIPE (selected by BASEDATE, UPSTREAM_20261101.md §1c):
#   20260901        GRUB era      -> raw Image (install.sh writes the grub twin entries)
#   20261001        qcom-abl era  -> boot.img (BOOTIMG=1: pack_bootimg.sh + bootimg_parity.py,
#                                    cmdline baked, kit DTBs spliced INTO the image at mint)
#   20261101+       BLS era       -> raw PE Image again (BLS=1: OpenABL + Boot Loader Spec
#                                    entries; cmdline = the entry's options line, DTB = a file
#                                    under /flash/dtbs, both rendered at DEPLOY by the kit).
#                                    No pack; scripts/bls_gate.sh is the parity proof.
# LAW: gate every stage on real exit codes; never pipe make to tail.
# LAW: build in the sid container with STOCK's compiler major (scripts/stock_gcc.sh reads it
#      from the ground-truth config: gcc-15 through 20261001, gcc-16 from 20261101) and
#      binutils >=2.44 — gcc-14 black-screens pre-userspace on this target (proven 2026-07-05).
# LAW: staging inputs are GROUND TRUTH from the post-update rig (config.gz,
#      carved initramfs, firmware blobs) — never repo-derived approximations.
set -u
cd /kernel

log() { echo "[build_72] $*"; }
die() { echo "[build_72] FATAL: $*"; exit 1; }

KVER="${KVER:-7.2}"
BASEDATE="${BASEDATE:-20260901}"
# One rule shared with stage_72.sh: the shipping 20260901 lane keeps its historic
# un-suffixed paths (byte-for-byte the recipe it always was); a newer chassis stages,
# extracts and builds side by side under -<BASEDATE>, so the certified kernel can
# always be reminted while the next one bakes.
if [ "$BASEDATE" = 20260901 ]; then SFX=""; else SFX="-$BASEDATE"; fi
SRC=/kernel/linux-$KVER$SFX
OUT="${OUT:-/kernel/out72$SFX}"
STG=/kernel/staging
PDIR="$STG/patches-72$SFX"
CFG_GT="$STG/config-7.2-rig$SFX.txt"
# qcom-abl era (ROCKNIX 20261001+): /flash/KERNEL is an Android boot.img with the DTBs
# inside and the cmdline baked in (the ABL appends nothing), so the deliverable is a
# boot.img and the keepalive moves from install time to mint time. UPSTREAM_20261001.md.
# BLS era (ROCKNIX 20261101+): /flash/KERNEL is the raw PE Image again, loaded by OpenABL
# through the EFI stub; the cmdline and the DTB come from a Boot Loader Spec entry the kit
# renders at deploy. The boot.img machinery has no object on this lane. UPSTREAM_20261101.md.
BLS="${BLS:-$([ "$BASEDATE" -ge 20261101 ] && echo 1 || echo 0)}"
BOOTIMG="${BOOTIMG:-$([ "$BASEDATE" -ge 20261001 ] && [ "$BLS" != 1 ] && echo 1 || echo 0)}"
[ "$BLS" = 1 ] && [ "$BOOTIMG" = 1 ] && die "BLS=1 and BOOTIMG=1 are exclusive (one artifact format per lane)"
# ETK_CMDLINE: the ONE record of what ETK adds to the stock cmdline. boot.img lane: baked into
# the header at mint. BLS lane: NOT baked -- the kit renders it into the entry's options line at
# deploy (gtk_stack.json cmdline_extra); the lane only records and gate-checks it.
ETK_CMDLINE="${ETK_CMDLINE:-msm.context_keepalive=1 panic=30}"
# Kit DTB splice at mint (ABL era: the DTBs ride inside the boot.img). ETK_KIT_DTB=0
# mints a pure-parity image (no splice); ETK_INTERNAL_MIC=0 drops the mic delta only.
# The splicer is etk's bin/etk_dtb_mic.py, staged by lane_kernel.sh (docker cp) --
# never a copy kept in this repo.
ETK_KIT_DTB="${ETK_KIT_DTB:-1}"
ETK_INTERNAL_MIC="${ETK_INTERNAL_MIC:-1}"
# ETK_SD_POLL=1 (2026-10-24, car8's dead SD card-detect switch) adds the splicer's opt-in
# sdpoll delta: the SD host's cd-gpios becomes broken-cd, so the slot is polled and its
# detect pin ignored. Default 0 = every certified mint, unchanged. Never a release kernel.
ETK_SD_POLL="${ETK_SD_POLL:-0}"
# BLS lane: the three kit-DTB knobs above are DEPLOY-TIME knobs now (install.sh / osguard derive
# dtbs/etk/<model>.dtb from the OS's own /flash/dtbs at every deploy and heal, with the same
# flags from etk.conf). A non-default value at mint would be silently meaningless, so it FAILS
# the mint instead (step 1). The splicer is still staged: bls_gate.sh dry-runs it on both Flip 2
# trees as the lane's early warning that it still fits the new DTS.
# BOOT LOGO (ABL era, 2026-10-08): stock 20261001 ships CONFIG_TYPEC_MUX_GPIO_SBU=m and
# the 20261001 DTS routes the USB-C connector's orientation/mode switch through that
# gpio-sbu-mux (e4461cfea5 retired the phantom nb7vpq904m, which was =y). The connector
# defers until udev loads the module from the rootfs AFTER switch_root, DP waits on the
# connector, and the msm master (DSI+DP+GPU) binds at ~3.9 s -- but init's load_splash
# runs at ~2.2 s, so rocknix-splash opens a /dev/fb0 that does not exist yet (GRUB era:
# msm bound at ~1.2 s, logo fine). Upstream fixed it on main six days after the tag --
# ROCKNIX 187eb24f2e "sm8250: fix splash at boot" = this one config line -- so we carry
# that commit as a CONFIG DELTA over the rig ground truth. The rig's ground truth stays
# =m (it IS the rig); the drift log shows exactly this line. ETK_GPIO_SBU_BUILTIN=0 =
# pure-parity mint (the A/B arm that reproduces the missing logo).
# BLS lane: MOOT -- stock 20261101 ships CONFIG_TYPEC_MUX_GPIO_SBU=y (upstream 187eb24f2e is in
# the tag), so parity already carries the fix; the knob is ignored, the drift must not show the
# line, and the VERIFY step asserts the built-in from the BUILT config (groundtruth
# config-diff-20261001-to-20261030.diff).
ETK_GPIO_SBU_BUILTIN="${ETK_GPIO_SBU_BUILTIN:-1}"
# FORENSICS (2026-10-11, ETK GT5 op -- etk-dossiers Hunt_GT5_20261011.md §8): GT5 freezes the
# whole SoC and a firmware watchdog resets it ~6.5 s later (N=4), so Linux never logs a word and
# the SoC has no working dump path (Sahara gave no 900e). ETK_FORENSICS=1 mints a HUNT kernel that
# can witness the freeze, everything log-only or dark until armed:
#   WATCHDOG_SYSFS            read the APSS wdt's state/timeout/bootstatus without opening (=arming)
#                             it: is it running from boot, and did IT bite last time?
#   pretimeout governors      bark plumbing (qcom-wdt has set_pretimeout; bark IRQ wired), noop default
#   DEBUG_KERNEL + soft/hard  lockup detectors, LOG-ONLY (BOOTPARAM_*_PANIC stay off), with
#     lockup detectors        watchdog_thresh=2 -> hard 2 s / soft 4 s, inside the ~6.5 s window
#   msm.gpu_stall_on_fault=0  patch #11: the adreno SMMU terminates faulting GPU transactions
#                             instead of stalling them (the GT5 freeze hypothesis, Hunt_GT5 §16)
#   (NOT pseudo-NMI, NOT the hung-task detector: see the MODULE-ABI GUARD below -- 0.6.4.1 was
#    minted with both and REJECTED before install, 2026-10-11)
#   PSTORE_RAM=y + CONSOLE    ramoops in reserve_mem: the console log lives in RAM; GT5's death is a
#                             WARM reset (PMIC warm_reset=PS_HOLD) and RAM survival across a WARM
#                             reset was never tested (2026-07-02 falsified it on COLD Linux-panic
#                             resets). etk's blackbox_d already harvests /sys/fs/pstore at boot.
# Default 0: every certified mint is unchanged. NOT for release.
ETK_FORENSICS="${ETK_FORENSICS:-0}"
if [ "$ETK_FORENSICS" = 1 ]; then
  ETK_CMDLINE="$ETK_CMDLINE msm.gpu_stall_on_fault=0 watchdog_thresh=2 sysctl.kernel.hardlockup_all_cpu_backtrace=1 sysctl.kernel.softlockup_all_cpu_backtrace=1 reserve_mem=2M:4096:etk_ramoops ramoops.mem_name=etk_ramoops ramoops.record_size=0x40000 ramoops.console_size=0x80000 ramoops.max_reason=2 efi_pstore.pstore_disable=1"
fi
REF_KERNEL="$STG/KERNEL.stock-$BASEDATE"
# BLS lane: stage_72.sh records the stock modules dir name (SYSTEM squashfs) here when it had the
# SYSTEM image; the gate asserts it equals kernel.release. Empty = not known offline, skip.
STOCK_MODULES_DIR="${STOCK_MODULES_DIR:-$(cat "$STG/stock-modules-dir-$BASEDATE.txt" 2>/dev/null || true)}"

# --- 0. Staging inputs exist? Fail LOUDLY with the step that produces each.
#        (The 20260901 groundtruth refresh happens AFTER the rig is migrated —
#        UPSTREAM_20260901.md "K1 execution order".)
[ -f /kernel/linux-$KVER.tar.xz ] || [ -d "$SRC" ] \
  || die "linux-$KVER.tar.xz missing — fetch the mainline tarball (NEVER git: LOCALVERSION_AUTO would break the module-ABI law)"
[ -d $STG/dts-device-$BASEDATE ] \
  || die "staging/dts-device-$BASEDATE/ missing — stage_72.sh with BASEDATE=$BASEDATE (rsyncs devices/SM8250 DTS from the tag)"
[ -d $PDIR/01-mainline ] \
  || die "$PDIR/ missing — stage_72.sh with BASEDATE=$BASEDATE (mainline/7.2/device stacks + patches-7.2/ as 04-etk)"
[ -f $CFG_GT ] \
  || die "staging/config-7.2-rig.txt missing — pull /proc/config.gz from the MIGRATED rig (K1 step 2; repo conf is a recipe input, the rig is ground truth)"
[ -f $STG/initramfs-stock-$BASEDATE.cpio ] \
  || die "staging/initramfs-stock-$BASEDATE.cpio missing — carve from the new stock KERNEL (scripts/extract_initramfs.py; K1 step 2)"
[ -d $STG/external-firmware-$BASEDATE ] \
  || die "staging/external-firmware-$BASEDATE/ missing — pull the 8 blobs (6 Qualcomm + regulatory.db + regulatory.db.p7s) from the migrated rig's /usr/lib/firmware (K1 step 2)"
# Count files RECURSIVELY: the blobs are nested (qcom/sm8250/adsp.mbn, ...) so
# a top-level `ls` sees only 3 entries (qcom/ + the two regulatory.db files)
# and false-fails the gate (2026-08-28, first real 7.2 mint). CONFIG_EXTRA_
# FIRMWARE references the nested relative paths, so the tree must stay nested.
FWCOUNT=$(find $STG/external-firmware-$BASEDATE -type f | wc -l)
[ "$FWCOUNT" -ge 8 ] || die "external-firmware-$BASEDATE has $FWCOUNT files, expected >=8 (regulatory.db + .p7s are NEW in 20260901 — CONFIG_EXTRA_FIRMWARE includes them when CONFIG_CFG80211=y)"

# --- 0b. THE TOOLCHAIN LAW, read from stock (scripts/stock_gcc.sh; operator decision 2026-10-31):
#         the compiler major is the one the stock kernel was built with, taken from the ground-
#         truth config's CONFIG_GCC_VERSION -- gcc-15 on 20260901/20261001, gcc-16 on 20261101+.
#         gcc-14 black-screened the rig pre-userspace after a clean verify (BUILDING.md); the
#         container's bare `gcc` is never used by default (sid moves). An explicit KCC= is a
#         deliberate, logged override and skips the parity check; otherwise a major mismatch
#         between the resolved compiler and stock fails the mint BEFORE the build.
KCC_EXPLICIT="${KCC:+yes}"
if [ -z "$KCC_EXPLICIT" ]; then
  KCC=$(bash /work/scripts/stock_gcc.sh "$CFG_GT") || die "could not read stock's compiler major from $CFG_GT (stock_gcc.sh)"
  command -v "$KCC" >/dev/null || die "stock $BASEDATE is built with $KCC but the container has none -- re-run provision-build-container.sh (it installs gcc-15 and gcc-16 side by side)"
  bash /work/scripts/stock_gcc.sh "$CFG_GT" --check "$KCC" || die "toolchain parity check failed"
  log "toolchain: $KCC ($($KCC -dumpfullversion)) = stock's compiler major (CONFIG_GCC_VERSION $(sed -n 's/^CONFIG_GCC_VERSION=//p' "$CFG_GT")), parity law"
else
  log "toolchain: KCC=$KCC EXPLICIT -- stock's is $(bash /work/scripts/stock_gcc.sh "$CFG_GT" 2>/dev/null || echo unknown) ($(sed -n 's/^CONFIG_CC_VERSION_TEXT=//p' "$CFG_GT")); a deliberate override, cold-boot gated, parity check skipped"
fi

# --- 1. Extract pristine tarball — fresh whenever the staged patch set changed.
#        The tree persists in the container volume; the stamp used to be a bare
#        `touch`, so a remint after a patch-set change logged "patches already
#        applied" and rebuilt the OLD source while reporting success (caught
#        while staging #9, 2026-09-26). A tree is valid only if its stamp equals
#        the fingerprint of what is staged now (names + order + content). ---
if [ "$BOOTIMG" = 1 ]; then
  [ -f "$REF_KERNEL" ] || die "staging/KERNEL.stock-$BASEDATE missing — the boot.img lane packs against the STOCK KERNEL (header fields, cmdline, DTB order): stage it from the migrated rig's /flash/KERNEL"
  python3 -I /work/scripts/bootimg_parity.py fields "$REF_KERNEL" >/dev/null || die "KERNEL.stock-$BASEDATE is not a readable boot.img"
  command -v mkbootimg >/dev/null || die "mkbootimg missing in the container — re-run provision-build-container.sh (it installs mkbootimg)"
  if [ "$ETK_KIT_DTB" = 1 ]; then
    [ -f "$STG/etk_dtb_mic.py" ] || die "staging/etk_dtb_mic.py missing — lane_kernel.sh stages it from the node's ~/etk (ETK_KIT_DTB=0 for a pure-parity mint)"
    python3 -I "$STG/etk_dtb_mic.py" >/dev/null 2>&1 || [ $? = 2 ] || die "staging/etk_dtb_mic.py does not run"
  fi
fi
if [ "$BLS" = 1 ]; then
  # the stock reference is the raw PE Image now: MZ at 0, ARMd at 0x38 -- NOT ANDROID!
  [ -f "$REF_KERNEL" ] || die "staging/KERNEL.stock-$BASEDATE missing — the BLS lane gates the Image against the STOCK KERNEL (release token, vermagic): stage the image's /flash/KERNEL (stage_72.sh BASEDATE=$BASEDATE)"
  if head -c 8 "$REF_KERNEL" | grep -q 'ANDROID!'; then
    die "staging/KERNEL.stock-$BASEDATE is an Android boot.img (the 20261001 format) — BASEDATE=$BASEDATE is the BLS lane; stage the 20261101 raw PE KERNEL"
  fi
  { [ "$(head -c 2 "$REF_KERNEL")" = MZ ] && [ "$(dd if="$REF_KERNEL" bs=1 skip=56 count=4 2>/dev/null)" = ARMd ]; } \
    || die "staging/KERNEL.stock-$BASEDATE is not a raw arm64 PE Image (MZ + ARMd@0x38)"
  STOCK_DTBS="$STG/stock-dtbs-$BASEDATE"
  [ -d "$STOCK_DTBS" ] && [ -n "$(ls "$STOCK_DTBS"/*.dtb 2>/dev/null)" ] \
    || die "staging/stock-dtbs-$BASEDATE/ missing or empty — the image's /flash/dtbs/*.dtb (9 trees), the DTB parity reference (stage_72.sh)"
  # mint-time kit knobs are RETIRED here: a non-default value means someone expects a spliced
  # artifact, and this lane cannot deliver one -- fail loud, point at deploy time
  [ "$ETK_KIT_DTB" = 1 ] && [ "$ETK_INTERNAL_MIC" = 1 ] && [ "$ETK_SD_POLL" = 0 ] \
    || die "BLS lane: ETK_KIT_DTB/ETK_INTERNAL_MIC/ETK_SD_POLL have no mint-time meaning (got $ETK_KIT_DTB/$ETK_INTERNAL_MIC/$ETK_SD_POLL) — the kit DTB is derived on the rig at deploy from /flash/dtbs (install.sh / osguard, flags from etk.conf). Unset them."
  [ "$ETK_GPIO_SBU_BUILTIN" = 1 ] || log "ETK_GPIO_SBU_BUILTIN=$ETK_GPIO_SBU_BUILTIN ignored on the BLS lane: stock ships CONFIG_TYPEC_MUX_GPIO_SBU=y, there is no delta to turn off"
  [ -f "$STG/etk_dtb_mic.py" ] || die "staging/etk_dtb_mic.py missing — lane_kernel.sh stages it from the node's ~/etk; the BLS gate dry-runs it on both Flip 2 trees (no splice, early warning only)"
  python3 -I "$STG/etk_dtb_mic.py" >/dev/null 2>&1 || [ $? = 2 ] || die "staging/etk_dtb_mic.py does not run"
  [ -f /work/scripts/bls_gate.sh ] || die "/work/scripts/bls_gate.sh missing — pull ~/rocknix-gtk on the node"
fi
# ETK STACK SYNC (2026-10-11): 04-etk is re-derived from THIS repo's committed patches-7.2/ at every
# build (the repo is /work), with stage_72.sh's own ABSORBED rule. Before this, a new ETK patch reached
# the build only if someone re-ran stage_72.sh: forge's fingerprint saw the new repo tip and built, the
# stale staged set's stamp matched, and the mint shipped WITHOUT the patch (0.6.4.3, patch #11 -- caught
# before install). The ROCKNIX-sourced stacks (01-03) stay stage_72.sh's job.
if [ -d /work/patches-7.2 ]; then
  mkdir -p "$PDIR/04-etk"
  rm -f "$PDIR/04-etk/"*.patch
  cp /work/patches-7.2/*.patch "$PDIR/04-etk/" || die "04-etk sync from /work/patches-7.2 failed"
  if [ -f /work/patches-7.2/ABSORBED ]; then
    while read -r since pf evidence; do
      case "$since" in ''|\#*) continue ;; esac
      if [ "$BASEDATE" -ge "$since" ] && [ -f "$PDIR/04-etk/$pf" ]; then
        rm -f "$PDIR/04-etk/$pf"; log "04-etk: skipping $pf (absorbed upstream since $since)"
      fi
    done < /work/patches-7.2/ABSORBED
  fi
  log "04-etk synced from the repo: $(ls "$PDIR/04-etk/" | LC_ALL=C sort | tr '\n' ' ')"
fi
PSET=$(cd $PDIR && find . -name '*.patch' | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-16)
[ -n "$PSET" ] || die "could not fingerprint staging/patches-72"
if [ -d "$SRC" ] && [ "$(cat "$SRC/.etk-patches-applied" 2>/dev/null)" != "$PSET" ]; then
  log "tree stamp '$(cat "$SRC/.etk-patches-applied" 2>/dev/null || echo none)' != staged patch set $PSET — re-extracting pristine"
  [ -f linux-$KVER.tar.xz ] || die "patch set changed but linux-$KVER.tar.xz is missing — refusing to reuse a stale tree (fetch the tarball)"
  rm -rf "$SRC" || die "could not remove stale tree $SRC"
fi
if [ ! -d "$SRC" ]; then
  log "extracting linux-$KVER.tar.xz -> $SRC ..."
  if [ -z "$SFX" ]; then
    tar xf linux-$KVER.tar.xz || die "tarball extract failed"
  else
    rm -rf "/kernel/x$SFX" && mkdir -p "/kernel/x$SFX" \
      && tar xf linux-$KVER.tar.xz -C "/kernel/x$SFX" \
      && mv "/kernel/x$SFX/linux-$KVER" "$SRC" && rmdir "/kernel/x$SFX" || die "tarball extract failed"
  fi
fi
grep -q "^VERSION = 7$" "$SRC/Makefile" || die "unexpected kernel VERSION"
grep -q "^PATCHLEVEL = 2$" "$SRC/Makefile" || die "unexpected kernel PATCHLEVEL"
log "SUBLEVEL: $(grep '^SUBLEVEL' "$SRC/Makefile")"

# --- 2. Device DTS overlay (mirrors package.mk DTS_SOURCE_DIR rsync;
#        20260901 dts carries the 9998-gpu-tuning chassis: 305-925 MHz OPP
#        ladder + ACD + GPU->DDR bandwidth voting — rides the DTB, not Image) ---
cp -r $STG/dts-device-$BASEDATE/* "$SRC/arch/arm64/boot/dts/" || die "dts copy failed"

# --- 3. Patch stack in scripts/unpack order: mainline -> 7.2 -> device
#        SM8250 -> 04-etk (EIGHT patches; see patches-7.2/ and PATCHES.md) ---
if [ ! -f "$SRC/.etk-patches-applied" ]; then
  for d in 01-mainline 02-72 03-device 04-etk; do
    [ -d $PDIR/$d ] || continue
    for p in $PDIR/$d/*.patch; do
      [ -e "$p" ] || continue
      if patch -p1 -N --no-backup-if-mismatch -d "$SRC" < "$p" > /tmp/patch.log 2>&1; then
        log "applied: $d/$(basename "$p")"
      else
        cat /tmp/patch.log
        die "patch FAILED: $d/$(basename "$p")"
      fi
    done
  done
  echo "$PSET" > "$SRC/.etk-patches-applied"
else
  log "patches already applied (stamp matches staged set $PSET)"
fi

# --- 4. Config = live-rig 20260901 /proc/config.gz ground truth, with only
#        the two build-local path substitutions. NOTE vs the 712 lane: the
#        ARM64_LSUI parity-disable is GONE — stock 20260901 ships
#        CONFIG_ARM64_LSUI=y (upstream CI binutils passes the AS probe now,
#        ours does too), so the rig ground truth already carries =y and
#        parity means leaving it alone. Inert on this silicon (no FEAT_LSUI).
mkdir -p "$OUT"
cp $CFG_GT "$OUT/.config"
"$SRC/scripts/config" --file "$OUT/.config" \
  --set-str CONFIG_INITRAMFS_SOURCE "$STG/initramfs-stock-$BASEDATE.cpio" \
  --set-str CONFIG_EXTRA_FIRMWARE_DIR "$STG/external-firmware-$BASEDATE"
# Boot-logo fix (see ETK_GPIO_SBU_BUILTIN above): upstream 187eb24f2e, carried as a config
# delta on the boot.img lane only (the 20260901 GRUB-era chassis binds msm early anyway).
SPLASH_FIX=0
if [ "$BOOTIMG" = 1 ] && [ "$ETK_GPIO_SBU_BUILTIN" = 1 ]; then
  "$SRC/scripts/config" --file "$OUT/.config" --enable CONFIG_TYPEC_MUX_GPIO_SBU
  SPLASH_FIX=1
  log "boot-logo fix: CONFIG_TYPEC_MUX_GPIO_SBU=y (upstream 187eb24f2e) -- expect it in the drift"
elif [ "$BLS" = 1 ]; then
  log "boot-logo fix: MOOT on the BLS lane -- stock $BASEDATE ships CONFIG_TYPEC_MUX_GPIO_SBU=y (upstream 187eb24f2e in the tag); no config delta, the drift must not show the line"
else
  log "boot-logo fix: OFF (BOOTIMG=$BOOTIMG ETK_GPIO_SBU_BUILTIN=$ETK_GPIO_SBU_BUILTIN) -- stock =m, logo missing on 20261001 is EXPECTED"
fi

if [ "$ETK_FORENSICS" = 1 ]; then
  "$SRC/scripts/config" --file "$OUT/.config" \
    --enable CONFIG_WATCHDOG_SYSFS \
    --enable CONFIG_WATCHDOG_PRETIMEOUT_GOV \
    --enable CONFIG_WATCHDOG_PRETIMEOUT_GOV_NOOP \
    --enable CONFIG_WATCHDOG_PRETIMEOUT_GOV_PANIC \
    --enable CONFIG_WATCHDOG_PRETIMEOUT_DEFAULT_GOV_NOOP \
    --enable CONFIG_DEBUG_KERNEL \
    --enable CONFIG_SOFTLOCKUP_DETECTOR \
    --enable CONFIG_HARDLOCKUP_DETECTOR \
    --enable CONFIG_HARDLOCKUP_DETECTOR_PREFER_BUDDY \
    --disable CONFIG_BOOTPARAM_SOFTLOCKUP_PANIC \
    --disable CONFIG_BOOTPARAM_HARDLOCKUP_PANIC \
    --disable CONFIG_DETECT_HUNG_TASK \
    --disable CONFIG_DETECT_HUNG_TASK_BLOCKER \
    --disable CONFIG_ARM64_PSEUDO_NMI \
    --enable CONFIG_PSTORE_RAM \
    --enable CONFIG_PSTORE_CONSOLE
  log "FORENSICS kernel: wdt sysfs + pretimeout govs, log-only lockup detectors, ramoops console -- expect them (and DEBUG_KERNEL's ABI-neutral defaults) in the drift; cmdline + '$ETK_CMDLINE'"
fi

MAKE="make -C $SRC O=$OUT ARCH=arm64 CC=$KCC HOSTCC=$KCC KBUILD_BUILD_HOST=rocknix-gtk -j6"

# --- 5. olddefconfig + drift check against ground truth ---
$MAKE olddefconfig > /tmp/olddefconfig.log 2>&1 || { cat /tmp/olddefconfig.log; die "olddefconfig failed"; }
# MODULE-ABI GUARD (2026-10-11): ABL-era kits ship only the boot.img; the modules come from
# ROCKNIX's stock system image, built for the stock config, and CONFIG_MODVERSIONS is OFF -- a
# layout drift corrupts memory silently instead of refusing to load. 0.6.4.1 (the first
# FORENSICS mint) let DEBUG_KERNEL pull in DETECT_HUNG_TASK(+_BLOCKER), which adds fields mid-
# task_struct (sched.h last_switch_count/time, blocker) and to struct semaphore (last_holder),
# and enabled ARM64_PSEUDO_NMI (PMR vs the stock modules' DAIF masking). Any of these =y while
# the stock config has it off fails the mint.
for sym in DETECT_HUNG_TASK DETECT_HUNG_TASK_BLOCKER ARM64_PSEUDO_NMI DEBUG_LOCK_ALLOC LOCKDEP DEBUG_SPINLOCK DEBUG_MUTEXES KASAN; do
  if grep -q "^CONFIG_$sym=y" "$OUT/.config" && ! grep -q "^CONFIG_$sym=y" $CFG_GT; then
    die "MODULE-ABI GUARD: CONFIG_$sym=y but the rig's stock modules were built without it (struct layouts / irq masking differ, MODVERSIONS off)"
  fi
done
diff $CFG_GT "$OUT/.config" > /kernel/config72$SFX.drift
DRIFT_NOTE=""; [ "$SPLASH_FIX" = 1 ] && DRIFT_NOTE=" + the one TYPEC_MUX_GPIO_SBU m->y line (boot-logo fix)"
[ "$ETK_FORENSICS" = 1 ] && DRIFT_NOTE="$DRIFT_NOTE + the FORENSICS block (wdt/lockup/pstore + DEBUG_KERNEL's ABI-neutral defaults)"
log "config drift vs rig ground truth (expect only INITRAMFS/FIRMWARE paths + toolchain-probe lines$DRIFT_NOTE):"
cat /kernel/config72$SFX.drift

# --- 6. The build (Image + modules [+ the device DTBs on the boot.img lane]) ---
#        DTB set = every staged device .dts, C-sorted: that IS stock's order ('-' < '.'
#        puts each -visionox before its base board), the same qcom/<name>.dtb make
#        targets ROCKNIX passes via get_kernel_make_extracmd.
#        BLS lane: the DTBs are built for the PARITY GATE only (9/9 byte-identical to the
#        image's /flash/dtbs); the OS ships them, the artifact is the Image alone.
DTB_TARGETS=""
if [ "$BOOTIMG" = 1 ] || [ "$BLS" = 1 ]; then
  for f in $(cd $STG/dts-device-$BASEDATE/qcom && LC_ALL=C ls *.dts); do
    DTB_TARGETS="$DTB_TARGETS qcom/${f%.dts}.dtb"
  done
  [ -n "$DTB_TARGETS" ] || die "no .dts in staging/dts-device-$BASEDATE/qcom"
  [ "$BOOTIMG" = 1 ] && log "boot.img lane: DTBs (stock order):$DTB_TARGETS"
  [ "$BLS" = 1 ] && log "BLS lane: DTBs built for the parity gate only:$DTB_TARGETS"
fi
log "building Image + modules${DTB_TARGETS:+ + dtbs} with $($KCC --version | head -1) ..."
# DTC_FLAGS=-@ : ROCKNIX's linux package.mk builds every DTB with symbols
#        (`DTC_FLAGS=-@ kernel_make ...`), which also makes dtc emit a phandle for
#        every labelled node. Without it the 0.6 mint packed DTBs that were
#        semantically identical to stock but 0/9 byte-identical (~47 KB smaller
#        each, no __symbols__ node) -- the parity gate could only say "inspect".
#        With it the gate's DTB note is the proof: 9/9 byte-identical.
if $MAKE DTC_FLAGS=-@ Image modules $DTB_TARGETS > /kernel/build72$SFX.log 2>&1; then
  log "BUILD OK"
else
  echo "=== last 60 lines of build72$SFX.log ==="
  tail -60 /kernel/build72$SFX.log
  die "kernel build FAILED (full log: /kernel/build72$SFX.log)"
fi

# --- 7. Verification summary ---
echo "=== VERIFY ==="
echo "kernel.release: $(cat "$OUT/include/config/kernel.release")"
ls -la "$OUT/arch/arm64/boot/Image"
# modules.order is what modules_install ships; a `find -name '*.ko'` also counts STALE
# objects an incremental rebuild left behind (2026-10-08: the 0.6.3 remint kept 0.6.2's
# gpio-sbu-mux.ko on disk after the symbol went =y and the old gate died on it).
# modules.order lists the .o names (mm/zsmalloc.o); modules_install turns them into .ko.
STALE=$(find "$OUT" -name '*.ko' | sed "s|^$OUT/||" | grep -vxF -f <(sed 's/\.o$/.ko/' "$OUT/modules.order") || true)
if [ -n "$STALE" ]; then
  echo "pruning stale .ko not in modules.order:"; echo "$STALE" | sed 's/^/  /'
  echo "$STALE" | while read -r f; do rm -f "$OUT/$f"; done
fi
echo "modules built: $(wc -l < "$OUT/modules.order") (modules.order)"
strings "$OUT/arch/arm64/boot/Image" | grep -m1 "Linux version"
echo "patch set: $PSET"
# #9 is a battery-safety patch: the lane FAILS if the tree lacks it. Checks the
# code, not the patch source, so it stays true if upstream absorbs #3382.
grep -q 'clamp(chip->batt_info->voltage_max_design_uv, 3600000, 4450000)' \
    "$SRC/drivers/power/supply/qcom_pm8150b_charger.c" \
  && echo "#9 pm8150b float-voltage fix: PRESENT" \
  || die "#9 pm8150b float-voltage fix MISSING from the built tree"
# #10: the input current limit follows the Type-C source and is actually applied
# (ICL override). Without it a Flip 2 on a laptop's USB-C port sits at 500 mA.
grep -q 'smb5_typec_rp_current' "$SRC/drivers/power/supply/qcom_pm8150b_charger.c" \
  && grep -q 'ICL_OVERRIDE_BIT, ICL_OVERRIDE_BIT' "$SRC/drivers/power/supply/qcom_pm8150b_charger.c" \
  && echo "#10 pm8150b Type-C input current limit: PRESENT" \
  || die "#10 pm8150b Type-C input current limit MISSING from the built tree"
# Boot-logo fix: the gate is the BUILT config, not the request -- olddefconfig could
# silently drop a symbol whose deps moved. Built-in = modules.builtin lists it and
# modules.order does not (NOT a find for the .ko: an incremental rebuild leaves the old one).
if [ "$SPLASH_FIX" = 1 ]; then
  grep -q '^CONFIG_TYPEC_MUX_GPIO_SBU=y$' "$OUT/.config" \
    || die "boot-logo fix requested but CONFIG_TYPEC_MUX_GPIO_SBU is not =y in the built config"
  grep -qE 'gpio-sbu-mux\.k?o$' "$OUT/modules.order" \
    && die "boot-logo fix requested but modules.order still lists gpio-sbu-mux (built as a module)"
  grep -q 'gpio-sbu-mux' "$OUT/modules.builtin" \
    || die "boot-logo fix requested but modules.builtin does not list gpio-sbu-mux"
  echo "boot-logo fix (gpio-sbu-mux built-in, upstream 187eb24f2e): PRESENT"
elif [ "$BLS" = 1 ]; then
  # parity carries it: assert from the BUILT config and the ground truth, not from a knob
  grep -q '^CONFIG_TYPEC_MUX_GPIO_SBU=y$' $CFG_GT \
    || die "BLS lane expects stock CONFIG_TYPEC_MUX_GPIO_SBU=y in the ground truth (it is =y in 20261101); re-read the config carve"
  grep -q '^CONFIG_TYPEC_MUX_GPIO_SBU=y$' "$OUT/.config" \
    || die "CONFIG_TYPEC_MUX_GPIO_SBU is not =y in the built config although the ground truth has it (olddefconfig dropped it?)"
  grep -q 'gpio-sbu-mux' "$OUT/modules.builtin" \
    || die "modules.builtin does not list gpio-sbu-mux although the config says =y"
  echo "boot-logo fix (gpio-sbu-mux built-in): STOCK PARITY -- 20261101 ships it =y, no ETK delta"
else
  echo "boot-logo fix: OFF -- stock CONFIG_TYPEC_MUX_GPIO_SBU=m (pure parity)"
fi

# --- 8. qcom-abl packaging (boot.img lane only) — the artifact the ABL boots ---
#        pack_bootimg.sh mirrors ROCKNIX's makeinstall_target (gzip Image + DTBs, 5-byte
#        "dummy" ramdisk, mkbootimg v0) with every header field and the base cmdline taken
#        from the STOCK KERNEL, appends ETK_CMDLINE, and ends in the parity gate.
if [ "$BOOTIMG" = 1 ]; then
  DTB_FILES=""
  for d in $DTB_TARGETS; do
    [ -f "$OUT/arch/arm64/boot/dts/$d" ] || die "built DTB missing: $d"
    DTB_FILES="$DTB_FILES $OUT/arch/arm64/boot/dts/$d"
  done
  echo "=== BOOT.IMG (qcom-abl) ==="
  KIT_ENV=""
  KIT_FLAGS=""     # one env value, possibly two flags: passed whole, never through $KIT_ENV's split
  if [ "$ETK_KIT_DTB" = 1 ]; then
    KIT_ENV="KIT_DTB_TOOL=$STG/etk_dtb_mic.py"
    [ "$ETK_INTERNAL_MIC" = 1 ] || KIT_FLAGS="--no-mic"
    if [ "$ETK_SD_POLL" = 1 ]; then
      grep -q -- '--sd-poll' "$STG/etk_dtb_mic.py" || die "ETK_SD_POLL=1 but the staged splicer has no --sd-poll (pull the node's ~/etk)"
      # the parity gate's kit check reads the mic delta only: an sdpoll-only kit DTB would
      # fail it AFTER the whole build (proven 2026-10-24 on the stock 20261001 boot.img)
      [ "$ETK_INTERNAL_MIC" = 1 ] || die "ETK_SD_POLL=1 needs ETK_INTERNAL_MIC=1 (the parity gate verifies kit DTBs by their mic delta)"
      KIT_FLAGS="${KIT_FLAGS:+$KIT_FLAGS }--sd-poll"
    fi
    echo "kit DTB splice: ON (mic=$ETK_INTERNAL_MIC sdpoll=$ETK_SD_POLL) via $STG/etk_dtb_mic.py sha $(sha256sum "$STG/etk_dtb_mic.py" | cut -c1-16)"
  else
    [ "$ETK_SD_POLL" = 1 ] && die "ETK_SD_POLL=1 is a kit DTB delta -- it needs ETK_KIT_DTB=1"
    echo "kit DTB splice: OFF (ETK_KIT_DTB=0) — pure-parity mint"
  fi
  KIT_DTB_FLAGS="$KIT_FLAGS" env $KIT_ENV bash /work/scripts/pack_bootimg.sh "$OUT/arch/arm64/boot/Image" "$REF_KERNEL" "$ETK_CMDLINE" \
       "$OUT/arch/arm64/boot/boot.img" $DTB_FILES \
    || die "boot.img packaging/parity FAILED — nothing to ship"
  grep -q "msm.context_keepalive=1" <(python3 -I /work/scripts/bootimg_parity.py show "$OUT/arch/arm64/boot/boot.img") \
    || die "boot.img cmdline lacks msm.context_keepalive=1 — the anti-lock would be lost silently"
  echo "boot.img: $OUT/arch/arm64/boot/boot.img (cmdline + '$ETK_CMDLINE')"
fi

# --- 9. BLS gate (20261101+ lane only) — the raw Image IS the artifact; prove it fits the OS
#        bls_gate.sh: PE magic + release == kernel.release == stock's, vermagic == stock's
#        (the stock modules dir is named after it), built DTBs 9/9 byte-identical to the
#        image's /flash/dtbs, the kit splicer dry-runs on both Flip 2 trees (DTB_MIC_PATCHED;
#        the artifact set itself stays stock), drift surfaced with the retired GPIO_SBU knob
#        asserted gone and CONFIG_CMDLINE asserted empty (one cmdline source: the entry).
if [ "$BLS" = 1 ]; then
  echo "=== BLS GATE (OpenABL + Boot Loader Spec) ==="
  echo "cmdline_extra (deploy-time; the kit renders it into loader/entries/etk-gtk.conf options, NOT baked here): '$ETK_CMDLINE'"
  printf '%s\n' "$ETK_CMDLINE" > "/kernel/cmdline_extra$SFX.txt"
  bash /work/scripts/bls_gate.sh \
      --image "$OUT/arch/arm64/boot/Image" --release "$OUT/include/config/kernel.release" \
      --stock "$REF_KERNEL" --stock-dtbs "$STOCK_DTBS" --built-dtbs "$OUT/arch/arm64/boot/dts/qcom" \
      --splicer "$STG/etk_dtb_mic.py" --modules-out "$OUT" --config "$OUT/.config" \
      --drift "/kernel/config72$SFX.drift" --cmdline-extra "$ETK_CMDLINE" \
      ${STOCK_MODULES_DIR:+--modules-dir "$STOCK_MODULES_DIR"} \
    || die "BLS gate FAILED — nothing to ship"
  echo "Image: $OUT/arch/arm64/boot/Image (the artifact; lane_kernel.sh ships it as KERNEL.rocknix-gtk-$BASEDATE-<ver>)"
fi
