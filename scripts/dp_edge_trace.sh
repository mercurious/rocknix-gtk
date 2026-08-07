#!/bin/bash
# ROCKNIX-GTK DP hotplug harness — live edge tracer. READ-ONLY over ssh.
#
# Run in a second terminal for the duration of every protocol step (see
# scripts/dp_plug_protocol.md). Streams the kernel journal PLUS the InputPlumber
# unit journal (the udev-storm victim) through one filter, teeing raw lines to
# ~/etk/manual_forensics/dp_trace_<epoch>.log so a wedge is captured the moment
# it happens instead of reconstructed after.
#
# journalctl match semantics: fields of different types AND together, so kernel
# transport and the unit filter must be OR'd with the '+' separator — plain
# `-k -u inputplumber` silently matches nothing.
set -u
RIG="${RIG:-root@SM8250.local}"
OUT="${DP_TRACE_OUT:-$HOME/etk/manual_forensics/dp_trace_$(date +%s).log}"

echo "dp_edge_trace: streaming to $OUT (Ctrl-C to stop)"
ssh -o ConnectTimeout=8 -o BatchMode=yes "$RIG" \
  'journalctl -f -o short-monotonic _TRANSPORT=kernel + _SYSTEMD_UNIT=inputplumber.service' \
  | grep --line-buffered -iE 'typec|tcpm|nb7|15-001c|msm_dp|dp_display|dp_ctrl|dpu|drm|usb 1-1|xhci|inputplumber|Removed device' \
  | tee "$OUT"
