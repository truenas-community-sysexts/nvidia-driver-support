# Changelog

All notable changes to `nvidia-driver-support` are documented here.

## [Unreleased]

### Added

- Initial release. Driver-only NVIDIA sysext for TrueNAS SCALE, forked from the on-host
  build pipeline in [`nvidia-mig-support`](https://github.com/truenas-community-sysexts/nvidia-mig-support).
- **Driver catalog + card-aware picker** (`install-nvidia-driver.sh`): detects the GPU chip
  family from `lspci` and recommends a branch; `--branch` (legacy-470/580/390/340 / latest),
  `--driver=X.Y.Z`, `--custom-run=PATH`, `--list`, `--check`, `--dry-run`.
- **Legacy-branch support**: 470.x (Kepler) and 580.x (Maxwell/Pascal/Volta) officially
  supported; 390.x (Fermi) and 340.x (Tesla) offered best-effort with a patched-`.run`
  escape hatch.
- **Branch-aware installer flags** in `build-nvidia-sysext.sh`: drops `--kernel-module-type`
  and other version-fragile flags for pre-515 legacy installers, filtered against the
  installer's own `--help`; forces proprietary modules where no open path exists.
- **Auto-kmod**: open for Turing+, proprietary for legacy; refuses open on pre-Turing cards.
- **Daily catalog refresh** (`check-drivers.yml` + `refresh-catalog.py`) scraping NVIDIA's
  Linux driver index; CI smoke build (`build-sysext.yml`) for latest-open / 470 / 580.
- Ported `build-on-host.sh`, `nvidia-preinit-driver.sh`, `recover-stock-nvidia.sh`, and a
  driver-only `uninstall-nvidia-driver.sh`.
- Shares `/mnt/<pool>/.config/nvidia-gpu/` with `nvidia-mig-support`; documented as the
  driver-swap owner so MIG layers on top in its default mode.
