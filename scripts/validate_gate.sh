#!/bin/bash
# ROCKNIX-GTK §4.4 boot-gate check — READ-ONLY over ssh, run after the operator's
# on-device cold boot. Automates the mechanical half of the gate; the second half
# (etk_drift.py bank + one warm GT5P session with a normal ledger row) is listed,
# not automated, per the verdict-from-the-operator's-screen doctrine.
set -u
RIG="${RIG:-root@SM8250.local}"
EXPECTED_SHA="${1:-}"

echo "=== ROCKNIX-GTK boot gate (read-only) ==="
# The booted image is whatever GRUB named in BOOT_IMAGE (last wins, exactly as the
# initramfs parses it) -- under the twin-entry scheme that is KERNEL.gtktest, NOT
# /flash/KERNEL (stock). The 7.0.11-era version of this gate hashed /flash/KERNEL
# and counted modules under a hard-coded 7.0.11 dir: a correct GTK boot read as
# MISMATCH with 0 modules (fixed 2026-09-26, before the 0.5.1 gate).
BOOTED='K=KERNEL; for a in $(cat /proc/cmdline); do case $a in BOOT_IMAGE=*) K=${a#BOOT_IMAGE=}; K=${K#/};; esac; done'
ssh "$RIG" "$BOOTED"'
  echo "--- uname -a (expect builder @rocknix-gtk = OUR build live)"
  uname -a
  echo "--- uptime (expect fresh boot)"
  uptime
  echo "--- booted image: /flash/$K"
  sha256sum "/flash/$K"
  echo "--- anti-lock (expect cmdline msm.context_keepalive=1 and the param set)"
  grep -o "msm.context_keepalive=[^ ]*" /proc/cmdline || echo "NOT on cmdline"
  cat /sys/module/msm/parameters/context_keepalive 2>/dev/null || echo "param absent"
  echo "--- modules for $(uname -r): loaded / shipped"
  lsmod | wc -l; find "/usr/lib/modules/$(uname -r)" -name "*.ko*" | wc -l
  echo "--- fallback entries in grub twins (expect 2; GRUB era only)"
  grep -c etk-fallback-stock /flash/EFI/BOOT/grub.cfg /flash/boot/grub/grub.cfg
  echo "--- #9 charger (expect 1061: 26 / 1070: 50; 6b / 7a = fix NOT live)"
  for d in /sys/kernel/debug/regmap/*0-02*; do [ -r "$d/registers" ] && grep -m2 -E "^(1061|1070): " "$d/registers"; done
  echo "--- audio card (known 1-in-4 probe-race flake, separate issue)"
  head -3 /proc/asound/cards 2>/dev/null || echo "NO SOUNDCARD (probe race? revive: echo 3370000.codec > /sys/bus/platform/drivers_probe)"
  echo "--- etk sentry"
  systemctl is-active etk.service 2>/dev/null
  echo "--- dmesg error sweep (first 15)"
  dmesg | grep -iE "fail|error|panic" | grep -viE "thermal|EDID|deferred" | head -15
'
if [ -n "$EXPECTED_SHA" ]; then
  LIVE_SHA=$(ssh "$RIG" "$BOOTED"'; sha256sum "/flash/$K"' | cut -d' ' -f1)
  if [ "$LIVE_SHA" = "$EXPECTED_SHA" ]; then echo "BOOTED KERNEL SHA: MATCH ($LIVE_SHA)"; else echo "BOOTED KERNEL SHA: MISMATCH live=$LIVE_SHA expected=$EXPECTED_SHA"; fi
fi
cat <<'EOF'

Remaining gate items (manual):
  1. tools/etk_drift.py — bank the OS profile for this boot
  2. One warm GT5P session -> graceful exit -> normal ledger row
Only after ALL items pass does the kernel count as proven.
EOF
