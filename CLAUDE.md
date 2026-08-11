# NextUI-Gen1Recomp-Pak

A NextUI **Emu pak** that runs [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp) — a native
LÖVE 11.5 / LuaJIT recreation of Pokémon Red, Blue and Yellow — on TrimUI handhelds.

## Critical constraints

- **No compiler.** There is nothing to build. `scripts/build.sh` downloads one pinned upstream
  release zip and rearranges it. Do not add a cross-compilation toolchain or a Docker build.
- **`launch.sh` is POSIX `sh`, never bash.** `/bin/bash` on these cards can be a symlink PortMaster
  creates into its own vendored bin, so a `#!/bin/bash` shebang silently reintroduces the dependency
  this pak exists to avoid. `scripts/verify.sh` enforces this.
- **Never ship a ROM, or anything derived from one.** The pak reads the user's own dump once and
  writes only the engine's generated cache. `verify.sh` fails if a ROM-shaped file appears in the tree.
- **Never create a swapfile.** The voxel mod needs swap; providing it is
  [Swap.pak](https://github.com/carroarmato0/NextUI-Swap-Pak)'s job, not ours. We only detect its
  absence and log a hint.
- **CI cannot test this pak.** GitHub runners have no aarch64 TrimUI, no Mali/PowerVR GPU and no
  NextUI. CI does packaging and contract checks only; it must never publish a release.
- **Clean-room MIT.** Device findings were learned from `mohammadsyuhada/nx-redux` (GPL-3.0). Use the
  factual parameters — env var names, the controller GUID, sysfs paths, thresholds — but do not copy
  its script text.

## Supported platforms

| Platform | Devices (`$DEVICE`) | Screen | SoC / GPU |
|---|---|---|---|
| `tg5040` | `smartpro` | 1280×720 | Allwinner A133P, 4× Cortex-A53, PowerVR GE8300 |
| `tg5040` | `brick`, `brickpro` | **1024×768** | same |
| `tg5050` | `smartpros` | 1280×720 | 8× Cortex-A55, Mali |

NextUI is TrimUI-only (`makefile:15` upstream is `PLATFORMS = tg5050 tg5040`). There is no `my355`
target here, unlike the author's other paks.

Both platforms are **1 GB** on Brick and Smart Pro S. The LÖVE runtime is a single aarch64 binary
shared by both platforms — there are no per-platform `bin/` or `lib/` directories.

## Key commands

```sh
scripts/build.sh              # fetch + stage runtime and game payload (verifies upstream.lock)
scripts/build.sh --no-voxel   # skip the ~8 MB voxel mod
scripts/verify.sh             # all static + contract checks (also run by CI and release.sh)
scripts/release.sh            # -> dist/Gen1Recomp.pak.zip and dist/Gen1Recomp.pakz
scripts/deploy.sh             # adb push to the device
scripts/verify-device.sh      # the real functional test, over ADB
```

## Key directories

```
launch.sh                 the entire pak runtime; Section A is game-agnostic
pak.json                  Pak Store manifest (independent semver)
upstream.lock             every pinned hash; single source of truth
scripts/                  build, verify, release, deploy, verify-device
test/smoke.love           device diagnostic: renderer, video driver, joystick GUIDs
build/                    gitignored; assembled pak contents
dist/                     gitignored; release artifacts
```

On-card layout is documented in README.md. Saves live at `.userdata/shared/Gen1Recomp/`, never in
the pak directory — a pak update would otherwise destroy them.

## Known gotchas

- **`portable.txt` must be stripped from the upstream payload.** With it present, LÖVE writes beside
  `main.lua` (inside the pak dir) and a pak update wipes saves. We set `XDG_DATA_HOME` instead.
- **The upstream voxel mod repo (`DramaticShape/DramaticShapeVoxelMod`) is gone — 404.** The only
  source is the community backup `linkfy/DramaticShapeVoxelModBackup`, pinned at 1.7.2.
- **The controller GUID in `launch.sh` is unverified** until someone runs `test/smoke.love` on real
  hardware. It prints every joystick's name and GUID for exactly this reason.
- **The CPU-tuning block in `launch.sh` may be unnecessary** on stock NextUI, which already sets the
  `performance` governor before launching a pak. It was needed on the nx-redux fork. If device
  verification shows audio is clean without it, delete it rather than keeping it on faith.
- **MENU does not quit and sleep does not work.** Nothing intercepts MENU; it arrives as SDL joystick
  button 8 (15 on Brick Pro). Brightness and volume do keep working via `keymon.elf`.
- **NextUI cannot launch a directory.** `addEntries` marks any directory `ENTRY_DIR` unless it ends
  `.pak`, so the ROM-folder entry must be a file — hence the 0-byte `Gen1Recomp.g1r` stub.

## Coding standards

- Shell: POSIX `sh` for `launch.sh`; `bash` with `set -euo pipefail` is fine for `scripts/`.
- Every network command carries a timeout. Every download is hash-verified and fails closed.
- Prefer deleting unexplained code over carrying it. If a workaround's justification cannot be
  stated in a comment, it does not belong in the tree.
- Claims about device behaviour in docs must be measured, not assumed. An untested device belongs in
  the README's "Tested on" table as untested.
