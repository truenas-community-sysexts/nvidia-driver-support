#!/usr/bin/env bash
# Install a chosen NVIDIA driver on TrueNAS by swapping the stock nvidia.raw
# sysext for one built on this host for the driver you pick.
#
# Three ways to choose a driver:
#
#   sudo ./install-nvidia-driver.sh                     # detect card, recommend, confirm
#   sudo ./install-nvidia-driver.sh --branch=legacy-580 # last branch for a card series
#   sudo ./install-nvidia-driver.sh --driver=595.71.05  # an exact open driver version
#   sudo ./install-nvidia-driver.sh --custom-run=PATH   # a patched / hand-supplied .run
#
# What it does (every path):
#   - Resolves the target driver version + kernel-module flavor (open for
#     Turing+, proprietary for the legacy branches).
#   - Builds nvidia.raw on THIS host inside a transient ubuntu:24.04 docker
#     container (NVIDIA's EULA prohibits us redistributing the proprietary
#     userspace, so nothing is downloaded pre-built — you accept NVIDIA's EULA
#     when the .run installer runs with --silent). Cached for re-installs.
#   - Swaps TrueNAS's stock nvidia.raw with the freshly built one (brief
#     /usr r/w via a zfs readonly toggle), keeping nvidia-original.raw as a
#     backup so you can always get back to stock.
#   - Registers a TrueNAS PREINIT entry that restores the custom nvidia.raw
#     after a TrueNAS update wipes /usr, and flags a kernel bump.
#   - **Reboot required** — live-swapping the driver leaves stale kernel
#     modules in memory; nvidia-smi reports a driver/library mismatch until
#     you reboot.
#
# This repo is the driver-swap owner. To also run MIG, install
# nvidia-mig-support in its DEFAULT mode afterwards (it layers on top of
# whatever driver is present — do NOT use its --with-driver path alongside
# this one).
#
# Driver versions come from catalog/driver-catalog.json (refreshed daily by
# CI). `--list` prints it. The catalog also maps your card's chip family to a
# recommended branch for the interactive default.
#
# Flags:
#   --branch=NAME         latest | legacy-580 | legacy-470
#                         (resolves to the catalog's pinned version for that branch).
#                         Fermi/Tesla (390.x/340.x) are not branches — they don't
#                         build unpatched; use --custom-run/--run-url with a patched .run.
#   --driver=X.Y.Z        an exact NVIDIA driver version (need not be in the catalog)
#   --custom-run=PATH     a local NVIDIA .run installer (patched/vGPU/etc). Filename
#                         must be NVIDIA-Linux-x86_64-<X.Y.Z>[-no-compat32].run
#   --run-url=URL         download an NVIDIA .run from URL and install it — a beta
#                         or any non-catalog version. Same filename rule as
#                         --custom-run. Not tracked or smoke-tested.
#   --release=TAG         pin a published release (TAG form: v<N>): source the
#                         install tooling + catalog from that release's assets
#                         instead of main. Releases are tooling+catalog
#                         snapshots — they do NOT pin a driver; pick the driver
#                         with --branch/--driver as usual. With no --release the
#                         repo's latest release is used (falling back to main).
#   --kmod=open|proprietary
#                         kernel-module flavor. Auto-derived from the branch/version
#                         if omitted (open for Turing+, proprietary for legacy). When
#                         run interactively without this flag, the picker offers the
#                         choice for drivers that ship both (515+).
#   --driver-sysext=PATH  install a pre-built nvidia.raw (skips the on-host build)
#   --rebuild             ignore any cached nvidia.raw and rebuild from scratch
#   --list                print the driver catalog and exit
#   --catalog=PATH        use a local catalog file instead of the bundled/remote one
#   --pool=NAME           ZFS pool for persistent storage (/mnt/NAME/.config/nvidia-gpu)
#   --persist-path=PATH   exact persist dir (must be /mnt/<pool>/.config/nvidia-gpu)
#   --skip-backup-check   don't refuse if the nvidia-original.raw backup is missing
#                         (at your own risk — you may be unable to recover stock later)
#   --yes                 assume "yes" to confirmations (non-interactive)
#   --force               bypass kmod/architecture safety refusals and best-effort
#                         branch confirmation
#   --check               read-only probe of an existing install; exits 1 on failure
#   --dry-run             validate + resolve, but skip every mutation (logs
#                         `[dry-run] would: ...`). Mutually exclusive with --check.
#   -h, --help            show this help and exit
#
# Pool selection priority: --persist-path > --pool > existing config dir >
# only data pool > interactive prompt (multi-pool) > error (no tty + ambiguous).

set -euo pipefail

REPO="truenas-community-sysexts/nvidia-driver-support"
SYSEXT_DIR="/usr/share/truenas/sysext-extensions"
LIVE_NVIDIA="${SYSEXT_DIR}/nvidia.raw"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"

BRANCH=""
DRIVER_VER=""
CUSTOM_RUN=""
RUN_URL=""            # --run-url=URL; downloaded then treated like --custom-run
KMOD_TYPE=""          # empty = auto-derive
DRIVER_SRC=""
RELEASE_TAG=""        # --release=TAG (v<N>); empty = auto-resolve repo's latest release
RESOLVED_TAG=""       # set by resolve_release_for_install (release used for sourcing)
RELEASE_DL_BASE=""    # release asset download base URL when a release is in use
REBUILD=false
LIST_MODE=false
CATALOG_PATH=""
POOL_NAME=""
PERSIST_PATH=""
SKIP_BACKUP_CHECK=false
ASSUME_YES=false
FORCE=false
CHECK_MODE=false
DRY_RUN=false
INTERACTIVE_PICK=false   # set true when the interactive numbered picker runs

for arg in "$@"; do
    case "$arg" in
        --branch=*) BRANCH="${arg#*=}" ;;
        --driver=*) DRIVER_VER="${arg#*=}" ;;
        --custom-run=*) CUSTOM_RUN="${arg#*=}" ;;
        --run-url=*) RUN_URL="${arg#*=}" ;;
        --release=*) RELEASE_TAG="${arg#*=}" ;;
        --kmod=*) KMOD_TYPE="${arg#*=}" ;;
        --driver-sysext=*) DRIVER_SRC="${arg#*=}" ;;
        --rebuild) REBUILD=true ;;
        --list) LIST_MODE=true ;;
        --catalog=*) CATALOG_PATH="${arg#*=}" ;;
        --pool=*) POOL_NAME="${arg#*=}" ;;
        --persist-path=*) PERSIST_PATH="${arg#*=}" ;;
        --skip-backup-check) SKIP_BACKUP_CHECK=true ;;
        --yes|-y) ASSUME_YES=true ;;
        --force) FORCE=true ;;
        --check) CHECK_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
        *) echo "Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# --- Mutually-exclusive / shape validation ---
if $CHECK_MODE && $DRY_RUN; then
    echo "ERROR: --check and --dry-run are mutually exclusive" >&2; exit 2
fi
_src_count=0
[ -n "$BRANCH" ] && _src_count=$((_src_count+1))
[ -n "$DRIVER_VER" ] && _src_count=$((_src_count+1))
[ -n "$CUSTOM_RUN" ] && _src_count=$((_src_count+1))
[ -n "$RUN_URL" ] && _src_count=$((_src_count+1))
if [ "$_src_count" -gt 1 ]; then
    echo "ERROR: pick at most one of --branch / --driver / --custom-run / --run-url" >&2; exit 2
fi
if [ -n "$DRIVER_SRC" ] && { [ -n "$CUSTOM_RUN" ] || [ -n "$RUN_URL" ] || [ -n "$DRIVER_VER" ] || [ -n "$BRANCH" ]; }; then
    echo "ERROR: --driver-sysext installs a pre-built .raw; it can't combine with a driver selector" >&2; exit 2
fi
if [ -n "$KMOD_TYPE" ]; then
    case "$KMOD_TYPE" in
        open|proprietary) ;;
        *) echo "ERROR: --kmod must be 'open' or 'proprietary' (got: $KMOD_TYPE)" >&2; exit 2 ;;
    esac
fi

# ─────────────────────────────────────────────────────────────────────────
# Logging / dry-run helpers (mirror install-mig-sysext.sh)
# ─────────────────────────────────────────────────────────────────────────
if_real() {
    if $DRY_RUN; then printf '[dry-run] would: %s\n' "$*" >&2; else "$@"; fi
}

ELAPSED=0
CAPTURED_OUT=""
run_with_elapsed_capture() {
    local label="$1"; shift
    local start outfile ticker_pid rc
    start=$(date +%s)
    outfile=$(mktemp)
    (
        while sleep 1; do
            printf "\r%s... %ds" "$label" "$(($(date +%s) - start))"
        done
    ) &
    ticker_pid=$!
    "$@" >"$outfile" 2>&1
    rc=$?
    kill "$ticker_pid" 2>/dev/null
    wait "$ticker_pid" 2>/dev/null
    ELAPSED=$(($(date +%s) - start))
    CAPTURED_OUT=$(cat "$outfile")
    rm -f "$outfile"
    printf "\r%80s\r" ""
    return $rc
}

# ─────────────────────────────────────────────────────────────────────────
# Version / tag parsing helpers
# ─────────────────────────────────────────────────────────────────────────
detect_truenas_version() {
    local v i
    for i in 1 2 3; do
        v=$(midclt call system.info 2>/dev/null | python3 -c '
import sys, json
try:
    print(json.load(sys.stdin)["version"])
except Exception:
    pass' 2>/dev/null) || true
        if [ -n "$v" ]; then printf '%s\n' "$v"; return 0; fi
        [ "$i" -lt 3 ] && sleep 1
    done
    return 1
}

resolve_truenas_codename() {
    case "$1" in
        25.*) echo "Goldeye" ;;
        *)    echo "" ;;
    esac
}

# Newest published release tag for the repo. Releases are tooling+catalog
# snapshots tagged v<N> (not per-driver/per-TrueNAS), so we just take the
# latest. Echoes the tag, or nothing on no-release / API error (caller treats
# "nothing" as "use main").
latest_release_tag() {
    curl -sS --max-time 30 \
        "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if isinstance(data, dict) and data.get('tag_name'):
    print(data['tag_name'], end='')
" 2>/dev/null || true
}

# Decide which release (if any) supplies the install tooling + catalog. Sets
# globals RESOLVED_TAG and RELEASE_DL_BASE. Explicit --release is trusted
# verbatim; otherwise use the repo's latest release. A full local checkout
# needs no release (helpers are local). Releases don't pin a driver — this only
# governs where the scripts + catalog come from.
resolve_release_for_install() {
    if [ -n "$RELEASE_TAG" ]; then
        RESOLVED_TAG="$RELEASE_TAG"
    elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/build-nvidia-sysext.sh" ]; then
        return 0
    else
        local tag
        tag=$(latest_release_tag)
        [ -n "$tag" ] || { echo "No published release found; using install tooling from main." >&2; return 0; }
        RESOLVED_TAG="$tag"
    fi
    RELEASE_DL_BASE="https://github.com/${REPO}/releases/download/${RESOLVED_TAG}"
    echo "Release: ${RESOLVED_TAG} (sourcing install tooling + catalog from its assets)" >&2
}

# Download a repo file, preferring the resolved release's (flat) assets —
# version-pinned — and falling back to main. $1=asset basename,
# $2=path-under-repo for the main fallback, $3=dest.
fetch_repo_file() {
    local asset="$1" main_rel="$2" dest="$3"
    if [ -n "$RELEASE_DL_BASE" ] \
        && curl -fL --retry 3 -o "$dest" "${RELEASE_DL_BASE}/${asset}" 2>/dev/null; then
        return 0
    fi
    [ -z "$RELEASE_DL_BASE" ] || echo "WARN: '${asset}' not in release ${RESOLVED_TAG}; falling back to main" >&2
    curl -fL --retry 3 -o "$dest" "${RAW_BASE}/${main_rel}"
}

# Driver version out of an NVIDIA .run filename. Accepts both the no-compat32
# variant and the plain .run (the latter for --run-url / arbitrary downloads).
# VER is X.Y.Z (modern) or X.Y (older legacy, e.g. 390.157).
parse_nvidia_version_from_run_file() {
    basename "$1" \
        | sed -nE 's/^NVIDIA-Linux-x86_64-([0-9]+\.[0-9]+(\.[0-9]+)?)(-no-compat32)?\.run$/\1/p'
}

read_raw_driver_version() {
    [ -f "$1" ] || return 0
    unsquashfs -l "$1" 2>/dev/null \
        | grep -oE 'libnvidia-ml\.so\.[0-9]+\.[0-9]+\.[0-9]+' \
        | head -1 | sed 's/^libnvidia-ml\.so\.//' || true
}

read_raw_kernel_version() {
    [ -f "$1" ] || return 0
    unsquashfs -l "$1" 2>/dev/null \
        | sed -nE 's|.*usr/lib/modules/([^/[:space:]]+)$|\1|p' \
        | sort -u | head -1
}

cache_valid_for_target() {
    local target_drv="$1"
    local cached="${PERSIST_DIR}/nvidia.raw"
    [ -f "$cached" ] || return 1
    local cached_drv cached_kver running_kver
    cached_drv=$(read_raw_driver_version "$cached")
    cached_kver=$(read_raw_kernel_version "$cached")
    running_kver=$(uname -r)
    [ -n "$cached_drv" ] && [ "$cached_drv" = "$target_drv" ] || return 1
    [ -n "$cached_kver" ] && [ "$cached_kver" = "$running_kver" ] || return 1
    return 0
}

# ─────────────────────────────────────────────────────────────────────────
# Catalog loading + queries (python3 — already a hard dependency)
# ─────────────────────────────────────────────────────────────────────────
CATALOG_JSON=""
load_catalog() {
    # Priority: --catalog=PATH > local checkout copy > fetch from main.
    local candidate
    if [ -n "$CATALOG_PATH" ]; then
        [ -f "$CATALOG_PATH" ] || { echo "ERROR: --catalog not found: $CATALOG_PATH" >&2; exit 1; }
        CATALOG_JSON=$(cat "$CATALOG_PATH")
    elif [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/../catalog/driver-catalog.json" ]; then
        candidate="${SCRIPT_DIR}/../catalog/driver-catalog.json"
        CATALOG_JSON=$(cat "$candidate")
    else
        # Prefer the resolved release's pinned catalog; fall back to main.
        CATALOG_JSON=""
        if [ -n "$RELEASE_DL_BASE" ]; then
            CATALOG_JSON=$(curl -fsSL --retry 3 --max-time 30 "${RELEASE_DL_BASE}/driver-catalog.json" 2>/dev/null) || CATALOG_JSON=""
        fi
        if [ -z "$CATALOG_JSON" ]; then
            CATALOG_JSON=$(curl -fsSL --retry 3 --max-time 30 "${RAW_BASE}/catalog/driver-catalog.json") \
                || { echo "ERROR: could not fetch driver catalog from ${RAW_BASE}/catalog/driver-catalog.json" >&2; exit 1; }
        fi
    fi
    # Validate it parses.
    printf '%s' "$CATALOG_JSON" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null \
        || { echo "ERROR: driver catalog is not valid JSON" >&2; exit 1; }
}

# Resolve a branch name to its concrete driver version (handles the
# "latest" branch's "track":"open_latest[0]" indirection).
catalog_branch_version() {
    printf '%s' "$CATALOG_JSON" | BR="$1" python3 -c '
import sys, json, os, re
c = json.load(sys.stdin); br = os.environ["BR"]
b = c.get("branches", {}).get(br)
if not b: sys.exit(0)
if "version" in b:
    print(b["version"], end=""); sys.exit(0)
t = b.get("track", "")
m = re.match(r"open_latest\[(\d+)\]$", t)
if m:
    lst = c.get("open_latest", [])
    i = int(m.group(1))
    if i < len(lst): print(lst[i], end="")
'
}

catalog_branch_field() {
    # $1=branch $2=field(kmod|support|note)
    printf '%s' "$CATALOG_JSON" | BR="$1" FLD="$2" python3 -c '
import sys, json, os
c = json.load(sys.stdin)
b = c.get("branches", {}).get(os.environ["BR"], {})
print(b.get(os.environ["FLD"], ""), end="")
'
}

catalog_branch_names() {
    printf '%s' "$CATALOG_JSON" | python3 -c '
import sys, json
c = json.load(sys.stdin)
for k in c.get("branches", {}): print(k)
'
}

catalog_open_latest() {
    printf '%s' "$CATALOG_JSON" | python3 -c '
import sys, json
c = json.load(sys.stdin)
for v in c.get("open_latest", []): print(v)
'
}

# Map an NVIDIA chip codename (e.g. GP107) to a recommended branch via
# chip_map, longest-prefix first. Echoes the branch name or nothing.
catalog_chip_branch() {
    printf '%s' "$CATALOG_JSON" | CODE="$1" python3 -c '
import sys, json, os
c = json.load(sys.stdin)
code = os.environ["CODE"].upper()
cm = c.get("chip_map", {})
for L in (3, 2, 1):
    if len(code) >= L and code[:L] in cm:
        print(cm[code[:L]], end=""); break
'
}

# Default kernel-module flavor for a driver version when nothing else
# decides it: proprietary below 515 (no open variant), open at/above.
auto_kmod_for_version() {
    local major="${1%%.*}"
    if [ "$major" -ge 515 ] 2>/dev/null; then echo "open"; else echo "proprietary"; fi
}

# ─────────────────────────────────────────────────────────────────────────
# GPU detection — chip codename + recommended branch from lspci
# ─────────────────────────────────────────────────────────────────────────
DETECTED_CODENAME=""
DETECTED_NAME=""
DETECTED_BRANCH=""
DETECTED_DEVICE_ID=""
DETECTED_UNCLASSIFIED=false
DETECTED_LEGACY_UNSUPPORTED=false   # Fermi/Tesla: recognized, but no catalog branch
# Detect an installed NVIDIA GPU and recommend a branch.
#
# Presence comes from /sys (vendor 0x10de + display class 0x03xx), so it works
# even when lspci is absent. A chip codename — needed for a precise branch via
# chip_map — is best-effort from lspci: a card newer than the host's PCI ID
# database prints as "NVIDIA Corporation Device <id>" with NO codename (e.g. a
# Blackwell 10de:2bb1 on an older pci.ids). In that "present but unclassified"
# case we default to the latest OPEN driver, which is correct for anything
# newer than the database (Turing and up). Returns 0 if any NVIDIA display GPU
# is present (classified or not), 1 only if none is found.
detect_gpu() {
    local d v cls dev=""
    for d in /sys/bus/pci/devices/*; do
        [ -r "$d/vendor" ] && [ -r "$d/class" ] || continue
        v=$(cat "$d/vendor" 2>/dev/null) || continue
        [ "$v" = "0x10de" ] || continue
        cls=$(cat "$d/class" 2>/dev/null)
        case "$cls" in 0x03*) dev="$d"; break ;; esac   # 0300 VGA / 0302 3D
    done
    [ -n "$dev" ] || return 1
    DETECTED_DEVICE_ID=$(cat "$dev/device" 2>/dev/null | sed 's/^0x//')

    # Best-effort codename + marketing name from lspci (when present and the
    # chip is in the local PCI ID database).
    if command -v lspci >/dev/null 2>&1; then
        local line
        line=$(lspci -nn -d 10de: 2>/dev/null | grep -iE 'VGA|3D|Display' | head -1)
        [ -n "$line" ] || line=$(lspci -nn -d 10de: 2>/dev/null | head -1)
        DETECTED_CODENAME=$(printf '%s' "$line" \
            | sed -nE 's/.*NVIDIA Corporation ([A-Z]{1,2}[0-9]+[A-Z]?).*/\1/p')
        DETECTED_NAME=$(printf '%s' "$line" \
            | grep -oE '\[[^]]+\]' | grep -E '[A-Za-z]' | grep -viE '10de:' | head -1 | tr -d '[]')
    fi
    [ -n "$DETECTED_NAME" ] || DETECTED_NAME="NVIDIA GPU [10de:${DETECTED_DEVICE_ID}]"

    [ -n "$DETECTED_CODENAME" ] && DETECTED_BRANCH=$(catalog_chip_branch "$DETECTED_CODENAME")
    if [ -z "$DETECTED_BRANCH" ]; then
        case "$DETECTED_CODENAME" in
            GF*|G8*|G9*|GT2*)
                # Fermi/Tesla (G8x/G9x/GT2xx): recognized, but no longer a
                # catalog branch — those drivers don't cross-compile against
                # modern kernels unpatched. No recommendation; the user must
                # bring a patched .run via --custom-run / --run-url.
                DETECTED_LEGACY_UNSUPPORTED=true ;;
            *)
                # Present but unclassifiable (newer than the PCI DB) → newest open.
                DETECTED_BRANCH="latest"
                DETECTED_UNCLASSIFIED=true ;;
        esac
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────
# --list
# ─────────────────────────────────────────────────────────────────────────
# The catalog body: open drivers (all open-module) + legacy branches with a
# MODULES column. Used by --list (print_catalog) to show the full matrix and
# the open/proprietary flavor. The interactive picker renders its own numbered
# menu (run_interactive_picker), so no "recommended" marking is needed here.
print_catalog_body() {
    echo "Open drivers (Turing and newer — open kernel modules):"
    printf "  %-12s %-11s %s\n" "VERSION" "MODULES" "SELECT"
    local v first=true
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        if $first; then
            printf "  %-12s %-11s %s\n" "$v" "open" "--branch=latest"
            first=false
        else
            printf "  %-12s %-11s %s\n" "$v" "open" "--driver=$v"
        fi
    done < <(catalog_open_latest)
    echo ""
    echo "Legacy branches (last driver for a card series TrueNAS dropped):"
    printf "  %-14s %-12s %-12s %s\n" "BRANCH" "VERSION" "MODULES" "SUPPORT"
    local b ver kmod sup
    while IFS= read -r b; do
        [ "$b" = "latest" ] && continue
        ver=$(catalog_branch_version "$b")
        kmod=$(catalog_branch_field "$b" kmod)
        sup=$(catalog_branch_field "$b" support)
        printf "  %-14s %-12s %-12s %s\n" "$b" "${ver:-?}" "$kmod" "$sup"
    done < <(catalog_branch_names)
}

# Interactive numbered picker. Builds a menu from the catalog (open trains
# newest-per-major, then legacy branches), preselects the card-detected
# recommendation, and reads one choice. Sets SELECTED_BRANCH or TARGET_NV_VER
# in caller scope. $1 = recommended branch (may be empty if no card detected).
# A pure integer is a menu index; an X.Y[.Z] string is an exact version; any
# other word is accepted as a branch name (back-compat with the old prompt).
run_interactive_picker() {
    local rec="${1:-}"
    local -a m_label m_ver m_kmod m_branch m_note
    local v first=true major def_idx="" i=0 n mark

    # Open trains (open_latest is newest-per-major). First entry is branch "latest".
    while IFS= read -r v; do
        [ -z "$v" ] && continue
        if $first; then
            m_label+=("latest"); m_ver+=("$v"); m_kmod+=("open"); m_branch+=("latest"); m_note+=("")
            first=false
        else
            major="${v%%.*}"
            m_label+=("train ${major}"); m_ver+=("$v"); m_kmod+=("open"); m_branch+=(""); m_note+=("")
        fi
    done < <(catalog_open_latest)

    # Legacy branches.
    local b ver kmod sup
    while IFS= read -r b; do
        [ "$b" = "latest" ] && continue
        ver=$(catalog_branch_version "$b")
        kmod=$(catalog_branch_field "$b" kmod)
        sup=$(catalog_branch_field "$b" support)
        m_label+=("$b"); m_ver+=("$ver"); m_kmod+=("$kmod"); m_branch+=("$b")
        if [ "$sup" = "best-effort" ]; then m_note+=("best-effort, needs patched .run"); else m_note+=(""); fi
    done < <(catalog_branch_names)

    n="${#m_label[@]}"
    echo ""
    echo "Choose a driver:"
    for ((i=0; i<n; i++)); do
        mark="${m_note[$i]}"
        if [ -n "$rec" ] && [ "${m_branch[$i]}" = "$rec" ]; then
            def_idx="$((i+1))"
            mark="recommended${mark:+ · $mark}"
        fi
        printf "  %2d) %-12s %-11s %-12s %s\n" \
            "$((i+1))" "${m_label[$i]}" "${m_ver[$i]}" "${m_kmod[$i]}" "$mark"
    done
    echo "  (or type an exact X.Y.Z version)"

    local prompt reply
    if [ -n "$def_idx" ]; then prompt="Selection [${def_idx}] (press Enter for the recommended default): "
    else prompt="Selection (number or X.Y.Z): "; fi
    printf "%s" "$prompt"
    read -r reply </dev/tty || true
    [ -z "$reply" ] && reply="$def_idx"
    [ -n "$reply" ] || { echo "ERROR: no selection and no recommendation to default to." >&2; exit 1; }

    if printf '%s' "$reply" | grep -qE '^[0-9]+$'; then
        if [ "$reply" -lt 1 ] || [ "$reply" -gt "$n" ]; then
            echo "ERROR: selection out of range: $reply (1-$n)" >&2; exit 1
        fi
        i="$((reply-1))"
        if [ -n "${m_branch[$i]}" ]; then SELECTED_BRANCH="${m_branch[$i]}"
        else TARGET_NV_VER="${m_ver[$i]}"; SELECTED_BRANCH=""; fi
    elif printf '%s' "$reply" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        TARGET_NV_VER="$reply"; SELECTED_BRANCH=""
    else
        SELECTED_BRANCH="$reply"
    fi
}

# Prompt for the kernel-module flavor when the .run ships both (515+). $1 =
# driver version, $2 = recommended default (open|proprietary). Echoes the
# chosen flavor on stdout; all UI goes to stderr so $(prompt_kmod ...) captures
# only the answer. An unrecognized reply keeps the recommended default.
prompt_kmod() {
    local ver="$1" def="$2" reply def_num reason
    if [ "$def" = "open" ]; then def_num=1; reason="recommended for Turing and newer"
    else def_num=2; reason="recommended for this card"; fi
    {
        echo ""
        echo "Driver ${ver} ships both module flavors:"
        if [ "$def" = "open" ]; then
            echo "  1) open         <- ${reason}"
            echo "  2) proprietary"
        else
            echo "  1) open"
            echo "  2) proprietary  <- ${reason}"
        fi
        printf "Modules [%d] (press Enter for the recommended default): " "$def_num"
    } >&2
    read -r reply </dev/tty || true
    [ -z "$reply" ] && reply="$def_num"
    case "$reply" in
        1|open)        echo "open" ;;
        2|proprietary) echo "proprietary" ;;
        *)             echo "$def" ;;
    esac
}

print_catalog() {
    echo "=== NVIDIA driver catalog ==="
    echo ""
    print_catalog_body
    echo ""
    echo "  modules: open = Turing+ (auto-derived); proprietary = legacy branches."
    echo "           override with --kmod=open|proprietary"
    echo "  supported   = builds against TrueNAS's current kernel"
    echo "  best-effort = won't cross-compile unpatched; bring --custom-run=PATH"
    echo ""
    echo "Install examples:"
    echo "  sudo install-nvidia-driver.sh --branch=legacy-580"
    echo "  sudo install-nvidia-driver.sh --driver=$(catalog_open_latest | head -1)"
    echo "  sudo install-nvidia-driver.sh --custom-run=/path/to/patched.run"
}

# ─────────────────────────────────────────────────────────────────────────
# Persist-dir resolution (verbatim copy — keep in sync with siblings)
# ─────────────────────────────────────────────────────────────────────────
resolve_persist_dir() {
    PERSIST_DIR=""
    local d p
    local -a existing=() pools=() choices=()
    local header n i

    if [ -n "${PERSIST_PATH:-}" ]; then PERSIST_DIR="$PERSIST_PATH"; return 0; fi
    if [ -n "${POOL_NAME:-}" ]; then PERSIST_DIR="/mnt/${POOL_NAME}/.config/nvidia-gpu"; return 0; fi

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
        PERSIST_DIR="${existing[0]}"; echo "Using existing nvidia-gpu config: $PERSIST_DIR"; return 0
    fi
    if [ "${#existing[@]}" -eq 0 ] && [ "${#pools[@]}" -eq 1 ]; then
        PERSIST_DIR="/mnt/${pools[0]}/.config/nvidia-gpu"; echo "Auto-selected pool: ${pools[0]} → $PERSIST_DIR"; return 0
    fi
    if [ "${#existing[@]}" -gt 1 ]; then
        header="Found existing nvidia-gpu configs on multiple pools:"; choices=("${existing[@]}")
    else
        header="No existing nvidia-gpu config. Multiple data pools available:"
        for p in "${pools[@]}"; do choices+=("/mnt/${p}/.config/nvidia-gpu"); done
    fi
    if ! { : </dev/tty; } 2>/dev/null; then
        echo "ERROR: $header" >&2
        echo "       No controlling terminal for prompt. Pass --pool=NAME or --persist-path=PATH." >&2
        return 1
    fi
    echo "$header"
    for i in "${!choices[@]}"; do echo "  [$((i+1))] ${choices[$i]}"; done
    while true; do
        printf "Pick one (1-%d): " "${#choices[@]}"
        read -r n </dev/tty || return 1
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#choices[@]}" ]; then
            PERSIST_DIR="${choices[$((n-1))]}"; echo "Selected: $PERSIST_DIR"; return 0
        fi
        echo "  Invalid. Enter 1-${#choices[@]}."
    done
}

# ─────────────────────────────────────────────────────────────────────────
# Stage build + management helpers into PERSIST_DIR/scripts so the user can
# rebuild / uninstall without re-running the curl one-liner.
# ─────────────────────────────────────────────────────────────────────────
stage_build_helpers() {
    local stage_dir="${PERSIST_DIR}/scripts"
    if_real mkdir -p "$stage_dir"
    local f
    for f in build-on-host.sh build-nvidia-sysext.sh uninstall-nvidia-driver.sh recover-stock-nvidia.sh; do
        if [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/${f}" ]; then
            if_real cp "${SCRIPT_DIR}/${f}" "${stage_dir}/${f}"
        else
            if $DRY_RUN; then
                echo "[dry-run] would: fetch ${f} (release ${RESOLVED_TAG:-<none>} → main) to ${stage_dir}/${f}" >&2
            else
                fetch_repo_file "${f}" "scripts/${f}" "${stage_dir}/${f}" \
                    || { echo "ERROR: failed to download helper: $f" >&2; return 1; }
            fi
        fi
        if_real chmod 0755 "${stage_dir}/${f}"
    done
    printf '%s\n' "$stage_dir"
}

build_driver_sysext_on_host() {
    local nvidia_ver="$1" truenas_ver="$2" stage_dir="$3"
    local codename out_dir built_raw
    codename=$(resolve_truenas_codename "$truenas_ver")
    out_dir="${PERSIST_DIR}/build"
    if_real mkdir -p "$out_dir"
    built_raw="${out_dir}/nvidia.raw"

    local args=(
        --nvidia-version="$nvidia_ver"
        --truenas-version="$truenas_ver"
        --kernel-module-type="$KMOD_TYPE"
        --cache-dir="${PERSIST_DIR}/cache"
        --scripts-dir="$stage_dir"
        --out="$built_raw"
    )
    [ -n "$codename" ] && args+=(--truenas-codename="$codename")
    [ -n "$CUSTOM_RUN" ] && args+=(--run-file="$CUSTOM_RUN")

    if $DRY_RUN; then
        echo "[dry-run] would: ${stage_dir}/build-on-host.sh ${args[*]}" >&2
        echo "[dry-run] would: produce $built_raw" >&2
        printf '%s\n' "$built_raw"
        return 0
    fi
    "${stage_dir}/build-on-host.sh" "${args[@]}" >&2 \
        || { echo "ERROR: build-on-host.sh failed" >&2; return 1; }
    [ -f "$built_raw" ] \
        || { echo "ERROR: build-on-host claimed success but $built_raw is missing" >&2; return 1; }
    printf '%s\n' "$built_raw"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd || true)"

# ─────────────────────────────────────────────────────────────────────────
# Read-only check mode (driver-only)
# ─────────────────────────────────────────────────────────────────────────
do_check() {
    local pass=0 warn=0 fail=0
    local -a status_lines=() hint_lines=()
    record_pass() { status_lines+=("  [OK] $1"); pass=$((pass+1)); }
    record_warn() { status_lines+=("  [--] $1"); warn=$((warn+1)); [ -n "${2:-}" ] && hint_lines+=("       → $2"); }
    record_fail() { status_lines+=("  [!!] $1"); fail=$((fail+1)); [ -n "${2:-}" ] && hint_lines+=("       → $2"); }

    echo "=== install-nvidia-driver status ==="
    echo ""

    if systemd-sysext list 2>/dev/null | awk '{print $1}' | grep -qx nvidia; then
        record_pass "Sysext 'nvidia' merged into /usr"
    else
        record_fail "Sysext 'nvidia' not merged" "the driver sysext isn't active — re-run install"
    fi

    local sysext_drv="" runtime_drv=""
    if command -v unsquashfs >/dev/null 2>&1 && [ -f "$LIVE_NVIDIA" ]; then
        sysext_drv=$(read_raw_driver_version "$LIVE_NVIDIA")
    fi
    if command -v nvidia-smi >/dev/null 2>&1; then
        runtime_drv=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 | tr -d '[:space:]' || true)
    fi
    if [ -n "$sysext_drv" ] && [ -n "$runtime_drv" ]; then
        if [ "$sysext_drv" = "$runtime_drv" ]; then
            record_pass "Driver versions match: sysext=${sysext_drv}, runtime=${runtime_drv}"
        else
            record_fail "Driver mismatch: sysext=${sysext_drv} but runtime=${runtime_drv}" \
                "reboot to load the new kernel module from the sysext"
        fi
    elif [ -n "$sysext_drv" ]; then
        record_warn "Sysext driver=${sysext_drv}; could not query nvidia-smi" \
            "no GPU detected or driver not loaded — reboot may be required"
    else
        record_warn "Could not read sysext driver version" "unsquashfs missing or sysext unreadable"
    fi

    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx nvidia; then
        record_pass "Kernel module 'nvidia' loaded"
    else
        record_fail "Kernel module 'nvidia' not loaded" \
            "reboot — a fresh install can't load a new module while the old one is in use"
    fi

    if [ -n "${PERSIST_DIR:-}" ] && [ -d "${PERSIST_DIR}" ]; then
        record_pass "Persistent config at ${PERSIST_DIR}"
    else
        record_fail "No persistent config under /mnt/*/.config/nvidia-gpu/" \
            "re-run install with --pool=NAME or --persist-path=PATH"
    fi
    if [ -n "${PERSIST_DIR:-}" ] && [ -f "${PERSIST_DIR}/nvidia.raw" ]; then
        record_pass "Custom-driver backup ${PERSIST_DIR}/nvidia.raw present"
    elif [ -n "${PERSIST_DIR:-}" ]; then
        record_fail "Custom-driver backup ${PERSIST_DIR}/nvidia.raw missing" "re-run install"
    fi
    if [ -n "${PERSIST_DIR:-}" ] && [ -f "${PERSIST_DIR}/nvidia-original.raw" ]; then
        record_pass "Stock backup ${PERSIST_DIR}/nvidia-original.raw present"
    elif [ -n "${PERSIST_DIR:-}" ]; then
        record_warn "No stock backup ${PERSIST_DIR}/nvidia-original.raw" \
            "you may be unable to recover stock — run recover-stock-nvidia.sh"
    fi
    if [ -n "${PERSIST_DIR:-}" ] && [ -x "${PERSIST_DIR}/nvidia-preinit-driver.sh" ]; then
        record_pass "PREINIT helper staged + executable"
    elif [ -n "${PERSIST_DIR:-}" ]; then
        record_fail "PREINIT helper missing in ${PERSIST_DIR}" "re-run install"
    fi

    if command -v midclt >/dev/null 2>&1; then
        local entry when enabled
        entry=$(midclt call initshutdownscript.query 2>/dev/null | python3 -c "
import sys, json
try:
    for s in json.load(sys.stdin):
        h = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if 'nvidia-preinit-driver' in h:
            print(f\"{s.get('when','?')}|{s.get('enabled','?')}\"); break
except Exception:
    pass" 2>/dev/null || true)
        if [ -z "$entry" ]; then
            record_fail "No PREINIT entry registered for nvidia-preinit-driver" "re-run install"
        else
            IFS='|' read -r when enabled <<<"$entry"
            if [ "$when" = "PREINIT" ] && [ "$enabled" = "True" ]; then
                record_pass "PREINIT 'nvidia-preinit-driver' registered (PREINIT, enabled)"
            else
                record_warn "PREINIT entry state: when=${when}, enabled=${enabled}" "re-run install to normalize"
            fi
        fi
    else
        record_warn "midclt not available — skipping middleware check" "this script must run on TrueNAS SCALE"
    fi

    echo "Checks: ${pass} pass, ${warn} warn, ${fail} fail"
    echo ""
    printf '%s\n' "${status_lines[@]}"
    if [ "${#hint_lines[@]}" -gt 0 ]; then echo ""; printf '%s\n' "${hint_lines[@]}"; fi
    [ "$fail" -eq 0 ]
}

# ─────────────────────────────────────────────────────────────────────────
# Entry: --list / --check short-circuits
# ─────────────────────────────────────────────────────────────────────────
if $LIST_MODE; then
    load_catalog
    print_catalog
    exit 0
fi

[ "$(id -u 2>/dev/null)" = "0" ] || { echo "ERROR: must run as root" >&2; exit 1; }
command -v unsquashfs >/dev/null 2>&1 || { echo "ERROR: unsquashfs not found (squashfs-tools)" >&2; exit 1; }

if $CHECK_MODE; then
    resolve_persist_dir 2>/dev/null || PERSIST_DIR=""
    do_check
    exit $?
fi

# ─────────────────────────────────────────────────────────────────────────
# Resolve target driver version + kernel-module flavor.
# Precedence: --driver-sysext (skip) > --custom-run > --driver > --branch >
#             interactive (detect card → recommend).
# ─────────────────────────────────────────────────────────────────────────
TARGET_NV_VER=""
SELECTED_BRANCH=""

# Decide which release supplies the tooling + catalog (sets RESOLVED_TAG /
# RELEASE_DL_BASE). Releases are tooling+catalog snapshots — they don't pin a
# driver — so this only governs where the scripts + catalog come from; driver
# selection stays card-detect / --branch / --driver / --custom-run.
resolve_release_for_install

# --run-url: fetch an arbitrary NVIDIA .run (a beta, or any version hosted
# anywhere) and treat it exactly like --custom-run from here on. Not tracked or
# smoke-tested — an explicit user escape hatch for installing anything.
if [ -n "$RUN_URL" ]; then
    _run_base=$(basename "${RUN_URL%%\?*}")
    case "$_run_base" in
        NVIDIA-Linux-x86_64-*.run) ;;
        *) echo "ERROR: --run-url must point to an NVIDIA-Linux-x86_64-<X.Y.Z>[-no-compat32].run (got '$_run_base')" >&2; exit 2 ;;
    esac
    _run_dir=$(mktemp -d "${TMPDIR:-/tmp}/nvidia-run.XXXXXX")
    CUSTOM_RUN="${_run_dir}/${_run_base}"
    if $DRY_RUN; then
        echo "[dry-run] would: curl -fL -o ${CUSTOM_RUN} ${RUN_URL}"
        : > "$CUSTOM_RUN"   # placeholder so version-parse + the file check proceed
    else
        echo "Downloading custom .run from ${RUN_URL} ..."
        curl -fL --retry 3 -o "$CUSTOM_RUN" "$RUN_URL" \
            || { echo "ERROR: failed to download --run-url: $RUN_URL" >&2; exit 1; }
    fi
fi

if [ -z "$DRIVER_SRC" ]; then
    load_catalog

    if [ -n "$CUSTOM_RUN" ]; then
        [ -f "$CUSTOM_RUN" ] || { echo "ERROR: --custom-run not found: $CUSTOM_RUN" >&2; exit 1; }
        TARGET_NV_VER=$(parse_nvidia_version_from_run_file "$CUSTOM_RUN")
        [ -n "$TARGET_NV_VER" ] || {
            echo "ERROR: cannot parse version from .run filename '$CUSTOM_RUN'" >&2
            echo "       Expected: NVIDIA-Linux-x86_64-<X.Y.Z>[-no-compat32].run" >&2
            exit 1
        }
        echo "Custom .run: $TARGET_NV_VER ($(basename "$CUSTOM_RUN"))"

    elif [ -n "$DRIVER_VER" ]; then
        echo "$DRIVER_VER" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$' \
            || { echo "ERROR: --driver must be X.Y.Z or X.Y (got: $DRIVER_VER)" >&2; exit 1; }
        TARGET_NV_VER="$DRIVER_VER"
        echo "Target driver (explicit): $TARGET_NV_VER"

    elif [ -n "$BRANCH" ]; then
        SELECTED_BRANCH="$BRANCH"

    else
        # Interactive: detect card, recommend a branch.
        echo "Detecting NVIDIA GPU..."
        if detect_gpu; then
            if $DETECTED_LEGACY_UNSUPPORTED; then
                echo "  Found: ${DETECTED_NAME:-$DETECTED_CODENAME} (chip ${DETECTED_CODENAME})"
                echo "  This is a Fermi/Tesla-era card. Its last driver (390.x / 340.x) does NOT"
                echo "  cross-compile against TrueNAS's modern kernel, so there's no catalog branch."
                echo "  To use it, supply a patched installer:  --custom-run=PATH  or  --run-url=URL"
                echo "  (see docs/legacy-cards.md). No driver is recommended automatically."
            elif $DETECTED_UNCLASSIFIED; then
                echo "  Found: ${DETECTED_NAME} (10de:${DETECTED_DEVICE_ID})"
                echo "  This chip isn't in the system's PCI ID database (it's newer than the DB),"
                echo "  so defaulting to the latest OPEN driver — correct for Turing and newer."
                echo "  If this is a pre-Turing card (Kepler/Maxwell/Pascal/Volta), pick a legacy branch below."
            else
                echo "  Found: ${DETECTED_NAME:-$DETECTED_CODENAME} (chip ${DETECTED_CODENAME})"
            fi
            [ -n "$DETECTED_BRANCH" ] && echo "  Recommended: --branch=${DETECTED_BRANCH}"
            SELECTED_BRANCH="$DETECTED_BRANCH"
        else
            echo "  No NVIDIA GPU detected (no 0x10de display device under /sys)."
        fi
        if { : </dev/tty; } 2>/dev/null; then
            INTERACTIVE_PICK=true
            run_interactive_picker "$SELECTED_BRANCH"
        elif [ -z "$SELECTED_BRANCH" ]; then
            echo "ERROR: no card detected and no controlling terminal to prompt." >&2
            echo "       Pass --branch=NAME or --driver=X.Y.Z (see --list)." >&2
            exit 1
        fi
        # No tty but a card was detected: proceed with the recommended branch.
    fi

    # If a branch was selected (flag or interactive), resolve it now.
    if [ -n "$SELECTED_BRANCH" ] && [ -z "$TARGET_NV_VER" ]; then
        TARGET_NV_VER=$(catalog_branch_version "$SELECTED_BRANCH")
        [ -n "$TARGET_NV_VER" ] || {
            echo "ERROR: unknown branch '$SELECTED_BRANCH'. Run --list for valid branches." >&2
            exit 1
        }
        echo "Branch '$SELECTED_BRANCH' → driver $TARGET_NV_VER"

        # best-effort branches: confirm before the long build.
        sup=$(catalog_branch_field "$SELECTED_BRANCH" support)
        if [ "$sup" = "best-effort" ]; then
            echo ""
            echo "WARNING: '$SELECTED_BRANCH' (driver $TARGET_NV_VER) is BEST-EFFORT."
            echo "  This branch does not cross-compile against TrueNAS's current kernel"
            echo "  without patches. The on-host build will very likely fail unless you"
            echo "  supply a patched installer:  --custom-run=/path/to/patched.run"
            echo "  See docs/legacy-cards.md."
            echo ""
            if ! $FORCE && ! $ASSUME_YES; then
                if { : </dev/tty; } 2>/dev/null; then
                    printf "Continue anyway? [y/N]: "; read -r yn </dev/tty || yn=""
                    case "$yn" in [Yy]*) ;; *) echo "Aborted."; exit 1 ;; esac
                else
                    echo "ERROR: refusing best-effort branch non-interactively. Pass --yes or --force." >&2
                    exit 1
                fi
            fi
        fi
    fi

    # ── Derive kernel-module flavor ──
    # --kmod wins. Otherwise compute the recommended default (branch kmod, else
    # version-based). In the interactive picker, when the .run ships both
    # flavors (515+), offer the choice with that default preselected; legacy
    # branches are proprietary-only so there's nothing to ask.
    if [ -z "$KMOD_TYPE" ]; then
        _default_kmod=""
        if [ -n "$SELECTED_BRANCH" ]; then
            _default_kmod=$(catalog_branch_field "$SELECTED_BRANCH" kmod)
        fi
        [ -n "$_default_kmod" ] || _default_kmod=$(auto_kmod_for_version "$TARGET_NV_VER")

        _kmajor="${TARGET_NV_VER%%.*}"
        if $INTERACTIVE_PICK && [ "$_kmajor" -ge 515 ] 2>/dev/null \
               && { : </dev/tty; } 2>/dev/null; then
            KMOD_TYPE=$(prompt_kmod "$TARGET_NV_VER" "$_default_kmod")
        else
            KMOD_TYPE="$_default_kmod"
        fi
    fi
    echo "Kernel modules: $KMOD_TYPE"

    # ── Safety: open modules need Turing+ and a 515+ driver ──
    _major="${TARGET_NV_VER%%.*}"
    if [ "$KMOD_TYPE" = "open" ] && [ "$_major" -lt 515 ] 2>/dev/null; then
        echo "ERROR: open kernel modules don't exist before driver 515 (got $TARGET_NV_VER)." >&2
        echo "       Use --kmod=proprietary (the build forces this for legacy branches)." >&2
        $FORCE || exit 1
    fi
    if [ "$KMOD_TYPE" = "open" ] && [ -n "$DETECTED_CODENAME" ]; then
        case "$DETECTED_CODENAME" in
            GK*|GM*|GP*|GV*|GF*|G8*|G9*|GT2*)
                echo "ERROR: detected ${DETECTED_CODENAME} predates Turing — open modules are unsupported on it." >&2
                echo "       Use --kmod=proprietary, or --force to override." >&2
                $FORCE || exit 1 ;;
        esac
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Resolve persist dir + ensure it exists
# ─────────────────────────────────────────────────────────────────────────
if [ -n "$PERSIST_PATH" ]; then
    PERSIST_PATH_REAL=$(realpath -m "$PERSIST_PATH" 2>/dev/null || echo "$PERSIST_PATH")
    if [[ ! "$PERSIST_PATH_REAL" =~ ^/mnt/[^/]+/\.config/nvidia-gpu/?$ ]]; then
        echo "ERROR: --persist-path must be /mnt/<pool>/.config/nvidia-gpu (got: ${PERSIST_PATH})" >&2
        echo "  The boot-time PREINIT only scans /mnt/*/.config/nvidia-gpu," >&2
        echo "  so any other location silently breaks persistence after a reboot/update." >&2
        exit 2
    fi
fi
resolve_persist_dir || exit 1
if_real mkdir -p "$PERSIST_DIR"

# ─────────────────────────────────────────────────────────────────────────
# Stock-backup pre-flight — needed so we can always revert to stock. Applies
# to every swap, including --driver-sysext (the source of the .raw doesn't
# change the fact that we're replacing the live stock driver).
# ─────────────────────────────────────────────────────────────────────────
if ! $SKIP_BACKUP_CHECK; then
    if [ ! -f "${PERSIST_DIR}/nvidia-original.raw" ]; then
        cat >&2 <<EOF
ERROR: ${PERSIST_DIR}/nvidia-original.raw not found.
       Refusing to swap nvidia.raw without a stock backup on hand.
       Run scripts/recover-stock-nvidia.sh first (downloads + extracts
       stock nvidia.raw from the official TrueNAS .update). Or pass
       --skip-backup-check if you accept the risk.
EOF
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────────────────
# Acquire nvidia.raw: --driver-sysext > cached reuse > build on host.
# ─────────────────────────────────────────────────────────────────────────
if [ -n "$DRIVER_SRC" ]; then
    echo "Using pre-built driver sysext: $DRIVER_SRC (--driver-sysext; skipping build)"
else
    TARGET_TN_VER=$(detect_truenas_version || true)
    [ -n "$TARGET_TN_VER" ] || { echo "ERROR: cannot determine TrueNAS version for the build" >&2; exit 1; }
    echo "TrueNAS version: $TARGET_TN_VER"

    if ! $REBUILD && cache_valid_for_target "$TARGET_NV_VER"; then
        DRIVER_SRC="${PERSIST_DIR}/nvidia.raw"
        echo "Reusing cached driver sysext (driver=$TARGET_NV_VER, kernel=$(uname -r))"
        echo "  (pass --rebuild to force a fresh build)"
    else
        if $REBUILD; then
            echo "--rebuild given; ignoring any cached nvidia.raw"
        else
            echo "No valid cached nvidia.raw for driver=$TARGET_NV_VER + kernel=$(uname -r); building on host"
            echo "(first run takes ≈ 8 min; cached for subsequent installs)"
        fi
        STAGED_SCRIPTS_DIR=$(stage_build_helpers) || { echo "ERROR: failed to stage build helpers" >&2; exit 1; }
        DRIVER_SRC=$(build_driver_sysext_on_host "$TARGET_NV_VER" "$TARGET_TN_VER" "$STAGED_SCRIPTS_DIR") || exit 1
        echo "Built driver sysext: $DRIVER_SRC"
    fi
fi

if ! $DRY_RUN && [ ! -f "$DRIVER_SRC" ]; then
    echo "ERROR: driver sysext source not found: $DRIVER_SRC" >&2
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────
# /usr readonly tracking + cleanup trap
# ─────────────────────────────────────────────────────────────────────────
USR_WAS_WRITABLE=0
USR_DATASET=""
DRIVER_TMP=""
PREINIT_DRY_TMP=""

# GPU-release rollback state (mirrors install-mig-sysext.sh's hardened drain).
# The install frees the GPU before the swap — stops GPU-bound apps and toggles
# docker's nvidia runtime off. On a CLEAN finish we restore both (there's no
# post-reboot configure-mig here to do it, unlike the MIG flow). On an ABORT we
# roll them back so an interrupted install never leaves apps down / GPU off.
DOCKER_NVIDIA_DISABLED=0     # 1 once we toggled docker.nvidia off
DOCKER_NVIDIA_PRIOR=""       # docker.config.nvidia value captured before we touched it
SWAP_STARTED=0               # 1 once the sysext unmerge / driver swap has begun
STOPPED_APPS=""              # newline list of apps we successfully app.stop'd
STOPPING_APP=""              # app currently mid app.stop (set before, cleared after)

# Restore the docker nvidia toggle to its captured prior value. No-op if we
# never disabled it. Default to true if we somehow never read the prior value.
restore_docker_nvidia() {
    [ "$DOCKER_NVIDIA_DISABLED" = "1" ] || return 0
    local want="${DOCKER_NVIDIA_PRIOR:-true}"
    midclt call docker.update "{\"nvidia\": ${want}}" >/dev/null 2>&1 \
        && echo "  Restored docker.config.nvidia=${want}" >&2 \
        || echo "  WARN: could not restore docker.config.nvidia (set it manually)" >&2
    DOCKER_NVIDIA_DISABLED=0
}

# Restart every app we stopped (STOPPED_APPS) plus any app caught mid-stop
# (STOPPING_APP). Must run AFTER restore_docker_nvidia — TrueNAS won't start a
# container while the nvidia toggle is off.
restart_stopped_apps() {
    local app
    while IFS= read -r app; do
        [ -n "$app" ] || continue
        midclt call -j app.start "$app" >/dev/null 2>&1 \
            && echo "  Restarted $app" >&2 \
            || echo "  WARN: could not restart $app — start it from the Apps UI" >&2
    done <<< "$(printf '%s\n%s\n' "$STOPPED_APPS" "$STOPPING_APP")"
}

cleanup_tmp() {
    local rc=$?
    # Always put /usr back read-only if we left it writable.
    if [ "$USR_WAS_WRITABLE" = "1" ] && [ -n "$USR_DATASET" ]; then
        zfs set readonly=on "$USR_DATASET" 2>/dev/null || true
        USR_WAS_WRITABLE=0
    fi
    [ -n "${DRIVER_TMP:-}" ] && rm -f "$DRIVER_TMP"
    [ -n "${PREINIT_DRY_TMP:-}" ] && rm -f "$PREINIT_DRY_TMP"

    # Abnormal exit only — the clean-success path restores the GPU release
    # itself (in order, with its own messaging). Dry-run never sets the flags.
    if [ "$rc" -ne 0 ]; then
        if [ "$SWAP_STARTED" = "0" ]; then
            # Pre-swap: the stock/old driver is still intact and merged, so a
            # full rollback is safe. Toggle FIRST (apps won't start while off),
            # then restart everything we stopped.
            if [ "$DOCKER_NVIDIA_DISABLED" = "1" ] || [ -n "${STOPPED_APPS}${STOPPING_APP}" ]; then
                echo "" >&2
                echo "Install aborted before the driver swap — rolling back the GPU release..." >&2
                restore_docker_nvidia
                restart_stopped_apps
            fi
        else
            # Post-swap: the live driver may be half-swapped. Do NOT restart
            # apps onto it or re-enable the toggle; point at recovery instead.
            echo "" >&2
            echo "Install aborted AFTER the driver swap began — NOT restarting apps onto a" >&2
            echo "possibly half-swapped driver. Recover the stock driver first:" >&2
            if [ -x "${PERSIST_DIR:-}/scripts/recover-stock-nvidia.sh" ]; then
                echo "  sudo ${PERSIST_DIR}/scripts/recover-stock-nvidia.sh --install && sudo reboot" >&2
            else
                echo "  re-run the installer, or restore ${LIVE_NVIDIA}.bak, then reboot" >&2
            fi
            if [ -n "${STOPPED_APPS}${STOPPING_APP}" ]; then
                echo "  Apps left stopped (start them after recovery):" >&2
                printf '%s\n%s\n' "$STOPPED_APPS" "$STOPPING_APP" | sed '/^$/d;s/^/    /' >&2
            fi
        fi
    fi
}
trap cleanup_tmp EXIT INT TERM

# ─────────────────────────────────────────────────────────────────────────
# Sanity-check the driver sysext contents.
# ─────────────────────────────────────────────────────────────────────────
if ! $DRY_RUN || [ -f "$DRIVER_SRC" ]; then
    if ! DRIVER_LISTING=$(unsquashfs -l "$DRIVER_SRC" 2>/dev/null); then
        echo "ERROR: unsquashfs -l failed on $DRIVER_SRC" >&2; exit 1
    fi
    if ! printf '%s\n' "$DRIVER_LISTING" | grep -q 'extension-release.nvidia$'; then
        echo "ERROR: $DRIVER_SRC missing extension-release.nvidia" >&2; exit 1
    fi
    NEW_DRIVER_VER=$(printf '%s\n' "$DRIVER_LISTING" \
        | grep -oE 'libnvidia-ml\.so\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 | sed 's/^libnvidia-ml\.so\.//' || true)
    echo "Driver sysext version: ${NEW_DRIVER_VER:-unknown}"
fi

echo ""
echo "=== Install plan ==="
echo "Persist dir:    $PERSIST_DIR"
echo "Driver sysext:  $DRIVER_SRC"
echo "Kernel modules: ${KMOD_TYPE:-(pre-built sysext)}"
echo "Reboot:         REQUIRED after install"
echo ""

# Copy the built/supplied raw to persistent storage so TrueNAS updates can be
# survived by the PREINIT.
if [ "$DRIVER_SRC" -ef "${PERSIST_DIR}/nvidia.raw" ] 2>/dev/null; then
    $DRY_RUN || echo "Driver sysext already at ${PERSIST_DIR}/nvidia.raw (cache-reuse); skipping copy"
else
    if_real cp "$DRIVER_SRC" "${PERSIST_DIR}/nvidia.raw"
    $DRY_RUN || echo "Copied driver sysext to ${PERSIST_DIR}/nvidia.raw"
fi

# Stage the PREINIT helper BEFORE any /usr mutation so a failed fetch aborts early.
PREINIT_LOCAL="${PERSIST_DIR}/nvidia-preinit-driver.sh"
if $DRY_RUN; then
    PREINIT_DRY_TMP=$(mktemp -t nvidia-preinit-driver.XXXXXX.sh)
    PREINIT_STAGE="$PREINIT_DRY_TMP"
else
    PREINIT_STAGE="$PREINIT_LOCAL"
fi
if [ -n "${SCRIPT_DIR:-}" ] && [ -f "${SCRIPT_DIR}/nvidia-preinit-driver.sh" ]; then
    cp "${SCRIPT_DIR}/nvidia-preinit-driver.sh" "$PREINIT_STAGE"
    echo "Staged PREINIT helper from local checkout"
else
    echo "Staging PREINIT helper (release ${RESOLVED_TAG:-<none>} → main)"
    fetch_repo_file "nvidia-preinit-driver.sh" "scripts/nvidia-preinit-driver.sh" "$PREINIT_STAGE" \
        || { echo "ERROR: failed to download PREINIT helper — aborting BEFORE system changes" >&2; exit 1; }
fi
if $DRY_RUN; then
    [ -s "$PREINIT_STAGE" ] || { echo "ERROR: PREINIT helper downloaded empty" >&2; exit 1; }
    echo "[dry-run] would: install staged preinit to ${PREINIT_LOCAL} (chmod 0755)"
else
    chmod 0755 "$PREINIT_LOCAL"
    echo "Staged: $PREINIT_LOCAL"
fi

# ─────────────────────────────────────────────────────────────────────────
# Free the GPU so the swap is clean: stop GPU-bound apps, then toggle the
# docker nvidia runtime off. (Mirrors install-mig-sysext.sh's drain block.)
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "Stopping GPU-bound apps to free the GPU..."
if $DRY_RUN; then
    echo "[dry-run] would: stop apps with use_gpu=true, then docker.update '{\"nvidia\": false}', wait for drain"
elif [ -x /usr/bin/nvidia-smi ]; then
    VALID_UUIDS=$(/usr/bin/nvidia-smi -L 2>/dev/null \
        | sed -nE 's/.*\(UUID:[[:space:]]*((GPU|MIG)-[^)]+)\).*/\1/p' || true)
    ALL_APPS=$(midclt call app.query 2>/dev/null | python3 -c "
import sys, json
try:
    for a in json.load(sys.stdin):
        n = a.get('name', ''); s = a.get('state', '')
        if n: print(f'{n}|{s}')
except Exception:
    pass" 2>/dev/null || true)
    GPU_APPS_INFO=""
    if [ -n "$ALL_APPS" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            app="${line%|*}"; state="${line#*|}"
            config_json=$(midclt call app.config "$app" 2>/dev/null || true)
            is_gpu=$(printf '%s' "$config_json" | VALID_UUIDS="$VALID_UUIDS" python3 -c "
import sys, json, os
valid = set(os.environ.get('VALID_UUIDS', '').split())
try:
    d = json.load(sys.stdin)
    gpus = (d.get('resources', {}) or {}).get('gpus', {}) or {}
    sel = gpus.get('nvidia_gpu_selection', {}) or {}
    for slot, cfg in sel.items():
        if isinstance(cfg, dict):
            uuid = (cfg.get('uuid') or '').strip()
            if cfg.get('use_gpu') is True and uuid and uuid in valid:
                print('y'); break
except Exception:
    pass" 2>/dev/null || true)
            [ "$is_gpu" = "y" ] && GPU_APPS_INFO+="$app|$state"$'\n'
        done <<<"$ALL_APPS"
    fi
    if [ -z "$GPU_APPS_INFO" ]; then
        echo "  No GPU-bound apps found"
    else
        echo "  GPU-bound apps (will be stopped):"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            IFS='|' read -r gapp gstate <<<"$line"; echo "    $gapp (state=$gstate)"
        done <<<"$GPU_APPS_INFO"
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            IFS='|' read -r app state <<<"$line"
            if [ "$state" != "RUNNING" ]; then echo "  $app: state=$state — no container to stop"; continue; fi
            # Mark in-flight before the blocking call so an abort mid-stop still
            # restarts it on rollback; record only on success (a cleanly-failed
            # stop left the app up, so it needs no restart).
            STOPPING_APP="$app"
            if run_with_elapsed_capture "  Stopping $app" midclt call -j app.stop "$app"; then
                echo "  Stopping $app... OK (${ELAPSED}s)"
                STOPPED_APPS+="$app"$'\n'
            else
                echo "  Stopping $app... WARN (${ELAPSED}s): $CAPTURED_OUT"
            fi
            STOPPING_APP=""
        done <<<"$GPU_APPS_INFO"
    fi
    echo "  Disabling nvidia toolkit for docker (belt-and-suspenders)..."
    DOCKER_NVIDIA_PRIOR=$(midclt call docker.config 2>/dev/null \
        | python3 -c "import sys,json; print('true' if json.load(sys.stdin).get('nvidia') else 'false')" 2>/dev/null || echo true)
    midclt call docker.update '{"nvidia": false}' >/dev/null \
        && DOCKER_NVIDIA_DISABLED=1 \
        || echo "  WARN: docker.update returned an error — middleware may be flapping"
    printf "  Waiting for GPU compute clients to release... 0s/30s"
    for attempt in $(seq 1 10); do
        N=$(/usr/bin/nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null | wc -l || echo 0)
        if [ "${N:-0}" -eq 0 ]; then printf "\r  GPU compute clients released                              \n"; break; fi
        printf "\r  Waiting for %d GPU process(es)... %ds/30s" "$N" "$((attempt * 3))"; sleep 3
    done
    if [ "${N:-0}" -gt 0 ]; then
        echo ""
        echo "  WARN: $N GPU process(es) still attached after 30s — continuing anyway (reboot clears stale state)."
    fi
else
    echo "  nvidia-smi missing; toggling docker.nvidia=false only (no drain check)"
    DOCKER_NVIDIA_PRIOR=$(midclt call docker.config 2>/dev/null \
        | python3 -c "import sys,json; print('true' if json.load(sys.stdin).get('nvidia') else 'false')" 2>/dev/null || echo true)
    midclt call docker.update '{"nvidia": false}' >/dev/null \
        && DOCKER_NVIDIA_DISABLED=1 \
        || echo "  WARN: docker.update returned an error"
fi

# ─────────────────────────────────────────────────────────────────────────
# Swap nvidia.raw on read-only /usr.
# ─────────────────────────────────────────────────────────────────────────
echo "Unmerging sysext..."
# Past this point the live driver is being replaced — an abort can no longer
# safely restart apps onto it (see cleanup_tmp's post-swap branch).
$DRY_RUN || SWAP_STARTED=1
if_real systemd-sysext unmerge

USR_DATASET=$(zfs list -H -o name /usr 2>/dev/null)
if ! $DRY_RUN && [ -z "$USR_DATASET" ]; then
    echo "ERROR: could not determine the ZFS dataset for /usr; aborting before driver swap" >&2
    exit 1
fi
echo "Setting ${USR_DATASET:-<usr>} writable..."
if_real zfs set readonly=off "$USR_DATASET"
$DRY_RUN || USR_WAS_WRITABLE=1

if $DRY_RUN; then
    echo "[dry-run] would: cp ${LIVE_NVIDIA} ${LIVE_NVIDIA}.bak (unless .bak already present)"
elif [ ! -f "${LIVE_NVIDIA}.bak" ]; then
    cp "$LIVE_NVIDIA" "${LIVE_NVIDIA}.bak" 2>/dev/null \
        && echo "Backed up current to ${LIVE_NVIDIA}.bak" || echo "WARN: could not back up to .bak"
fi
if_real cp "$DRIVER_SRC" "$LIVE_NVIDIA"
$DRY_RUN || echo "Installed custom nvidia.raw at $LIVE_NVIDIA"
if_real zfs set readonly=on "$USR_DATASET"
$DRY_RUN || USR_WAS_WRITABLE=0

echo "Ensuring /etc/extensions/nvidia.raw symlink..."
if_real mkdir -p /etc/extensions
if_real ln -sf "$LIVE_NVIDIA" /etc/extensions/nvidia.raw

echo "Re-merging sysext..."
if_real systemd-sysext merge
if_real systemctl daemon-reload

# ─────────────────────────────────────────────────────────────────────────
# Register the driver PREINIT (restore custom nvidia.raw after a TrueNAS
# update + kernel-mismatch detection). Idempotent register-or-update.
# ─────────────────────────────────────────────────────────────────────────
echo ""
echo "Registering PREINIT entry..."
register_preinit() {
    local match_token="$1" cmd="$2" comment="$3" timeout="$4"
    local existing_id json
    export MATCH_TOKEN="$match_token"
    existing_id=$(midclt call initshutdownscript.query 2>/dev/null | python3 -c "
import sys, json, os
tok = os.environ['MATCH_TOKEN']
try:
    for s in json.load(sys.stdin):
        h = (s.get('command') or '') + ' ' + (s.get('script') or '')
        if tok in h: print(s['id'], end=''); break
except Exception:
    pass" 2>/dev/null)
    json="{\"type\": \"COMMAND\", \"command\": \"${cmd}\", \"when\": \"PREINIT\", \"enabled\": true, \"timeout\": ${timeout}, \"comment\": \"${comment}\"}"
    if $DRY_RUN; then
        if [ -n "$existing_id" ]; then echo "[dry-run] would: midclt call initshutdownscript.update ${existing_id} '${json}'"
        else echo "[dry-run] would: midclt call initshutdownscript.create '${json}'"; fi
    elif [ -n "$existing_id" ]; then
        echo "  Updating existing entry (id ${existing_id})"
        midclt call initshutdownscript.update "$existing_id" "$json" >/dev/null || echo "  WARN: PREINIT update failed"
    else
        echo "  Creating entry: ${cmd}"
        midclt call initshutdownscript.create "$json" >/dev/null || echo "  WARN: PREINIT create failed"
    fi
}
register_preinit "nvidia-preinit-driver" \
    "${PERSIST_DIR}/nvidia-preinit-driver.sh" \
    "Custom NVIDIA driver restore + kernel-mismatch detection" \
    180

# ─────────────────────────────────────────────────────────────────────────
# Done.
# ─────────────────────────────────────────────────────────────────────────
if $DRY_RUN; then
    echo ""
    echo "=== Dry-run complete; no system changes applied ==="
    echo "Re-run without --dry-run to apply."
    exit 0
fi

echo ""
echo "=== Verification ==="
systemd-sysext status || true
echo ""
OK=true
if [ -x /usr/bin/nvidia-smi ]; then
    echo "OK:   /usr/bin/nvidia-smi present (running driver still old until reboot)"
else
    echo "FAIL: /usr/bin/nvidia-smi not available — nvidia sysext may not be merged"
    OK=false
fi

echo ""
if $OK; then
    # Restore the GPU release we did before the swap: re-enable the docker
    # nvidia toggle (to its prior value) and restart the apps we stopped. Order
    # matters — the toggle must be back on before app.start, or TrueNAS no-ops
    # the start. There's no post-reboot configure-mig here to do this, so the
    # installer owns it. The apps come up healthy after the reboot below; until
    # then they'll show the same driver/library mismatch nvidia-smi does.
    if [ "$DOCKER_NVIDIA_DISABLED" = "1" ] || [ -n "$STOPPED_APPS" ]; then
        echo "Restoring GPU access (docker nvidia toggle + stopped apps)..."
        restore_docker_nvidia
        restart_stopped_apps
        echo ""
    fi
    cat <<EOF
=== Driver install complete — REBOOT REQUIRED ===

The kernel modules currently loaded are the PREVIOUS driver's; userspace
libraries are now the new driver's (${NEW_DRIVER_VER:-$TARGET_NV_VER}). Until you reboot:

  nvidia-smi will report "Driver/library version mismatch"
  any GPU apps just restarted will mismatch too — reboot promptly

After reboot:
  - new kernel modules load from /usr/lib/modules/<kernel>/
  - userspace libs match; restarted GPU apps recover
  - the PREINIT restores this driver after any future TrueNAS update

Run: sudo reboot

After reboot, confirm:
  sudo nvidia-smi --query-gpu=driver_version --format=csv,noheader

To revert to stock later:
  sudo ${PERSIST_DIR}/scripts/uninstall-nvidia-driver.sh
EOF
else
    echo "=== Install completed with errors — see FAIL lines above ==="
    exit 1
fi
