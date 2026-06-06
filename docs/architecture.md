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
driver `nvidia.raw`, swapped in place of the one TrueNAS ships.

## Build pipeline

[`scripts/build-nvidia-sysext.sh`](../scripts/build-nvidia-sysext.sh) (ported from
biohazardious/truenas-nvidia-driver-updater) runs either in CI on a native `ubuntu-24.04`
runner (smoke test) or inside a transient `ubuntu:24.04` container on the TrueNAS host (real
install, via [`build-on-host.sh`](../scripts/build-on-host.sh)):

1. Download the official TrueNAS `.update`, peel its two-level squashfs, extract
   `usr/src` + `usr/lib/modules` to get the **kernel headers** for the running kernel.
2. Download the NVIDIA `.run` for the chosen version.
3. **Select installer flags per branch** — `select_installer_flags()` filters the flag set
   against the installer's own `--help`. Pre-515 legacy installers don't have
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
