#!/bin/bash
# ROCKNIX-GTK §4.4 boot-gate check — READ-ONLY over ssh, run after the operator's
# on-device cold boot. Automates the mechanical half of the gate; the second half
# (etk_drift.py bank + one warm GT5P session with a normal ledger row) is listed,
# not automated, per the verdict-from-the-operator's-screen doctrine.
set -u
RIG="${RIG:-root@SM8250.local}"
EXPECTED_SHA="${1:-}"

echo "=== ROCKNIX-GTK boot gate (read-only) ==="
ssh "$RIG" '
  echo "--- uname -a (expect: 7.0.11 #1 SMP PREEMPT; builder @rocknix-gtk = OUR build live)"
  uname -a
  echo "--- uptime (expect fresh boot)"
  uptime
  echo "--- /flash/KERNEL sha256"
  sha256sum /flash/KERNEL
  echo "--- modules: loaded / shipped (baseline 27 / 236)"
  lsmod | wc -l; find /usr/lib/modules/7.0.11 -name "*.ko*" | wc -l
  echo "--- fallback entries in grub twins (expect 2)"
  grep -c etk-fallback-stock /flash/EFI/BOOT/grub.cfg /flash/boot/grub/grub.cfg
  echo "--- audio card (known 1-in-4 probe-race flake, separate issue)"
  head -3 /proc/asound/cards 2>/dev/null || echo "NO SOUNDCARD (probe race? revive: echo 3370000.codec > /sys/bus/platform/drivers_probe)"
  echo "--- etk sentry"
  systemctl is-active etk.service 2>/dev/null
  echo "--- dmesg error sweep (first 15)"
  dmesg | grep -iE "fail|error|panic" | grep -viE "thermal|EDID|deferred" | head -15
'
if [ -n "$EXPECTED_SHA" ]; then
  LIVE_SHA=$(ssh "$RIG" 'sha256sum /flash/KERNEL' | cut -d' ' -f1)
  if [ "$LIVE_SHA" = "$EXPECTED_SHA" ]; then echo "KERNEL SHA: MATCH ($LIVE_SHA)"; else echo "KERNEL SHA: MISMATCH live=$LIVE_SHA expected=$EXPECTED_SHA"; fi
fi
cat <<'EOF'

Remaining gate items (manual):
  1. tools/etk_drift.py — bank the OS profile for this boot
  2. One warm GT5P session -> graceful exit -> normal ledger row
Only after ALL items pass does the pipeline count as proven (then: KGSL parity patch).
EOF
