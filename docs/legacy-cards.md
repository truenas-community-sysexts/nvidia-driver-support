# Legacy cards & the driver-branch matrix

NVIDIA splits Linux driver support into **branches**, and each GPU architecture has a
**last** branch that will ever support it. TrueNAS ships only a current branch, so older
cards need an older driver built here. This is the core of what `nvidia-driver-support`
does.

## The matrix

| Architecture | Chip prefix (lspci) | Example cards | Last branch | Modules | Builds on TrueNAS 6.x kernel? |
| --- | --- | --- | --- | --- | --- |
| Kepler | `GK` | GTX 660/680/750 Ti, GT 710/730, Quadro K2200/K4200, Tesla K80 | **470.x** | proprietary | ✅ yes |
| Maxwell | `GM` | GTX 750/950/970/980, Quadro M4000 | **580.x** | proprietary | ✅ yes |
| Pascal | `GP` | GTX 1050/1060/1070/1080, Quadro P400/P2000, Tesla P40 | **580.x** | proprietary | ✅ yes |
| Volta | `GV` | Titan V, Tesla V100 | **580.x** | proprietary | ✅ yes |
| Turing+ | `TU`/`GA`/`AD`/`GB`/`GH` | RTX 20/30/40/50, A/L-series | current (590+) | open | ✅ yes |
| Fermi | `GF` | GTX 400/500, Quadro 2000 | **390.x** | proprietary | ⚠️ no (patched `.run`) |
| Tesla (gen 1–2) | `G8x`/`G9x`/`GT2xx` | 8/9/200-series, Quadro FX | **340.x** | proprietary | ⚠️ no (patched `.run`) |

Sources: NVIDIA's [legacy GPU release timeframes](https://nvidia.custhelp.com/app/answers/detail/a_id/3142/)
and the [580 = last for Maxwell/Pascal/Volta announcement](https://nvidia.custhelp.com/app/answers/detail/a_id/5676/).

## Why proprietary modules for legacy cards

NVIDIA's **open** kernel modules only support GPUs with a GSP — **Turing and newer**.
Maxwell/Pascal/Volta and older have no open path, so every legacy branch is built with
`--kmod=proprietary`. The picker forces this automatically; if you pass `--kmod=open` on a
detected pre-Turing card the install refuses (the modules literally don't exist) unless you
`--force`. The build script also drops `--kernel-module-type` entirely for installers
older than 515, which predate the open/proprietary split.

## Why 470 + 580 are "supported" but 390 + 340 are "best-effort"

The on-host build cross-compiles `nvidia.ko` against TrueNAS's running kernel (6.x).

- **470.x** and **580.x** installers compile cleanly against 6.x kernels — these are the
  branches CI smoke-tests on every change, so they're the ones we stand behind.
- **390.x** and **340.x** predate the 6.x kernel API. Their stock installers fail to build
  (missing/renamed kernel symbols, ancient GCC assumptions). They're in the catalog so the
  picker can *recommend* them for Fermi/Tesla cards, but the stock build will almost
  certainly fail.

## Making a best-effort card work: patched `.run`

The escape hatch is `--custom-run`. The community maintains patch sets that make old
installers build against modern kernels:

```bash
# 1. Obtain a patched installer (example sources):
#    - Frogging-Family `nvidia-all` (re-packs an installer with kernel patches)
#    - distro AUR/overlay 390xx/340xx packages (lift their patches onto the .run)
#    The filename MUST be canonical for the picker to read the version:
#       NVIDIA-Linux-x86_64-<X.Y.Z|X.Y>-no-compat32.run
#
# 2. Build + install with it:
sudo install-nvidia-driver.sh \
  --custom-run=/mnt/tank/NVIDIA-Linux-x86_64-390.157-no-compat32.run

# The build forces proprietary modules for a pre-515 version automatically.
```

`--custom-run` (a local file) — alongside `--driver=X.Y.Z` (any version on NVIDIA's CDN) and
`--run-url=URL` (any `.run` by URL) — is how you install **anything the catalog doesn't list**:
a vGPU / NVENC-patched build, a beta, or a version above the catalog's `latest.txt` ceiling.

If even a patched `.run` won't compile (very old GCC requirements, removed kernel APIs),
the card is genuinely past what a modern TrueNAS kernel can host — there's no sysext that
fixes that.

## Finding your chip prefix manually

```bash
lspci -nn -d 10de: | grep -iE 'VGA|3D|Display'
# 01:00.0 VGA compatible controller [0300]: NVIDIA Corporation GP107 [GeForce GTX 1050] [10de:1c81]
#                                                               ^^^^^ -> GP -> legacy-580
```

The two-letter prefix before the digits is the architecture (`GP` = Pascal). Cross-reference
the matrix above, or just run `sudo install-nvidia-driver.sh` and accept the recommendation.
