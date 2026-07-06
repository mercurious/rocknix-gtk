# Building the ETK ROCKNIX-GTK kernel

Reproduces the ROCKNIX `20260701` SM8250 kernel (`7.0.11`) from upstream sources + the ROCKNIX
patch stack + this fork's patches, on an arm64 host (native, or a colima/Docker aarch64
container so the cross-build runs at native speed). No full distro build is needed — this
builds only the kernel image, then it overlays via ETK.

## Toolchain law (learned the hard way)

**Build with GCC ≥ 15 and binutils ≥ 2.44.** A GCC-14 / binutils-2.42 build compiles and
verifies clean (correct vermagic, 236/236 modules, byte-identical initramfs) yet
**black-screens the rig pre-userspace** — no console, no ssh, nothing readable. A GCC-15.x /
binutils-2.46 build of the identical tree boots first try and lands at the exact stock image
byte size. The kernel is boot-sensitive to the toolchain; don't fight it. (Debian `sid`'s
`build-essential` satisfies this; Ubuntu `noble`'s GCC-14 does not.)

## 1. Reconstruct the base tree

From [`ROCKNIX/distribution`](https://github.com/ROCKNIX/distribution) at tag `20260701`,
`projects/ROCKNIX/packages/linux/package.mk` selects, for `DEVICE=SM8250`:

- **Source:** mainline `https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.0.11.tar.xz`
  (sha256 `e56c8356dda01136a6041c6ef832bd0ec99bd2d35dff97832aa5ec10ed014304`).
  **Tarball, never a git checkout** — the config has `CONFIG_LOCALVERSION_AUTO=y`.
- **Patch stack (34), in `scripts/unpack` order:**
  1. `projects/ROCKNIX/packages/linux/patches/mainline/` (5)
  2. `projects/ROCKNIX/packages/linux/patches/7.0/` (2)
  3. `projects/ROCKNIX/devices/SM8250/patches/linux/` (27)
- **Device DTS:** `projects/ROCKNIX/devices/SM8250/linux/dts/qcom/*` rsynced over
  `arch/arm64/boot/dts/` before patching.

Apply the ROCKNIX stacks first, then this fork's [`patches/`](patches) on top.

## 2. Config — ground truth beats archaeology

Use the **live rig's** `/proc/config.gz` (`zcat` it off the device), not the repo's
`linux.aarch64.conf` (which carries CI placeholders — an 18-line diff, all substitution
artifacts). The only build-local edits: `CONFIG_INITRAMFS_SOURCE` and
`CONFIG_EXTRA_FIRMWARE_DIR` (paths into your staging dir). `CONFIG_MODVERSIONS` and
`CONFIG_MODULE_SIG` are both off, so module compatibility is vermagic-string only — a
same-config build satisfies it.

## 3. Initramfs — carve it, don't rebuild it

Rebuilding the initramfs is a mini world-build (busybox/util-linux/e2fsprogs/avfs/rocknix-splash
with their toolchain) — ruled out on a small host. Instead, **carve the exact gzip'd cpio out of
the live `/flash/KERNEL`** and re-embed it verbatim: [`scripts/extract_initramfs.py`](scripts/extract_initramfs.py)
scans for the gzip stream, verifies it's a `newc` cpio, and writes it out. Point
`CONFIG_INITRAMFS_SOURCE` at the carved `.cpio`. The re-embedded initramfs is byte-identical to stock.

## 4. Firmware

The six embedded blobs (`qcom/a650_gmu.bin a650_sqe.fw sm8250/{a650_zap,adsp,cdsp,slpi}.mbn`)
are **proprietary Qualcomm firmware — not redistributed here.** Pull them from your own rig's
`/usr/lib/firmware/` into the staging `external-firmware/` tree; they are byte-identical to what
the stock image embeds.

## 5. Build (gate on the real exit code — never pipe make to `tail`)

[`scripts/build_stock.sh`](scripts/build_stock.sh) drives it end to end (extract → DTS → patch
stack → config → `olddefconfig` + drift check → build). Core invocation:

```
make -C linux-7.0.11 O=out ARCH=arm64 CC=gcc HOSTCC=gcc KBUILD_BUILD_HOST=rocknix-gtk -j6 Image modules
```

Expect ~15–25 min cold, minutes warm (keep `O=out` for incremental — a one-file patch relinks
in ~2 min). `KERNEL_TARGET=Image` (uncompressed, ~60 MB with initramfs + firmware embedded).

## 6. Verify before you trust it

- `cat out/include/config/kernel.release` = `7.0.11` exactly.
- Module vermagic (`modinfo -F vermagic out/.../snd-aloop.ko`) matches a live rig module
  (`7.0.11 SMP preempt mod_unload aarch64`).
- 236 `.ko` built (matches the rig).
- Re-extract the initramfs from your built `Image` and `cmp` it against the carved cpio —
  byte-identical.
- Embedded firmware blobs `cmp`-match the rig's.

## 7. Deploy + validate

Stage via ETK's `install.sh` (`KERNEL_IMAGE=...`, `KERNEL_CONTEXT_KEEPALIVE=1`). It writes a
TEST grub entry (default boot stays stock). Reboot **on-device**, pick the TEST entry, then run
[`scripts/validate_gate.sh`](scripts/validate_gate.sh) (read-only ssh) for the boot gate:
`uname` matches intent, `lsmod` count vs stock, modules dir untouched, one warm session with a
normal race-ledger row. Only then does a kernel count as live.
