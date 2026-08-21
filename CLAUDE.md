# CLAUDE.md — rocknix-gtk (sister repo of the ETK ecosystem)

**Mother repo: `~/etk`.** Bootstrap every session there first — read `~/etk/CLAUDE.md`, then
`~/etk/TRACK_MANUAL.md` (§8 deployment, §8.5 the build fleet) before working here. This repo is
one spoke of that system: the **ROCKNIX kernel fork** for the SM8250 rig — the
`msm.context_keepalive` KGSL-parity patch (one half of the kernel+driver anti-lock pair) and the
q6afe audio-probe-race root fix.

## Reading order (this repo)
`README.md` → `RECIPE.md` / `BUILDING.md` (the container recipe; `scripts/` provisions it) →
`PATCHES.md` → `VALIDATION.md` → `groundtruth/` (the staging byte-parity evidence).
For the 20260901 chassis lane: `UPSTREAM_20260901.md` (K1 prep — upstream deltas since
20260801, surveyed 2026-08-21, with the release-day execution order).

## How artifacts flow (never deviate)
1. **Mint**: `~/etk/forge.sh kernel` conducts `~/etk/tools/forge/lane_kernel.sh` on **etk-cloud**
   (container `rocknix-gtk-kernel-sid`, tree `~/rocknix-gtk` on the node). Law #8 naming:
   `KERNEL.rocknix-gtk-<8-digit-date>-<ver>` (knobs `FORGE_KERNEL_DATE`/`FORGE_KERNEL_VER`).
   Config drift vs groundtruth is SURFACED in the lane log — read it, don't skip it.
2. **THE GCC-15 LAW**: kernels build with `gcc-15` (enforced in-recipe; sid's default moved to
   16). The failure mode of a wrong toolchain is a **silent pre-userspace black screen** — clean
   build, clean verify, dead rig. Never relax this to "whatever the container has".
3. **Deploy**: only the operator, only via `~/etk/install.sh` (STEP 6.4: grub twin entries,
   `/flash/KERNEL.gtktest` + pristine `KERNEL.etk-stock` fallback; knobs `KERNEL_IMAGE`,
   `KERNEL_CONTEXT_KEEPALIVE`, `KERNEL_DEPLOY_MODE`). **Only the operator's cold boot passes a
   kernel** — the forge can only build it. Claude NEVER contacts the rig from anywhere but the
   Air, and never reboots it.

## Non-negotiables inherited from the mother repo
- Always-reboot gate; stock is always one grub pick away — never remove the fallback entry.
- Trunk-based: work on `main`, push same session; never force-push.
- Public artifacts under the **mercurious** pseudonym; docs stay development/tuning-focused.
