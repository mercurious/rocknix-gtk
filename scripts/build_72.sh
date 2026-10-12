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
BOOTIMG="${BOOTIMG:-$([ "$BASEDATE" -ge 20261001 ] && echo 1 || echo 0)}"
ETK_CMDLINE="${ETK_CMDLINE:-msm.context_keepalive=1 panic=30}"
# Kit DTB splice at mint (ABL era: the DTBs ride inside the boot.img). ETK_KIT_DTB=0
# mints a pure-parity image (no splice); ETK_INTERNAL_MIC=0 drops the mic delta only.
# The splicer is etk's bin/etk_dtb_mic.py, staged by lane_kernel.sh (docker cp) --
# never a copy kept in this repo.
ETK_KIT_DTB="${ETK_KIT_DTB:-1}"
ETK_INTERNAL_MIC="${ETK_INTERNAL_MIC:-1}"
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
DTB_TARGETS=""
if [ "$BOOTIMG" = 1 ]; then
  for f in $(cd $STG/dts-device-$BASEDATE/qcom && LC_ALL=C ls *.dts); do
    DTB_TARGETS="$DTB_TARGETS qcom/${f%.dts}.dtb"
  done
  [ -n "$DTB_TARGETS" ] || die "no .dts in staging/dts-device-$BASEDATE/qcom"
  log "boot.img lane: DTBs (stock order):$DTB_TARGETS"
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
  if [ "$ETK_KIT_DTB" = 1 ]; then
    KIT_ENV="KIT_DTB_TOOL=$STG/etk_dtb_mic.py"
    [ "$ETK_INTERNAL_MIC" = 1 ] || KIT_ENV="$KIT_ENV KIT_DTB_FLAGS=--no-mic"
    echo "kit DTB splice: ON (mic=$ETK_INTERNAL_MIC) via $STG/etk_dtb_mic.py sha $(sha256sum "$STG/etk_dtb_mic.py" | cut -c1-16)"
  else
    echo "kit DTB splice: OFF (ETK_KIT_DTB=0) — pure-parity mint"
  fi
  env $KIT_ENV bash /work/scripts/pack_bootimg.sh "$OUT/arch/arm64/boot/Image" "$REF_KERNEL" "$ETK_CMDLINE" \
       "$OUT/arch/arm64/boot/boot.img" $DTB_FILES \
    || die "boot.img packaging/parity FAILED — nothing to ship"
  grep -q "msm.context_keepalive=1" <(python3 -I /work/scripts/bootimg_parity.py show "$OUT/arch/arm64/boot/boot.img") \
    || die "boot.img cmdline lacks msm.context_keepalive=1 — the anti-lock would be lost silently"
  echo "boot.img: $OUT/arch/arm64/boot/boot.img (cmdline + '$ETK_CMDLINE')"
fi
