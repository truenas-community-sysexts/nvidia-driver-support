# Troubleshooting

Run `sudo install-nvidia-driver.sh --check` first — it reports sysext merge state, kernel
module load, sysext-vs-runtime driver version match, the stock backup, and the PREINIT entry.

## `nvidia-smi: Driver/library version mismatch` right after install

Expected — **you haven't rebooted yet**. The swap replaced the userspace libs but the old
kernel module is still loaded. `sudo reboot`, then `nvidia-smi` should report the new
version.

## `nvidia-smi: NVIDIA-SMI couldn't find any device` after a TrueNAS update

The update bumped the kernel and the bundled `nvidia.ko` no longer matches. Check:

```bash
sudo journalctl -b -t nvidia-preinit-driver
```

Look for `ERROR: kernel-version mismatch — running <A> but sysext bundles modules for <B>`.
Rebuild against the new kernel:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-driver-support/main/scripts/install-nvidia-driver.sh \
  | sudo bash -s -- --rebuild
# or, using the staged helper (no network round-trip):
sudo /mnt/<pool>/.config/nvidia-gpu/scripts/build-on-host.sh --help
```

## The on-host build fails for a legacy branch

If you chose `legacy-390` / `legacy-340`, the stock installer doesn't compile against
TrueNAS's 6.x kernel — this is the documented **best-effort** case. Supply a patched
installer:

```bash
sudo install-nvidia-driver.sh --custom-run=/path/to/NVIDIA-Linux-x86_64-<VER>-no-compat32.run
```

See [legacy-cards.md](legacy-cards.md#making-a-best-effort-card-work-patched-run). For
`legacy-470` / `legacy-580` a build failure is unexpected — re-run with the build output
visible and check whether NVIDIA changed the `.run` (the CI smoke build catches most of
these first).

## `open kernel modules don't exist before driver 515` / `predates Turing`

You asked for `--kmod=open` on a card or driver that has no open-module path
(Maxwell/Pascal/Volta/older). Use `--kmod=proprietary` (the default for legacy branches),
or `--force` if you really mean to try.

## `refusing to swap nvidia.raw without a stock backup`

Create the backup once before your first install:

```bash
curl -fsSL https://raw.githubusercontent.com/truenas-community-sysexts/nvidia-driver-support/main/scripts/recover-stock-nvidia.sh | sudo bash
```

This extracts the stock `nvidia.raw` from the official TrueNAS `.update` into
`/mnt/<pool>/.config/nvidia-gpu/nvidia-original.raw`. Or `--skip-backup-check` to proceed
without one (you won't be able to revert to stock cleanly).

## `docker not found` during the build

The on-host build runs inside a docker container. TrueNAS Apps users have docker already; if
you've never enabled Apps, enable it once (or run the build on another machine and install
the result with `--driver-sysext=/path/to/nvidia.raw`).

## Multi-pool host: "Multiple data pools available"

Pin the persist location:

```bash
sudo install-nvidia-driver.sh --pool=tank
# or
sudo install-nvidia-driver.sh --persist-path=/mnt/tank/.config/nvidia-gpu
```

## Reverting everything

```bash
sudo /mnt/<pool>/.config/nvidia-gpu/scripts/uninstall-nvidia-driver.sh   # reboot after
```

Restores stock `nvidia.raw` from `nvidia-original.raw`, deregisters the PREINIT, and cleans
build artifacts (keeps the stock backup). Reboot required so the stock kernel module reloads.

## GPU not detected by the picker

If `lspci` can't be parsed (unknown card, missing pci.ids), the interactive picker falls back
to asking for a branch. Find your chip prefix manually with
`lspci -nn -d 10de:` and pass `--branch=NAME` or `--driver=X.Y.Z` (see
[legacy-cards.md](legacy-cards.md#finding-your-chip-prefix-manually)).
