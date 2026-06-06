# The driver catalog

[`catalog/driver-catalog.json`](../catalog/driver-catalog.json) is the data the picker reads:
which versions exist, which one each card series wants, and how to map a detected GPU to a
branch. It's refreshed daily by CI so `--list`, `--branch=latest`, and the card-detected
recommendation stay current with no manual upkeep.

## Format

```jsonc
{
  "open_latest_count": 5,
  "open_latest": ["610.43.02", "595.71.05", "..."],   // newest N open-capable, newest first
  "branches": {
    "latest":     { "track": "open_latest[0]", "kmod": "open", "support": "supported" },
    "legacy-580": { "version": "580.159.04", "kmod": "proprietary",
                    "chips": ["GM","GP","GV"], "support": "supported" },
    "legacy-470": { "version": "470.256.02", "kmod": "proprietary",
                    "chips": ["GK"], "support": "supported" },
    "legacy-390": { "version": "390.157", "kmod": "proprietary",
                    "chips": ["GF"], "support": "best-effort" },
    "legacy-340": { "version": "340.108", "kmod": "proprietary",
                    "chips": ["G8","G9","GT2"], "support": "best-effort" }
  },
  "chip_map": { "GK":"legacy-470", "GP":"legacy-580", "TU":"latest", "...": "..." }
}
```

- **`open_latest`** — the newest `open_latest_count` driver versions with major ≥ 515
  (open-module capable), newest first. `--branch=latest` resolves to `open_latest[0]`.
- **`branches`** — one entry per selectable branch. `version` is a fixed pin (legacy) or
  `track` points into `open_latest`. `kmod` is the default module flavor; `support` is
  `supported` (CI-smoke-tested, builds on the current kernel) or `best-effort`
  (needs a patched `.run`).
- **`chip_map`** — NVIDIA chip prefix → branch. The picker tries the longest prefix first
  (`GT2` before `GP` before `G9`), so Tesla `GT218` maps to `legacy-340`, not a `G`-prefix
  collision.

## Daily refresh

[`.github/workflows/check-drivers.yml`](../.github/workflows/check-drivers.yml) runs
[`refresh-catalog.py`](../.github/scripts/refresh-catalog.py) every morning:

1. Scrape the autoindex at `https://download.nvidia.com/XFree86/Linux-x86_64/` for every
   `X.Y.Z` / `X.Y` version directory.
2. Recompute `open_latest` (newest N with major ≥ 515) and each legacy branch's `version`
   (newest release matching that branch's major — NVIDIA still ships occasional security
   updates to legacy branches).
3. Everything else — `chip_map`, `kmod`, `support`, notes — is **preserved verbatim**.
4. Commit `catalog/driver-catalog.json` if it changed.

Run it manually from the repo root:

```bash
python3 .github/scripts/refresh-catalog.py          # rewrite if stale
python3 .github/scripts/refresh-catalog.py --check   # exit 1 if a refresh would change it
```

## Editing by hand

You **can** hand-edit `chip_map`, `kmod`, `support`, notes, and `open_latest_count` — those
survive the refresh. Don't hand-pin `open_latest` or a legacy `version`; the daily job
overwrites them. To add a new selectable branch (say a future `legacy-XXX`), add the branch
object **and** its `chips` to `chip_map`, then run `validate-catalog.sh`.

## Validation

[`.github/scripts/validate-catalog.sh`](../.github/scripts/validate-catalog.sh) (run in
`lint.yml`) asserts: required top-level keys, `open_latest` non-empty and well-formed,
every branch has `version`-or-`track` + valid `kmod` + valid `support`, and every
`chip_map` value references a defined branch.
