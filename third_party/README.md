# Vendored third-party sources

## nvidia-470xx-linux-mainline

- **Upstream:** https://github.com/joanbm/nvidia-470xx-linux-mainline
- **Form:** git submodule, pinned to a specific commit (see `git submodule status`).
  The same commit is pinned as `PATCH_470XX_COMMIT` in `scripts/build-nvidia-sysext.sh`.
- **License:** upstream publishes no license file (the patches are roughly aligned
  with the Arch User Repository `nvidia-470xx-dkms` package). This repo does not
  redistribute them: the submodule is only a pointer, and on-host builds download
  the patches from upstream (see below).

### Why it's here

The NVIDIA 470 legacy branch (`470.256.02` is its final release) is end-of-life
upstream and its kernel-module source does not compile against modern Linux
kernels — TrueNAS 25.10 ships 6.12. This community patch series lets the
otherwise-uncompilable 470 driver build against current kernels.

`scripts/build-nvidia-sysext.sh` applies these patches to the extracted driver
source (in the exact order from upstream's own `extract_and_patch`, minus the
opt-in `staging/` patches) before compiling the 470 kernel modules. Only the
470 build path uses them; every other branch builds straight from the `.run`.

The patches are applied at build time on the user's own host; nothing here
redistributes NVIDIA's proprietary userspace.

### Where the build gets them

- **A populated `third_party/nvidia-470xx-linux-mainline`** next to `scripts/` is used
  as is: a clone with submodules initialized (`git submodule update --init`).
- **`build-on-host.sh`** mounts `third_party/` from next to its scripts dir into the
  build container when it holds the patch set. For the installer's staged scripts that
  is `/mnt/<pool>/.config/nvidia-gpu/third_party/nvidia-470xx-linux-mainline`, where you
  can place a copy (a host that can't reach GitHub, or a newer patch set to try).
- **Otherwise** the build downloads upstream's archive at `PATCH_470XX_COMMIT`, on the
  user's host, at build time. The install one-liner and `--release` stage only the
  scripts, so this is their path, and CI's `legacy-470` smoke build (which checks out
  without submodules) takes it too.

### Bumping

```sh
git -C third_party/nvidia-470xx-linux-mainline fetch
git -C third_party/nvidia-470xx-linux-mainline checkout <new-commit>
git add third_party/nvidia-470xx-linux-mainline
# then set the same commit in scripts/build-nvidia-sysext.sh:
#   PATCH_470XX_COMMIT="<new-commit>"
```

Bump deliberately (e.g. when a newer TrueNAS kernel needs additional patches)
and let CI's `legacy-470` smoke build confirm it still compiles. The lint
workflow fails if the submodule commit and `PATCH_470XX_COMMIT` differ.
