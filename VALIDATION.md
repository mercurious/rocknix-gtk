# Validation record

Honest status of the ROCKNIX-GTK kernel work. What's proven, what isn't, and the exact
mechanism of what remains.

## Pipeline — PROVEN

A stock-identical `7.0.11` built from this recipe (GCC-15.x / binutils-2.46 container) boots the
rig cold and passes the gate: `uname -a` = `7.0.11 #1 SMP PREEMPT` (builder host `rocknix-gtk` =
our-build-live marker), 27 loaded / 236 shipped modules (stock baseline), modules dir untouched,
no structural OS drift, one warm GT5P session with a normal race-ledger row. The initramfs
re-embeds byte-identical; module vermagic and all six firmware blobs match the stock image.

> **Toolchain caveat (load-bearing):** a GCC-14 / binutils-2.42 build of the *identical tree*
> black-screens the rig pre-userspace despite verifying clean. Build GCC ≥ 15 / binutils ≥ 2.44.

## Patch #1 (`context_keepalive`) — kernel half PROVEN to engage; parity not yet end-to-end

On every live a6xx boss hang tested (GT5P and GT HD Concept), with the param armed via the baked
grub cmdline:

- dmesg shows `context_keepalive: surviving hang, context kept usable` — the survive branch runs.
- The VM is **not** marked unusable; `MSM_PARAM_FAULTS` is **not** bumped; the GPU recovers and
  the context stays alive (confirmed: no re-hang, GPU returns to idle).

**But the emulator still did not keep racing**, because the kill switch moved *up the stack* to
userspace. Two distinct wedge classes were observed; the kernel patch is necessary for both but
sufficient for neither alone:

| wedge (a6xx status) | where userspace parks | needs, on top of the kernel patch |
|---|---|---|
| **query** (`00C5xxxx`, GT5P 787B) | Turnip `get_query_pool_results` poll | etk-turnip-gtk Patch #6 (`TU_ETK_QUERY_SURVIVE`) — built, **not yet reproduced on-track** |
| **fence** (`00E5xxxx`, GT HD / London flip path) | RPCS3 spins `vkGetFenceStatus(timeout=0)` | an emulator-side fence force-signal — **not yet shipped** |

Two findings from a full 2026-07-05 session worth recording:

1. **The flip fence never self-recovers under the parity kernel.** With nothing killing it (no
   emulator timeout, no manual recovery), GT HD Concept sat frozen 20 s+ with the render thread
   spinning at ~350 % CPU and the GPU idle — the specific fence RPCS3 polls is never signalled by
   hangcheck recovery. So relaxing any userspace timeout is futile; the fence must be *force-signalled*.
2. **The dominant real-play wedge is the fence poll**, not the query poll. Across a full session
   every boss hit was `00E5xxxx` (fence); the `00C5xxxx` query wedge never reproduced. So the
   Turnip query companion, while correct, addresses the minority case; the emulator-side fence fix
   is the critical path.

## Recovery ladder (proven)

Fallback is never more than a reboot away: the custom kernel is staged under a TEST grub entry
(default entry = stock). Below that: VolDown fastboot → reflash the official image. Games, shader
vault, and telemetry survive all of it (they live on the storage partition, not the kernel).
