# TrueNAS Community NVIDIA Driver Support

Install **any** NVIDIA driver on TrueNAS by swapping the stock driver sysext for one built on your own host — a legacy branch for a card TrueNAS no longer supports, a specific recent open driver, or a patched/custom `.run` you supply.

```bash
# On TrueNAS, as root — detects your card and recommends a driver:
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-driver-support/main/scripts/install-nvidia-driver.sh \
  | sudo bash
sudo reboot
```

> **Driver-only.** This repo owns the **driver swap**. If you want **MIG** on a Blackwell card, install [`nvidia-mig-support`](https://github.com/truenas-community-sysexts/nvidia-mig-support) after the reboot. The MIG sysext layers on top of whatever driver is present.  see [MIG coexistence](#coexistence-with-nvidia-mig-support).)

## Why this exists

TrueNAS ships exactly one NVIDIA driver, and recent releases moved to a 570.x+ branch that **only supports Turing and newer GPUs with open kernel modules**. That drops a lot of hardware people still run in NAS boxes for transcoding and light compute:

- **Kepler** (GTX 600/700, Quadro K-series) — last driver is the **470** branch
- **Maxwell / Pascal / Volta** (GTX 900/10-series, Quadro P400/P2000, Titan V) — last driver is the **580** branch
- Plus anyone who wants a **specific** open driver version, or a **patched** `.run` (vGPU-unlock, NVENC patch, hand-built).


## How a card maps to a driver

The picker reads [`catalog/driver-catalog.json`](catalog/driver-catalog.json) (refreshed daily by CI) and detects your GPU via `/sys` (with `lspci` for the exact chip name when the system's PCI database knows it) to recommend a branch:

| Your card | Chip family | Recommended driver | Modules |
| --- | --- | --- | --- |
| Turing and newer — RTX 20/30/40/50, A/B-series, Quadro RTX | `TU`/`GA`/`AD`/`GB`/`GH` | `latest` (newest open in the catalog) | open |
| Maxwell · Pascal · Volta — GTX 900/10-series, Quadro P-series, Titan V | `GM`/`GP`/`GV` | `legacy-580` | proprietary |
| Kepler — GTX 600/700, Quadro K-series, Tesla K-series | `GK` | `legacy-470` | proprietary |

All three tiers **build against TrueNAS's current 6.x kernel and are smoke-tested in CI** on every change. Kepler/`legacy-470` is EOL upstream and only compiles on 6.x thanks to a vendored community patch set ([`nvidia-470xx-linux-mainline`](https://github.com/joanbm/nvidia-470xx-linux-mainline)) this repo applies for you.

> **Older than Kepler?** **Fermi** (GTX 400/500, `GF` → 390.x) and **Tesla gen 1–2** (8/9/200-series, `G8x`/`G9x`/`GT2xx` → 340.x) are **not supported out of the box** — those EOL installers don't compile against the 6.x kernel and this repo ships **no** patches for them. You can still attempt one by supplying your own community-patched installer via `--custom-run` or `--run-url` (see [docs/legacy-cards.md](docs/legacy-cards.md)); expect to do the legwork.

A card **newer than the host's PCI database** (e.g. a just-released GPU) won't have a chip name to map, but it's still detected as an NVIDIA display device via `/sys` and treated as Turing+ → the latest open driver.

`--list` prints the live catalog with exact versions **and module flavor**. Through the `curl … | sudo bash` one-liner, flags for the script go after `bash -s --` (otherwise they're consumed by `curl`/`bash`):

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-driver-support/main/scripts/install-nvidia-driver.sh | sudo bash -s -- --list
```

## Ways to choose a driver

```bash
# 1. Detect my card and recommend (default, interactive)
sudo install-nvidia-driver.sh

# 2. Last driver for a card series
sudo install-nvidia-driver.sh --branch=legacy-580     # Maxwell/Pascal/Volta
sudo install-nvidia-driver.sh --branch=legacy-470     # Kepler

# 3. A specific driver version (need not be in the catalog — incl. betas /
#    a version newer than the catalog's "latest")
sudo install-nvidia-driver.sh --list                  # see the catalog
sudo install-nvidia-driver.sh --driver=595.80
sudo install-nvidia-driver.sh --branch=latest         # newest open in the catalog

# 4. A patched / custom .run you already have
sudo install-nvidia-driver.sh \
  --custom-run=/mnt/tank/NVIDIA-Linux-x86_64-580.65.06-vgpu.run

# 5. Any .run by URL (betas / versions hosted anywhere)
sudo install-nvidia-driver.sh \
  --run-url=https://us.download.nvidia.com/XFree86/Linux-x86_64/610.43.02/NVIDIA-Linux-x86_64-610.43.02-no-compat32.run
```

The catalog deliberately lists only NVIDIA's blessed production drivers (≤ `latest.txt`); **betas / not-yet-promoted versions install fine by number (`--driver=`) or URL (`--run-url=`)** — they're just not tracked or smoke-tested. The kernel-module flavor (`--kmod`) is auto-derived — **open** for Turing+, **proprietary** for the legacy branches — and overridable. Open modules are refused on pre-Turing cards (they don't exist there) unless you `--force`.

## What install does

1. **Resolves** the target driver version + module flavor (from your flag or the card-detected recommendation).
2. **Builds `nvidia.raw` on this host** inside a transient `ubuntu:24.04` docker container — downloads the matching TrueNAS `.update` (for kernel headers) and the NVIDIA `.run`, cross-compiles `nvidia.ko` against your running kernel, and squashfs's the result. ≈ 8 min first run; cached after (~10 s re-install).
3. **Swaps** the stock `nvidia.raw` for the built one (brief `/usr` read-write via a ZFS `readonly` toggle), keeping `nvidia-original.raw` as a backup.
4. **Registers a PREINIT** that restores your driver after a TrueNAS update wipes `/usr`, and flags a kernel bump.
5. **Reboot required** — live-swapping the driver leaves stale kernel modules in memory; `nvidia-smi` reports a driver/library mismatch until you reboot.

Nothing pre-built is downloaded: NVIDIA's EULA prohibits redistributing the proprietary userspace, so `nvidia.raw` is **only ever assembled on your machine**, where you accept NVIDIA's license when the `.run` runs with `--silent`.

## Releases

A release is a **tooling + catalog snapshot**, tagged `v<N>` (an auto-incrementing counter). It carries the install scripts + the driver catalog (the whole supported matrix) — never a prebuilt driver, since the EULA point above means `nvidia.raw` is always built on your host. **It is not tied to a driver, module flavor, or TrueNAS version**: the install script reads the bundled catalog, detects your card, and builds the right driver against your host's kernel, so one release covers everything and works across TrueNAS versions (a kernel bump just triggers an on-host rebuild).

The install one-liner pulls the repo's **latest** release for its tooling + catalog (falling back to `main` when none exists). To pin an exact, reproducible snapshot:

```bash
curl -fsSL .../scripts/install-nvidia-driver.sh | sudo bash -s -- --release=v5
```

`--release` only pins the tooling + catalog snapshot — driver selection is unchanged (card-detect / `--branch` / `--driver` / `--custom-run` / `--run-url`).

## Prerequisites

- TrueNAS 25.10 or later
- A working Docker daemon (TrueNAS Apps users already have it; on a headless box with Apps disabled the build starts Docker and restores its prior state on exit)
- A stock-driver backup before the first swap — the install refuses without one. Create it once:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-driver-support/main/scripts/recover-stock-nvidia.sh | sudo bash
  ```

## Verify / preview / uninstall

```bash
sudo install-nvidia-driver.sh --check     # read-only probe of an existing install
sudo install-nvidia-driver.sh --dry-run --branch=legacy-580   # walk the steps, mutate nothing
sudo uninstall-nvidia-driver               # revert to stock (reboot) — bundled on PATH in the sysext
```

`--check` and `--dry-run` are mutually exclusive. `--dry-run` resolves the version, validates URLs, and prints every mutation as `[dry-run] would: …` without touching the system. The uninstaller is **bundled into the sysext** at `/usr/bin/uninstall-nvidia-driver` (on PATH whenever the custom driver is merged), and a copy is also staged to `/mnt/<pool>/.config/nvidia-gpu/scripts/` (along with `recover-stock-nvidia.sh` + build helpers) — that copy survives even when the sysext is unmerged or restored to stock, so teardown always works. Equivalents:

```bash
sudo /mnt/<pool>/.config/nvidia-gpu/scripts/uninstall-nvidia-driver.sh   # persisted copy (survives unmerge)
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-driver-support/main/scripts/uninstall-nvidia-driver.sh | sudo bash   # last resort (no local copy)
```

## After a TrueNAS update

The PREINIT restores your custom driver automatically when an update wipes `/usr`. If the update **bumped the kernel**, the bundled `nvidia.ko` no longer matches — `journalctl -b -t nvidia-preinit-driver` logs a loud kernel-mismatch error. Re-run the install one-liner (or the staged `build-on-host.sh`) to rebuild against the new kernel:

```bash
curl -fsSL .../scripts/install-nvidia-driver.sh | sudo bash -s -- --rebuild
```

## Scripts reference

| Script | What it does |
| --- | --- |
| [`install-nvidia-driver.sh`](scripts/install-nvidia-driver.sh) | Picks a driver (card-detect / `--branch` / `--driver` / `--custom-run` / `--run-url`), builds `nvidia.raw` on-host, swaps the stock driver, registers the restore PREINIT. `--list`, `--check`, `--dry-run`. |
| [`build-nvidia-sysext.sh`](scripts/build-nvidia-sysext.sh) | The driver build itself. Branch-aware installer flags (drops `--kernel-module-type` etc. for pre-515 legacy installers). Runs in CI as a smoke test and inside the on-host container. |
| [`build-on-host.sh`](scripts/build-on-host.sh) | Wraps the build in `docker run --rm ubuntu:24.04`; caches the TrueNAS `.update` + NVIDIA `.run`. |
| [`recover-stock-nvidia.sh`](scripts/recover-stock-nvidia.sh) | Extracts stock `nvidia.raw` from the official TrueNAS `.update` → `nvidia-original.raw` (backup before first swap). |
| [`uninstall-nvidia-driver.sh`](scripts/uninstall-nvidia-driver.sh) | Reverts to stock, deregisters the PREINIT, cleans build artifacts (keeps `nvidia-original.raw`). |
| [`nvidia-preinit-driver.sh`](scripts/nvidia-preinit-driver.sh) | Boot-time PREINIT: restores the custom driver after a TrueNAS update + kernel-mismatch detection. |

All scripts support `--help`.

## License

MIT (see [LICENSE](LICENSE)). This repo redistributes **no** NVIDIA-proprietary code — release assets contain only the MIT-licensed scripts and the catalog (version strings). `nvidia.raw` is assembled on your machine; by installing you accept the [NVIDIA Linux Driver License](https://www.nvidia.com/en-us/drivers/nvidia-license/).

## More

- [docs/architecture.md](docs/architecture.md) — sysext model, build pipeline, PREINIT flow, ZFS readonly dance
- [docs/legacy-cards.md](docs/legacy-cards.md) — the card→branch matrix, proprietary modules, patched-`.run` guidance
- [docs/driver-catalog.md](docs/driver-catalog.md) — catalog format + how the daily refresh works
- [docs/troubleshooting.md](docs/troubleshooting.md) — common failure modes

## Credits

- [`nvidia-mig-support`](https://github.com/truenas-community-sysexts/nvidia-mig-support) — the on-host driver-build pipeline this repo forks
- [biohazardious/truenas-nvidia-driver-updater](https://github.com/biohazardious/truenas-nvidia-driver-updater) — the snapshot-diff / two-level squashfs extraction the build is ported from
- [zzzhouuu/truenas-nvidia-drivers](https://github.com/zzzhouuu/truenas-nvidia-drivers) — original inspiration that this is doable
