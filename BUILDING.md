# Building the ETK ROCKNIX-GTK kernel

Reproduces the ROCKNIX `20260801` SM8250 kernel (`7.1.2`) from upstream sources + the ROCKNIX
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

**Pin the compiler explicitly — `sid` moves.** As of 2026-08-05 sid's default `gcc` is
**16.1.0** (binutils 2.47), while every validated artifact to date was built with
**GCC 15.3.0 / binutils 2.46.50**. GCC 16 is untested here, and the failure mode above is
silent (clean build, clean verification, black screen), so do not let a container's default
compiler decide. Install `gcc-15` alongside and pass it in:

```
apt-get install -y build-essential gcc-15   # sid keeps 15.x available next to the default
make -C linux-7.1.2 O=out ARCH=arm64 CC=gcc-15 HOSTCC=gcc-15 ...
```

A kernel built with any other toolchain combination is unvalidated by definition and must
clear the §7 cold-boot gate before it is trusted — no exceptions, however clean the verify.

## 1. Reconstruct the base tree

From [`ROCKNIX/distribution`](https://github.com/ROCKNIX/distribution) at tag `20260801`,
`projects/ROCKNIX/packages/linux/package.mk` selects, for `DEVICE=SM8250`:

- **Source:** mainline `https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.2.tar.xz`
  (sha256 `37198c93727be247c9fb5309bb86cd5e496c61e5322cd8c4eca9476bb0b5883f`, 158,323,320
  bytes — corrected 2026-08-05: verified identical between the staging tarball that built the
  shipping `-0.3` artifact and a fresh cdn.kernel.org fetch. The value recorded here
  previously (`e56c8356…`) matched neither and would have failed a legitimate source.)
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
make -C linux-7.1.2 O=out ARCH=arm64 CC=gcc HOSTCC=gcc KBUILD_BUILD_HOST=rocknix-gtk -j6 Image modules
```

Expect ~15–25 min cold, minutes warm (keep `O=out` for incremental — a one-file patch relinks
in ~2 min). `KERNEL_TARGET=Image` (uncompressed, ~60 MB with initramfs + firmware embedded).

## 6. Verify before you trust it

- `cat out/include/config/kernel.release` = `7.1.2` exactly.
- Module vermagic (`modinfo -F vermagic out/.../snd-aloop.ko`) matches a live rig module
  (`7.1.2 SMP preempt mod_unload aarch64`).
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
