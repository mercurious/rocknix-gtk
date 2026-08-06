#!/usr/bin/env bash
#
# provision-build-container.sh
#
# Create the `rocknix-gtk-kernel-sid` kernel build container on any arm64 Linux
# Docker host — the laptop's colima VM, or a remote box like etk-cloud.
#
# WHY THIS EXISTS: until 2026-08-05 the container's exact dependency set lived
# only inside the containers themselves. BUILDING.md documented one line of it
# (`build-essential gcc-15`) and the rest was whatever had been apt-installed by
# hand months earlier. A fresh box could not be brought to a buildable state
# from the repo alone. The package list below is `dpkg-query` from the container
# that built the shipping artifacts — keep it in sync with that, not with docs.
#
# WHAT IT DOES NOT GIVE YOU: toolchain parity across hosts. `sid` moves. On
# 2026-08-05 the laptop container held gcc 15.3.0-1 / binutils 2.46.50 while a
# freshly provisioned etk-cloud container got gcc 15.3.0-2 / binutils 2.47. Both
# satisfy the toolchain law (gcc >= 15, binutils >= 2.44), but they are DIFFERENT
# combinations, and BUILDING.md is explicit: any combination other than the
# validated one is unvalidated by definition and must clear the section 7
# cold-boot gate before it is trusted, however clean the verify.
#
# Usage:
#   scripts/provision-build-container.sh                       # local docker
#   ETK_BUILD_HOST=etk-cloud scripts/provision-build-container.sh
#
# Overrides: ETK_BUILD_HOST  CONTAINER  IMAGE  VOLUME  REPO_DIR
#
# Idempotent: re-running against an existing container only re-checks packages
# and re-syncs staging.
set -euo pipefail

ETK_BUILD_HOST="${ETK_BUILD_HOST:-}"          # empty = local docker
CONTAINER="${CONTAINER:-rocknix-gtk-kernel-sid}"
IMAGE="${IMAGE:-debian:sid}"
VOLUME="${VOLUME:-rocknix-gtk-kernel-build}"
# Where this repo lives ON THE BUILD HOST (bind-mounted read-write at /work).
REPO_DIR="${REPO_DIR:-}"

# The dep set is not guessed — it is dpkg-query from the container that has been
# producing shipped kernels. gcc-15 rides alongside sid's default compiler; the
# build scripts pin CC to it deliberately (see the toolchain law in BUILDING.md).
PKGS="bc bison build-essential cpio flex gcc-15 kmod libelf-dev libssl-dev
      python3 rsync xz-utils"
PKGS="$(printf '%s' "$PKGS" | tr -s '[:space:]' ' ')"

host_sh() {
  if [ -n "$ETK_BUILD_HOST" ]; then
    ssh -o BatchMode=yes -o ConnectTimeout=15 "$ETK_BUILD_HOST" "bash -s"
  else
    bash -s
  fi
}

if [ -z "$REPO_DIR" ]; then
  if [ -n "$ETK_BUILD_HOST" ]; then
    REPO_DIR="/home/ubuntu/rocknix-gtk"
  else
    REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
fi

echo ">> Target: ${ETK_BUILD_HOST:-local docker}   container=${CONTAINER}  repo=${REPO_DIR}"

host_sh <<REMOTE
set -euo pipefail
command -v docker >/dev/null || { echo "ERROR: docker not found on this host." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: docker daemon unreachable." >&2; exit 1; }

arch=\$(uname -m)
[ "\$arch" = "aarch64" ] || [ "\$arch" = "arm64" ] || \
  echo "WARNING: host arch is \$arch, not aarch64 — cross-building is not this lane's contract." >&2

[ -d "${REPO_DIR}/staging" ] || { echo "ERROR: no staging/ at ${REPO_DIR} on the build host." >&2; exit 1; }

docker volume create "${VOLUME}" >/dev/null

if docker ps -a --format '{{.Names}}' | grep -qx "${CONTAINER}"; then
  echo ">> Container ${CONTAINER} exists; starting it"
  docker start "${CONTAINER}" >/dev/null
else
  echo ">> Creating ${CONTAINER} from ${IMAGE}"
  docker pull -q "${IMAGE}" >/dev/null
  # /kernel is a VOLUME, not a bind mount: the build writes multi-GB trees and
  # logs, and they must not land in the repo checkout.
  docker run -d --name "${CONTAINER}" \
    -v "${VOLUME}":/kernel \
    -v "${REPO_DIR}":/work \
    -w /kernel "${IMAGE}" sleep infinity >/dev/null
fi

echo ">> Installing build dependencies (idempotent)"
docker exec "${CONTAINER}" bash -lc '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq --no-install-recommends ${PKGS} >/dev/null
'

echo ">> Syncing staging into /kernel"
docker exec "${CONTAINER}" bash -lc '
  rsync -a --delete /work/staging/ /kernel/staging/
  # The build scripts extract the tarball from /kernel, not /kernel/staging.
  for t in /kernel/staging/linux-*.tar.xz; do
    [ -e "\$t" ] || continue
    b=\$(basename "\$t")
    [ -f "/kernel/\$b" ] || cp "\$t" "/kernel/\$b"
  done
'

echo ">> Toolchain in ${CONTAINER}:"
docker exec "${CONTAINER}" bash -lc '
  printf "     %-10s %s\n" gcc-15 "\$(gcc-15 -dumpfullversion 2>/dev/null)"
  printf "     %-10s %s\n" binutils "\$(ld --version | head -1 | awk "{print \\\$NF}")"
  printf "     %-10s %s\n" default-gcc "\$(gcc -dumpfullversion 2>/dev/null)"
'
REMOTE

echo ">> Done. Build with:  docker exec ${CONTAINER} bash /work/scripts/build_712.sh"
