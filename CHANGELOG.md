# Changelog

All notable changes to `nvidia-driver-support` are documented here.

## [Unreleased]

### Fixed

- **A stale stock backup is no longer restored.** `nvidia-original.raw` holds the stock driver
  of the TrueNAS version it was made on; after an update that changed the kernel (seen on
  hardware: a backup with `6.12.33-production+truenas` modules on a box running
  `6.18.42-production+truenas`), restoring it would put a driver on the system that cannot
  load. A backup now counts only if it has modules for the running kernel. The installer
  refuses a stale backup exactly as it refuses a missing one (same `--skip-backup-check`
  override), `--check` warns with the refresh command, the uninstaller refuses to restore it
  (with `--skip-backup-check` it uninstalls without restoring stock, as with no backup), and
  `recover-stock-nvidia.sh` never stages or installs a stock driver for another kernel. Refresh
  a stale backup by running `recover-stock-nvidia.sh` without flags.
- **`recover-stock-nvidia.sh` no longer resumes another version's download.** It resumed any
  leftover `recovery/truenas.update` with `curl --continue-at -`, so a partial from an
  interrupted run on an older TrueNAS could be extended with the new version's bytes, or taken
  as complete, and the old version's stock driver extracted. The download URL is now recorded
  next to the file and a partial with a different (or no) record is discarded; the download is
  also checked against the `.sha256` sidecar TrueNAS publishes, as `build-nvidia-sysext.sh`
  does.
- **The post-install message says what to expect until the reboot.** When a working driver
  is replaced, its kernel module stays loaded until the reboot: `nvidia-smi` fails with a
  driver/library mismatch and the whole Apps service can fail to start, not just GPU apps. The
  final message now says so (only when the loaded module is the previous driver's), lists the
  GPU apps it stopped but could not restart (those stay stopped after the reboot) with the
  command to start each, and says when the docker nvidia toggle could not be restored.
- **Daily catalog refresh no longer flip-flops the latest open driver.** NVIDIA's
  `latest.txt` is served through Akamai, and different edges held stale copies (595.58.03,
  595.84, 595.91.07, 595.99.02), so each day's run could see a different "latest", rewrite
  `open_latest`, and cut a new prerelease plus hardware-test issue (v41 to v77 were almost all
  these flips). `refresh-catalog.py` now never lets the production ceiling drop below the one
  already committed; a stale edge is logged and ignored, while a genuinely newer production
  version still moves the catalog forward.
- **`cleanup_tmp` no longer fires twice on Ctrl-C / SIGTERM.** The trap caught `EXIT INT TERM`
  but the handler never disarmed or exited, so a signal ran it once via INT/TERM and then again
  via EXIT. The second pass called `app.start` on already-running apps (bogus "could not restart,
  start it from the Apps UI" warnings) and printed the rollback banner twice. Worse, after the
  INT handler returned the script resumed into the driver swap, so a Ctrl-C during the GPU-drain
  wait did not actually abort. Fixed by disarming at the top of the handler and `exit "$rc"` at
  the bottom, plus clearing `STOPPED_APPS`/`STOPPING_APP` after the rollback to match the
  flag-reset idiom used in the sibling scripts. INT/TERM pass explicit exit codes (130/143) so a
  signal delivered only to the script (`kill <pid>`) cannot skip the rollback and exit 0, and
  further signals are ignored while the rollback runs so a second Ctrl-C cannot cut it short.
- **`build-on-host.sh` handles INT/TERM explicitly** with the same run-once handler and
  130/143 exit codes (bash already ran its `EXIT` trap on a signal, so docker was restored; this
  makes the behavior explicit and consistent).
- **Install no longer aborts mid-swap with "Hierarchy '/usr' is already merged".** The
  installer toggled `docker.config.nvidia` with `midclt call docker.update` but without `-j`,
  so it did not wait for the job. That job runs TrueNAS's nvidia handler (its own
  `systemd-sysext refresh`, then a docker restart), which landed inside the installer's
  unmerge/merge window; the installer's plain `merge` then failed and the install aborted after
  the driver swap, leaving the docker nvidia toggle off. Seen on hardware on TrueNAS
  26.0.0-BETA.3; the 25.10 middleware has the same job shape. Every `docker.update` in
  `install-nvidia-driver.sh`, `recover-stock-nvidia.sh` and `uninstall-nvidia-driver.sh` now
  uses `-j` (as the uninstaller's disable call already did), and the post-swap re-merge uses
  `systemd-sysext refresh`, which is correct whether or not `/usr` was re-merged meanwhile.
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

- **Downloads are SHA256-verified** (previously fetched blind). `build-nvidia-sysext.sh`
  checks the TrueNAS `.update` against the `.sha256` sidecar download.truenas.com publishes
  next to it, and a fresh NVIDIA `.run` against NVIDIA's `.run.sha256sum`; sidecars are
  fetched before the multi-GB transfers, mismatches are fatal, and only a definitive 404
  (versions NVIDIA never published a sidecar for, e.g. 470.129.06) downgrades to a warning.
  `--run-url` verifies when the host publishes a sidecar and warns otherwise. A hex guard
  keeps proxy soft-404 pages from reading as checksums, and verified downloads record their
  hash so cached reuse re-verifies instead of trusting (truncation/bit-rot fails the build).
- **`build-on-host.sh` cache bridge repaired.** Cached and `--run-file` runs were staged at
  a fixed `/tmp/nvidia_build/` path the build script no longer reads (its work dirs moved
  under a per-run mktemp root), so a patched custom `.run` was silently replaced by a stock
  download and the `.run` cache never backfilled. The build script now takes `--run-file=`
  (mirroring `--update-file`) and bridges through root-owned `/var/cache/nvidia-sysext-stage`
  (0700, no world-writable `/tmp` paths trusted or executed as root). Backfill copies only
  genuinely fresh downloads instead of rewriting multi-GB cache entries every build.

### Added

- **Persistent build logs.** The on-host build runs in a `--rm` container, so a failed
  cross-compile used to take its `/var/log/nvidia-installer.log` with it — leaving nothing to
  diagnose. Now each build writes two timestamped files to `/mnt/<pool>/.config/nvidia-gpu/logs/`:
  `build-<ts>.log` (the full container console, via `tee`) and `nvidia-installer-<ts>.log`
  (lifted out of the container on success *and* failure). Kept to the newest 3 of each; removed
  by uninstall; printed in the build output and on failure so issue reports can attach them. In
  CI the installer log also rides along in the build output dir.
- Initial release. Driver-only NVIDIA sysext for TrueNAS, forked from the on-host
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
