#!/bin/bash
# stock_gcc.sh — THE TOOLCHAIN LAW, read from stock instead of hard-coded (2026-10-31).
#
# The kernel is boot-sensitive to the compiler: a gcc-14 build of a stock-identical tree
# verified clean and black-screened the rig pre-userspace (VALIDATION.md, 2026-07-05) while
# gcc-15 -- stock's compiler major at the time -- booted first try. The law was written as
# "gcc-15"; its reason was "match stock". ROCKNIX 20261101 moved to gcc 16.2.0, so the law
# now reads itself out of the ground truth: the compiler major is CONFIG_GCC_VERSION's,
# carved from the stock KERNEL's own IKCONFIG (scripts/ikconfig.py). 20260901/20261001 lanes
# resolve to gcc-15, 20261101+ to gcc-16; a future stock bump changes nothing here.
# Operator decision 2026-10-31 (UPSTREAM_20261101.md §5): parity over the letter.
#
#   stock_gcc.sh <stock .config>            -> prints gcc-<major> (e.g. gcc-16), exit 0
#   stock_gcc.sh <stock .config> --check CC -> exit 0 if `CC -dumpfullversion` has that major,
#                                              exit 1 with the mismatch spelled out
# Exit 2: the config has no parseable CONFIG_GCC_VERSION (not a kernel config, or clang).
set -u
CFG="${1:-}"; [ -f "$CFG" ] || { echo "stock_gcc: usage: $0 <stock .config> [--check <cc>]" >&2; exit 2; }
V=$(sed -n 's/^CONFIG_GCC_VERSION=\([0-9]\+\)$/\1/p' "$CFG" | head -1)
case "$V" in
  [0-9][0-9][0-9][0-9][0-9]|[0-9][0-9][0-9][0-9][0-9][0-9]) ;;   # MMmmpp or Mmmpp
  *) echo "stock_gcc: no CONFIG_GCC_VERSION in $CFG (got '${V:-}'): stock was not built with gcc, or this is not a kernel .config" >&2; exit 2 ;;
esac
MAJOR=$(( V / 10000 ))
TEXT=$(sed -n 's/^CONFIG_CC_VERSION_TEXT="\(.*\)"$/\1/p' "$CFG" | head -1)
if [ "${2:-}" = "--check" ]; then
  CC="${3:?--check needs a compiler}"
  GOT=$("$CC" -dumpfullversion 2>/dev/null || "$CC" -dumpversion 2>/dev/null || echo none)
  case "$GOT" in
    "$MAJOR".*) echo "stock_gcc: $CC is $GOT, stock is ${TEXT:-gcc $V} -- same major ($MAJOR), parity holds"; exit 0 ;;
    *) echo "stock_gcc: $CC is $GOT but stock is built with ${TEXT:-gcc $V} (major $MAJOR) -- toolchain parity BROKEN; the failure mode is a silent pre-userspace black screen. Install gcc-$MAJOR in the container, or set KCC=... deliberately." >&2; exit 1 ;;
  esac
fi
echo "gcc-$MAJOR"
