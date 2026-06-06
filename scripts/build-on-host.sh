#!/usr/bin/env bash
# Build nvidia.raw on the TrueNAS host inside a transient docker container.
#
# Wraps scripts/build-nvidia-sysext.sh so it can run on a TrueNAS host (which
# has docker for Apps but no build toolchain). The .raw produced never leaves
# the user's machine — this repo no longer ships nvidia.raw on releases (NVIDIA
# EULA §2.7 prohibits redistributing the proprietary userspace). The user
# accepts NVIDIA's EULA when build-nvidia-sysext.sh invokes the .run installer
# with --silent.
#
# Usage:
#   sudo scripts/build-on-host.sh \
#        --nvidia-version=595.58.03 \
#        --truenas-version=25.10.3.1 \
#        [--truenas-codename=Goldeye] \
#        [--kernel-module-type=open|proprietary] \
#        [--run-file=/path/to/NVIDIA-Linux-x86_64-VER-no-compat32.run] \
#        [--cache-dir=/mnt/<pool>/.config/nvidia-gpu/cache] \
#        [--scripts-dir=/path/to/scripts] \
#        --out=/path/to/nvidia.raw
#
# Caches between runs (in --cache-dir, defaults to /var/cache/nvidia-build):
#   truenas-<version>.update    — ~1.5 GB, per TrueNAS version
#   NVIDIA-Linux-x86_64-*.run   — ~400 MB, per driver version
#   These survive across rebuilds; deleting the cache dir is safe.
#
# Output:
#   <--out>           — nvidia.raw built for the running kernel
#   <--out>.sha256
#
# Docker daemon: starts it if stopped, tracks original state, restores on exit.
# Image: pulls ubuntu:24.04 once; subsequent runs reuse.

set -euo pipefail

NVIDIA_VERSION=""
TRUENAS_VERSION=""
TRUENAS_CODENAME=""
KERNEL_MODULE_TYPE="open"
RUN_FILE_OVERRIDE=""
CACHE_DIR="/var/cache/nvidia-build"
SCRIPTS_DIR=""
OUT_FILE=""
DOCKER_IMAGE="ubuntu:24.04"

for arg in "$@"; do
    case "$arg" in
        --nvidia-version=*)     NVIDIA_VERSION="${arg#*=}" ;;
        --truenas-version=*)    TRUENAS_VERSION="${arg#*=}" ;;
        --truenas-codename=*)   TRUENAS_CODENAME="${arg#*=}" ;;
        --kernel-module-type=*) KERNEL_MODULE_TYPE="${arg#*=}" ;;
        --run-file=*)           RUN_FILE_OVERRIDE="${arg#*=}" ;;
        --cache-dir=*)          CACHE_DIR="${arg#*=}" ;;
        --scripts-dir=*)        SCRIPTS_DIR="${arg#*=}" ;;
        --out=*)                OUT_FILE="${arg#*=}" ;;
        --docker-image=*)       DOCKER_IMAGE="${arg#*=}" ;;
        -h|--help)
            sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ERROR: unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ "$(id -u)" = "0" ] || { echo "ERROR: must run as root (docker socket access)" >&2; exit 1; }
[ -n "$NVIDIA_VERSION" ]  || { echo "ERROR: --nvidia-version=X.Y.Z required" >&2; exit 1; }
[ -n "$TRUENAS_VERSION" ] || { echo "ERROR: --truenas-version=X.Y.Z required" >&2; exit 1; }
[ -n "$OUT_FILE" ]        || { echo "ERROR: --out=PATH required" >&2; exit 1; }

# Resolve SCRIPTS_DIR to where build-nvidia-sysext.sh lives. Default: same
# directory as this script. Allows curl|bash callers to point at a checkout
# without env trickery.
if [ -z "$SCRIPTS_DIR" ]; then
    SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi
[ -f "${SCRIPTS_DIR}/build-nvidia-sysext.sh" ] \
    || { echo "ERROR: build-nvidia-sysext.sh not found at ${SCRIPTS_DIR}/" >&2; exit 1; }

# Resolve OUT_FILE to absolute so docker bind-mount can target its parent.
OUT_DIR="$(dirname "$OUT_FILE")"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
OUT_NAME="$(basename "$OUT_FILE")"
OUT_FILE="${OUT_DIR}/${OUT_NAME}"

info()   { echo "[build-on-host] $*"; }
warn()   { echo "[build-on-host] WARN: $*" >&2; }
die()    { echo "[build-on-host] FATAL: $*" >&2; exit 1; }
banner() { printf "\n==========================================================\n  %s\n==========================================================\n\n" "$*"; }

command -v docker >/dev/null 2>&1 \
    || die "docker not found in PATH — TrueNAS Apps requires it; if you've never enabled Apps, install it or run the build elsewhere"

# ─────────────────────────────────────────────────────────────────────────
# Docker daemon: start if stopped, remember to restore on exit.
# TrueNAS Apps users already have it running; headless-no-Apps users have
# it installed but not started. Least-surprise: leave it in whatever state
# we found it.
# ─────────────────────────────────────────────────────────────────────────
DOCKER_WAS_RUNNING=true
if ! docker info >/dev/null 2>&1; then
    DOCKER_WAS_RUNNING=false
    info "docker daemon not running; starting it for the build"
    systemctl start docker 2>/dev/null || die "failed to start docker"
    # Poll for readiness; docker info exit 0 = up
    for _ in $(seq 1 30); do
        docker info >/dev/null 2>&1 && break
        sleep 1
    done
    docker info >/dev/null 2>&1 || die "docker did not become ready within 30s"
fi

restore_docker_state() {
    if ! $DOCKER_WAS_RUNNING; then
        info "stopping docker daemon (was stopped before this build)"
        systemctl stop docker 2>/dev/null || warn "failed to stop docker"
    fi
}
trap restore_docker_state EXIT

# ─────────────────────────────────────────────────────────────────────────
# Cache setup. Update + run files survive between runs.
# ─────────────────────────────────────────────────────────────────────────
mkdir -p "$CACHE_DIR" || die "could not create cache dir: $CACHE_DIR"
UPDATE_CACHE="${CACHE_DIR}/truenas-${TRUENAS_VERSION}.update"
RUN_BASENAME="NVIDIA-Linux-x86_64-${NVIDIA_VERSION}-no-compat32.run"
RUN_CACHE="${CACHE_DIR}/${RUN_BASENAME}"

# If user passed --run-file, stage it into cache under the canonical name
# so the build script's Phase 3 "already present, skipping download" branch
# fires inside the container. cp -L follows symlinks.
if [ -n "$RUN_FILE_OVERRIDE" ]; then
    [ -f "$RUN_FILE_OVERRIDE" ] || die "--run-file not found: $RUN_FILE_OVERRIDE"
    if [ "$(readlink -f "$RUN_FILE_OVERRIDE")" != "$(readlink -f "$RUN_CACHE" 2>/dev/null || echo)" ]; then
        info "staging --run-file → ${RUN_CACHE}"
        cp -L "$RUN_FILE_OVERRIDE" "$RUN_CACHE"
        chmod +x "$RUN_CACHE"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Pull the build image if not present.
# ─────────────────────────────────────────────────────────────────────────
if ! docker image inspect "$DOCKER_IMAGE" >/dev/null 2>&1; then
    banner "Pulling $DOCKER_IMAGE (one-time, ~80 MB compressed)"
    docker pull "$DOCKER_IMAGE" || die "failed to pull $DOCKER_IMAGE"
fi

# ─────────────────────────────────────────────────────────────────────────
# Run the build in a transient container.
#
# Layout inside the container:
#   /work/scripts     ← repo scripts (read-only)
#   /work/cache       ← persistent cache (truenas.update + .run file)
#   /work/out         ← output dir (we copy nvidia.raw out)
#
# build-nvidia-sysext.sh uses /tmp/{stage1,rootfs,nvidia_build,staging,truenas.update}
# inside the container — those are container-ephemeral and disappear on --rm.
# We bridge:
#   /work/cache/truenas-<ver>.update  →  /tmp/truenas.update (--update-file=)
#   /work/cache/NVIDIA-Linux-...run   →  /tmp/nvidia_build/NVIDIA-Linux-...run
#                                        (placed before build script runs;
#                                         skips Phase 3 download)
# ─────────────────────────────────────────────────────────────────────────

# Build-time deps for the script's Phase 4 cross-compile and squashfs ops.
# These are not on a fresh ubuntu:24.04; ~250 MB of packages, ~2 min the
# first time per container. Pre-baking a base image is a future optimization.
APT_INSTALL='apt-get update -qq && apt-get install -y --no-install-recommends \
    build-essential gcc-14 squashfs-tools kmod xz-utils \
    bison flex libelf-dev bc rsync libssl-dev pkg-config \
    pciutils gnupg ca-certificates wget curl'

# Build the inner command. Stages cache → expected build paths before
# invoking the build script.
BUILD_ARGS=(
    --nvidia-version="$NVIDIA_VERSION"
    --truenas-version="$TRUENAS_VERSION"
    --kernel-module-type="$KERNEL_MODULE_TYPE"
    --out=/work/out
)
[ -n "$TRUENAS_CODENAME" ] && BUILD_ARGS+=(--truenas-codename="$TRUENAS_CODENAME")

INNER_SCRIPT=$(cat <<EOF
set -euo pipefail
${APT_INSTALL}

# Stage cached TrueNAS .update if present (build script's --update-file=
# skips its own download phase).
EXTRA_ARGS=()
if [ -f /work/cache/$(basename "$UPDATE_CACHE") ]; then
    cp /work/cache/$(basename "$UPDATE_CACHE") /tmp/truenas.update
    EXTRA_ARGS+=(--update-file=/tmp/truenas.update)
fi

# Stage cached NVIDIA .run if present (build script's Phase 3 picks up
# any file already at \$BUILD_DIR/NVIDIA-Linux-x86_64-*-no-compat32.run).
mkdir -p /tmp/nvidia_build
if [ -f /work/cache/${RUN_BASENAME} ]; then
    cp /work/cache/${RUN_BASENAME} /tmp/nvidia_build/${RUN_BASENAME}
    chmod +x /tmp/nvidia_build/${RUN_BASENAME}
fi

/work/scripts/build-nvidia-sysext.sh "\${EXTRA_ARGS[@]}" \\
    --nvidia-version=${NVIDIA_VERSION} \\
    --truenas-version=${TRUENAS_VERSION} \\
    --kernel-module-type=${KERNEL_MODULE_TYPE}${TRUENAS_CODENAME:+ \\
    --truenas-codename=${TRUENAS_CODENAME}} \\
    --out=/work/out

# Backfill cache with anything the build downloaded.
[ -f /tmp/truenas.update ] && cp /tmp/truenas.update /work/cache/$(basename "$UPDATE_CACHE") || true
[ -f /tmp/nvidia_build/${RUN_BASENAME} ] && cp /tmp/nvidia_build/${RUN_BASENAME} /work/cache/${RUN_BASENAME} || true
EOF
)

banner "Building nvidia.raw inside $DOCKER_IMAGE (≈ 8 min on first run)"
info "  NVIDIA driver  : $NVIDIA_VERSION ($KERNEL_MODULE_TYPE)"
info "  TrueNAS version: $TRUENAS_VERSION${TRUENAS_CODENAME:+ ($TRUENAS_CODENAME)}"
info "  Cache dir      : $CACHE_DIR"
info "  Output         : $OUT_FILE"

docker run --rm \
    -v "${SCRIPTS_DIR}:/work/scripts:ro" \
    -v "${CACHE_DIR}:/work/cache" \
    -v "${OUT_DIR}:/work/out" \
    -e DEBIAN_FRONTEND=noninteractive \
    "$DOCKER_IMAGE" \
    bash -c "$INNER_SCRIPT" \
    || die "container build failed — see output above"

[ -f "${OUT_DIR}/nvidia.raw" ] \
    || die "build claimed success but ${OUT_DIR}/nvidia.raw is missing"

# Rename to user-requested filename if it differs from the default.
if [ "$OUT_NAME" != "nvidia.raw" ]; then
    mv "${OUT_DIR}/nvidia.raw" "$OUT_FILE"
    [ -f "${OUT_DIR}/nvidia.raw.sha256" ] \
        && mv "${OUT_DIR}/nvidia.raw.sha256" "${OUT_FILE}.sha256"
fi

banner "Build complete"
info "  Output : $OUT_FILE ($(du -h "$OUT_FILE" | cut -f1))"
[ -f "${OUT_FILE}.sha256" ] && info "  SHA256 : $(cut -d' ' -f1 "${OUT_FILE}.sha256")"
