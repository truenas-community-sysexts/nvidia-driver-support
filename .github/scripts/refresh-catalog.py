#!/usr/bin/env python3
"""Refresh catalog/driver-catalog.json from NVIDIA's Linux driver index.

Scrapes the autoindex at https://us.download.nvidia.com/XFree86/Linux-x86_64/
for version directories (X.Y.Z), then:

  * open_latest  = the newest open-capable (>= 515) driver per distinct major
                   ("train"), newest first, capped at `open_latest_count`, and
                   never above NVIDIA's blessed production latest (latest.txt).
                   latest.txt is the authority for "latest", so versions NVIDIA
                   published but hasn't promoted (new-feature-branch / beta) are
                   excluded; each kept version must also ship a -no-compat32.run.
                   (Users can still install anything via --driver=X.Y.Z.)
  * branches[legacy-*].version = the highest X.Y.Z found whose major matches
                   that branch's series (470/580/390/340). NVIDIA still ships
                   occasional security updates to legacy branches, so we track
                   the newest rather than a hard-coded historical pin.

Everything else in the file (chip_map, kmod, support, notes, schema) is
preserved verbatim. Only open_latest and branches[].version are rewritten.

Run from the repo root:  python3 .github/scripts/refresh-catalog.py
Exit 0 always (unless the index is unreachable); the caller commits if the
file changed. Pass --check to fail (exit 1) if a refresh WOULD change it.
"""
import json
import os
import re
import sys
import urllib.request

# The us.download CDN host (used for .run downloads) does not serve a
# directory autoindex; the bare download.nvidia.com host does.
INDEX_URL = "https://download.nvidia.com/XFree86/Linux-x86_64/"
CATALOG = os.path.join(
    os.path.dirname(__file__), "..", "..", "catalog", "driver-catalog.json"
)
# Autoindex hrefs use single quotes: <a href='570.86.16/'>. Accept either
# quote style and both X.Y.Z (modern) and X.Y (older legacy, e.g. 390.157).
VERSION_RE = re.compile(r"""href=['"](\d+\.\d+(?:\.\d+)?)/['"]""")


def fetch_versions():
    req = urllib.request.Request(INDEX_URL, headers={"User-Agent": "catalog-refresh"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        html = resp.read().decode("utf-8", "replace")
    seen = set()
    out = []
    for v in VERSION_RE.findall(html):
        if v not in seen:
            seen.add(v)
            out.append(v)
    return out


def vkey(v):
    return tuple(int(x) for x in v.split("."))


# latest.txt is NVIDIA's blessed production-latest pointer; the bare directory
# index also lists versions NVIDIA hasn't promoted (new-feature-branch / beta).
LATEST_TXT_URL = "https://download.nvidia.com/XFree86/Linux-x86_64/latest.txt"
RUN_URL_TMPL = (
    "https://us.download.nvidia.com/XFree86/Linux-x86_64/"
    "{v}/NVIDIA-Linux-x86_64-{v}-no-compat32.run"
)


def fetch_latest_txt():
    """The blessed production-latest version from latest.txt, or None."""
    req = urllib.request.Request(LATEST_TXT_URL, headers={"User-Agent": "catalog-refresh"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        txt = resp.read().decode("utf-8", "replace")
    m = re.match(r"\s*(\d+\.\d+(?:\.\d+)?)", txt)
    return m.group(1) if m else None


def run_ships(v):
    """True if this version publishes a buildable -no-compat32.run — i.e. a real
    shipping Linux driver, not a placeholder / pulled directory."""
    url = RUN_URL_TMPL.format(v=v)
    # HEAD first; some CDNs reject it, so fall back to a 1-byte ranged GET.
    for headers, method in (
        ({"User-Agent": "catalog-refresh"}, "HEAD"),
        ({"User-Agent": "catalog-refresh", "Range": "bytes=0-0"}, "GET"),
    ):
        try:
            req = urllib.request.Request(url, headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=20) as r:
                return 200 <= r.status < 400
        except Exception:  # noqa: BLE001
            continue
    return False


def main():
    check_only = "--check" in sys.argv
    with open(CATALOG) as f:
        cat = json.load(f)

    try:
        versions = fetch_versions()
    except Exception as e:  # noqa: BLE001
        print(f"ERROR: could not fetch NVIDIA index: {e}", file=sys.stderr)
        return 1
    if not versions:
        print("ERROR: NVIDIA index returned no version directories", file=sys.stderr)
        return 1

    versions.sort(key=vkey, reverse=True)

    # open_latest: the newest open-capable (>= 515) driver per distinct major
    # ("train"), newest-first, capped at N — but NEVER above NVIDIA's blessed
    # production latest (latest.txt). The bare index also contains versions
    # NVIDIA published but hasn't promoted (new-feature-branch / beta); latest.txt
    # is the authority for "latest", so we use it as a ceiling and exclude
    # anything higher. Deduping by major keeps whole trains from being evicted by
    # one branch's point releases. Each kept version must also ship a real
    # -no-compat32.run (no placeholder / pulled dirs). Users can still install
    # anything above the ceiling explicitly via --driver=X.Y.Z (betas included).
    n = cat.get("open_latest_count", 5)
    try:
        latest_txt = fetch_latest_txt()
    except Exception as e:  # noqa: BLE001
        print(f"WARN: could not fetch latest.txt: {e}", file=sys.stderr)
        latest_txt = None

    if not latest_txt:
        print("WARN: latest.txt unavailable — leaving open_latest unchanged", file=sys.stderr)
        new_open_latest = cat.get("open_latest", [])
    else:
        ceiling = vkey(latest_txt)
        # Trust latest.txt for its own train even if a HEAD check flakes.
        open_trains = {ceiling[0]: latest_txt}
        for v in versions:                       # newest-first
            k = vkey(v)
            if k[0] < 515 or k > ceiling:
                continue                          # pre-515, or above the blessed latest
            if k[0] in open_trains:
                continue
            if run_ships(v):
                open_trains[k[0]] = v
        new_open_latest = sorted(open_trains.values(), key=vkey, reverse=True)[:n]

    # legacy branch pins: newest version matching the branch major.
    new_branches = json.loads(json.dumps(cat.get("branches", {})))
    for name, b in new_branches.items():
        if "version" not in b:
            continue  # the "latest" branch tracks open_latest, no fixed version
        cur_major = int(b["version"].split(".")[0])
        same = [v for v in versions if vkey(v)[0] == cur_major]
        if same:
            newest = max(same, key=vkey)
            b["version"] = newest

    changed = (new_open_latest != cat.get("open_latest")) or (
        new_branches != cat.get("branches")
    )

    if not changed:
        print("Catalog already up to date.")
        return 0

    print("Catalog changes:")
    if new_open_latest != cat.get("open_latest"):
        print(f"  open_latest: {cat.get('open_latest')} -> {new_open_latest}")
    for name, b in new_branches.items():
        old = cat.get("branches", {}).get(name, {}).get("version")
        if old and old != b.get("version"):
            print(f"  {name}: {old} -> {b['version']}")

    if check_only:
        print("(--check) catalog is stale", file=sys.stderr)
        return 1

    cat["open_latest"] = new_open_latest
    cat["branches"] = new_branches
    with open(CATALOG, "w") as f:
        json.dump(cat, f, indent=2)
        f.write("\n")
    print(f"Wrote {CATALOG}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
