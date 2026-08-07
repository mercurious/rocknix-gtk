# DP plug/unplug protocol — single-variable discipline

The discipline the 2026-08-07 teardown lacked, encoded. Every step is:

```
dp_state_probe.sh <declared>   # pre-probe: layers must AGREE before acting
<ONE physical action>
<35 s dwell>                   # straddles the ~30 s phantom-HID flap cycle
dp_state_probe.sh <declared>   # post-probe
```

Rules:
- **One variable per step.** Never combine a plug with a launch, a flip, or a restart.
- **DISAGREE freezes the protocol.** Keep `dp_edge_trace.sh` running in a second
  terminal from before the first step; on DISAGREE, save its output and the probe
  output BEFORE touching anything (no heals, no restarts — evidence first).
- Gamepad check after every arm: pads respond in ES (or in-game). `INPUTPLUMBER-DOWN`
  in a probe verdict is a protocol-stopping event, not a nuisance.
- The operator performs every physical action and every reboot. Probes are read-only.

## Arms (in order)

| # | Arm | Steps | Discriminates |
|---|-----|-------|---------------|
| 1 | at-ES plug/unplug, normal | out→normal→out | baseline hotplug path |
| 2 | at-ES plug/unplug, reverse | out→reverse→out | **reverse-orientation dead-AUX** (pre-patch: expect `REVERSE-DEAD-AUX`; post-Build-A: expect AGREE) |
| 3 | in-game plug/unplug, normal | launch GT5P → out→normal→out → exit | **P1b commit stall** (pre-Build-B: expect freeze; post: both screens live, worst case dark DP + `DP enable:` dmesg line) |
| 4 | flap-storm | 5× plug/unplug at ~2 s cadence, then `dp_state_probe.sh out` ×3 across 35 s dwells | **P0 wedge** (pre-Build-A: expect `PHANTOM-*`/`WEDGE-SIGNATURE`; post: AGREE ×3, no `usb 1-1` phantom) |
| 5 | plug-before-boot | dock attached → operator cold boot → probe `normal` | boot-time attach path (no dedicated patch; evidence decides follow-up) |
| 6 | audio tone (Boot C only) | see Boot C checklist | S24 root fix vs S16 reference |

## Per-boot validation checklists

**Boot A (`-0.4`, typec cluster #3+#4+#5):** `validate_gate.sh <sha>` basics → charging +
USB sanity (plug charger both ways; charge indicator both times) → arms 1, 2, 4
(arm 2 is the headline: reverse DP must link) → pads alive after everything →
arm 3 EXPECTED STILL FREEZY (P1b unpatched — record honestly, do not chase).

**Boot B (`-0.4.1`, + #6+#7):** arms 1–4 all green ×3 reps; arm 3 is the headline
(no compositor freeze in-game; `no encoder found for crtc` dmesg count = 0 across the
matrix). A/B attribution knob: `echo 0 > /sys/module/msm/parameters/dp_enable_lock_timeout_ms`
restores stock unbounded waiting live.

**Boot C (`-0.4.2`, + #8):** S16 tone at clipping roof FIRST (proves the 16-bit wire
path is untouched) → operator lifts the S16 pin for the session → S24 tone A/B vs the
S16 roof (the −25 dB gap must be gone) → restore pin. Pin retirement is a follow-up
session even on success.
