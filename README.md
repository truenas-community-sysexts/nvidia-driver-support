# TrueNAS Community NVIDIA Driver Support

Install **any** NVIDIA driver on TrueNAS SCALE by swapping the stock driver sysext for one built on your own host — a legacy branch for a card TrueNAS no longer supports, a specific recent open driver, or a patched/custom `.run` you supply.

```bash
# On TrueNAS, as root — detects your card and recommends a driver:
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-driver-support/main/scripts/install-nvidia-driver.sh \
  | sudo bash
sudo reboot
```

> **Driver-only.** This repo owns the **driver swap**. If you want **MIG** on a Blackwell card, install [`nvidia-mig-support`](https://github.com/truenas-community-sysexts/nvidia-mig-support) in its **default mode** afterwards — it layers on top of whatever driver is present. (Don't use that repo's `--with-driver` path alongside this one; see [MIG coexistence](#coexistence-with-nvidia-mig-support).)

## Why this exists

TrueNAS SCALE ships exactly one NVIDIA driver, and recent releases moved to a 570.x+ branch that **only supports Turing and newer GPUs with open kernel modules**. That drops a lot of hardware people still run in NAS boxes for transcoding and light compute:

- **Kepler** (GTX 600/700, Quadro K-series) — last driver is the **470** branch
- **Maxwell / Pascal / Volta** (GTX 900/10-series, Quadro P400/P2000, Titan V) — last driver is the **580** branch
- Plus anyone who wants a **specific** open driver version, or a **patched** `.run` (vGPU-unlock, NVENC patch, hand-built).

The driver-build machinery is a driver-only fork of [`nvidia-mig-support`](https://github.com/truenas-community-sysexts/nvidia-mig-support)'s on-host build, wrapped in a **driver catalog + card-aware picker**.

## How a card maps to a driver

The picker reads [`catalog/driver-catalog.json`](catalog/driver-catalog.json) (refreshed daily by CI) and detects your GPU's chip family from `lspci` to recommend a branch:

| Your card (chip family) | Examples | Branch | Modules | Status |
| --- | --- | --- | --- | --- |
| Kepler (`GK`) | GTX 660/750 Ti, GT 710/730, Quadro K2200, Tesla K80 | `legacy-470` | proprietary | ✅ supported |
| Maxwell/Pascal/Volta (`GM`/`GP`/`GV`) | GTX 970/1060/1080, Quadro P400/P2000, Titan V | `legacy-580` | proprietary | ✅ supported |
| Turing and newer (`TU`/`GA`/`AD`/`GB`) | RTX 20/30/40/50, A-series | `latest` | open | ✅ supported |
| Fermi (`GF`) | GTX 400/500 | `legacy-390` | proprietary | ⚠️ best-effort¹ |
| Tesla (`G8x`/`G9x`/`GT2xx`) | 8/9/200-series | `legacy-340` | proprietary | ⚠️ best-effort¹ |

¹ **best-effort** branches don't cross-compile against TrueNAS's current (6.x) kernel without patches. Bring a patched installer via `--custom-run` — see [docs/legacy-cards.md](docs/legacy-cards.md).

`sudo install-nvidia-driver.sh --list` prints the live catalog with exact versions.

## The four ways to choose a driver

```bash
# 1. Detect my card and recommend (default, interactive)
sudo install-nvidia-driver.sh

# 2. Last driver for a card series
sudo install-nvidia-driver.sh --branch=legacy-580     # Maxwell/Pascal/Volta
sudo install-nvidia-driver.sh --branch=legacy-470     # Kepler

# 3. A specific open driver version
sudo install-nvidia-driver.sh --list                  # see what's available
sudo install-nvidia-driver.sh --driver=595.71.05
sudo install-nvidia-driver.sh --branch=latest         # newest open in the catalog

# 4. A patched / custom .run you already have
sudo install-nvidia-driver.sh \
  --custom-run=/mnt/tank/NVIDIA-Linux-x86_64-535.xx-vgpu-kvm.run
```

The kernel-module flavor (`--kmod`) is auto-derived — **open** for Turing+, **proprietary** for the legacy branches — and overridable. Open modules are refused on pre-Turing cards (they don't exist there) unless you `--force`.

## What install does

1. **Resolves** the target driver version + module flavor (from your flag or the card-detected recommendation).
2. **Builds `nvidia.raw` on this host** inside a transient `ubuntu:24.04` docker container — downloads the matching TrueNAS `.update` (for kernel headers) and the NVIDIA `.run`, cross-compiles `nvidia.ko` against your running kernel, and squashfs's the result. ≈ 8 min first run; cached after (~10 s re-install).
3. **Swaps** the stock `nvidia.raw` for the built one (brief `/usr` read-write via a ZFS `readonly` toggle), keeping `nvidia-original.raw` as a backup.
4. **Registers a PREINIT** that restores your driver after a TrueNAS update wipes `/usr`, and flags a kernel bump.
5. **Reboot required** — live-swapping the driver leaves stale kernel modules in memory; `nvidia-smi` reports a driver/library mismatch until you reboot.

Nothing pre-built is downloaded: NVIDIA's EULA prohibits redistributing the proprietary userspace, so `nvidia.raw` is **only ever assembled on your machine**, where you accept NVIDIA's license when the `.run` runs with `--silent`.

## Prerequisites

- TrueNAS SCALE 25.10 or later
- A working Docker daemon (TrueNAS Apps users already have it; on a headless box with Apps disabled the build starts Docker and restores its prior state on exit)
- A stock-driver backup before the first swap — the install refuses without one. Create it once:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-driver-support/main/scripts/recover-stock-nvidia.sh | sudo bash
  ```

## Verify / preview / uninstall

```bash
sudo install-nvidia-driver.sh --check     # read-only probe of an existing install
sudo install-nvidia-driver.sh --dry-run --branch=legacy-580   # walk the steps, mutate nothing
sudo /mnt/<pool>/.config/nvidia-gpu/scripts/uninstall-nvidia-driver.sh   # revert to stock (reboot)
```

`--check` and `--dry-run` are mutually exclusive. `--dry-run` resolves the version, validates URLs, and prints every mutation as `[dry-run] would: …` without touching the system. The uninstaller (and `recover-stock-nvidia.sh`, build helpers) are staged into `/mnt/<pool>/.config/nvidia-gpu/scripts/` on install, so teardown needs no network. Fallback if the sysext is unmerged:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-driver-support/main/scripts/uninstall-nvidia-driver.sh | sudo bash
```

## After a TrueNAS update

The PREINIT restores your custom driver automatically when an update wipes `/usr`. If the update **bumped the kernel**, the bundled `nvidia.ko` no longer matches — `journalctl -b -t nvidia-preinit-driver` logs a loud kernel-mismatch error. Re-run the install one-liner (or the staged `build-on-host.sh`) to rebuild against the new kernel:

```bash
curl -fsSL .../scripts/install-nvidia-driver.sh | sudo bash -s -- --rebuild
```

## Coexistence with `nvidia-mig-support`

Both repos can swap `nvidia.raw`; to avoid two owners of one file, **this repo is the driver-swap owner**. They share `/mnt/<pool>/.config/nvidia-gpu/` (one `nvidia-original.raw`, one `cache/`, one driver PREINIT).

- **Driver only** → this repo.
- **Driver + MIG** → install this repo first, then `nvidia-mig-support` in its **default** mode (it layers MIG on top of whatever driver is present). Do **not** pass `nvidia-mig-support --with-driver` alongside this — that path is its own driver-swap owner and would fight this one.

## Scripts reference

| Script | What it does |
| --- | --- |
| [`install-nvidia-driver.sh`](scripts/install-nvidia-driver.sh) | Picks a driver (card-detect / `--branch` / `--driver` / `--custom-run`), builds `nvidia.raw` on-host, swaps the stock driver, registers the restore PREINIT. `--list`, `--check`, `--dry-run`. |
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
