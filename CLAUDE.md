# NextUI-Gen1Recomp-Pak

A NextUI **Tool pak** that runs [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp) — a native
LÖVE 11.5 / LuaJIT recreation of Pokémon Red, Blue and Yellow — on TrimUI handhelds.

It was an Emu pak through v0.1.0. That required a `Roms/Gen1Recomp (Gen1Recomp)/` folder holding a
0-byte launchable stub, and users who did not get one saw no entry at all. The pak imports the
player's dump itself, so the ROM-folder machinery bought nothing. `launch.sh` therefore takes **no
arguments** — `verify.sh` fails if it reads `$1`.

## Critical constraints

- **No compiler.** There is nothing to build. The game is Lua, so upstream's `.love` already *is*
  the from-source build; `scripts/build.sh` downloads two pinned upstream artifacts — the `.love`
  for the game and the port zip for the LOVE runtime — and rearranges them. Do not add a
  cross-compilation toolchain or a Docker build.
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
shared by both platforms — there are no *per-platform* `bin/` or `lib/` directories. There is one
shared `bin/lib/`, holding a fallback `libmpg123.so.0` for firmware images that lack one (see the
gotcha below); the aarch64 build is identical on tg5040 and tg5050.

## Key commands

```sh
scripts/build.sh              # fetch + stage runtime and game payload (verifies upstream.lock)
scripts/build.sh --no-voxel   # skip the voxel mod (0.5 MB download, 1.8 MB of the 22 MB pak)
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
- **The voxel mod is `DRAMALESS_SHAPE`, and the reason is licensing, not features.** Through v0.3.0
  the pak shipped `DRAMATIC_SHAPE` 1.7.2 from a community mirror, after the author deleted the repo.
  That tree has **no LICENSE file** and its `README.md:3` reads *"Redistribution of non-derivative
  code is expressly prohibited after v1.6.0 without permission"* — so the pak was redistributing a
  work whose author had forbidden it, and nothing in the build caught it. Of the forks, only
  `artyrambles/DRAMALESS_SHAPE` is redistributable: it rebased onto the openly licensed upstream code
  and issues its own MIT grant, shipped inside the release zip. `BATTLE_ART_VOXEL_FORK` (absol89),
  `potato_voxel` and `TERRARIUM` all have **no licence** — PotatoVoxel is the best performance fit
  for this hardware and still cannot be bundled. The upstream MIT window was **v1.5.4–v1.6.0 only**,
  not "until 1.6.2" as commonly repeated. `verify.sh` now asserts the LICENSE exists and grants
  permission, so a future bump cannot silently lose it.
- **A leftover mod folder disables the mod that replaced it, silently.** A pak update *merges*, so a
  card from v0.3.0 keeps `game/mods/DRAMATIC_SHAPE/`. `DRAMALESS_SHAPE` declares a conflict with it,
  and the engine's rule (`src/mods/Loader.lua`, `_enforceConflicts`) is that **the declaring mod
  loses** — so the *new* mod fails and the player keeps running the old one with nothing in the log
  to say so. Both are enabled by default: the loader enables anything not marked `experimental`.
  `contracts.legacy_mod_ids` in `upstream.lock` is the source of truth; `launch.sh` deletes each id
  from the pak's own `game/mods/` and only *reports* a copy in the player's save dir, and
  `verify.sh` asserts both the staged tree and `launch.sh`'s hard-coded copy of the list.
- **Gen1Recomp has an official mod index, and `launch.sh` seeds it on fresh installs only.**
  `bryanthaboi/gen1recomp-mod-index`, ~107 mods, pinned in `contracts.mod_index`. The engine ships
  none configured by design (`src/mods/ModIndex.lua`: adding one is a deliberate act of trust), but
  the "ask" costs a URL typed on a d-pad, so the pak enters it once. **The guard is the interesting
  part:** it writes only when `options.lua`, `options.lua.bak` *and* `options.lua.tmp` are all
  absent. `SaveData.loadOptions` heals from the `.bak`/`.tmp` copies when the main file is missing,
  so writing ours over that state would destroy every setting the player had. `verify.sh` asserts
  both the slug and the presence of that guard. `ModIndex.resolveSource` also accepts a bare
  `owner/repo`, which is what the README tells people to type. Works on device only because of the
  CA bundle. Player-installed mods land in `$SAVEROOT/mods/`, so a pak update leaves them alone.
- **Choosing a version does not choose what gets imported, and that is upstream, not us.** On Linux
  `chooseRom` (zenity/kdialog) is absent, so `RomImporter.lua:1971` falls back to
  `findPendingRom(self.ready)` — the **first** not-yet-imported `.gb/.gbc` in
  `getDirectoryItems("")` order. `self.chooseVersion` is used only for the dialog title and the
  notice text. We stage all four dumps at once, so "select Red" commonly imports Blue (it sorts
  first). **Nothing is mislabelled** — `startData` routes by SHA-1 — and repeated launches import
  everything, so do not "fix" this by staging one dump per launch: that costs four launches for
  four games and still ignores the selection. Verified on a Brick, 2026-08-14.
- **Browsing the mod catalogue freezes the game, and seeding the index is what exposes players to
  it.** `HostShell.httpGet` is `io.popen` + `read("*a")` with `--connect-timeout 10 --max-time 40`,
  so a call on the render thread stops the picture for up to ~50 s. Upstream moved the *feed* fetch
  onto `love.thread` workers (`src/net/Fetch.lua`, whose header records the old 2-minute freeze) and
  `fetch_worker.lua` **is** present in our payload — but `RomImporter:_findShowDetails` still calls
  `ModIndex.fetchText` synchronously. Players also report freezes on first listing load and on
  paging, which are **not** explained by the async feed path; the 142 KB / 107-mod parse on the main
  thread is a candidate, unproven. Do not describe the trigger more confidently than that.
- **The official index lists `DRAMATIC_SHAPE` 1.8.2, and installing it silently disables our mod.**
  Verified 2026-08-14: same id, same `github` field, **196 of 222 files byte-identical** to the
  1.7.2 we removed, hosted by the `scottcandy34` mirror, still **no LICENSE file**. The prohibition
  line at `README.md:3` of 1.7.2 is **absent** in 1.8.2 — cannot be established whether the author
  dropped it before deleting the repo or the mirror did, and do not assert either. Its manifest does
  *not* list `DRAMALESS_SHAPE` as a conflict, but ours lists it — and the declaring mod loses — so a
  player who installs it from the catalogue gets the old unlicensed mod running and the bundled one
  failed, with nothing on screen to explain it. `launch.sh` reports a save-dir copy and deliberately
  does not delete it. The pak neither ships nor hosts it; note that we *do* seed the catalogue that
  lists it, which is a pointer, not redistribution.
- **The voxel mod's hotkeys are keyboard-only, so on a handheld the OPTIONS menu is the only route.**
  Dramaless binds letters (`v`/`g`/`t`/`c`) via `Game.keypressed` and has no gamepad binding at all;
  the mod it replaced deliberately bound SELECT because "phones and pads have no number row".
  Confirmed on a Brick, 2026-08-14. Not a bug to fix here — worth an upstream issue.
- **The device has no `sha1sum`.** It ships `sha256sum` and `md5sum` only (confirmed on a
  Trimui Brick). The ROM scan therefore matches on SHA-256, and `upstream.lock`'s
  `contracts.device_missing_tools` is enforced by `verify.sh` — the original SHA-1 scan
  matched nothing and logged no error, so nothing off-device could have caught it. `stat`,
  `taskset`, `openssl`, `cksum` and `nproc` are also absent.
- **Whether the firmware ships `libmpg123.so.0` varies by image, and `liblove` needs it.**
  `readelf -d liblove-11.5.so` lists it, and neither the RG34XXSP port zip nor PortMaster's own
  `love_11.5` runtime bundles it (both ship only liblove, libluajit, libmodplug, libogg). On an
  image without one, `love.aarch64` dies at load with *"error while loading shared libraries:
  libmpg123.so.0: cannot open shared object file"* — a black screen, the log ending right after
  `=== love output follows ===` (issue #1, a clean NextUI flash). It is the *only* NEEDED library
  that can be missing: the loader names it, not the entries before it (SDL2, freetype, openal, z,
  vorbisfile, theoradec), which resolve. **Do not restate this as "the firmware has none"** — the
  Brick measured on 2026-08-13 ships `libmpg123.so.0.44.12` (Nov 2025) and runs fine without the
  bundle. That is exactly why `bin/lib` goes **last** on `LD_LIBRARY_PATH`, after `/usr/trimui/lib`:
  the bundled build is 0.44.8 (2018), so putting it first silently downgrades the decoder on every
  device that already works. Verified with `LD_DEBUG=libs` in both orders, and against a simulated
  image with the firmware copy removed. `build.sh` unpacks it from a pinned Ubuntu 18.04 `.deb` into
  `bin/lib/`. The Ubuntu 18.04 build is deliberate: it needs only `GLIBC_2.17`, so it loads on any
  device this pak targets, where a current distro build would pull in `GLIBC_2.29+` math symbols.
  `verify.sh` pins the extracted `.so`, asserts its SONAME, arch and glibc ceiling, asserts the
  search-path order, and fails if `liblove` ever stops needing it. Do **not** bundle SDL2, freetype, openal or
  the rest of `liblove`'s dependencies — those come from the firmware, and shadowing the vendor SDL2
  breaks GLES.
- **`POKEPORT_GBCFX` is gone, and the thing that now holds the shader off is the performance
  tier.** Upstream deleted `src/render/GBCFX.lua` between 0.2.20 and 0.2.24 and replaced it with
  `src/render/ShaderFX.lua` (libretro slang-shader presets). `POKEPORT_SHADERFX` is **not** a
  replacement switch — it names a preset to auto-activate, so unset already means "no shader" and
  there is nothing to set. The export was **deleted** rather than translated: a dead env var that
  reads like a safety guard is worse than none. What actually keeps upstream issue #136's black
  frame away is `Performance.detect()` returning `low` for `isArm and os == "Linux"` — every device
  this pak targets — and `CAPS.low.shaderfx = false`, a hard off read before any preset is
  considered. `verify.sh` asserts the tier rule, the cap, that the old module stays absent, that no
  `.slangp` ships, and that `launch.sh` never re-adds the export.
- **The bundled voxel mod is patched at build time, and the patch must be deleted rather than
  carried.** `DRAMALESS_SHAPE` 2.0.1 — and 2.0.3, the latest, which predates the removal — still
  `require`s the deleted `src.render.GBCFX` in two places. `main.lua:293` *looks* guarded but is
  not: the `pcall` wraps the **call**, and the `require` is an argument, so it is evaluated first
  and throws. That line is the first statement of `pinEngineFx`, which is the first statement of the
  `ui.options.rows` hook, and `src/mods/Hooks.lua` logs-and-skips a wrapper that throws — so the
  mod's rows never reach OPTIONS. Since the mod's hotkeys are keyboard-only, that leaves **no way to
  toggle 3D on a handheld**, with nothing on screen to explain it. Upstream refused to shim it
  (`gen1recomp#1823`, closed by the author as "this is a mod issue"); reported to the mod author as
  `DRAMALESS_SHAPE#53`. `patches/DRAMALESS_SHAPE-gbcfx.patch` fixes both sites with the shape
  upstream itself used at `src/import/LauncherSettings.lua`. `verify.sh` asserts the effect on the
  staged tree **and** that `src/render/GBCFX.lua` has not come back — if it does, drop the patch.
  Note the patch must preserve CRLF: 2.0.1's `main.lua` is CRLF throughout and a LF rewrite diffs
  the whole file.
- **`libs.aarch64/` is checked by exact name, not by count, and that is deliberate.** The check used
  to be "exactly 4", which is satisfiable by editing a number — and that is precisely the wrong
  reflex when upstream adds a library. The pinned `love_runtime.files` entries now *are* the
  allowlist, so an unknown library fails by name. That is how `liblibrashader_bridge.so` was caught.
  It is **stripped** (`love_runtime.strip`), because at 8.4 MB it exists only to translate `.slangp`
  presets and the tier rule above means this hardware never enters that path; it took the pak from
  22 MB to 37 MB and stripping puts it at 29 MB. `build.sh` copies **all** of `libs.aarch64/` and
  then removes by name — never an allowlist copy, or the next new dependency becomes invisible.
- **Silver and Crystal exist upstream but this pak cannot import them yet, and the blocker is hash
  algebra.** `GameVersion.lua` declares six versions as of 0.2.43 (Crystal with two revisions), and
  the payload ships `rom_manifest_silver.json` and `rom_manifest_crystal.json`. `launch.sh`'s
  `VERSIONS` is still `red blue yellow gold`. The scan matches on **SHA-256** because the device has
  no `sha1sum`, and **everything upstream provides is SHA-1** — `GameVersion.lua` and every
  `tools/rom_manifest_*.json` carry `romSha1` and nothing else. One cannot be derived from the
  other, so adding a version needs its SHA-256 taken from a real dump. **Do not guess one to close
  the gap**: a wrong value makes the scan match nothing and log nothing, which is exactly how Gold
  stayed hidden for two releases. (Whether a third-party DAT publishes SHA-256 for these carts is
  unchecked — and a hash taken from one would still want confirming against a real dump before it
  is trusted, since the failure is silent.)
- **The device has no CA store.** `/etc/ssl/certs`, `/etc/ssl/cert.pem` and `/etc/pki` are all
  absent, and the engine does HTTPS by shelling out to `curl` (`src/net/Fetch.lua`). Without a
  bundle every request fails with curl exit 60, surfacing in the mod manager as a failed update
  check with no mention of certificates. The pak ships `assets/ca-certificates.crt` and exports
  `CURL_CA_BUNDLE` + `SSL_CERT_FILE`. The bundle is pinned; refresh with
  `scripts/build.sh --refresh-ca`, since roots expire and a stale bundle fails the same silent way.
- **`DRAMALESS_SHAPE` is measured on both devices, and it is NOT lighter than the mod it replaced.**
  Do not repeat the "halves its render scale, so its ceiling is probably lower" guess — it was
  tested and it is wrong. Measured 2026-08-14, v0.4.0, voxel on:
  - **Smart Pro S**: peak RSS **726 MB** vs the old mod's 722 MB, paging in **9 of 30** samples
    (old: 22 of 30), MemAvailable down to 37 MB, GPU p75 85%, love CPU 98% of *one* core of eight.
    Memory- and single-thread-bound, swap-thrashing. The lower paging count is not a fix: that run
    started already at 726 MB and covered a different route. **Swap.pak stays a requirement.**
  - **Brick**: GPU median 68% / **p75 96% / peak 100%** (old mod's p75 was also 96%), love CPU 235%
    of one core of four, RSS 38 MB → **~440 MB peak** (old mod: 386 MB), only 3 MB of swap touched.
    GPU-bound. The lower median came from a session with indoor stretches, not a controlled
    comparison — do not sell it as a 23-point win. RSS is not monotonic: it fell to 75 MB
    mid-session (mesh eviction), though that coincided with a voxel-level change.
  - The two devices fail differently: Brick is GPU-bound, Smart Pro S is memory-bound. Same mod.
- **`profile-device.sh`'s first sample is garbage.** The GPU counter has no previous delta to
  difference against, so row one reported 649% here while reading 0% CPU. Discard it; it poisons the
  reported peak.
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
- **An update cannot remove the v0.1.0 install, so `launch.sh` removes half of it.**
  `Roms/Gen1Recomp (Gen1Recomp)/` is deleted outright: everything in it came from this project, and
  leaving it means a stale duplicate entry under Games. User-added box art in `.media/` goes with it
  — a deliberate maintainer call, taken while the install base is small. The Emu pak under `Emus/`
  is only reported: deleting the ROM folder already removes the entry, so removing an entire
  installed pak would buy disk space and nothing else. Both are logged as `legacy` lines.
- **The game payload comes from the `.love` asset; only the runtime comes from the port zip.**
  `gen1recomp-<ver>.love` is upstream's canonical build of the Lua tree. The
  `rg34xxsp-stockos64-mod.zip` is a *downstream port's* convenience bundle, and its `lovegame/` is
  **trimmed**: it dropped `tools/rom_manifest_yellow.json` in 0.1.77 and `rom_manifest_gold.json` in
  0.1.79, both times while shipping an engine that declares those versions — so an import reached
  `RomImporter.lua:264` and died with *"ROM import metadata is missing"*. Chasing the missing file
  per release cost two of them. Taking the whole payload from the `.love` ends the class of bug and
  picks up new versions for free (verified: a `--tag v0.1.79` build ships Gold's manifest and passes
  the contract check unaided). On 0.1.79 the `.love` is a strict superset of `lovegame/` — all 451
  shared files byte-identical, the `.love` adding the manifests and `build-info.json`, the zip
  adding only `portable.txt`, which we delete anyway. **There is nothing to compile**: the game is
  Lua, so the `.love` *is* the from-source build. The port zip is still fetched, for the hash-pinned
  LOVE runtime and `LICENSE.love2d.txt` only — that runtime is the exact build upstream tested this
  game version against, which is worth keeping. `verify.sh` asserts every manifest
  `GameVersion.lua` declares is on disk, so a future version cannot regress silently.
- **The import gate is per-version, and must stay that way.** It was all-or-nothing through v0.2.0:
  any one staged dump or decoded cache skipped the whole scan permanently, so a player who imported
  Red and Blue and later added Yellow never got it — and the log said `already imported`, so it read
  as working. Reproduced on a Smart Pro S, 2026-08-12. `launch.sh` now builds a `$HAVE` set from
  `$SAVEROOT/<red|blue|yellow>/{data/generated,rom-cache.complete}` plus the hashes of dumps staged
  at the save root, and only skips the scan when all three are in. The old `$SAVEROOT/data/generated`
  check was also simply the wrong path — the engine writes per-version prefixes
  (`GameVersion.lua` `cachePrefix`), so that branch never once fired.
- **Gold is Gen 2 and therefore 2 MiB, and that is what hid it.** The scan filters by size *before*
  hashing, and the filter was 1 MiB only — so a Gold dump was skipped before its hash was ever
  computed and the log cheerfully reported "all three versions already imported". Two more
  hard-coded threes compounded it: the version list and the count that ends the scan. All three now
  derive from `VERSIONS="red blue yellow gold"` in `launch.sh`, and `verify.sh` asserts the scan
  accepts both 1048576 and 2097152 bytes, matching `RomImporter.isAcceptedRomSize`. Adding Silver
  later should mean one entry in `VERSIONS`, one SHA-256, and one lock entry — nothing else.
  The size test is **two separate `find` calls**, not `-size A -o -size B`: the single-size form is
  what has been run on device, and the `-o` form depends on find applying its implicit `-print`
  across an OR, which is unverified on this busybox. The failure mode would be silent.
- **The scan now repeats until all versions are in, so it filters by size first.** Only files
  of exactly 1048576 bytes are hashed, which is what `findPendingRom` requires anyway
  (`#data == 1024 * 1024`). On a real 90-ROM card that is 20 files instead of 90. The device has no
  `stat`, so the test is `find "$rom" -size 1048576c` — busybox reads the `c` suffix as exact bytes.
  Parsing `ls -l` works too but trips shellcheck's SC2012, and `find` needs no suppression.
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
