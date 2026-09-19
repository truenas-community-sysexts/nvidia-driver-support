# Architecture

`nvidia-driver-support` replaces TrueNAS's stock NVIDIA driver sysext (`nvidia.raw`) with
one built on your host for a driver version you choose. It is a **driver-only** fork of the
build pipeline in [`nvidia-mig-support`](https://github.com/truenas-community-sysexts/nvidia-mig-support),
with a driver **catalog + card-aware picker** on top and all MIG tooling removed.

## The single sysext

```text
                ┌─────────────────────────────────────────────────────────┐
                │                  TrueNAS host                            │
  ┌────────┐    │   /usr/share/truenas/sysext-extensions/                  │
  │  GPU   │◄───┤     └─ nvidia.raw   (stock → custom, swapped by us)      │
  └────────┘    │   /etc/extensions/                                       │
                │     └─ nvidia.raw   → symlink to above                   │
                │   /mnt/<pool>/.config/nvidia-gpu/                        │
                │     ├─ nvidia-original.raw  (stock backup, always kept)  │
                │     ├─ nvidia.raw           (custom, re-applied on update)│
                │     ├─ nvidia-preinit-driver.sh                          │
                │     ├─ cache/   (.update + .run downloads)               │
                │     └─ scripts/ (build + uninstall helpers, staged)      │
                └─────────────────────────────────────────────────────────┘
```

Unlike the MIG repo there is no second lightweight sysext — the only artifact is the
driver `nvidia.raw`, swapped in place of the one TrueNAS ships. Because it's the only
sysext (no second tooling sysext to collide with), `nvidia.raw` also bundles the MIT
`uninstall-nvidia-driver` at `/usr/bin/` — on PATH whenever the custom driver is merged.
The install script additionally stages a copy (plus `recover-stock-nvidia.sh` and the build
helpers) to `/mnt/<pool>/.config/nvidia-gpu/scripts/`, which survives when the sysext is
unmerged or restored to stock — so an uninstall always has a script to run.

## Build pipeline

[`scripts/build-nvidia-sysext.sh`](../scripts/build-nvidia-sysext.sh) (ported from
biohazardious/truenas-nvidia-driver-updater) runs either in CI on a native `ubuntu-24.04`
runner (smoke test) or inside a transient `ubuntu:24.04` container on the TrueNAS host (real
install, via [`build-on-host.sh`](../scripts/build-on-host.sh)):

1. Download the official TrueNAS `.update`, peel its two-level squashfs, extract
   `usr/src` + `usr/lib/modules` to get the **kernel headers** for the running kernel.
2. Download the NVIDIA `.run` for the chosen version.
3. **Select installer flags per branch** — `select_installer_flags()` filters the flag set
   against the installer's own `--advanced-options` listing. Pre-515 legacy installers don't have
   `--kernel-module-type` (proprietary-only) and may lack `--no-drm`/`--install-libglvnd`;
   those are dropped so the old `.run` doesn't abort.
4. Snapshot `/usr`+`/etc` before/after the silent install to capture every new file.
5. Stage new files, remap `/etc/{OpenCL,vulkan,nvidia-container-*}` → `/usr/share/...`,
   build a **combined `modules.dep`** over the full module tree (so the overlay doesn't
   hide other kernel modules), write `extension-release.nvidia` (`ID=_any`), squashfs.

The driver build is **identical** to the MIG repo's — it never contained MIG tooling — so
the only behavioral change here is the branch-aware installer flag selection (step 3).

## Boot-time activation: TrueNAS PREINIT

On TrueNAS a sysext-shipped `WantedBy` symlink isn't reliably honored at boot, so this repo
registers a middleware PREINIT entry (`midclt initshutdownscript`) running
[`nvidia-preinit-driver.sh`](../scripts/nvidia-preinit-driver.sh) before Docker:

```text
TrueNAS boot → systemd-sysext merges nvidia.raw
            → PREINIT: nvidia-preinit-driver.sh
                 ├─ compare SHA of live nvidia.raw vs persistent custom
                 ├─ if differ (TrueNAS update wiped /usr):
                 │     unmerge → zfs writable → cp custom → readonly → re-merge
                 └─ log any kernel-version mismatch (bundled .ko vs running kernel)
            → docker.service starts
```

This is the **only** PREINIT this repo registers. If you also run `nvidia-mig-support`
(default mode), it registers its own independent MIG-service PREINIT — order doesn't matter.

## Why the ZFS readonly dance

`/usr` on TrueNAS is a ZFS dataset with `readonly=on`. Swapping `nvidia.raw` requires:

1. `systemd-sysext unmerge`
2. `zfs set readonly=off <usr-dataset>`
3. `cp` the new `nvidia.raw`
4. `zfs set readonly=on <usr-dataset>`
5. `ln -sf` into `/etc/extensions/` (`/etc` is writable, no toggle)
6. `systemd-sysext merge` + `systemctl daemon-reload`

A cleanup trap restores `readonly=on` if the script dies mid-swap, so a failure never
leaves `/usr` writable.

## What's NOT in the build

Same exclusions as the MIG repo's driver build: no `nvidia-drm.ko` (TrueNAS kernel lacks
`drm_fbdev_ttm_driver_fbdev_probe`; irrelevant on a headless NAS — built with `--no-drm`),
no DKMS source, no docs/man/licenses, no apt repo config. See the build script for the full
staging filter.

## Catalog + picker

[`catalog/driver-catalog.json`](../catalog/driver-catalog.json) lists the latest open
drivers, one pinned version per legacy branch, and a chip-prefix → branch map. The picker in
[`install-nvidia-driver.sh`](../scripts/install-nvidia-driver.sh) reads `lspci`, extracts the
GPU chip prefix, and recommends a branch. The catalog is refreshed daily by
[`check-drivers.yml`](../.github/workflows/check-drivers.yml) — see
[driver-catalog.md](driver-catalog.md).

## Releases + cadence

A release is a **tooling + catalog snapshot**, tagged `v<N>` (the auto-incrementing
`github.run_number`). It carries the MIT install scripts + the driver catalog and **no
`nvidia.raw`** (EULA — same reason the MIG repo only publishes its open component). Critically
it is **not** tied to a driver, module flavor, or TrueNAS version: the install script reads the
bundled catalog, detects the card, and builds the right driver on the host against the host's
kernel. So one release covers the whole driver × kmod × card matrix and works across TrueNAS
versions — a kernel bump just triggers an on-host rebuild. (This is why the old
`v<truenas>-nvidia<driver>-rN` scheme, inherited from the Blackwell-only MIG repo, didn't fit.)

- [`release.yml`](../.github/workflows/release.yml): runs the full `build-sysext.yml` smoke
  matrix, then generates notes from the catalog (so the "supported" list can't drift), tags
  `v<N>`, attaches the scripts + catalog, and publishes a **pre-release**. It then opens one
  hardware-test issue per TrueNAS train listed in `.github/tracked-versions.json` (`trains`):
  label `hardware-test` for a stable train, `preview-hardware-test` for a preview one, with
  `<!-- release-tag -->` and `<!-- train -->` markers. It has no publish-straight-to-Latest
  option (see below). check-drivers.yml dispatches it after a catalog change; run it by hand
  whenever the tooling has changed enough to publish.
- [`promote.yml`](../.github/workflows/promote.yml): closing a train's issue as completed
  approves the release for that train only: it appends `<!-- verified-train: KEY -->` to the
  release notes, and on the first approval also flips the release out of pre-release and
  appends the changelog, in the same update. GitHub's "Latest" follows the newest release
  approved for a stable train, but nothing selects by it. An issue with no train marker (from
  before per-train issues) keeps the old behavior: full release, Latest, no marker.
- [`check-drivers.yml`](../.github/workflows/check-drivers.yml) — daily; refreshes the picker
  catalog from the NVIDIA index. `open_latest` is newest-per-major, bounded by `latest.txt`
  (NVIDIA's blessed production latest — so betas / not-yet-promoted versions never appear) and
  `.run`-shipping-checked; plus the legacy branch pins. (There is no auto-release cadence:
  releases are cut by hand, since a TrueNAS/NVIDIA bump changes a release's *content* only via
  the catalog, and the tooling is version-agnostic.)

Build validation lives entirely in the smoke (`build-sysext.yml`) on PRs that touch the build
path, plus the user's on-host build — never in the release path.

### Which release a box installs

The one-liner is [`get.sh`](../get.sh) on `main`. It reads the TrueNAS version
(`midclt call system.info`), derives the **train** (the major version from 26 on, so every
26.x release including betas is train `26`; major.minor before that, e.g. `25.10`), lists the
releases through the GitHub API, and picks the newest one **approved** for that train:

- its notes carry `<!-- verified-train: <train> -->`, or
- it is a full (non-pre-release) release with no `verified-train` marker at all. Every release
  published before per-train approval is one of these, so they stay approved for every train.

A marker for another train only does not count, and nothing unapproved is installed on stable or
beta boxes: with no approved release for the train it stops and links the open hardware-test
issues. It then downloads **that** release's `install-nvidia-driver.sh` (or, with `--uninstall`,
its `uninstall-nvidia-driver.sh`) and runs it with the user's arguments plus `--release=<tag>`,
so the installer's own downloads (build helpers, PREINIT helper, catalog) come from the same
release, with no fallback to `main`. `--release=TAG` skips the selection.

`install-nvidia-driver.sh` run on its own (a raw download from `main`) resolves its release by
the same rule: the selection code is one block copied verbatim into both scripts, and
`tests/test_release_selection.py` fails CI if the copies differ. Run from a full checkout it
uses the checkout's own helpers and catalog. A release only affects *sourcing*; driver
selection stays card-detect / `--branch` / `--driver` / `--custom-run`.

Why there is no publish-straight-to-Latest option: a full release without markers counts as
approved for every train, so it would reach every box untested. Every release starts as a
pre-release and becomes a full release only through a train's sign-off, which writes the marker
in the same update.
