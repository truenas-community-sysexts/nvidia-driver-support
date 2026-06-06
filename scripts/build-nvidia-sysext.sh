#!/usr/bin/env bash
# Build a driver-only nvidia.raw sysext for TrueNAS — replaces the stock
# nvidia sysext with a chosen NVIDIA driver version. Drives any driver
# branch: a current open driver, a legacy branch (470/580/390/340) for a
# card TrueNAS no longer ships a driver for, or a patched/custom .run.
# See install-nvidia-driver.sh, which picks the version and invokes this.
#
# Port of https://github.com/biohazardious/truenas-nvidia-driver-updater
# entrypoint.sh, adapted to run directly on a fresh Debian/Ubuntu host
# (e.g. a GitHub Actions ubuntu-24.04 runner) — no Docker required.
#
# Installer flags are selected per driver branch: pre-515 legacy installers
# predate the open/proprietary split (--kernel-module-type) and some newer
# flags, so the set passed to the .run is filtered against its own --help.
# See select_installer_flags() below.
#
# Usage:
#   sudo scripts/build-nvidia-sysext.sh \
#        --nvidia-version=570.172.08 \
#        --truenas-version=25.10.3.1 \
#        [--kernel-module-type=open|proprietary] \
#        [--truenas-codename=Goldeye] \
#        [--build-cc=gcc-14] \
#        [--update-file=/path/to/preloaded.update] \
#        [--out=dist]
#
# Output:
#   <out>/nvidia.raw
#   <out>/nvidia.raw.sha256

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Defaults / args
# ─────────────────────────────────────────────────────────────────────────────
NVIDIA_VERSION="${NVIDIA_VERSION:-}"
TRUENAS_VERSION="${TRUENAS_VERSION:-}"
NVIDIA_KERNEL_MODULE_TYPE="${NVIDIA_KERNEL_MODULE_TYPE:-open}"
TRUENAS_CODENAME="${TRUENAS_CODENAME:-}"
NVIDIA_BUILD_CC="${NVIDIA_BUILD_CC:-}"
UPDATE_FILE_OVERRIDE=""
OUT_DIR=""

for arg in "$@"; do
    case "$arg" in
        --nvidia-version=*) NVIDIA_VERSION="${arg#*=}" ;;
        --truenas-version=*) TRUENAS_VERSION="${arg#*=}" ;;
        --kernel-module-type=*) NVIDIA_KERNEL_MODULE_TYPE="${arg#*=}" ;;
        --truenas-codename=*) TRUENAS_CODENAME="${arg#*=}" ;;
        --build-cc=*) NVIDIA_BUILD_CC="${arg#*=}" ;;
        --update-file=*) UPDATE_FILE_OVERRIDE="${arg#*=}" ;;
        --out=*) OUT_DIR="${arg#*=}" ;;
        -h|--help)
            sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# Auto-detect codename for 25.x (Goldeye); 26.x uses BETA URL pattern
if [ -z "$TRUENAS_CODENAME" ] && [[ "$TRUENAS_VERSION" =~ ^25\. ]]; then
    TRUENAS_CODENAME="Goldeye"
fi

[ -n "$NVIDIA_VERSION" ] || { echo "ERROR: --nvidia-version=X.Y.Z required" >&2; exit 1; }
[ -n "$TRUENAS_VERSION" ] || { echo "ERROR: --truenas-version=X.Y.Z required" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-${REPO_ROOT}/dist}"
mkdir -p "$OUT_DIR"
# Resolve to absolute — the script chdirs into $BUILD_DIR in Phase 3, after
# which a relative --out would point at the wrong location at squashfs time.
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

# Build/staging dirs (large; kept under TMPDIR or /tmp for tmpfs speed on
# hosts that have it). A unique mktemp -d root means parallel runs and any
# pre-created predictable paths can't collide; it's removed on exit by the
# trap below.
WORK_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nvidia-build.XXXXXX")
cleanup_work_root() { rm -rf "$WORK_ROOT"; }
trap cleanup_work_root EXIT

STAGE1_DIR="${WORK_ROOT}/stage1"
ROOTFS_DIR="${WORK_ROOT}/rootfs"
BUILD_DIR="${WORK_ROOT}/nvidia_build"
STAGING_DIR="${WORK_ROOT}/staging"
# UPDATE_FILE keeps a fixed /tmp path on purpose: the CI workflow caches it by
# that exact path (build-sysext.yml), so randomizing it would break the cache.
# Overridable via --update-file=.
UPDATE_FILE="/tmp/truenas.update"

# ─────────────────────────────────────────────────────────────────────────────
# Logging
# ─────────────────────────────────────────────────────────────────────────────
info()   { echo "[INFO]  $*"; }
ok()     { echo "[OK]    $*"; }
warn()   { echo "[WARN]  $*" >&2; }
die()    { echo "[FATAL] $*" >&2; exit 1; }
banner() { printf "\n==========================================================\n  %s\n==========================================================\n\n" "$*"; }

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
build_update_filename() {
    case "$1" in
        26.*) printf 'TrueNAS-%s.update\n' "$1" ;;
        *)    printf 'TrueNAS-SCALE-%s.update\n' "$1" ;;
    esac
}

build_update_url() {
    local version="$1" codename="$2"
    local fname
    fname="$(build_update_filename "$version")"
    case "$version" in
        26.*) printf 'https://update-public.sys.truenas.net/TrueNAS-26-BETA/%s\n' "$fname" ;;
        *)
            [ -n "$codename" ] || return 1
            printf 'https://download.truenas.com/TrueNAS-SCALE-%s/%s/%s?download=1\n' \
                "$codename" "$version" "$fname"
            ;;
    esac
}

select_build_cc() {
    if [ -n "$NVIDIA_BUILD_CC" ]; then
        command -v "$NVIDIA_BUILD_CC" >/dev/null 2>&1 \
            || die "NVIDIA_BUILD_CC=$NVIDIA_BUILD_CC not found in PATH"
        printf '%s\n' "$NVIDIA_BUILD_CC"
        return
    fi
    # Prefer gcc-14 (handles -fmin-function-alignment=16 used by modern kernels)
    if command -v gcc-14 >/dev/null 2>&1; then
        printf 'gcc-14\n'
    elif command -v gcc >/dev/null 2>&1 && \
         printf 'int main(void){return 0;}\n' | \
         gcc -fmin-function-alignment=16 -x c - -o "${WORK_ROOT}/_cc_check" >/dev/null 2>&1; then
        rm -f "${WORK_ROOT}/_cc_check"
        printf 'gcc\n'
    else
        rm -f "${WORK_ROOT}/_cc_check"
        die "No GCC found that supports -fmin-function-alignment=16 (need gcc-14 or newer gcc)"
    fi
}

write_extension_release() {
    printf 'ID=_any\nEXTENSION_RELOAD_MANAGER=1\n' > "$1"
}

# Build the NVIDIA .run installer flag list for this driver version. The
# installer's flag surface changed across branches, so we filter against
# the installer's own --help rather than hard-coding one set:
#
#   --kernel-module-type   only exists on 515+ (the open/proprietary split).
#                          Pre-515 branches (470/390/340) are proprietary-only;
#                          passing it makes the installer abort. We drop it and
#                          force NVIDIA_KERNEL_MODULE_TYPE=proprietary so the
#                          rest of the build (modules.dep, staging) is consistent.
#   --kernel-module-type   only exists on 515+ (the open/proprietary split).
#   --no-rebuild-initramfs,
#   --skip-module-load,
#   --no-x-check,
#   --no-nouveau-check,
#   --no-backup,
#   --no-drm,
#   --install-libglvnd,
#   --no-systemd,
#   --allow-installation-with-running-driver
#                          present on modern installers; older branches (e.g.
#                          470) may lack one or more. Passing an unknown flag
#                          makes the .run abort with "unrecognized option", so
#                          every flag beyond the essential set below is gated on
#                          the installer advertising it in --help.
#
# Only --silent, --kernel-source-path and --kernel-name are passed
# unconditionally: they exist on every supported .run and the cross-compile
# cannot proceed without them. Everything else is best-effort and dropped (with
# a warning) when the installer doesn't advertise it.
#
# Echoes the flag list, one per line. Reads RUN_FILE, NVIDIA_VERSION, and the
# (already-normalized) NVIDIA_KERNEL_MODULE_TYPE from caller scope. It does NOT
# mutate caller state — it runs inside a process substitution where a write
# wouldn't propagate; force-proprietary normalization happens in the caller
# (Phase 4) before this is invoked.
select_installer_flags() {
    local help major
    help="$("./${RUN_FILE}" --help 2>&1 || true)"
    major="${NVIDIA_VERSION%%.*}"

    # Essential flags every supported .run understands.
    printf '%s\n' \
        --silent \
        --kernel-source-path="$KERNEL_HEADERS_PATH" \
        --kernel-name="$KERNEL_VERSION"

    # Kernel-module flavor: only on 515+ installers that advertise it.
    if [ "$major" -ge 515 ] 2>/dev/null && printf '%s' "$help" | grep -q -- '--kernel-module-type'; then
        printf '%s\n' --kernel-module-type="$NVIDIA_KERNEL_MODULE_TYPE"
    fi

    # Version-fragile flags: pass only if advertised.
    local flag
    for flag in \
        --no-rebuild-initramfs --skip-module-load --no-x-check \
        --no-nouveau-check --no-backup --no-systemd --no-drm \
        --install-libglvnd --allow-installation-with-running-driver; do
        if printf '%s' "$help" | grep -q -- "$flag"; then
            printf '%s\n' "$flag"
        else
            warn "Installer for $NVIDIA_VERSION does not advertise ${flag}; omitting"
        fi
    done
}

# ─────────────────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────────────────
banner "NVIDIA driver-only sysext builder for TrueNAS"

if [ "$(id -u)" -ne 0 ]; then
    die "Must run as root (kernel-module compile + /usr writes)"
fi

for cmd in unsquashfs mksquashfs depmod sha256sum wget curl gpg apt-get find rsync; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required tool: $cmd"
done

info "NVIDIA driver        : $NVIDIA_VERSION ($NVIDIA_KERNEL_MODULE_TYPE)"
info "TrueNAS version      : $TRUENAS_VERSION${TRUENAS_CODENAME:+ ($TRUENAS_CODENAME)}"
info "Output dir           : $OUT_DIR"

# Clean any leftover state from a prior run
rm -rf "$STAGE1_DIR" "$ROOTFS_DIR" "$BUILD_DIR" "$STAGING_DIR"
mkdir -p "$STAGE1_DIR" "$ROOTFS_DIR" "$BUILD_DIR" "$STAGING_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Obtain the TrueNAS .update file
# ─────────────────────────────────────────────────────────────────────────────
if [ -n "$UPDATE_FILE_OVERRIDE" ]; then
    [ -f "$UPDATE_FILE_OVERRIDE" ] || die "--update-file not found: $UPDATE_FILE_OVERRIDE"
    UPDATE_FILE="$UPDATE_FILE_OVERRIDE"
    info "Using pre-loaded update file: $UPDATE_FILE"
else
    URL="$(build_update_url "$TRUENAS_VERSION" "$TRUENAS_CODENAME")" \
        || die "Cannot build .update URL for $TRUENAS_VERSION (pass --truenas-codename or --update-file)"
    info "Downloading: $URL"
    wget -q --show-progress -O "$UPDATE_FILE" "$URL" \
        || die "Failed to download .update file"
    ok "Downloaded $(du -h "$UPDATE_FILE" | cut -f1)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 — Extract the nested rootfs.squashfs from .update
# ─────────────────────────────────────────────────────────────────────────────
banner "Phase 1: Extract rootfs.squashfs from .update"

unsquashfs -f -d "$STAGE1_DIR" "$UPDATE_FILE" rootfs.squashfs

INNER_SQUASHFS="${STAGE1_DIR}/rootfs.squashfs"
[ -f "$INNER_SQUASHFS" ] || die "rootfs.squashfs not found inside .update"
ok "Inner rootfs.squashfs: $(du -h "$INNER_SQUASHFS" | cut -f1)"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 — Extract kernel headers + module tree from the rootfs
# ─────────────────────────────────────────────────────────────────────────────
banner "Phase 2: Extract kernel source & module tree from rootfs"

unsquashfs -f -d "$ROOTFS_DIR" "$INNER_SQUASHFS" usr/src usr/lib/modules
rm -f "$INNER_SQUASHFS"

info "Scanning kernel versions in usr/lib/modules/ ..."
ALL_KERNEL_VERSIONS=()
for d in "$ROOTFS_DIR/usr/lib/modules/"*/; do
    kdir="$(basename "$d")"
    if [[ "$kdir" =~ ^[0-9] ]]; then
        ALL_KERNEL_VERSIONS+=("$kdir")
        info "  Found kernel: $kdir"
    fi
done
[ ${#ALL_KERNEL_VERSIONS[@]} -gt 0 ] || die "No kernel versions found in extracted rootfs"

# Production kernel preferred over debug (TrueNAS boots production)
KERNEL_VERSION=""
for ver in "${ALL_KERNEL_VERSIONS[@]}"; do
    if [[ "$ver" != *debug* ]]; then
        KERNEL_VERSION="$ver"
        break
    fi
done
[ -n "$KERNEL_VERSION" ] || { KERNEL_VERSION="${ALL_KERNEL_VERSIONS[0]}"; warn "No production kernel found, using $KERNEL_VERSION"; }
ok "Selected kernel: $KERNEL_VERSION"

# Find matching headers — strategy 1: follow modules/<ver>/build symlink
KERNEL_HEADERS_PATH=""
BUILD_LINK=$(readlink "$ROOTFS_DIR/usr/lib/modules/$KERNEL_VERSION/build" 2>/dev/null || true)
if [ -n "$BUILD_LINK" ]; then
    CANDIDATE="${ROOTFS_DIR}${BUILD_LINK}"
    if [ -d "$CANDIDATE" ]; then
        KERNEL_HEADERS_PATH="$CANDIDATE"
        ok "Headers found via modules/build symlink: $(basename "$KERNEL_HEADERS_PATH")"
    fi
fi
# Strategy 2: match by variant name
if [ -z "$KERNEL_HEADERS_PATH" ]; then
    KERNEL_VARIANT=""
    if [[ "$KERNEL_VERSION" =~ -([a-zA-Z]+)\+ ]]; then
        KERNEL_VARIANT="${BASH_REMATCH[1]}"
    fi
    if [ -n "$KERNEL_VARIANT" ]; then
        for d in "$ROOTFS_DIR"/usr/src/linux-headers-*; do
            [ -d "$d" ] || continue
            [[ "$d" == *-common ]] && continue
            if [[ "$(basename "$d")" == *"$KERNEL_VARIANT"* ]]; then
                KERNEL_HEADERS_PATH="$d"; break
            fi
        done
    fi
fi
# Strategy 3: any non-common non-debug
if [ -z "$KERNEL_HEADERS_PATH" ]; then
    for d in "$ROOTFS_DIR"/usr/src/linux-headers-*; do
        [ -d "$d" ] || continue
        [[ "$d" == *-common ]] && continue
        [[ "$d" == *debug* ]] && continue
        KERNEL_HEADERS_PATH="$d"; break
    done
fi
[ -n "$KERNEL_HEADERS_PATH" ] || die "No suitable linux-headers-* found"
ok "Kernel headers: $KERNEL_HEADERS_PATH"

# Ensure Module.symvers is reachable from headers root
if [ ! -f "$KERNEL_HEADERS_PATH/Module.symvers" ] \
   && [ -f "$ROOTFS_DIR/usr/lib/modules/$KERNEL_VERSION/build/Module.symvers" ]; then
    ln -sf "$ROOTFS_DIR/usr/lib/modules/$KERNEL_VERSION/build/Module.symvers" \
           "$KERNEL_HEADERS_PATH/Module.symvers"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 — Download the NVIDIA .run installer
# ─────────────────────────────────────────────────────────────────────────────
banner "Phase 3: Download NVIDIA $NVIDIA_VERSION installer"

cd "$BUILD_DIR"
RUN_FILE="NVIDIA-Linux-x86_64-${NVIDIA_VERSION}-no-compat32.run"
NV_URL="https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_VERSION}/${RUN_FILE}"

if [ -f "$RUN_FILE" ]; then
    info "Run file already present, skipping download"
else
    info "Downloading from $NV_URL"
    wget -q --show-progress -c "$NV_URL" || die "Failed to download $RUN_FILE"
fi
chmod +x "$RUN_FILE"
ok "NVIDIA installer: $BUILD_DIR/$RUN_FILE"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 — Snapshot, install container-toolkit, run NVIDIA installer, diff
# ─────────────────────────────────────────────────────────────────────────────
banner "Phase 4: Compile & install NVIDIA driver"

CC_TO_USE="$(select_build_cc)"
info "Using compiler for NVIDIA modules: $CC_TO_USE"
export CC="$CC_TO_USE"
export HOSTCC="$CC_TO_USE"
export IGNORE_CC_MISMATCH=1

# Pause apt's daily/weekly timers so background package activity doesn't
# leak files into our before/after filesystem diff.
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl stop unattended-upgrades.service 2>/dev/null || true

info "Taking pre-install filesystem snapshot ..."
find /usr /etc -xdev \( -type f -o -type l \) 2>/dev/null \
    | LC_ALL=C sort > "${WORK_ROOT}/fs_before.txt"
BEFORE_COUNT=$(wc -l < "${WORK_ROOT}/fs_before.txt")
ok "Snapshot: $BEFORE_COUNT files"

# Install nvidia-container-toolkit (mirrors official TrueNAS extension build)
info "Adding NVIDIA container-toolkit APT repo ..."
mkdir -p /usr/share/keyrings
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
echo 'deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/$(ARCH) /' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list

info "Installing nvidia-container-toolkit + libvulkan1 ..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    nvidia-container-toolkit libvulkan1 \
    || die "Failed to install nvidia-container-toolkit"

# Run NVIDIA installer (cross-compile against extracted TrueNAS kernel).
# Flags are selected per-branch — legacy installers (< 515) predate
# --kernel-module-type and some newer flags.
#
# Legacy branches (< 515) are proprietary-only — there is no open variant.
# Normalize here, in the main shell, so the value sticks for the post-install
# messages (select_installer_flags runs in a subshell and can't write it back).
DRIVER_MAJOR="${NVIDIA_VERSION%%.*}"
if [ "$DRIVER_MAJOR" -lt 515 ] 2>/dev/null && [ "$NVIDIA_KERNEL_MODULE_TYPE" != "proprietary" ]; then
    warn "Driver $NVIDIA_VERSION predates the open/proprietary split — forcing proprietary kernel modules"
    NVIDIA_KERNEL_MODULE_TYPE="proprietary"
fi

info "Selecting installer flags for $NVIDIA_VERSION ..."
INSTALLER_FLAGS=()
while IFS= read -r _flag; do
    [ -n "$_flag" ] && INSTALLER_FLAGS+=("$_flag")
done < <(select_installer_flags)
info "Installer flags: ${INSTALLER_FLAGS[*]}"

info "Running NVIDIA installer (silent cross-compile) ..."
"./${RUN_FILE}" "${INSTALLER_FLAGS[@]}" \
    || die "NVIDIA installer failed"
ok "NVIDIA driver installed ($NVIDIA_KERNEL_MODULE_TYPE modules)"

info "Taking post-install snapshot ..."
find /usr /etc -xdev \( -type f -o -type l \) 2>/dev/null \
    | LC_ALL=C sort > "${WORK_ROOT}/fs_after.txt"
LC_ALL=C comm -13 "${WORK_ROOT}/fs_before.txt" "${WORK_ROOT}/fs_after.txt" > "${WORK_ROOT}/nvidia_new_files.txt"
NEW_COUNT=$(wc -l < "${WORK_ROOT}/nvidia_new_files.txt")
ok "Filesystem diff: $NEW_COUNT new files"
[ "$NEW_COUNT" -gt 0 ] || die "Installer produced zero new files — build failed"

info "New-file breakdown:"
awk -F/ '{
    if ($2=="usr") {
        if ($3=="lib" && $4=="modules") print "  kernel-modules"
        else if ($3=="lib" && $4=="firmware") print "  firmware"
        else if ($3=="lib") print "  libraries"
        else if ($3=="bin") print "  binaries"
        else if ($3=="share") print "  data/config"
        else print "  other-usr"
    } else if ($2=="etc") print "  etc-config"
    else print "  other"
}' "${WORK_ROOT}/nvidia_new_files.txt" | sort | uniq -c | sort -rn

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5 — Stage new files into sysext tree (remap /etc → /usr/share as needed)
# ─────────────────────────────────────────────────────────────────────────────
banner "Phase 5: Stage sysext directory tree"

STAGED_COUNT=0
SKIPPED_COUNT=0

while IFS= read -r src_file; do
    # Bloat / DKMS source / unrelated paths
    if [[ "$src_file" == /usr/src/nvidia-* ]] \
    || [[ "$src_file" == /usr/share/doc/* ]] \
    || [[ "$src_file" == /usr/share/man/* ]] \
    || [[ "$src_file" == /usr/share/licenses/* ]] \
    || [[ "$src_file" == *.manifest ]] \
    || [[ "$src_file" == /etc/apt/* ]] \
    || [[ "$src_file" == /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg ]]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT+1))
        continue
    fi

    dest_path=""
    if [[ "$src_file" == /usr/* ]]; then
        dest_path="${STAGING_DIR}${src_file}"
    elif [[ "$src_file" == /etc/OpenCL/* ]] \
      || [[ "$src_file" == /etc/vulkan/* ]] \
      || [[ "$src_file" == /etc/vulkansc/* ]] \
      || [[ "$src_file" == /etc/nvidia-container-runtime/* ]] \
      || [[ "$src_file" == /etc/nvidia-container-toolkit/* ]]; then
        rel="${src_file#/etc/}"
        dest_path="${STAGING_DIR}/usr/share/${rel}"
    elif [[ "$src_file" == /etc/systemd/system/* ]]; then
        rel="${src_file#/etc/systemd/system/}"
        dest_path="${STAGING_DIR}/usr/lib/systemd/system/${rel}"
    elif [[ "$src_file" == /etc/* ]]; then
        SKIPPED_COUNT=$((SKIPPED_COUNT+1))
        continue
    else
        warn "Unexpected path, skipping: $src_file"
        SKIPPED_COUNT=$((SKIPPED_COUNT+1))
        continue
    fi

    mkdir -p "$(dirname "$dest_path")"
    if [ -L "$src_file" ]; then
        cp -a "$src_file" "$dest_path" 2>/dev/null || true
    elif [ -f "$src_file" ]; then
        cp -a "$src_file" "$dest_path" 2>/dev/null || true
    fi
    STAGED_COUNT=$((STAGED_COUNT+1))
done < "${WORK_ROOT}/nvidia_new_files.txt"

ok "Staged $STAGED_COUNT files (skipped $SKIPPED_COUNT)"

# Verify .ko files were captured; fall back to scanning host paths
KO_COUNT=$(find "$STAGING_DIR" -name '*.ko' -type f 2>/dev/null | wc -l)
if [ "$KO_COUNT" -eq 0 ]; then
    warn "No .ko in diff; scanning host paths ..."
    MODULES_DEST="$STAGING_DIR/usr/lib/modules/$KERNEL_VERSION/updates/dkms"
    mkdir -p "$MODULES_DEST"
    for r in "/lib/modules/$KERNEL_VERSION" "/usr/lib/modules/$KERNEL_VERSION"; do
        [ -d "$r" ] && find "$r" -name '*.ko' -type f -exec cp -v {} "$MODULES_DEST/" \;
    done
    KO_COUNT=$(find "$STAGING_DIR" -name '*.ko' -type f | wc -l)
fi
[ "$KO_COUNT" -gt 0 ] || die "No .ko kernel modules found anywhere"
ok "Kernel modules: $KO_COUNT .ko"
find "$STAGING_DIR" -name '*.ko' -type f -exec basename {} \; | sort | sed 's/^/  /'

# Combined modules.dep (system + nvidia) — see biohazardious comment block:
# overlayfs replaces /usr/lib/modules/<ver>/modules.dep wholesale, so an
# nvidia-only modules.dep would hide every other kernel module. Build a
# combined one over the extracted full module tree.
info "Building combined modules.dep ..."
find "$STAGING_DIR/usr/lib/modules/" -maxdepth 2 -name 'modules.*' -type f -delete 2>/dev/null || true
ROOTFS_MODULES="$ROOTFS_DIR/usr/lib/modules/$KERNEL_VERSION"
mkdir -p "$ROOTFS_MODULES/video"
find "$STAGING_DIR" -name '*.ko' -type f -exec cp {} "$ROOTFS_MODULES/video/" \;
SYSTEM_KO_COUNT=$(find "$ROOTFS_MODULES" -name '*.ko' -type f | wc -l)
info "Combined module tree: $SYSTEM_KO_COUNT .ko"

if ! depmod -b "$ROOTFS_DIR/usr" "$KERNEL_VERSION"; then
    depmod -b "$ROOTFS_DIR" "$KERNEL_VERSION" \
        || die "depmod failed against combined tree"
fi

STAGING_MODULES="$STAGING_DIR/usr/lib/modules/$KERNEL_VERSION"
mkdir -p "$STAGING_MODULES"
for mfile in "$ROOTFS_MODULES"/modules.*; do
    [ -f "$mfile" ] && cp "$mfile" "$STAGING_MODULES/"
done
MODFILES_COUNT=$(find "$STAGING_MODULES" -name 'modules.*' -type f | wc -l)
ok "Shipped $MODFILES_COUNT module metadata files covering all $SYSTEM_KO_COUNT .ko"

# Critical-file sanity checks
info "Verifying critical files ..."
chk() {
    local label="$1" pat="$2"
    local n
    n=$(find "$STAGING_DIR" -path "$pat" 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then ok "  $label ($n)"; else warn "  $label — MISSING ($pat)"; fi
}
chk "nvidia-smi"              "*/usr/bin/nvidia-smi"
chk "libcuda"                 "*/libcuda.so*"
chk "libnvidia-ml (NVML)"     "*/libnvidia-ml.so*"
chk "libnvidia-encode"        "*/libnvidia-encode.so*"
chk "libnvcuvid"              "*/libnvcuvid.so*"
chk "Vulkan ICD JSON"         "*/nvidia_icd.json"
chk "GSP firmware"            "*/firmware/nvidia/*/gsp_*"
chk "nvidia.ko"               "*/nvidia.ko"
chk "nvidia-modeset.ko"       "*/nvidia-modeset.ko"
chk "nvidia-uvm.ko"           "*/nvidia-uvm.ko"
chk "nvidia-peermem.ko"       "*/nvidia-peermem.ko"
chk "nvidia-container-runtime" "*/usr/bin/nvidia-container-runtime"
chk "nvidia-container-cli"    "*/usr/bin/nvidia-container-cli"
chk "nvidia-ctk"              "*/usr/bin/nvidia-ctk"

MAIN_KO=$(find "$STAGING_DIR" -name 'nvidia.ko' -not -name 'nvidia-*.ko' -type f | head -1)
[ -n "$MAIN_KO" ] || die "CRITICAL: nvidia.ko missing from staged image"
ok "Main nvidia.ko at: $MAIN_KO"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5b — (intentionally empty)
# ─────────────────────────────────────────────────────────────────────────────
# nvidia.raw is driver-only. The user-facing uninstaller (`uninstall-nvidia-mig`)
# is bundled into nvidia-mig.raw, which is ALWAYS installed alongside
# nvidia.raw in the --with-driver path. Bundling another copy here would
# create a /usr/bin path collision under systemd-sysext merge.
info "Phase 5b: nothing to bundle in nvidia.raw (uninstaller lives in nvidia-mig.raw)"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5c — Extension-release metadata (ID=_any, matches TrueNAS convention)
# ─────────────────────────────────────────────────────────────────────────────
EXT_REL_DIR="$STAGING_DIR/usr/lib/extension-release.d"
mkdir -p "$EXT_REL_DIR"
write_extension_release "$EXT_REL_DIR/extension-release.nvidia"
ok "extension-release.nvidia written"

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6 — Squashfs the staged tree into nvidia.raw
# ─────────────────────────────────────────────────────────────────────────────
banner "Phase 6: Build nvidia.raw"

OUT_PATH="$OUT_DIR/nvidia.raw"
rm -f "$OUT_PATH"

STAGING_SIZE=$(du -sh "$STAGING_DIR" | cut -f1)
STAGING_FILES=$(find "$STAGING_DIR" -type f | wc -l)
STAGING_LINKS=$(find "$STAGING_DIR" -type l | wc -l)
info "Staging: $STAGING_SIZE — $STAGING_FILES files, $STAGING_LINKS symlinks"

# gzip matches TrueNAS's own convention; zstd would be smaller but mismatches
# what other tooling expects to see when inspecting TrueNAS sysexts.
mksquashfs "$STAGING_DIR" "$OUT_PATH" -comp gzip -all-root -noappend >/dev/null

( cd "$OUT_DIR" && sha256sum "$(basename "$OUT_PATH")" > "$(basename "$OUT_PATH").sha256" )

FINAL_SIZE=$(du -h "$OUT_PATH" | cut -f1)
FINAL_BYTES=$(stat -c%s "$OUT_PATH")
ok "nvidia.raw built: $FINAL_SIZE ($FINAL_BYTES bytes)"

# Size sanity: stock TrueNAS 25.10.x nvidia.raw is ~420 MB. Our driver-only
# build should land in the same neighborhood; warn outside reasonable bounds.
if [ "$FINAL_BYTES" -lt 350000000 ]; then
    warn "Image is under 350 MB — may be missing components"
elif [ "$FINAL_BYTES" -gt 700000000 ]; then
    warn "Image is over 700 MB — unexpectedly large"
else
    ok "Image size within expected band"
fi

banner "Build complete"
echo "  Output    : $OUT_PATH"
echo "  Driver    : $NVIDIA_VERSION ($NVIDIA_KERNEL_MODULE_TYPE)"
echo "  Kernel    : $KERNEL_VERSION"
echo "  Modules   : $KO_COUNT .ko"
echo "  Staged    : $STAGED_COUNT files"
echo "  SHA256    : $(cut -d' ' -f1 "$OUT_PATH.sha256")"
