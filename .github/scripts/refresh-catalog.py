#!/usr/bin/env python3
"""Refresh catalog/driver-catalog.json from NVIDIA's Linux driver index.

Scrapes the autoindex at https://us.download.nvidia.com/XFree86/Linux-x86_64/
for version directories (X.Y.Z), then:

  * open_latest  = the newest open-capable (>= 515) driver per distinct major
                   ("train"), newest first, capped at `open_latest_count`.
                   Deduping by major keeps whole trains from being evicted when
                   one branch ships several point releases.
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

    # open_latest: newest open-capable (>= 515) driver per distinct major
    # ("train"), newest-first, capped at N. Deduping by major stops one branch's
    # point releases (e.g. four 595.x) from crowding whole trains (590, 580, ...)
    # off the list — `versions` is already sorted newest-first, so the first
    # version seen for a major is that train's newest.
    n = cat.get("open_latest_count", 5)
    open_trains = {}
    for v in versions:
        if vkey(v)[0] >= 515:
            open_trains.setdefault(vkey(v)[0], v)
    new_open_latest = list(open_trains.values())[:n]

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
