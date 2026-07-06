# Licensing & attribution

This is a **downstream patch series for the Linux kernel** as packaged by
[ROCKNIX](https://github.com/ROCKNIX/distribution). The Linux kernel's own license governs this
source unchanged: **GNU General Public License, version 2** (`GPL-2.0`), matching both the Linux
kernel and ROCKNIX.

- **Base:** mainline `linux-7.0.11` (kernel.org) + ROCKNIX's SM8250 patch stack. Upstream is the
  canonical source; the patches in [`patches/`](patches) are the delta.
- **The patches** in this repository are offered under the same `GPL-2.0` terms as the code they
  modify.
- **Not included / not redistributed here:** the mainline kernel tarball, the ROCKNIX patch stack
  (fetch from `ROCKNIX/distribution`), and the proprietary Qualcomm firmware blobs embedded in the
  image (pull from your own device). See [`BUILDING.md`](BUILDING.md).

This repository is a development and tuning record for expert enthusiasts building their own
kernels for their own hardware. It is not a channel for distributing built kernel images.

Maintained by **mercurious**.
