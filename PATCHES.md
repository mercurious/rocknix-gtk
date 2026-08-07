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

### Patch #3 — `typec-debounce-resample`: close the Type-C phantom-cable wedge
- **File:** `drivers/usb/typec/tcpm/qcom/qcom_pmic_typec_port.c` (`patches/0003-...`).
- **The problem it solves:** after rapid plug/unplug ("flap storms"), the rig reports a connected
  DP sink and a `normal` orientation **with the cable physically out**; `echo detect >
  status` still says connected; only a reboot clears it
  (`~/etk/manual_forensics/typec_wedge_20260807.txt`). While wedged, a phantom low-speed USB HID
  flaps on ~30s cycles — the udev-storm generator that keeps killing InputPlumber. Mechanism: the
  driver's 2ms CC debounce swallows edges **twice** — the ISR gates `cc_change` on
  `!debouncing_cc` (edge consumed), and `get_cc()` returns `-EBUSY` to TCPM (poll skipped) — and
  nothing re-samples when the window closes. A detach edge inside the window is lost forever:
  TCPM never runs `tcpm_detach()`, the DP altmode is never unregistered, the cached orientation
  and DRM `link_ready` stay stale.
- **What it does:** on debounce completion (`qcom_pmic_typec_port_cc_debounce()`), notify TCPM
  with `tcpm_cc_change()` unconditionally. TCPM re-reads CC via `get_cc()` — no longer gated —
  and its state machine ignores no-change events, so a healthy plug sees one extra harmless poll
  per 2ms window. Companion hunk: `port_stop()` drains the worker with
  `cancel_delayed_work_sync()` before teardown, since the worker now touches the tcpm port.
- **Why it's safe:** bounded by construction — each `set_cc`/`start_toggling` schedules at most
  one debounce completion, hence at most one extra notify; no locks are shared with TCPM's event
  queue (the notify runs after the port spinlock drops, same shape as the existing ISR). No knob,
  same reasoning as Patch #2: the stock alternative is a guaranteed unrecoverable wedge, and the
  healthy-path delta is a no-op event.
- **Verdict (honest):** mechanism decoded from source against the live wedge capture; applies
  clean; **PENDING the Boot A cold-boot gate + flap-storm arm** (`scripts/dp_plug_protocol.md`).
- **Upstreamability:** clean lost-edge bugfix, upstream candidate (linux-usb), disclosed as
  AI-assisted.

### Patch #4 — `typec-mux-eprobe-defer`: 7.1 regression, connector loses its mux/switch silently
- **File:** `drivers/usb/typec/mux.c` (`patches/0004-...`). **Adopted from ROCKNIX PR #3080
  (author: Anze <aanzdev@gmail.com>), pending upstream — carried here with credit** because our
  7.1.2 tree has the identical regression and the fix is in shared code their PR ships only into
  the SM8550 device dir.
- **The problem it solves:** the 7.1 merge window added a skip-duplicates filter to
  `typec_switch_match()`/`typec_mux_match()`. When the switch/mux driver hasn't probed yet at
  fetch time, `class_find_device()` returns NULL, `container_of(NULL)` (device is the struct's
  first member) yields NULL, the dedup loop "matches" it against an empty slot of an
  **uninitialized stack array** and returns NULL — converting "not probed yet, defer" into a
  silent "no connection". The consumer is then wired **permanently without its
  orientation-switch/mux**: on this rig the nb7vpq904m redriver's AUX/SBU crossbar never gets
  programmed, the plausible root of "DP only links in the normal plug orientation" (AUX_CC
  power-on default = normal mapping). Our boot dmesg shows the exact fw_devlink cycle-breaks
  (`typec-mux@1c` ↔ connector ↔ `phy@88e8000`) that make the probe-order race live; the
  Odin 2/3 hit the fully-dead-DP variant of the same bug.
- **What it does:** bail with `ERR_PTR(-EPROBE_DEFER)` **before** the dedup loop when no device
  was found, and zero-init both fetch arrays so the dedup loop can never read stack garbage.
  Restores the documented pre-7.1 contract of both functions.
- **Why it's safe:** the deferred path is the designed one (callers already handle
  `-EPROBE_DEFER`); a real registered device can never compare equal to a zeroed slot, so dedup
  still fires only on true duplicates.
- **Verdict (honest):** regression shape verified verbatim in our tree; our exposure is a race
  (this boot's probe won it — `15-001c-switch`/`-retimer` registered, mux calls flowing), so the
  reverse-orientation claim is **behavioral, PENDING Boot A arm 2**; the patch is correct
  regardless of which mechanism the arm convicts.
- **Upstreamability:** already in flight as ROCKNIX PR #3080; our role is corroboration
  (SM8250/TCPM evidence), not duplication.

### Patch #5 — `nb7vpq904m-always-program`: no stale-register short-circuits in the redriver
- **File:** `drivers/usb/typec/mux/nb7vpq904m.c` (`patches/0005-...`).
- **The problem it solves:** `nb7vpq904m_sw_set()` and `nb7vpq904m_retimer_set()` skip
  reprogramming when the *cached* orientation/mode equals the request. The cache is assumed to
  equal hardware state; anything that desyncs them (a fetch swallowed by the Patch #4 bug, a
  redriver power event, an i2c glitch) strands `AUX_CC_REG` (0x09) — and the next identical
  request is skipped, so there is **no repair path**. This is the standing "plug it the right
  way" gotcha's second candidate mechanism, and it becomes reachable exactly when Patch #4
  starts delivering calls the driver used to miss.
- **What it does:** drops both equality guards — always cache, always call `nb7vpq904m_set()`.
  Three idempotent i2c register writes on a plug-rate path.
- **Why it's safe:** the writes are the same values the guard would have written on a "real"
  change; plug/unplug cadence is human-rate; the driver serializes via its own mutex.
- **Verdict (honest):** hygiene + repair-path fix; correctness argued from source; behavioral
  proof rides Boot A arm 2 (reverse-orientation DP link) with Patch #4 in the same image —
  attribution between #4/#5 is deliberately not claimed.
- **Upstreamability:** small robustness fix, reportable alongside the Patch #4 corroboration,
  disclosed as AI-assisted.
