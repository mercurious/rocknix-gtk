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

## 20260801 lane — `KERNEL.rocknix-gtk-20260801-0.3` (2026-08-01)
- §4.4 cold-boot gate PASSED on the reference rig (Retroid Pocket Flip 2, ROCKNIX official
  20260801): `uname -a` = `7.1.2 #1 SMP PREEMPT`, builder host `rocknix-gtk`,
  `msm.context_keepalive=1` armed (`/sys/module/msm/parameters/context_keepalive` = `Y`),
  29 modules loaded (= stock baseline), audio card present at boot (q6afe patch riding as a
  tripwire — zero retries needed), zero failed units, ETK drift tool verdict:
  **no structural drift — safe to adopt**.
- Field: `context_keepalive` absorbed two live GPU hangs on this kernel the same day
  (00E5-class fence faults on GT HD, "context kept usable", races finished) — the anti-lock
  net is proven on 7.1.2.
- Both ETK patches applied with zero fuzz — neither `msm_gpu.c` nor `q6afe.c` hunk sites
  drifted across mainline 7.0.11 → 7.1.2.

## 20260801-0.4 series — the DP A/V-out session (2026-08-07, patches #3–#8)

Three cumulative artifacts, three operator cold boots, one patch cluster per boot
(`scripts/dp_plug_protocol.md` holds the full per-boot checklists):

| artifact | adds | gate (operator cold boot) | status |
|---|---|---|---|
| `-0.4` (sha `5cbf86cb…`, stock-exact 60,246,528 B, drift = expected-class only, all 41 patches zero-fuzz) | #3 debounce-resample, #4 mux-eprobe-defer, #5 nb7-always-program | Boot A: charge/USB sanity both orientations, **reverse-orientation DP arm**, flap-storm ×3 → `dp_state_probe.sh out` AGREE, pads alive | **BOOT A RUN 2026-08-08 — see below** |
| `-0.4.1` (sha `e603ee94…`, stock-exact, drift = expected-class only, all 43 patches zero-fuzz) | #6 bounded-enable-lock, #7 encoder-resolution | Boot B: at-ES matrix ×3, **in-game plug arm** (no compositor freeze), `no encoder found for crtc` count = 0 | **BUILT — boot PENDING** |
| `-0.4.2` (sha `4e5a429e…`, stock-exact, drift = expected-class only, all 44 patches zero-fuzz) | #8 q6asm-24bit-word-size | Boot C: S16 tone at roof first (wire-parity proof), then S24 tone A/B vs the roof with the pin lifted | **BUILT — boot PENDING** |

Pre-patch baseline (2026-08-07, kernel `-0.3.1`, read-only probe — full record in
`~/etk/manual_forensics/dp_session_baseline_20260807.txt`): nb7vpq904m registered its
switch+retimer this boot and tcpm's mux-request path fired ("Requesting mux state 1, usb-role 2,
orientation 2" on a reverse-plugged charger) — so the Patch #4 race was *won* on this boot,
consistent with it being a race, not a constant; the reverse-orientation claim therefore rests on
Boot A's behavioral arm, not on a captured mux-less boot. tcpm ring log confirmed drain-on-read;
nb7 regmap has no debugfs read-back (AUX_CC not directly observable). The S16 pin file survived
its first cold boot (persistence half of its gate — the audible half rides Boot C).

Known-still-true until the boots run: in-game plug freezes (P1b) remain on `-0.4`; the S24 level
loss remains on everything below `-0.4.2`; expected-freezy results on Boot A's arm 3 are the
honest record, not a regression.

### Boot A verdicts (2026-08-08, operator cold boot, harness-gated)

- **§4.4 gate PASS**: uname `7.1.2 #2` builder rocknix-gtk, gtktest sha exact, 29/237 modules,
  keepalive armed, audio card up, zero typec/tcpm/nb7 dmesg errors, S16 pin persisted.
- **Patch #3 (wedge)** — *prevention*: clean 5-cycle flap storm survived, `out`-probe AGREE ×3
  across 35s dwells. A healer-contaminated storm earlier in the night DID wedge (final detach
  eaten while etk-dpmirror's pad-heal fought the edges) — single-resample is beatable under
  storm+noise; follow-up = delayed re-check after debounce completion (captures:
  session tcpm logs, `typec_wedge` comparison). *Recovery — NEW*: a wedged port resyncs with
  **one replug cycle** (verified live: stale SRC_READY → clean re-attach → tracked detach →
  AGREE). Yesterday's wedge was reboot-only. Facet: video does not retrain on a replug-over-
  phantom (stale `link_ready` no-ops the plug path) — clears with the state.
- **Patches #4/#5 (reverse orientation)** — **arm 2 FAIL, mechanism relocated**: in reverse,
  PD is healthy, DP alt-mode enters (`svid ff01 active`), the typec_displayport module latches
  `hpd: 1`, `configuration`/`pin_assignment` are byte-identical to the working normal face
  ([C]) — and with `drm.debug=0x117` armed, msm_dp logs **nothing**: no notify, no AUX, no
  training. The documented "dead AUX" is actually a **dead hpd-forwarding hop**
  (oob_hotplug_event → drm_aux_bridge → msm_dp bridge), orientation-correlated by a mechanism
  not yet visible; the nb7 guards were not the live culprit. Evidence:
  `~/etk/manual_forensics/reverse_aux_drmdebug_20260808.txt`. #4/#5 stay (correct hygiene;
  #4's race is real) — the reverse fix is a follow-up patch in the forwarding layer (=y).
- **Pads**: InputPlumber + ES alive through every arm (healer stopped mid-session for the
  clean storm; no reboot needed at any point).
- Legend for this hardware: the Anker C→HDMI adapter maps **logo-down = normal (works),
  logo-up = reverse (dead)**; the Retroid charge cable maps logo-up = reverse. Per-cable,
  probe is truth.

## P2 — kernel-native mirroring on SM8250: verdict = not a patch, a feature port

Investigated for the 2026-08-07 session brief and closed with a source-level answer:

- The SM8250 DPU catalog exposes **WB_2, a capture writeback block** (advertised 2560-wide,
  hardware 4096, linear-only, RGB + NV12) and **no CWB (concurrent writeback) block at all** —
  `possible_clones` is never even computed on this SoC (`dpu_kms.c` gates it on
  `catalog->cwb_count`, which only SM8650-and-newer catalogs define).
- Upstream dpu "clone mode" pairs exactly one real-time encoder with one **writeback** encoder
  (`dpu_encoder_get_clones()` matches `DRM_MODE_ENCODER_VIRTUAL` ↔ `DSI` only; DP/TMDS is
  explicitly excluded with an upstream TODO) — i.e. clone mode is *mirror-into-memory*, not two
  live outputs.
- One CRTC driving two live interfaces (DSI + DP) has **no implementation anywhere in the
  tree**, and the CWB hardware the current implementation leans on is absent on this silicon.

So a kernel-side "clone the panel to DP" is a feature port against missing hardware support —
out of this lane's scope. The `Writeback-1` connector is real and usable for *capture* by a
compositor-side consumer (a sway/wlroots lane, if ever). The supported posture stands:
record-only capture is the capture path; wl-mirror becomes reliable as the P0/P1b fixes land.
