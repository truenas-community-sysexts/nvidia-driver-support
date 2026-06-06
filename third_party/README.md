# Vendored third-party sources

## nvidia-470xx-linux-mainline

- **Upstream:** https://github.com/joanbm/nvidia-470xx-linux-mainline
- **Form:** git submodule, pinned to a specific commit (see `git submodule status`).
- **License:** see the submodule's own repository (the patches are open source,
  roughly aligned with the Arch User Repository `nvidia-470xx-dkms` package).

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

### Bumping

```sh
git -C third_party/nvidia-470xx-linux-mainline fetch
git -C third_party/nvidia-470xx-linux-mainline checkout <new-commit>
git add third_party/nvidia-470xx-linux-mainline
```

Bump deliberately (e.g. when a newer TrueNAS kernel needs additional patches)
and let CI's `legacy-470` smoke build confirm it still compiles.
