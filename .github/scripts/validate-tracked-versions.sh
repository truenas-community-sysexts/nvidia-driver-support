#!/usr/bin/env bash
# Validate that .github/tracked-versions.json has the shape the CI machinery
# assumes: build-sysext.yml reads the `truenas` block, release.yml and
# promote.yml read the `trains` list.
#
# Run locally:
#   .github/scripts/validate-tracked-versions.sh
# Exits non-zero with a `::error::` annotation on any shape violation.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="${REPO_ROOT}/.github/tracked-versions.json"

if [ ! -f "$FILE" ]; then
  echo "::error title=tracked-versions::file not found: ${FILE}" >&2
  exit 1
fi

python3 - "$FILE" <<'PY'
import json
import re
import sys

path = sys.argv[1]

def fail(msg):
    print(f"::error title=tracked-versions::{msg}", file=sys.stderr)
    sys.exit(1)

try:
    with open(path) as f:
        data = json.load(f)
except json.JSONDecodeError as e:
    fail(f"invalid JSON in {path}: {e}")

if not isinstance(data, dict):
    fail("top-level value must be an object")

# The smoke-build target (build-sysext.yml).
truenas = data.get("truenas")
if not isinstance(truenas, dict):
    fail("'truenas' key missing or not an object")
tn_version = truenas.get("version")
if not isinstance(tn_version, str) or not re.match(r"^\d+(\.\d+){1,4}$", tn_version):
    fail(f"'truenas.version' missing or malformed (got {tn_version!r}); expected X.Y[.Z[.W[.V]]]")
tn_train = truenas.get("train")
if not isinstance(tn_train, str) or not re.match(r"^[A-Z][a-zA-Z]+$", tn_train):
    fail(f"'truenas.train' missing or malformed (got {tn_train!r}); expected capitalized word (e.g. Goldeye)")

# Supported trains: one hardware-test issue each per release (release.yml),
# and promote.yml writes `verified-train: <key>` when one closes as completed.
trains = data.get("trains")
if not isinstance(trains, list) or not trains:
    fail("'trains' missing or not a non-empty list")
keys, names = set(), set()
for i, t in enumerate(trains):
    where = f"trains[{i}]"
    if not isinstance(t, dict):
        fail(f"{where} is not an object")
    key = t.get("key")
    # Shape only. That each key is one get.sh's truenas_train_key can
    # produce is tested against the shell function itself
    # (tests/test_release_selection.py), so the rule lives in one place.
    if not isinstance(key, str) or not re.match(r"^\d+(\.\d+)?$", key):
        fail(f"{where}.key missing or malformed (got {key!r}); expected e.g. 25.10 or 26")
    if key in keys:
        fail(f"{where}.key {key!r} is listed twice")
    keys.add(key)
    name = t.get("name")
    if not isinstance(name, str) or not name.strip():
        fail(f"{where}.name missing or empty (got {name!r}); expected e.g. 'TrueNAS 25.10'")
    if name in names:
        fail(f"{where}.name {name!r} is listed twice (issue titles and the duplicate check use it)")
    names.add(name)
    channel = t.get("channel")
    if channel not in ("stable", "preview"):
        fail(f"{where}.channel must be 'stable' or 'preview' (got {channel!r})")

summary = ", ".join(f"{t['key']} ({t['channel']})" for t in trains)
print(f"tracked-versions OK: smoke build TrueNAS {tn_version} ({tn_train}); trains {summary}")
PY
