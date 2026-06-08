#!/usr/bin/env bash
# Revert the custom NVIDIA driver back to TrueNAS's stock nvidia.raw and undo
# everything install-nvidia-driver.sh did.
#
#   - Restores stock nvidia.raw from nvidia-original.raw (brief /usr r/w).
#   - Stops GPU-bound apps so the swap is clean, restores the docker nvidia
#     toggle afterwards.
#   - Deregisters the driver PREINIT entry.
#   - Removes the custom nvidia.raw, PREINIT helper, and build artifacts from
#     the persist dir (nvidia-original.raw is always kept for re-install).
#   - **REBOOT REQUIRED** — kernel modules need to reload at the stock version.
#
# If nothing this repo installed is detected, prints "nothing to do" and exits.
#
# Staged to /mnt/<pool>/.config/nvidia-gpu/scripts/ on install, so you can run
#   sudo /mnt/<pool>/.config/nvidia-gpu/scripts/uninstall-nvidia-driver.sh
# without the curl one-liner.
#
# Usage:
#   sudo ./uninstall-nvidia-driver.sh
#   sudo ./uninstall-nvidia-driver.sh --keep-cache        # keep the ~2 GB build cache
#   sudo ./uninstall-nvidia-driver.sh --keep-persist      # remove nothing from persist dir
#   sudo ./uninstall-nvidia-driver.sh --skip-backup-check # revert without nvidia-original.raw

set -euo pipefail

KEEP_PERSIST=false
KEEP_CACHE=false
SKIP_BACKUP_CHECK=false
for arg in "$@"; do
    case "$arg" in
        --keep-persist) KEEP_PERSIST=true ;;
        --keep-cache) KEEP_CACHE=true ;;
        --skip-backup-check) SKIP_BACKUP_CHECK=true ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }

USR_WAS_WRITABLE=0
USR_DATASET=""
DOCKER_NVIDIA_DISABLED=0
restore_state() {
    if [ "$USR_WAS_WRITABLE" = "1" ] && [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        USR_WAS_WRITABLE=0
    fi
    if [ "$DOCKER_NVIDIA_DISABLED" = "1" ]; then
        midclt call docker.update '{"nvidia": true}' >/dev/null 2>&1 || true
        DOCKER_NVIDIA_DISABLED=0
    fi
}
trap restore_state EXIT INT TERM

SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"

# ── State detection ──
PERSIST_DIR=""
ORIGINAL=""
HAS_DRIVER=false
for d in /mnt/*/.config/nvidia-gpu; do
    [ -d "$d" ] || continue
    PERSIST_DIR="$d"
    [ -f "$d/nvidia-original.raw" ] && ORIGINAL="$d/nvidia-original.raw"
    if [ -f "$d/nvidia.raw" ] || [ -x "$d/nvidia-preinit-driver.sh" ]; then
        HAS_DRIVER=true
    fi
    break
done

echo "=== Uninstall plan ==="
echo "  Persist dir:             ${PERSIST_DIR:-<none found>}"
echo "  Custom driver installed: $HAS_DRIVER"
echo ""

if ! $HAS_DRIVER; then
    echo "Nothing to uninstall — no custom driver from this repo detected."
    echo "(If you also installed nvidia-mig-support, run uninstall-nvidia-mig for that.)"
    exit 0
fi

if [ -z "$ORIGINAL" ] && ! $SKIP_BACKUP_CHECK; then
    cat >&2 <<EOF
ERROR: nvidia-original.raw backup not found in /mnt/*/.config/nvidia-gpu/.
       Refusing to revert the driver without a stock copy on hand.
       Run scripts/recover-stock-nvidia.sh first (downloads + extracts
       stock nvidia.raw from the official TrueNAS .update). Or pass
       --skip-backup-check if you accept the risk.
EOF
    exit 1
fi

# ── Stop GPU apps + free the GPU before the swap ──
echo "Stopping app services..."
midclt call -j docker.update '{"nvidia": false}' >/dev/null \
    || echo "WARN: docker.update failed — continuing"
DOCKER_NVIDIA_DISABLED=1
if [ -x /usr/bin/nvidia-smi ]; then
    printf "  Waiting for GPU to be released... 0s/120s"
    for attempt in $(seq 1 24); do
        N=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l || echo 0)
        if [ "${N:-0}" -eq 0 ]; then printf "\r  GPU released                                            \n"; break; fi
        printf "\r  Waiting for %d GPU process(es)... %ds/120s" "$N" "$((attempt * 5))"; sleep 5
    done
    [ "${attempt:-0}" -eq 24 ] && echo ""
fi

# ── Single unmerge → restore stock → re-merge ──
echo "Unmerging sysext..."
systemd-sysext unmerge

if [ -n "$ORIGINAL" ]; then
    echo "Restoring stock nvidia.raw from $ORIGINAL"
    USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
    if [ -z "$USR_DATASET" ]; then
        echo "ERROR: could not determine the ZFS dataset for /usr" >&2; exit 1
    fi
    zfs set readonly=off "$USR_DATASET"; USR_WAS_WRITABLE=1
    cp "$ORIGINAL" "$LIVE_NVIDIA"
    [ -f "${LIVE_NVIDIA}.bak" ] && rm -f "${LIVE_NVIDIA}.bak" 2>/dev/null || true
    zfs set readonly=on "$USR_DATASET"; USR_WAS_WRITABLE=0
    mkdir -p /etc/extensions
    ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw
else
    echo "WARN: no nvidia-original.raw backup; leaving live nvidia.raw in place"
    echo "      (run recover-stock-nvidia.sh later to fetch one)"
fi

echo "Re-merging sysext..."
systemd-sysext merge
systemctl daemon-reload

# Restore the nvidia toggle (persists across reboot).
echo "Restoring nvidia toggle..."
midclt call docker.update '{"nvidia": true}' >/dev/null 2>&1 || true
DOCKER_NVIDIA_DISABLED=0

# ── Deregister the driver PREINIT ──
DRIVER_PREINIT_ID=$(midclt call initshutdownscript.query 2>/dev/null | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        h = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-preinit-driver' in h:
            print(s['id'], end=''); break
except Exception:
    pass" 2>/dev/null)
if [ -n "$DRIVER_PREINIT_ID" ]; then
    midclt call initshutdownscript.delete "$DRIVER_PREINIT_ID" >/dev/null 2>&1 \
        && echo "Deregistered driver PREINIT entry (id $DRIVER_PREINIT_ID)" \
        || echo "WARN: deregister driver PREINIT failed"
else
    echo "No driver PREINIT entry found"
fi

# ── Cleanup persist (nvidia-original.raw always kept) ──
if ! $KEEP_PERSIST && [ -n "$PERSIST_DIR" ]; then
    rm -f "$PERSIST_DIR/nvidia.raw" "$PERSIST_DIR/nvidia-preinit-driver.sh"
    rm -rf "$PERSIST_DIR/build" "$PERSIST_DIR/scripts" "$PERSIST_DIR/logs"
    echo "Removed custom nvidia.raw, PREINIT helper, and build/scripts/logs/ from $PERSIST_DIR"
    if [ -d "$PERSIST_DIR/cache" ]; then
        if $KEEP_CACHE; then
            echo "  ($PERSIST_DIR/cache retained: $(du -sh "$PERSIST_DIR/cache" 2>/dev/null | cut -f1 || echo '?') — --keep-cache)"
        else
            rm -rf "$PERSIST_DIR/cache"
            echo "Removed $PERSIST_DIR/cache (pass --keep-cache next time for a fast re-install)"
        fi
    fi
    echo "  (nvidia-original.raw kept — pass --keep-persist to retain everything)"
fi

echo ""
echo "=== Verification ==="
systemd-sysext status || true
cat <<EOF

=== Uninstall complete — REBOOT REQUIRED ===

Kernel modules currently loaded are still the custom driver's. After reboot,
modules load fresh from the stock sysext and match the userspace libs.

Run: sudo reboot
EOF
