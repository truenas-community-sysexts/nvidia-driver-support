#!/usr/bin/env bash
# Recover the stock TrueNAS nvidia.raw from the official .update archive
# when no backup is available locally. Run as root on TrueNAS.
#
# Pulls the .update file (~1.8 GB) into a working dir on a ZFS pool (not
# tmpfs), peels the two-level squashfs to extract
#   /usr/share/truenas/sysext-extensions/nvidia.raw
# and either stages it as a backup or restores it in place.
#
# Usage:
#   sudo ./recover-stock-nvidia.sh                  # download + extract, stage as nvidia-original.raw
#   sudo ./recover-stock-nvidia.sh --install        # also install over the current nvidia.raw
#   sudo ./recover-stock-nvidia.sh --version=25.10.3.1
#   sudo ./recover-stock-nvidia.sh --update-file=/path/to/preloaded.update
#   sudo ./recover-stock-nvidia.sh --keep-workdir   # leave the ~2 GB download in place
#   sudo ./recover-stock-nvidia.sh --pool=fast      # explicit pool (auto-detects + prompts otherwise)
#   sudo ./recover-stock-nvidia.sh --persist-path=/mnt/fast/.config/nvidia-gpu

set -euo pipefail

VERSION=""
UPDATE_FILE=""
DO_INSTALL=false
KEEP_WORKDIR=false
POOL_NAME=""
PERSIST_PATH=""

for arg in "$@"; do
    case "$arg" in
        --version=*) VERSION="${arg#*=}" ;;
        --update-file=*) UPDATE_FILE="${arg#*=}" ;;
        --install) DO_INSTALL=true ;;
        --keep-workdir) KEEP_WORKDIR=true ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    echo "ERROR: must run as root" >&2
    exit 1
fi

# Track mutations so the trap can undo them if we die mid-install (failure
# under set -e, or a SIGTERM/SIGINT). Without this, an abort between
# readonly=off and readonly=on leaves /usr writable until reboot, and an abort
# after the docker toggle leaves nvidia stuck off, both until manually fixed.
USR_WAS_WRITABLE=0
USR_DATASET=""
DOCKER_NVIDIA_DISABLED=0

restore_state() {
    if [ "$USR_WAS_WRITABLE" = "1" ] && [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        USR_WAS_WRITABLE=0
    fi
    if [ "$DOCKER_NVIDIA_DISABLED" = "1" ]; then
        midclt call -j docker.update '{"nvidia": true}' >/dev/null 2>&1 || true
        DOCKER_NVIDIA_DISABLED=0
    fi
}
trap restore_state EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────
# Stock-backup freshness. Duplicated verbatim in install-nvidia-driver.sh,
# uninstall-nvidia-driver.sh and recover-stock-nvidia.sh (each stays a
# self-contained curl|bash artifact); keep the copies in sync.
#
# nvidia-original.raw holds the stock driver of the TrueNAS version it was
# made on. After a TrueNAS update that changed the kernel, its modules are for
# the old kernel, and restoring it would put a driver on the system that
# cannot load. It is usable only if it ships modules for the running kernel.
# ─────────────────────────────────────────────────────────────────────────

# Kernel versions a sysext image ships modules for (usr/lib/modules/<kver>/),
# space-separated. Empty when it ships none or cannot be read.
raw_module_kernels() {
    unsquashfs -l "$1" 'usr/lib/modules/*' 2>/dev/null \
        | sed -nE 's|^[^/]*/usr/lib/modules/([^/]+)/.*|\1|p' \
        | sort -u | paste -sd ' ' - || true
}

# Why a stock nvidia.raw can't be restored on this system; prints nothing
# when it can. "missing", or "stale:<kernels it has modules for>".
stock_backup_problem() {
    local raw="$1" kvers
    [ -f "$raw" ] || { echo "missing"; return 0; }
    kvers=$(raw_module_kernels "$raw")
    case " ${kvers} " in
        *" $(uname -r) "*) ;;
        *) echo "stale:${kvers:-none found}" ;;
    esac
}

# Checksum from a sidecar URL: the 64-hex digest in its first field. Fails on
# transport errors and on non-hash content (soft-404 pages), so an HTML error
# body is never taken for a checksum. Same as build-nvidia-sysext.sh.
fetch_expected_sha() {
    local sha
    sha="$(curl -fsSL --retry 3 --max-time 60 "$1" | awk '{print $1; exit}')" || return 1
    [[ "$sha" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    printf '%s\n' "$sha" | tr '[:upper:]' '[:lower:]'
}

# Resume a partial download only if it is the same file. A leftover from an
# interrupted run for another TrueNAS version would otherwise be resumed:
# curl appends this version's bytes to it, or, when the leftover is at least
# as long, treats it as complete; either way the OLD version's stock driver
# gets extracted. The source URL is recorded next to the download, and a
# partial with a different URL (or none, from before this record existed) is
# discarded.
prepare_download_resume() {
    local file="$1" url="$2"
    if [ -e "$file" ] && [ "$(cat "${file}.url" 2>/dev/null)" != "$url" ]; then
        echo "Discarding ${file}: it is not a download of ${url}"
        rm -f "$file"
    fi
    printf '%s\n' "$url" > "${file}.url"
}

[ -n "$VERSION" ] || VERSION=$(cat /etc/version 2>/dev/null | tr -d '[:space:]')
[ -n "$VERSION" ] || { echo "ERROR: cannot determine TrueNAS version, pass --version=X.Y.Z" >&2; exit 1; }

case "$VERSION" in
    25.*) CODENAME="Goldeye"; URL_FILE="TrueNAS-SCALE-${VERSION}.update" ;;
    26.*) CODENAME=""; URL_FILE="TrueNAS-${VERSION}.update" ;;
    *) echo "ERROR: unsupported version pattern: $VERSION" >&2; exit 1 ;;
esac

# --- Resolve persistent storage location ---
# resolve_persist_dir is duplicated verbatim across install-nvidia-driver.sh,
# uninstall-nvidia-driver.sh, and recover-stock-nvidia.sh. Inline (rather than
# sourced from a sibling file) so each script remains a self-contained
# curl|bash artifact. Keep these copies in sync when changing the function.
resolve_persist_dir() {
    PERSIST_DIR=""
    local d p
    local -a existing=() pools=() choices=()
    local header n i

    if [ -n "${PERSIST_PATH:-}" ]; then
        PERSIST_DIR="$PERSIST_PATH"
        return 0
    fi
    if [ -n "${POOL_NAME:-}" ]; then
        PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"
        return 0
    fi

    for d in /mnt/*/.config/nvidia-gpu; do
        [ -d "$d" ] && existing+=("$d")
    done

    while IFS= read -r p; do
        [ -n "$p" ] && [ "$p" != "boot-pool" ] && pools+=("$p")
    done < <(zpool list -H -o name 2>/dev/null)

    if [ "${#pools[@]}" -eq 0 ]; then
        echo "ERROR: no data pool found (only boot-pool). Pass --pool=NAME or --persist-path=PATH." >&2
        return 1
    fi

    if [ "${#existing[@]}" -eq 1 ]; then
        PERSIST_DIR="${existing[0]}"
        echo "Using existing nvidia-gpu config: $PERSIST_DIR"
        return 0
    fi
    if [ "${#existing[@]}" -eq 0 ] && [ "${#pools[@]}" -eq 1 ]; then
        PERSIST_DIR="/mnt/${pools[0]}/.config/nvidia-gpu"
        echo "Auto-selected pool: ${pools[0]} → $PERSIST_DIR"
        return 0
    fi

    if [ "${#existing[@]}" -gt 1 ]; then
        header="Found existing nvidia-gpu configs on multiple pools:"
        choices=("${existing[@]}")
    else
        header="No existing nvidia-gpu config. Multiple data pools available:"
        for p in "${pools[@]}"; do
            choices+=("/mnt/${p}/.config/nvidia-gpu")
        done
    fi

    # /dev/tty the device node almost always exists; the real question is
    # whether THIS process can open it. CI runners and daemons can't.
    # `: < /dev/tty` forces an open() call and fails fast if no controlling
    # terminal is attached.
    if ! { : </dev/tty; } 2>/dev/null; then
        echo "ERROR: $header" >&2
        echo "       No controlling terminal for prompt. Pass --pool=NAME or --persist-path=PATH." >&2
        return 1
    fi

    echo "$header"
    for i in "${!choices[@]}"; do
        echo "  [$((i+1))] ${choices[$i]}"
    done
    while true; do
        printf "Pick one (1-%d): " "${#choices[@]}"
        read -r n </dev/tty || return 1
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#choices[@]}" ]; then
            PERSIST_DIR="${choices[$((n-1))]}"
            echo "Selected: $PERSIST_DIR"
            return 0
        fi
        echo "  Invalid. Enter 1-${#choices[@]}."
    done
}
# Validate --persist-path shape: the boot-time PREINIT (nvidia-preinit-driver.sh)
# only scans /mnt/*/.config/nvidia-gpu, so any other location silently breaks
# persistence after a reboot or TrueNAS update. Refuse early. --pool resolves
# to this shape automatically.
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_PATH_REAL=$(realpath -m "$PERSIST_PATH" 2>/dev/null || echo "$PERSIST_PATH")
    if [[ ! "$PERSIST_PATH_REAL" =~ ^/mnt/[^/]+/\.config/nvidia-gpu/?$ ]]; then
        echo "ERROR: --persist-path must be /mnt/<pool>/.config/nvidia-gpu (got: ${PERSIST_PATH})" >&2
        echo "  The boot-time PREINIT script only scans /mnt/*/.config/nvidia-gpu," >&2
        echo "  so any other location silently breaks persistence after a reboot or update." >&2
        echo "  Pass --pool=<name> instead (it resolves to /mnt/<name>/.config/nvidia-gpu)." >&2
        exit 2
    fi
fi
resolve_persist_dir || exit 1

PERSIST="$PERSIST_DIR"
WORK="${PERSIST}/recovery"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"

echo "=== Recover stock nvidia.raw ==="
echo "Version:  $VERSION ($CODENAME)"
echo "Persist:  $PERSIST"
echo "Workdir:  $WORK"
echo ""

mkdir -p "$WORK" "$PERSIST"

# --- 1. Get the .update file ---
if [ -n "$UPDATE_FILE" ]; then
    [ -f "$UPDATE_FILE" ] || { echo "ERROR: $UPDATE_FILE not found" >&2; exit 1; }
    echo "Using preloaded update file: $UPDATE_FILE"
else
    UPDATE_FILE="${WORK}/truenas.update"
    if [ "$CODENAME" = "Goldeye" ]; then
        URL="https://download.truenas.com/TrueNAS-SCALE-${CODENAME}/${VERSION}/${URL_FILE}?download=1"
    else
        URL="https://update-public.sys.truenas.net/TrueNAS-26-BETA/${URL_FILE}"
    fi
    # Checksum sidecar next to the .update (any ?download=1 query goes after
    # the .sha256 suffix), fetched before the ~2 GB download so a problem
    # fails fast. As in build-nvidia-sysext.sh, only a definitive 404 (no
    # sidecar published) downgrades to a warning.
    SHA_URL="${URL%%\?*}.sha256"
    case "$URL" in *\?*) SHA_URL="${SHA_URL}?${URL#*\?}" ;; esac
    SHA_STATUS="$(curl -sL -o /dev/null --retry 3 --max-time 30 -w '%{http_code}' "$SHA_URL" || true)"
    EXPECTED_SHA=""
    if [ "$SHA_STATUS" = "404" ]; then
        echo "WARN: no .sha256 published at ${SHA_URL}; the download will not be verified" >&2
    else
        EXPECTED_SHA="$(fetch_expected_sha "$SHA_URL")" \
            || { echo "ERROR: failed to fetch the .update checksum: ${SHA_URL} (HTTP ${SHA_STATUS})" >&2; exit 1; }
    fi
    prepare_download_resume "$UPDATE_FILE" "$URL"
    if [ -s "$UPDATE_FILE" ]; then
        echo "Resuming/using existing download at ${UPDATE_FILE}"
    fi
    echo "Downloading ${URL}"
    curl -fL --retry 3 --continue-at - -o "$UPDATE_FILE" "$URL"
    if [ -n "$EXPECTED_SHA" ]; then
        ACTUAL_SHA="$(sha256sum "$UPDATE_FILE" | awk '{print $1}')"
        if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
            rm -f "$UPDATE_FILE" "${UPDATE_FILE}.url"
            echo "ERROR: ${UPDATE_FILE} failed SHA256 verification (expected ${EXPECTED_SHA}, got ${ACTUAL_SHA})." >&2
            echo "       Discarded it; re-run to download it again." >&2
            exit 1
        fi
        echo "SHA256 verified against ${SHA_URL}"
    fi
fi
ls -lh "$UPDATE_FILE"

# --- 2. Peel outer squashfs to get rootfs.squashfs ---
OUTER_DIR="${WORK}/outer"
rm -rf "$OUTER_DIR"
echo ""
echo "Extracting rootfs.squashfs from .update..."
unsquashfs -f -d "$OUTER_DIR" "$UPDATE_FILE" rootfs.squashfs

INNER="${OUTER_DIR}/rootfs.squashfs"
[ -f "$INNER" ] || { echo "ERROR: rootfs.squashfs not found inside .update" >&2; exit 1; }
ls -lh "$INNER"

# --- 3. Peel inner squashfs to get the stock nvidia.raw ---
INNER_DIR="${WORK}/rootfs"
rm -rf "$INNER_DIR"
echo ""
echo "Extracting usr/share/truenas/sysext-extensions/nvidia.raw from rootfs.squashfs..."
unsquashfs -f -d "$INNER_DIR" "$INNER" usr/share/truenas/sysext-extensions/nvidia.raw

STOCK="${INNER_DIR}/usr/share/truenas/sysext-extensions/nvidia.raw"
[ -f "$STOCK" ] || { echo "ERROR: stock nvidia.raw not found inside rootfs.squashfs" >&2; exit 1; }

# Never stage or install a stock driver for another kernel (--version or
# --update-file for a different TrueNAS release): it cannot load here, and
# staging it would replace a usable nvidia-original.raw with a stale one.
STOCK_PROBLEM=$(stock_backup_problem "$STOCK")
if [ -n "$STOCK_PROBLEM" ]; then
    cat >&2 <<EOF
ERROR: the stock nvidia.raw extracted from ${UPDATE_FILE} is not for this kernel.
       It has kernel modules for: ${STOCK_PROBLEM#stale:}
       This system runs kernel:   $(uname -r)
       Leaving ${PERSIST}/nvidia-original.raw untouched and installing
       nothing: that driver cannot load on this kernel. If you passed
       --version or --update-file, run without them to fetch the stock
       driver of the running TrueNAS version (read from /etc/version).
EOF
    # Same cleanup as a successful run: the download and the extraction are
    # of no use for this kernel.
    $KEEP_WORKDIR || rm -rf "$WORK"
    exit 1
fi

echo ""
echo "=== Stock nvidia.raw recovered ==="
ls -lh "$STOCK"
STOCK_SHA=$(sha256sum "$STOCK" | awk '{print $1}')
STOCK_SIZE=$(stat -c '%s' "$STOCK")
echo "SHA256: $STOCK_SHA"
echo "Size:   $STOCK_SIZE bytes"

# Sanity bounds — observed: TrueNAS 25.10.x stock nvidia.raw is ~400 MB
# (570.172.08 driver + libs + nvidia-container-toolkit). Warn outside a
# generous range that catches truncated downloads or wildly different content.
if [ "$STOCK_SIZE" -lt 100000000 ]; then
    echo "WARN: extracted nvidia.raw is suspiciously small (${STOCK_SIZE} bytes); verify before installing"
elif [ "$STOCK_SIZE" -gt 700000000 ]; then
    echo "WARN: extracted nvidia.raw is unexpectedly large (${STOCK_SIZE} bytes); verify before installing"
fi

# --- 4. Stage as nvidia-original.raw for `install-nvidia-driver.sh` ---
#       (and for uninstall-nvidia-driver.sh to restore from later) ---
cp "$STOCK" "${PERSIST}/nvidia-original.raw"
echo ""
echo "Staged: ${PERSIST}/nvidia-original.raw"

# --- 5. Optionally install over the live nvidia.raw ---
if $DO_INSTALL; then
    CURRENT_SHA=$(sha256sum "${SYSEXT_DIR}/nvidia.raw" 2>/dev/null | awk '{print $1}' || echo "")
    if [ "$CURRENT_SHA" = "$STOCK_SHA" ]; then
        echo ""
        echo "Live nvidia.raw already matches stock — no install needed."
    else
        echo ""
        echo "=== Installing stock nvidia.raw over current ==="
        echo "Stopping Docker so the GPU is free..."
        midclt call -j docker.update '{"nvidia": false}' >/dev/null
        DOCKER_NVIDIA_DISABLED=1

        echo "Unmerging sysext..."
        systemd-sysext unmerge

        USR_DATASET=$(zfs list -H -o name /usr)
        if [ -z "$USR_DATASET" ]; then
            echo "ERROR: could not determine the ZFS dataset for /usr" >&2
            exit 1
        fi
        echo "Setting ${USR_DATASET} writable..."
        zfs set readonly=off "${USR_DATASET}"
        USR_WAS_WRITABLE=1

        # Backup current (custom) as .bak in case we need it later
        if [ ! -f "${SYSEXT_DIR}/nvidia.raw.bak" ]; then
            cp "${SYSEXT_DIR}/nvidia.raw" "${SYSEXT_DIR}/nvidia.raw.bak"
            echo "Backed up current (custom) to nvidia.raw.bak"
        fi
        cp "$STOCK" "${SYSEXT_DIR}/nvidia.raw"

        echo "Restoring ${USR_DATASET} readonly..."
        zfs set readonly=on "${USR_DATASET}"
        USR_WAS_WRITABLE=0

        echo "Ensuring /etc/extensions/nvidia.raw symlink..."
        mkdir -p /etc/extensions
        ln -sf "${SYSEXT_DIR}/nvidia.raw" /etc/extensions/nvidia.raw

        echo "Re-merging sysext..."
        # refresh, not merge: tolerates /usr having been re-merged meanwhile.
        systemd-sysext refresh
        systemctl daemon-reload

        echo "Re-enabling NVIDIA in Docker..."
        midclt call -j docker.update '{"nvidia": true}' >/dev/null
        DOCKER_NVIDIA_DISABLED=0

        sleep 3
        DRIVER=$(/usr/bin/nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null || echo "unknown")
        echo "Active driver version after install: $DRIVER"
    fi
fi

# --- 6. Cleanup workdir ---
if $KEEP_WORKDIR; then
    echo ""
    echo "Workdir preserved at $WORK ($(du -sh "$WORK" | cut -f1))"
else
    rm -rf "$WORK"
    echo ""
    echo "Cleaned up workdir."
fi

echo ""
echo "=== Done ==="
if ! $DO_INSTALL; then
    echo "Re-run with --install to actually swap the live nvidia.raw back to stock."
fi
