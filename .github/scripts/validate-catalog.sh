#!/usr/bin/env bash
# Validate catalog/driver-catalog.json shape. Run in CI (lint.yml) and safe
# to run locally. Exits non-zero with a message on the first problem.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CATALOG="${ROOT}/catalog/driver-catalog.json"

[ -f "$CATALOG" ] || { echo "ERROR: $CATALOG not found" >&2; exit 1; }

python3 - "$CATALOG" <<'PY'
import json, re, sys

path = sys.argv[1]
with open(path) as f:
    c = json.load(f)

errors = []
# NVIDIA versions are X.Y.Z (modern) or X.Y (older legacy, e.g. 390.157).
ver_re = re.compile(r'^\d+\.\d+(\.\d+)?$')

# Top-level keys.
for key in ("open_latest", "branches", "chip_map"):
    if key not in c:
        errors.append(f"missing top-level key: {key}")

open_latest = c.get("open_latest", [])
if not isinstance(open_latest, list) or not open_latest:
    errors.append("open_latest must be a non-empty list")
for v in open_latest:
    if not ver_re.match(v):
        errors.append(f"open_latest entry not X.Y.Z: {v!r}")

branches = c.get("branches", {})
if "latest" not in branches:
    errors.append("branches must include 'latest'")
for name, b in branches.items():
    if "version" not in b and "track" not in b:
        errors.append(f"branch {name}: needs 'version' or 'track'")
    if "version" in b and not ver_re.match(b["version"]):
        errors.append(f"branch {name}: version not X.Y.Z: {b['version']!r}")
    if b.get("kmod") not in ("open", "proprietary"):
        errors.append(f"branch {name}: kmod must be open|proprietary")
    if b.get("support") not in ("supported", "best-effort"):
        errors.append(f"branch {name}: support must be supported|best-effort")

# Every chip_map value must reference a defined branch.
for chip, br in c.get("chip_map", {}).items():
    if br not in branches:
        errors.append(f"chip_map[{chip}] -> {br!r} is not a defined branch")

if errors:
    print("driver-catalog.json validation FAILED:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print(f"driver-catalog.json OK: {len(open_latest)} open, {len(branches)} branches, {len(c['chip_map'])} chip mappings")
PY
