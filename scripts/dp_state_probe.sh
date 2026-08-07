#!/bin/bash
# ROCKNIX-GTK DP hotplug harness — connector-state validator. READ-ONLY over ssh.
#
# The round-2 law from the 2026-08-07 teardown: typec sysfs + DRM status must AGREE
# with physical reality before ANY DP test result is interpreted. The operator
# declares physical truth as the argument; this script reads every layer and issues
# an explicit AGREE/DISAGREE verdict. Exit 0 = AGREE, 1 = DISAGREE (wedge or dead
# link — capture scripts/dp_edge_trace.sh output before touching anything), 2 = usage.
#
# Declared states describe the DP sink cable/dock (not chargers):
#   out      cable physically removed
#   normal   dock plugged, connector "right way up" (Type-C normal orientation)
#   reverse  dock plugged, connector flipped
#
# Kernel-topology notes (baseline 2026-08-07, kernel 7.1.2 / -0.3.1):
#   - tcpm ring log lives at /sys/kernel/debug/usb/tcpm-*/log on this kernel, and it
#     is DRAIN-ON-READ (tcpm_debug_show advances logbuffer_tail): every read consumes
#     the entries, so each probe shows exactly the events since the previous probe.
#     An empty tail between events is normal — never read it from two places at once.
#   - nb7vpq904m (15-001c) regmap debugfs has no read-back (all XX) — AUX_CC is NOT
#     directly observable; reverse-orientation health is a behavioral verdict (DP-1
#     status) only.
#   - healthy detached orientation reads "unknown" (TYPEC_ORIENTATION_NONE); a
#     normal/reverse reading with no partner is the phantom-cable wedge signature.
set -u
RIG="${RIG:-root@SM8250.local}"
DECLARED="${1:-}"
case "$DECLARED" in out|normal|reverse) ;; *) echo "usage: $0 <out|normal|reverse>"; exit 2 ;; esac

STATE=$(ssh -o ConnectTimeout=8 -o BatchMode=yes "$RIG" '
  ORIENT=$(cat /sys/class/typec/port0/orientation 2>/dev/null || echo READ-FAIL)
  PARTNER=absent; [ -e /sys/class/typec/port0-partner ] && PARTNER=present
  ALTMODES=$(ls -d /sys/class/typec/port0-partner/port0-partner.* 2>/dev/null | wc -l)
  DP=$(cat /sys/class/drm/card0-DP-1/status 2>/dev/null || echo READ-FAIL)
  USB11=absent; [ -e /sys/bus/usb/devices/1-1 ] && USB11=present
  PADS_IP=$(systemctl is-active inputplumber 2>/dev/null)
  PADS_ES=$(systemctl is-active essway 2>/dev/null)
  echo "ORIENT=$ORIENT PARTNER=$PARTNER ALTMODES=$ALTMODES DP=$DP USB11=$USB11 IP=$PADS_IP ES=$PADS_ES"
  echo "--- tcpm log tail ---"
  tail -12 /sys/kernel/debug/usb/tcpm-*/log 2>/dev/null || echo "(no tcpm log)"
  echo "--- last usb 1-1 dmesg ---"
  dmesg | grep "usb 1-1" | tail -3
' 2>&1) || { echo "PROBE: rig unreachable"; exit 2; }

echo "=== dp_state_probe: declared physical state: $DECLARED ==="
echo "$STATE"
eval "$(echo "$STATE" | head -1)"

VERDICT=AGREE; TAGS=""
case "$DECLARED" in
  out)
    [ "$PARTNER" = present ]  && { VERDICT=DISAGREE; TAGS="$TAGS PHANTOM-PARTNER"; }
    [ "$DP" = connected ]     && { VERDICT=DISAGREE; TAGS="$TAGS PHANTOM-DP"; }
    [ "$USB11" = present ]    && { VERDICT=DISAGREE; TAGS="$TAGS PHANTOM-HID"; }
    case "$ORIENT" in normal|reverse) VERDICT=DISAGREE; TAGS="$TAGS STALE-ORIENTATION";; esac
    [ "$VERDICT" = DISAGREE ] && TAGS="$TAGS WEDGE-SIGNATURE"
    ;;
  normal|reverse)
    [ "$PARTNER" = absent ]        && { VERDICT=DISAGREE; TAGS="$TAGS NO-PARTNER"; }
    [ "$ORIENT" != "$DECLARED" ]   && { VERDICT=DISAGREE; TAGS="$TAGS ORIENTATION-MISMATCH($ORIENT)"; }
    if [ "$DP" != connected ]; then
      VERDICT=DISAGREE
      [ "$DECLARED" = reverse ] && TAGS="$TAGS REVERSE-DEAD-AUX" || TAGS="$TAGS DP-LINK-DEAD"
    fi
    ;;
esac
[ "$IP" != active ] && { VERDICT=DISAGREE; TAGS="$TAGS INPUTPLUMBER-DOWN"; }
[ "$ES" != active ] && { VERDICT=DISAGREE; TAGS="$TAGS ESSWAY-DOWN"; }

echo "=== VERDICT: $VERDICT${TAGS:+ —$TAGS} ==="
[ "$VERDICT" = AGREE ]
