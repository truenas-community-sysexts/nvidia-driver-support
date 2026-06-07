#!/usr/bin/env bash
# TrueNAS PREINIT for the custom-driver sysext path.
#
# Two responsibilities, both must run before Docker starts:
#   1. Survive TrueNAS updates. /usr gets replaced on update, which wipes
#      our custom nvidia.raw and restores stock. Compare SHAs between live
#      and persistent backup; if they differ, restore the custom.
#   2. Detect kernel-version mismatch. TrueNAS updates often bump the
#      kernel; our bundled nvidia.ko targets a specific kernel and will
#      simply not load against a different one. Surface the mismatch
#      loudly in syslog with a pointer at the release page so the user
#      doesn't end up debugging "nvidia-smi reports no devices" via
#      strace.
#
# This is the only PREINIT this repo registers — it owns the custom driver
# swap. If nvidia-mig-support is also installed (MIG layered on top of this
# driver), it registers its OWN separate PREINIT for the MIG service. The
# two have no ordering dependency.
#
# Registered via midclt initshutdownscript by install-nvidia-driver.sh.
# Logs to both stdout (visible via journalctl -u <init-shutdown-script>)
# and syslog tagged `nvidia-preinit-driver` (journalctl -b -t nvidia-preinit-driver
# for boot-scoped filtering).
#
# Never exits non-zero — must not block boot. All errors are logged and
# the script continues. The kernel-mismatch and SHA-restore branches
# print clear remediation hints.

set -uo pipefail

log() {
    echo "[nvidia-preinit-driver] $*"
    logger -t nvidia-preinit-driver "$*" 2>/dev/null || true
}

# Track /usr writable state for the trap. Without this, a SIGTERM
# between `zfs set readonly=off` and the matching readonly=on would
# leave /usr writable until the next reboot.
USR_WAS_WRITABLE=0
USR_DATASET=""

restore_usr_readonly() {
    if [ "$USR_WAS_WRITABLE" = "1" ] && [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        USR_WAS_WRITABLE=0
    fi
}
trap restore_usr_readonly EXIT INT TERM

log "Starting (boot: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown))"

REPO="truenas-community-sysexts/nvidia-driver-support"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"

# Find persistent custom nvidia.raw
PERSIST_NVIDIA=""
for f in /mnt/*/.config/nvidia-gpu/nvidia.raw; do
    [ -f "$f" ] && PERSIST_NVIDIA="$f" && break
done

# ── Phase 1: restore-from-backup if live differs from persistent ─────────
if [ -z "$PERSIST_NVIDIA" ]; then
    log "No persistent custom nvidia.raw found; nothing to restore"
else
    log "Persistent custom: $PERSIST_NVIDIA"
    PERSIST_SHA=$(sha256sum "$PERSIST_NVIDIA" 2>/dev/null | awk '{print $1}')
    LIVE_SHA=""
    [ -f "$LIVE_NVIDIA" ] && LIVE_SHA=$(sha256sum "$LIVE_NVIDIA" 2>/dev/null | awk '{print $1}')

    # Empty-SHA defensive: if either hash failed to compute, treat as
    # mismatch and reinstall rather than treating two empty strings as
    # equal (which is what the bare equality check would do).
    NEED_RESTORE=true
    if [ -z "$PERSIST_SHA" ] || [ -z "$LIVE_SHA" ]; then
        log "WARNING: failed to read sha256 (live='${LIVE_SHA}', persist='${PERSIST_SHA}'); restoring defensively"
    elif [ "$LIVE_SHA" = "$PERSIST_SHA" ]; then
        log "Live nvidia.raw matches persistent custom; no restore needed"
        NEED_RESTORE=false
    else
        log "Live nvidia.raw differs from custom (likely after TrueNAS update); restoring"
        log "  live SHA:    $LIVE_SHA"
        log "  persist SHA: $PERSIST_SHA"
    fi

    if $NEED_RESTORE; then
        systemd-sysext unmerge 2>/dev/null || true

        USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
        if [ -n "$USR_DATASET" ]; then
            if zfs set readonly=off "$USR_DATASET" 2>/dev/null; then
                USR_WAS_WRITABLE=1
                if cp "$PERSIST_NVIDIA" "$LIVE_NVIDIA"; then
                    log "Restored custom nvidia.raw"
                else
                    log "ERROR: failed to copy custom nvidia.raw"
                fi
                zfs set readonly=on "$USR_DATASET" 2>/dev/null \
                    || log "WARN: failed to restore /usr readonly"
                USR_WAS_WRITABLE=0
            else
                log "ERROR: failed to set $USR_DATASET writable; cannot restore"
            fi
        else
            log "WARN: could not resolve /usr dataset; cannot restore"
        fi

        mkdir -p /etc/extensions
        ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw
        systemd-sysext merge 2>/dev/null || log "WARN: sysext merge failed"
        systemctl daemon-reload 2>/dev/null || true
    fi
fi

# ── Phase 2: kernel-version mismatch detection ────────────────────────────
# nvidia.ko is built against a specific kernel. After a TrueNAS update
# bumps the kernel, our bundled module silently won't load and the user
# is left with "nvidia-smi: NVIDIA-SMI couldn't find any device" with no
# obvious cause. Surface the mismatch with a clear pointer to rebuild the
# sysext for the new kernel (re-run the install one-liner, or the staged
# build-on-host.sh with --rebuild) — the build is always done on-host.
#
# Module loading is normally driven by udev when the GPU PCI device is
# probed — we don't insmod here. We only verify the file exists for the
# running kernel.
#
# Path-finding strategy: search anywhere under /usr/lib/modules/<kver>/
# rather than hard-coding the subdir. On TrueNAS the merged custom sysext
# lands nvidia.ko at .../video/nvidia.ko (not .../updates/dkms/nvidia.ko
# like the build-script staging would suggest — depmod / installer
# normalize the layout on merge). Also tolerant of compressed modules
# (nvidia.ko.zst / .xz / .gz) for future kernels.
RUNNING_KVER=$(uname -r)
RUNNING_KO_DIR="/usr/lib/modules/${RUNNING_KVER}"
RUNNING_KO=""
if [ -d "$RUNNING_KO_DIR" ]; then
    RUNNING_KO=$(find "$RUNNING_KO_DIR" -name 'nvidia.ko*' -type f -print 2>/dev/null | head -1)
fi
if [ -n "$RUNNING_KO" ]; then
    log "Kernel-module path matches running kernel ${RUNNING_KVER} (${RUNNING_KO})"
else
    # Scan /usr/lib/modules/ for any nvidia.ko in a different kernel
    # directory — that's almost certainly the version the sysext was
    # built for.
    SYSEXT_KVER=""
    for d in /usr/lib/modules/*/; do
        [ -d "$d" ] || continue
        name=${d%/}
        name=${name##*/}
        [ "$name" = "$RUNNING_KVER" ] && continue
        if [ -n "$(find "$d" -name 'nvidia.ko*' -type f -print 2>/dev/null | head -1)" ]; then
            SYSEXT_KVER="$name"
            break
        fi
    done
    if [ -n "$SYSEXT_KVER" ]; then
        log "ERROR: kernel-version mismatch — running ${RUNNING_KVER} but sysext bundles modules for ${SYSEXT_KVER}"
        log "ERROR: TrueNAS was likely updated to a new kernel. Rebuild nvidia.raw against ${RUNNING_KVER}:"
        log "ERROR:   curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install-nvidia-driver.sh | sudo bash -s -- --rebuild"
        log "ERROR:   (the one-liner detects the new TrueNAS version and rebuilds the driver sysext on this host)"
        # Faster path if the build helpers are already staged from a prior install.
        PERSIST_SCRIPTS=""
        for d in /mnt/*/.config/nvidia-gpu/scripts; do
            [ -x "${d}/build-on-host.sh" ] && PERSIST_SCRIPTS="$d" && break
        done
        if [ -n "$PERSIST_SCRIPTS" ]; then
            log "ERROR: Or rebuild directly (skip the install-script round-trip):"
            log "ERROR:   sudo ${PERSIST_SCRIPTS}/build-on-host.sh --help"
        fi
    else
        log "WARNING: nvidia.ko not found anywhere under ${RUNNING_KO_DIR}/ and no other kernel-version directory has one either"
        log "WARNING: the sysext may not be merged, or the build is broken — check 'systemd-sysext status'"
    fi
fi

log "Done"
exit 0
