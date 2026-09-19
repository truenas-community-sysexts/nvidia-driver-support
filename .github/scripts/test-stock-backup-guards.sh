#!/usr/bin/env bash
# Exercise the stock-backup and download-resume guards without a TrueNAS box.
# Run in CI (lint.yml) and safe to run locally; needs squashfs-tools
# (mksquashfs + unsquashfs).
#
# The guards are functions inside self-contained curl|bash scripts, so this
# lifts each one out of the script text, checks that the duplicated copies
# are identical, and runs them against real squashfs images with a faked
# `uname -r`. Exits non-zero if any case fails.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="${ROOT}/scripts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for cmd in mksquashfs unsquashfs; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: $cmd not found (install squashfs-tools)" >&2; exit 1; }
done

FAILS=0
pass() { echo "ok   - $*"; }
fail() { echo "FAIL - $*"; FAILS=$((FAILS+1)); }
expect() {   # $1=case $2=expected $3=actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: expected '$2', got '$3'"; fi
}

# Print one top-level function definition (from "name() {" to the first "}"
# at column 0) out of a script.
fn_src() {
    awk -v f="$2" 'index($0, f "() {") == 1 {p=1} p {print} p && /^}/ {exit}' "$1"
}

# ── The shared helpers are identical in every script that carries them ──
for fn in raw_module_kernels stock_backup_problem; do
    ref="$(fn_src "$S/install-nvidia-driver.sh" "$fn")"
    if [ -z "$ref" ]; then fail "$fn not found in install-nvidia-driver.sh"; continue; fi
    for f in uninstall-nvidia-driver.sh recover-stock-nvidia.sh; do
        if [ "$(fn_src "$S/$f" "$fn")" = "$ref" ]; then
            pass "$fn in $f matches install-nvidia-driver.sh"
        else
            fail "$fn in $f differs from install-nvidia-driver.sh"
        fi
    done
done

eval "$(fn_src "$S/install-nvidia-driver.sh" raw_module_kernels)"
eval "$(fn_src "$S/install-nvidia-driver.sh" stock_backup_problem)"
eval "$(fn_src "$S/recover-stock-nvidia.sh" prepare_download_resume)"

# The helpers only ever call `uname -r`.
RUNNING="6.18.42-production+truenas"
OLD="6.12.33-production+truenas"
uname() { echo "$RUNNING"; }

# A minimal stock-like nvidia.raw with kernel modules for each kernel given.
mkraw() {
    local out="$1" tree k
    shift
    tree="$(mktemp -d "${TMP}/tree.XXXXXX")"
    mkdir -p "${tree}/usr/bin" "${tree}/usr/lib/extension-release.d"
    : > "${tree}/usr/bin/nvidia-smi"
    : > "${tree}/usr/lib/extension-release.d/extension-release.nvidia"
    for k in "$@"; do
        mkdir -p "${tree}/usr/lib/modules/${k}/video"
        : > "${tree}/usr/lib/modules/${k}/video/nvidia.ko"
        : > "${tree}/usr/lib/modules/${k}/modules.dep"
    done
    mksquashfs "$tree" "$out" -noappend -all-root >/dev/null
}

# ── Stock backup: fresh / stale / missing ──
mkraw "$TMP/fresh.raw" "$RUNNING"
mkraw "$TMP/stale.raw" "$OLD"
mkraw "$TMP/both.raw" "$OLD" "$RUNNING"
mkraw "$TMP/debug-only.raw" "6.18.42-debug+truenas"
mkraw "$TMP/lookalike.raw" "${RUNNING}2"
mkraw "$TMP/no-modules.raw"
echo "not a squashfs image" > "$TMP/garbage.raw"

expect "fresh backup (modules for the running kernel) is usable" \
    "" "$(stock_backup_problem "$TMP/fresh.raw")"
expect "stale backup (modules for the old kernel) is refused" \
    "stale:${OLD}" "$(stock_backup_problem "$TMP/stale.raw")"
expect "missing backup is reported as missing" \
    "missing" "$(stock_backup_problem "$TMP/does-not-exist.raw")"
expect "backup with modules for several kernels incl. the running one is usable" \
    "" "$(stock_backup_problem "$TMP/both.raw")"
expect "backup for another flavor of the same kernel version is stale" \
    "stale:6.18.42-debug+truenas" "$(stock_backup_problem "$TMP/debug-only.raw")"
expect "a kernel name that only starts with the running one does not match" \
    "stale:${RUNNING}2" "$(stock_backup_problem "$TMP/lookalike.raw")"
expect "backup with no kernel modules is stale" \
    "stale:none found" "$(stock_backup_problem "$TMP/no-modules.raw")"
expect "unreadable backup is stale" \
    "stale:none found" "$(stock_backup_problem "$TMP/garbage.raw")"
expect "raw_module_kernels lists every kernel, space-separated" \
    "${OLD} ${RUNNING}" "$(raw_module_kernels "$TMP/both.raw")"

# ── recover-stock-nvidia.sh: resume only a partial of the same URL ──
URL_NEW="https://update-public.sys.truenas.net/TrueNAS-26-BETA/TrueNAS-26.0.0-BETA.3.update"
URL_OLD="https://download.truenas.com/TrueNAS-SCALE-Goldeye/25.10.1/TrueNAS-SCALE-25.10.1.update?download=1"
W="$TMP/recovery"
mkdir -p "$W"

rm -f "$W"/truenas.update*
prepare_download_resume "$W/truenas.update" "$URL_NEW" >/dev/null
expect "no partial: nothing to resume, URL recorded" \
    "absent|${URL_NEW}" "$([ -e "$W/truenas.update" ] && echo present || echo absent)|$(cat "$W/truenas.update.url")"

echo "partial bytes" > "$W/truenas.update"
printf '%s\n' "$URL_NEW" > "$W/truenas.update.url"
prepare_download_resume "$W/truenas.update" "$URL_NEW" >/dev/null
expect "partial of the same version is kept for resume" \
    "partial bytes|${URL_NEW}" "$(cat "$W/truenas.update")|$(cat "$W/truenas.update.url")"

echo "old version bytes" > "$W/truenas.update"
printf '%s\n' "$URL_OLD" > "$W/truenas.update.url"
out="$(prepare_download_resume "$W/truenas.update" "$URL_NEW")"
expect "partial of another version is discarded and the new URL recorded" \
    "absent|${URL_NEW}" "$([ -e "$W/truenas.update" ] && echo present || echo absent)|$(cat "$W/truenas.update.url")"
case "$out" in
    "Discarding ${W}/truenas.update: it is not a download of ${URL_NEW}") pass "discard is announced" ;;
    *) fail "discard message: got '$out'" ;;
esac

echo "legacy leftover" > "$W/truenas.update"
rm -f "$W/truenas.update.url"
prepare_download_resume "$W/truenas.update" "$URL_NEW" >/dev/null
expect "partial with no recorded URL (from before the record existed) is discarded" \
    "absent|${URL_NEW}" "$([ -e "$W/truenas.update" ] && echo present || echo absent)|$(cat "$W/truenas.update.url")"

echo ""
if [ "$FAILS" -gt 0 ]; then
    echo "${FAILS} case(s) failed"
    exit 1
fi
echo "all cases passed"
