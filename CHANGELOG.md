# Changelog

All notable changes to `nvidia-driver-support` are documented here.

## [Unreleased]

### Fixed

- **`install-nvidia-driver.sh` now restores the GPU release it does before the swap.** To
  free the GPU the install stops GPU-bound apps (`app.stop`) and toggles `docker.config.nvidia`
  off — but it never turned them back on, so after the swap + reboot apps came back with the
  nvidia toggle stuck off (no GPU) and any stopped apps left down. Ported the hardened
  drain/rollback pattern from `nvidia-mig-support` (PRs #55/#63/#65):
  - **Clean finish:** re-enable the docker nvidia toggle (to its *captured prior value*, not a
    hardcoded `true`) and restart the apps that were stopped, in that order (TrueNAS won't start
    a container while the toggle is off). Apps recover after the required reboot.
  - **Abort before the swap:** roll the whole GPU release back (toggle first, then restart the
    stopped apps, including one caught mid-`app.stop`), so an interrupted install leaves the box
    as it was found.
  - **Abort after the swap began:** do NOT restart apps onto a half-swapped driver; print a
    `recover-stock-nvidia.sh` recovery banner and list the apps left stopped.
  - Phase-gated by a `SWAP_STARTED` flag; fully inert under `--dry-run`. `uninstall-nvidia-driver.sh`
    and `recover-stock-nvidia.sh` already had the `restore_state` trap, so no change there.

### Added

- **Persistent build logs.** The on-host build runs in a `--rm` container, so a failed
  cross-compile used to take its `/var/log/nvidia-installer.log` with it — leaving nothing to
  diagnose. Now each build writes two timestamped files to `/mnt/<pool>/.config/nvidia-gpu/logs/`:
  `build-<ts>.log` (the full container console, via `tee`) and `nvidia-installer-<ts>.log`
  (lifted out of the container on success *and* failure). Kept to the newest 3 of each; removed
  by uninstall; printed in the build output and on failure so issue reports can attach them. In
  CI the installer log also rides along in the build output dir.
- Initial release. Driver-only NVIDIA sysext for TrueNAS SCALE, forked from the on-host
  build pipeline in [`nvidia-mig-support`](https://github.com/truenas-community-sysexts/nvidia-mig-support).
- **Driver catalog + card-aware picker** (`install-nvidia-driver.sh`): detects the GPU via
  `/sys` (vendor `0x10de` + display class), names the chip via `lspci` when the host's PCI
  database knows it, and recommends a branch — a card newer than that database (e.g. a
  just-released Blackwell) is treated as Turing+ → latest/open. Selectors: `--branch`
  (legacy-580/470 / latest), `--driver=X.Y.Z`, `--custom-run=PATH`, `--run-url=URL`,
  `--release=v<N>`; plus `--list`, `--check`, `--dry-run`, `--kmod`. `--list` and the
  interactive picker show the full open-train matrix and each branch's module flavor.
  Run with no selector, the picker is a **numbered menu** (card-detected row
  preselected — usually just press Enter), and for drivers that ship both kernel-module
  flavors (515+) it follows up with an open-vs-proprietary prompt defaulted to the
  card's recommendation. `--kmod` still overrides non-interactively.
- **Legacy-branch support**: 470.x (Kepler) builds against modern (6.x) kernels via the
  vendored [`nvidia-470xx-linux-mainline`](https://github.com/joanbm/nvidia-470xx-linux-mainline)
  patch set (git submodule under `third_party/`); 580.x (Maxwell/Pascal/Volta) supported.
  Fermi (390.x) and Tesla gen 1–2 (340.x) are **not** catalog branches — they don't build
  against 6.x kernels unpatched; a detected such card gets no recommendation and must use a
  patched `.run` via `--custom-run` / `--run-url`.
- **Branch-aware installer flags** in `build-nvidia-sysext.sh`: every non-essential flag is
  gated on the installer advertising it in `--advanced-options` (pre-515 legacy installers
  reject `--kernel-module-type`, `--no-rebuild-initramfs`, etc.); forces proprietary where no
  open path exists.
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
