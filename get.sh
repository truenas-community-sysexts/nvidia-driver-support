#!/usr/bin/env bash
# Install the NVIDIA driver on TrueNAS with the newest installer release that
# a hardware test approved for this box's TrueNAS train.
#
#   curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-driver-support/main/get.sh | sudo bash
#
# Arguments go after `bash -s --` and pass through to the installer:
#
#   ... | sudo bash -s -- --branch=legacy-580   # any install-nvidia-driver.sh flag
#   ... | sudo bash -s -- --release=v80         # that release, no selection
#   ... | sudo bash -s -- --uninstall           # revert to stock with the approved
#                                               # release's uninstall-nvidia-driver.sh
#
# What it does:
#   1. Reads the TrueNAS version (midclt call system.info) and derives the
#      train: the major version from 26 on (every 26.x release, betas
#      included, is train 26), major.minor before that (25.10).
#   2. Lists this repo's releases and picks the newest one approved for that
#      train. A hardware test on a train approves a release for that train
#      only (promote.yml writes a verified-train marker into its notes). A
#      full release with no marker predates per-train sign-off and counts for
#      every train. Nothing else is ever installed: with no approved release
#      for the train it stops and points at the open hardware tests.
#   3. Downloads THAT release's install-nvidia-driver.sh (or, with
#      --uninstall, its uninstall-nvidia-driver.sh) and runs it with your
#      arguments plus --release=<tag>, so the tooling and driver catalog the
#      installer fetches come from the same release.
#
# --release=TAG skips step 1 and 2 and uses TAG as given.

set -euo pipefail

REPO="truenas-community-sysexts/nvidia-driver-support"
WORK_DIR=""

# BEGIN approved-release (a verbatim copy lives in get.sh and in
# scripts/install-nvidia-driver.sh, each a self-contained curl|bash script;
# tests/test_release_selection.py fails CI when the copies differ)

# TrueNAS version of this box, read from the middleware. Retried: midclt can
# be briefly unavailable right after boot.
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

# Train key of a TrueNAS version: the major version from 26 on (26.0.0-BETA.3
# and 26.1.2 are both train 26), major.minor before that (25.10.7 is 25.10,
# 25.04.2.6 is 25.04). Fails on anything else.
truenas_train_key() {
    local v="$1" major minor
    major="${v%%.*}"
    case "$major" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$major" -ge 26 ]; then
        printf '%s\n' "$major"
        return 0
    fi
    case "$v" in *.*) ;; *) return 1 ;; esac
    minor="${v#*.}"
    minor="${minor%%[!0-9]*}"
    [ -n "$minor" ] || return 1
    printf '%s.%s\n' "$major" "$minor"
}

# Every page of the repo's releases, appended to $1 as one JSON array per
# page. Only a full page can have more behind it; anything else (short page,
# API error object) ends the loop, and the selection reports API errors.
fetch_release_pages() {
    local out="$1" page=1 page_json page_len
    : > "$out"
    while :; do
        page_json=$(curl -sS --max-time 30 "https://api.github.com/repos/${REPO}/releases?per_page=100&page=${page}") \
            || { echo "ERROR: Failed to query GitHub releases" >&2; return 1; }
        printf '%s\n' "$page_json" >> "$out"
        page_len=$(printf '%s' "$page_json" | python3 -c "
import sys, json
try:
    doc = json.load(sys.stdin)
except Exception:
    print(0)
else:
    print(len(doc) if isinstance(doc, list) else 0)
")
        [ "$page_len" -eq 100 ] || break
        page=$((page + 1))
    done
}

# Newest release approved for train $2 on a box running TrueNAS $1, chosen
# from the release pages in $3. Prints its tag; explains on stderr and fails
# when there is none.
select_approved_release() {
    VERSION="$1" TRAIN="$2" REPO="$REPO" python3 -c "
# BEGIN release-selection (extracted verbatim by tests/test_release_selection.py;
# single-quoted strings only, \x60 stands for backtick, no dollar signs: this
# code lives inside a double-quoted bash string)
import sys, json, os, re
# stdin carries one JSON array per fetched API page, concatenated.
decoder = json.JSONDecoder()
text = sys.stdin.read()
data = []
pos = 0
while pos < len(text):
    if text[pos].isspace():
        pos += 1
        continue
    try:
        doc, pos = decoder.raw_decode(text, pos)
    except ValueError:
        print('Failed to parse GitHub API response', file=sys.stderr)
        sys.exit(1)
    if isinstance(doc, dict) and 'message' in doc:
        msg = doc['message']
        if 'rate limit' in msg.lower():
            print('GitHub API rate limit exceeded (60 requests/hour for unauthenticated calls).', file=sys.stderr)
            print('Wait a few minutes and try again.', file=sys.stderr)
        else:
            print(f'GitHub API error: {msg}', file=sys.stderr)
        sys.exit(1)
    elif isinstance(doc, list):
        data.extend(doc)
    else:
        print('Failed to parse GitHub API response', file=sys.stderr)
        sys.exit(1)
if not text.strip():
    print('Failed to parse GitHub API response', file=sys.stderr)
    sys.exit(1)
version = os.environ['VERSION']
train = os.environ['TRAIN']
repo = os.environ.get('REPO', '')
# The channel (preview on a BETA/RC box, else stable) no longer decides what
# installs: every box takes the newest release approved for its train. It
# only picks which hardware-test issues the no-match message points at.
vu = version.upper()
is_preview = ('-BETA' in vu) or ('-RC' in vu)
def preview_release(release):
    # This repo's v<N> tags carry no BETA/RC marker (one release serves every
    # train), so this never fires here; it keeps the approval gate below the
    # same expression as in the per-kernel repos (coral, hailo, memryx).
    tu = release.get('tag_name', '').upper()
    return ('-BETA' in tu) or ('-RC' in tu)
# Approval gate. promote.yml writes one verified-train line into the notes
# for each train whose hardware test signed the release off. A release with a
# line for this train is approved here; lines for other trains only are not.
# A full release with no line at all predates per-train sign-off and is
# grandfathered for every train. Nothing else qualifies: there is no fallback
# to an unverified build, on stable or preview boxes.
vt_re = re.compile(r'^[ \t]*<!--\s*verified-train:\s*([^\s>]+?)\s*-->', re.M)
def verified_trains(release):
    return set(vt_re.findall(release.get('body') or ''))
def approved(release):
    trains = verified_trains(release)
    if trains:
        return train in trains
    return not release.get('prerelease') and not preview_release(release)
def published(release):
    return release.get('published_at') or release.get('created_at') or ''
candidates = [r for r in data
              if not r.get('draft')
              and approved(r)]
if not candidates:
    print(f'No release is approved for TrueNAS train {train} yet (this box runs {version}).', file=sys.stderr)
    print('A hardware test on a train approves a release for that train only, and nothing', file=sys.stderr)
    print('unapproved is installed.', file=sys.stderr)
    pending = sorted([r for r in data if not r.get('draft')], key=published, reverse=True)
    if pending:
        print('Newest releases waiting for a hardware test on this train:', file=sys.stderr)
        for r in pending[:5]:
            t = r.get('tag_name', '?')
            mark = ' (prerelease)' if r.get('prerelease') else ''
            print(f'  {t}{mark}', file=sys.stderr)
    label = 'preview-hardware-test' if is_preview else 'hardware-test'
    print('Open hardware tests (each issue title names its train):', file=sys.stderr)
    print(f'  https://github.com/{repo}/issues?q=is%3Aissue+is%3Aopen+label%3A{label}', file=sys.stderr)
    sys.exit(1)
candidates.sort(key=published, reverse=True)
print(candidates[0]['tag_name'], end='')
# END release-selection
" < "$3"
}

# The release to use on this box when none is pinned with --release: the
# newest one approved for its train. Prints the tag.
approved_release_tag() {
    local version train pages tag
    version=$(detect_truenas_version) || {
        echo "ERROR: could not read the TrueNAS version (midclt call system.info)." >&2
        echo "       Run this as root on TrueNAS, or pin a release with --release=TAG." >&2
        return 1
    }
    train=$(truenas_train_key "$version") || {
        echo "ERROR: cannot derive a TrueNAS train from version '${version}'" >&2
        return 1
    }
    pages=$(mktemp) || return 1
    if fetch_release_pages "$pages" && tag=$(select_approved_release "$version" "$train" "$pages"); then
        rm -f "$pages"
        echo "TrueNAS ${version} (train ${train}): newest approved release is ${tag}" >&2
        printf '%s\n' "$tag"
        return 0
    fi
    rm -f "$pages"
    return 1
}
# END approved-release

main() {
    local mode=install tag="" arg asset
    local -a args=()
    for arg in "$@"; do
        case "$arg" in
            --uninstall) mode=uninstall ;;
            --release=*)
                tag="${arg#*=}"
                [ -n "$tag" ] || { echo "ERROR: --release= needs a tag, e.g. --release=v80" >&2; exit 2; }
                ;;
            *) args+=("$arg") ;;
        esac
    done

    if [ -n "$tag" ]; then
        echo "Release ${tag} (pinned with --release)" >&2
    else
        tag=$(approved_release_tag) || exit 1
    fi

    if [ "$mode" = uninstall ]; then
        # The uninstaller takes no --release: it only undoes the install.
        asset="uninstall-nvidia-driver.sh"
    else
        asset="install-nvidia-driver.sh"
        args+=("--release=${tag}")
    fi

    # Under scripts/ in a private temp dir: the installer treats a
    # ../catalog next to itself as a repo checkout, and there must be none.
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/nvidia-get.XXXXXX")
    trap 'rm -rf "$WORK_DIR"' EXIT
    mkdir "${WORK_DIR}/scripts"
    curl -fsSL --retry 3 --max-time 120 -o "${WORK_DIR}/scripts/${asset}" \
        "https://github.com/${REPO}/releases/download/${tag}/${asset}" \
        || { echo "ERROR: could not download ${asset} from release ${tag}" >&2; exit 1; }
    bash "${WORK_DIR}/scripts/${asset}" ${args[@]+"${args[@]}"}
}

# Called on the last line, so bash has read this whole script before
# anything runs and the installer cannot swallow the rest of it from stdin.
main "$@"
