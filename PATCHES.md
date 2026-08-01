# Patch series

Discrete patches over the reconstructed ROCKNIX `7.1.2` SM8250 tree (see `BUILDING.md`).
Each is kernel-image-only and preserves the module ABI (`uname -r` = `7.1.2`, unchanged).

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

### Patch #2 — `q6afe-vote-probe-race`: cure the SM8250 silent-boot audio coin flip
- **File:** `sound/soc/qcom/qdsp6/q6afe.c` (`patches/0002-...`).
- **The problem it solves:** on a fraction of cold boots (~1 in 4 observed on the Retroid Pocket
  Flip 2) the entire boot is silent — zero ALSA cards, PipeWire serves only "Dummy Output", every
  app plays into the void. Root cause is **two stacked kernel bugs** in the LPASS core-HW clock
  vote that the `va_macro` probe depends on:
  1. When the ADSP rejects `AFE_CMD_REMOTE_LPASS_CORE_HW_VOTE_REQUEST` (seen live: error `0x16`
     while the `audio_pd` protection domain is still settling, ~10ms after its PDR "up"
     indication), the error reply arrives as an `APR_BASIC_RSP_RESULT` carrying the CMD opcode.
     `q6afe_callback()` has no case for it → "Unknown cmd 0x100f4" → **the vote waiter is never
     woken** and a fast rejection becomes a 3s `wait_event` timeout.
  2. The resulting `-ETIMEDOUT` hard-fails the `va_macro` probe (`probe with driver va_macro
     failed with error -110`). A hard failure — unlike `-EPROBE_DEFER` — is **never retried** by
     the driver core, so the whole chain (macros → soundwire → wcd938x → sound card) parks in
     `/sys/kernel/debug/devices_deferred` forever. `va_macro` is the clock supplier for ALL LPASS
     macros; one lost race kills audio for the entire boot.
- **What it does:** (a) completes the vote waiter from the basic-rsp error path, so a rejection
  fails in milliseconds instead of 3s; (b) retries the vote in place (250ms period, bounded at
  ~15s wall time) until the ADSP accepts it. Probe/clk-prepare context, so sleeping is legal. A
  healthy boot's first vote succeeds and never enters either path — there is no knob because the
  no-retry behaviour is simply a bug (it ends in guaranteed dead audio). A kernel-side recovery
  announces itself in dmesg: `etk: AFE vote (N) recovered after N retries`.
- **Field evidence for the retry approach:** ETK's userspace watchdog (now deprecated to a
  validation tripwire) proved for a week that re-poking the deferred chain a few seconds after a
  lost race **always** succeeds — the ADSP just needs moments more. The patch moves that exact
  remedy to the point of failure, before anything downstream can park.
- **Verdict (honest):** root cause fully decoded from live dmesg + source; fix builds clean and
  boots pending; natural-race validation needs cold-boot mileage (~1-in-4 occurrence). The
  deprecated watchdog logs every kernel-fix engagement to the ETK tripwire, so each raced boot is
  a validation datapoint.
- **Upstreamability:** both halves are straightforward bugfixes (dropped wakeup + probe-race
  retry) with no behaviour change on healthy paths; candidate for a real upstream submission,
  disclosed as AI-assisted.
