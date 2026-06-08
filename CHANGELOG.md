# Changelog

All notable changes to `nvidia-driver-support` are documented here.

## [Unreleased]

### Added

- Initial release. Driver-only NVIDIA sysext for TrueNAS SCALE, forked from the on-host
  build pipeline in [`nvidia-mig-support`](https://github.com/truenas-community-sysexts/nvidia-mig-support).
- **Driver catalog + card-aware picker** (`install-nvidia-driver.sh`): detects the GPU via
  `/sys` (vendor `0x10de` + display class), names the chip via `lspci` when the host's PCI
  database knows it, and recommends a branch — a card newer than that database (e.g. a
  just-released Blackwell) is treated as Turing+ → latest/open. Selectors: `--branch`
  (legacy-470/580/390/340 / latest), `--driver=X.Y.Z`, `--custom-run=PATH`, `--run-url=URL`,
  `--release=v<N>`; plus `--list`, `--check`, `--dry-run`, `--kmod`. `--list` and the
  interactive picker show the full open-train matrix and each branch's module flavor.
  Run with no selector, the picker is a **numbered menu** (card-detected row
  preselected — usually just press Enter), and for drivers that ship both kernel-module
  flavors (515+) it follows up with an open-vs-proprietary prompt defaulted to the
  card's recommendation. `--kmod` still overrides non-interactively.
- **Legacy-branch support**: 470.x (Kepler) builds against modern (6.x) kernels via the
  vendored [`nvidia-470xx-linux-mainline`](https://github.com/joanbm/nvidia-470xx-linux-mainline)
  patch set (git submodule under `third_party/`); 580.x (Maxwell/Pascal/Volta) supported;
  390.x (Fermi) and 340.x (Tesla) best-effort with a patched-`.run` escape hatch.
- **Branch-aware installer flags** in `build-nvidia-sysext.sh`: every non-essential flag is
  gated on the installer advertising it in `--help` (pre-515 legacy installers reject
  `--kernel-module-type`, `--no-rebuild-initramfs`, etc.); forces proprietary where no open
  path exists.
- **Auto-kmod**: open for Turing+, proprietary for legacy; refuses open on pre-Turing cards.
- **Catalog** (`catalog/driver-catalog.json`): `open_latest` is the newest open driver per
  major/train, capped at `open_latest_count` and **never above NVIDIA's `latest.txt`** (so
  betas / not-yet-promoted versions are excluded), each verified to ship a `-no-compat32.run`.
  Refreshed daily by `check-drivers.yml` + `refresh-catalog.py`. Betas / arbitrary versions
  still install via `--driver` / `--run-url`.
- **CI smoke** (`build-sysext.yml`): builds the newest open trains in both open and
  proprietary flavors + the 580 branch + the patched 470, with a concurrency guard.
- **Releases** (`release.yml`): versioned "NVIDIA driver installer `v<N>`" snapshots carrying
  the MIT tooling + catalog (never `nvidia.raw` — NVIDIA's EULA; the driver is built on the
  user's host). Zero-input manual dispatch.
- Ported `build-on-host.sh`, `nvidia-preinit-driver.sh`, `recover-stock-nvidia.sh`, and a
  driver-only `uninstall-nvidia-driver.sh` — the uninstaller is also bundled on `PATH` inside
  the sysext (`/usr/bin/uninstall-nvidia-driver`).
- Shares `/mnt/<pool>/.config/nvidia-gpu/` with `nvidia-mig-support`; documented as the
  driver-swap owner so MIG layers on top in its default mode.
