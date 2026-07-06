# Patch series

Discrete patches over the reconstructed ROCKNIX `7.0.11` SM8250 tree (see `BUILDING.md`).
Each is kernel-image-only and preserves the module ABI (`uname -r` = `7.0.11`, unchanged).

### Patch #1 — `kgsl-parity`: keep a hung VM_BIND context alive (`msm.context_keepalive`)
- **File:** `drivers/gpu/drm/msm/msm_gpu.c` (`patches/0001-...`).
- **The problem it solves:** on an a6xx GPU hang, `recover_worker()` resets the GPU but then
  *punishes the guilty context* — for a VM_BIND (userspace-managed, i.e. Vulkan/Turnip) VM it
  calls `msm_gem_vm_unusable()` (`-EPIPE` on every future submit, `msm_gem_submit.c`) **and**
  bumps `vm->faults`, which Turnip polls via `MSM_PARAM_FAULTS` (`adreno_gpu.c`) to declare
  `VK_ERROR_DEVICE_LOST`. Either kill switch alone ends the emulator. Android's KGSL driver, on
  the same silicon, does neither — "reset, skip, continue" — which is why the same hang is a
  sub-second stutter there.
- **What it does:** adds a module parameter `context_keepalive` (bool, writable at
  `/sys/module/msm/parameters/context_keepalive`; `CONFIG_DRM_MSM=y`, so the kernel-cmdline form
  is `msm.context_keepalive=1`). **Default `false` = bit-for-bit stock behaviour** — the kernel
  boots identically until the param is set. When true, the VM_BIND punishment branch in
  `recover_worker()` is replaced by a survive path: **skip the VM-unusable ban AND skip the
  `vm->faults` bump.** The GPU is still reset and surviving work still replayed; the guilty
  submit is retired with its fence signalled completed, so fence *waiters* unpark. A
  `DRM_DEV_INFO` line (`context_keepalive: surviving hang, context kept usable`) marks it in
  dmesg. `submit->queue->faults` still increments as an honest stat (it feeds neither the ban nor
  `MSM_PARAM_FAULTS`).
- **Why it's safe to trial:** the survive path is the SAME "don't mark unusable, replay work"
  path that kernel-managed (`vm->managed`) VMs already take in stock `msm`; a hangcheck *timeout*
  does not corrupt page tables. Default-off means the boot gate stays valid; a userspace crash-net
  remains the fallback tier if a survived hang ever fails.
- **Pairs with** the Turnip driver ([etk-turnip-gtk](https://github.com/mercurious/etk-turnip-gtk),
  Patch #6 `TU_ETK_QUERY_SURVIVE`): the kernel keeps the context alive; the driver forges the
  dropped occlusion query so the app's poll unparks. One is not much use without the other.
- **Verdict (honest):** the kernel half is **field-proven to engage** — on live a6xx boss hangs
  the survive branch fires, the context stays usable, and the fault counter is suppressed. It is
  **necessary but not sufficient** on its own: a `get_query_pool_results` wedge additionally needs
  the Turnip companion, and a flip-path `vkGetFenceStatus` wedge additionally needs an
  emulator-side fence force-signal (not yet shipped). See `VALIDATION.md`.
- **Upstreamability:** the param is opt-in and default-off; the intent is a clean
  `msm`-side proposal (count-recoveries / opt-in survivable-context), disclosed as AI-assisted.
