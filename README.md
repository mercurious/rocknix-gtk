# ETK ROCKNIX-GTK — kernel fork (Linux 7.0.11, SM8250 / Adreno 650)

A small, focused downstream patch set on top of the **ROCKNIX** kernel (mainline Linux
`7.0.11` + ROCKNIX's SM8250 device patch stack), built for the Snapdragon 865 / Adreno 650
class (Retroid Pocket Flip 2) and tuned against PS3 emulation workloads (RPCS3).

This repository exists to **publish the source delta and reproduce the build** — it is a
development and tuning record, not a kernel-distribution channel. Build from source against
your own ROCKNIX kernel tree using the steps in [`BUILDING.md`](BUILDING.md), and deploy with
the [ETK](https://github.com/mercurious/etk) installer (`install.sh`), never a hand-copied
image.

---

## Lineage (downstream patch series)

> **Downstream of the ROCKNIX kernel.**
> Base: mainline **`linux-7.0.11`** (kernel.org) + ROCKNIX's SM8250 device patch stack, exactly
> as pinned by [`ROCKNIX/distribution`](https://github.com/ROCKNIX/distribution) for release
> `20260701`. Upstream is the canonical source; this is a discrete patch series carried on top.
> Target: `arm64`, `CONFIG_DRM_MSM` (a6xx / KGSL-less `msm` KMS driver), glibc/ROCKNIX userspace.

This is not a GitHub fork-network fork — it declares its lineage here and carries its changes as
patches over the reconstructed ROCKNIX tree, so the delta is exactly the files in
[`patches/`](patches). See [`BUILDING.md`](BUILDING.md) to reconstruct the base and apply them.

---

## What this adds

**The stock ROCKNIX kernel already boots and races fine — this fork exists for one behaviour:
GPU-hang *parity* with Android.** On this exact silicon, Android's downstream KGSL driver
absorbs an a6xx GPU hang as a sub-second stutter ("reset, skip, continue"), while mainline
`msm`'s hangcheck recovery **resets the GPU but punishes the guilty context** ("reset, ban,
punish") — it marks the VM unusable (`-EPIPE` on every future submit) and bumps the fault
counter userspace polls to declare `VK_ERROR_DEVICE_LOST`. Either one kills the emulator on a
GT-series boss hang.

Patch #1 (`msm.context_keepalive`) gives `msm` a KGSL-parity mode for the guilty VM_BIND
context — see [`PATCHES.md`](PATCHES.md). It is **default-off** (the kernel boots
bit-for-bit stock behaviour until the param is set), so this fork changes nothing until you opt
in. Honest validation status — including where it does and doesn't help — is in
[`VALIDATION.md`](VALIDATION.md).

---

## The module-ABI law (why `uname` stays stock)

ROCKNIX's `/lib/modules/7.0.11` ships as prebuilt `.ko`s next to a read-only squashfs. These
patches are **kernel-image-only** and keep the exact version string + localversion
(`7.0.11`, no `+g<hash>` — build from the **release tarball, never a git checkout**, or
`CONFIG_LOCALVERSION_AUTO=y` poisons the release string and the stock modules stop loading).
Any change that would shift module ABI belongs in an image-repack lane, not here.

---

## Deploy

Custom kernels reach the rig through ETK's `install.sh` (config-driven: `KERNEL_IMAGE` +
`KERNEL_CONTEXT_KEEPALIVE` in `etk.conf`), which stages the image under a **separate TEST grub
entry** so the default boot always falls back to stock. Never `scp` a kernel by hand — it
reverts on the next reinstall, and a bad image with no fallback is a brick. See the ETK repo.

---

## License

GPL-2.0 (matching the Linux kernel and ROCKNIX). See [`LICENSE.md`](LICENSE.md).
