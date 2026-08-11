# NextUI-Gen1Recomp-Pak

A NextUI **Tool pak** that runs [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp) — a native
LÖVE 11.5 / LuaJIT recreation of Pokémon Red, Blue and Yellow — on TrimUI handhelds.

It was an Emu pak through v0.1.0. That required a `Roms/Gen1Recomp (Gen1Recomp)/` folder holding a
0-byte launchable stub, and users who did not get one saw no entry at all. The pak imports the
player's dump itself, so the ROM-folder machinery bought nothing. `launch.sh` therefore takes **no
arguments** — `verify.sh` fails if it reads `$1`.

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
scripts/build.sh --no-voxel   # skip the voxel mod (7.8 MB download, 18 MB of the 31 MB pak)
scripts/verify.sh             # all static + contract checks (also run by CI and release.sh)
test/test-launch.sh           # launch.sh behaviour under dash against a fake SD card
scripts/release.sh            # -> dist/Gen1Recomp.pak.zip and dist/Gen1Recomp.pakz
scripts/deploy.sh             # adb push to the device (DEPLOY_PLATFORM defaults to tg5050)
scripts/verify-device.sh      # the real functional test, over ADB
scripts/profile-device.sh 60  # sample GPU/CPU/memory while playing
scripts/screenshot.sh         # grab /dev/fb0 over ADB as a PNG
```

## Key directories

```
launch.sh                 the entire pak runtime; Section A is game-agnostic
pak.json                  Pak Store manifest (independent semver)
upstream.lock             every pinned hash; single source of truth
scripts/                  build, verify, release, deploy, verify-device
test/smoke/               device diagnostic (renderer, video driver, joystick GUIDs); zipped into
                          smoke.love by verify-device.sh, never committed as a binary
test/test-launch.sh       off-device tests for launch.sh
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
- **The device has no `sha1sum`.** It ships `sha256sum` and `md5sum` only (confirmed on a
  Trimui Brick). The ROM scan therefore matches on SHA-256, and `upstream.lock`'s
  `contracts.device_missing_tools` is enforced by `verify.sh` — the original SHA-1 scan
  matched nothing and logged no error, so nothing off-device could have caught it. `stat`,
  `taskset`, `openssl`, `cksum` and `nproc` are also absent.
- **The device has no CA store.** `/etc/ssl/certs`, `/etc/ssl/cert.pem` and `/etc/pki` are all
  absent, and the engine does HTTPS by shelling out to `curl` (`src/net/Fetch.lua`). Without a
  bundle every request fails with curl exit 60, surfacing in the mod manager as a failed update
  check with no mention of certificates. The pak ships `assets/ca-certificates.crt` and exports
  `CURL_CA_BUNDLE` + `SSL_CERT_FILE`. The bundle is pinned; refresh with
  `scripts/build.sh --refresh-ca`, since roots expire and a stale bundle fails the same silent way.
- **The voxel mod's update check fails regardless** — `DramaticShape/DramaticShapeVoxelMod` is 404.
  Unrelated to TLS, and does not stop the mod working.
- **The voxel mod is GPU-bound on a Brick and memory-bound on a Smart Pro S.** Brick: GPU median
  91% / p75 96% / peak 100% while rendering. Smart Pro S: GPU has headroom (83% p75 once threads
  are pinned) but RSS climbs to **~722 MB** on a 962 MB device and pages hard — swap is what keeps
  the session alive. Memory scales with how many maps have been visited, so a short session
  measures low: an earlier "peak RSS 183 MB, swap unnecessary" reading here came from one such
  sample and was **wrong**. The ~750 MB nx-redux reports is accurate. There is no userspace GPU
  clock control on the PowerVR part, so the only lever is drawing less.
- **Do not read `scaling_cur_freq` as CPU load.** schedutil parks the clock at the ceiling
  regardless of utilisation; profile-device.sh once concluded "CPU-bound" from it on a session
  that was plainly GPU-bound. Difference `/proc/stat` jiffies instead.
- **The controller GUID string in `launch.sh` is still unconfirmed**, even though the *behaviour* it
  is meant to produce is verified — physical A confirms on a Brick. Those are different claims: the
  default mapping could be producing that on its own. Only `test/smoke/` prints the joystick's real
  name and GUID, and only comparing them settles whether our override does anything.
- **Know what the CPU-tuning block actually does per platform before touching it.** NextUI runs
  `governor.sh performance` immediately before launching any pak (`skeleton/SYSTEM/<plat>/paks/
  MinUI.pak/launch.sh:189`), which sets `performance` at the true hardware max.
  - On **tg5040** that is already 2.0 GHz, so our block raises nothing and its only real effect is
    swapping `performance` for `schedutil`. The `ceilings raised` log line overstates it there.
  - On **tg5050** the boot script offlines cpu2,3,5,6,7 and leaves 3 of 8 online
    (`tg5050/paks/MinUI.pak/launch.sh:112-123`). Bringing them up is measured-useful (+16 points of
    GPU utilisation with the cpuset), and it is the one thing NextUI does **not** redo afterwards —
    so failing to restore the online mask leaks into the rest of the user's session.
  - The audio justification inherited from nx-redux remains unverified. If it is dropped, drop the
    governor line, not the core onlining — they are separate claims with separate evidence.
- **`MALI_CreateWindow` in the log does not mean Mali.** The vendor SDL2 prints it on tg5040 too,
  where the GPU is PowerVR: device-tree `compatible` is `img,gpu`, `/sys/kernel/debug/pvr/` exists,
  and the same library exports `PVR_Vulkan_*`. Do not "correct" the platform table from that line.
- **MENU does not quit and sleep does not work.** Nothing intercepts MENU; it arrives as SDL joystick
  button 8 (15 on Brick Pro). Brightness and volume do keep working via `keymon.elf`.
- **NextUI cannot launch a directory.** `addEntries` marks any directory `ENTRY_DIR` unless it ends
  `.pak`. That is why the old Emu layout needed a 0-byte `Gen1Recomp.g1r` stub, and why it shipped
  broken for anyone whose card lacked the folder. Under `Tools/` the `.pak` directory *is* the entry.
- **The ROM scan is the only import path, so it matches folders the way NextUI does.** `getEmuName`
  (`workspace/all/common/utils.c:352`) takes the tag in a folder's *last* parentheses, or the whole
  name when there are none — `Game Boy (GB)`, `Nintendo Game Boy (GB)` and `GB` are one system to the
  frontend. `launch.sh` mirrors that rule. It used to hard-code two display names, which found
  nothing on a renamed folder and reported no error.
- **An update cannot remove the v0.1.0 install.** The Emu pak and its ROM folder stay on the card and
  keep showing a stale entry under Games. `launch.sh` logs `legacy` lines naming them and deletes
  nothing — that folder belongs to the user and may hold their box art.
- **The smoke test lives in the state dir, not a ROM folder.** With no launch argument, `launch.sh`
  discovers `$STATE/*.love` and runs it instead of the game. `verify-device.sh` pushes it, prompts,
  and removes it again — a forgotten one hides the game on every later launch.

## Coding standards

- Shell: POSIX `sh` for `launch.sh`; `bash` with `set -euo pipefail` is fine for `scripts/`.
- Every network command carries a timeout. Every download is hash-verified and fails closed.
- Prefer deleting unexplained code over carrying it. If a workaround's justification cannot be
  stated in a comment, it does not belong in the tree.
- Claims about device behaviour in docs must be measured, not assumed. An untested device belongs in
  the README's "Tested on" table as untested.
