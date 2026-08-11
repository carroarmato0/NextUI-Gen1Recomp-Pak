# Gen1Recomp for NextUI

**Play Pokémon Red, Blue and Yellow natively on the TrimUI Brick, Smart Pro and Smart Pro S** — no emulator, and optionally with a 3D voxel overworld.

This is a [NextUI](https://github.com/LoveRetro/NextUI) pak that packages [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp), a from-scratch recreation of the Generation 1 Pokémon games written in Lua on the LÖVE engine. It runs as native ARM64 code at your handheld's own resolution and frame rate, rather than emulating a Game Boy.

> **Status: not yet verified on hardware.** Everything here builds and passes static and contract checks, but no part of it has been run on a device yet. See [Tested on](#tested-on). If you are reading this before the first verified release, treat it as untested.

## What this is, and what it is not

**It is** a repackaging of Gen1Recomp for NextUI: the LÖVE 11.5 ARM64 runtime, the game engine, and a launcher that handles the device-specific setup (GLES, audio routing, controller mapping, CPU behaviour).

**It is not:**

- **An emulator.** No Game Boy hardware is simulated. The game logic is original Lua code.
- **A ROM, or a source of one.** Nothing here contains game data. You supply your own cartridge dump, which is read exactly once.
- **A ROM hack or a translation patch.** Nothing is patched.
- **Affiliated with `gen1recomp.com`.** Upstream's README states that site is unaffiliated with the project and impersonating it. The real project is [`bryanthaboi/gen1recomp`](https://github.com/bryanthaboi/gen1recomp).

Credit for the game itself belongs entirely upstream. This repository is packaging.

## Requirements

- **NextUI** on a TrimUI device — `tg5040` (Brick, Smart Pro, Brick Pro) or `tg5050` (Smart Pro S)
- **Your own US Red, Blue or Yellow cartridge dump.** Only the three canonical 1 MiB US ROMs are accepted; the engine verifies by SHA-1 and refuses anything else
- ~35 MB of card space, or ~16 MB if you build without the 3D mod
- For the 3D voxel mod: [Swap.pak](https://github.com/carroarmato0/NextUI-Swap-Pak). See [3D voxel mod](#3d-voxel-mod)

## Install

**Pak Store** (easiest): find **Gen1Recomp** and install.

**Manual, from a release:**

- `Gen1Recomp.pakz` — unzip at the root of your SD card. This creates the pak for both platforms plus the ROM folder, ready to go.
- `Gen1Recomp.pak.zip` — extract into the platform folder yourself:

```
/mnt/SDCARD/Emus/tg5050/Gen1Recomp.pak/     # or tg5040
/mnt/SDCARD/Roms/Gen1Recomp (Gen1Recomp)/
    Gen1Recomp.g1r                          # empty file; this is the launchable entry
```

The `.g1r` file is a 0-byte stub, and it has to exist: NextUI can only launch *files* from a ROM folder, never directories, so the stub is what appears as an entry. The game itself lives in the pak.

Then open **Games → Gen1Recomp → Gen1Recomp**.

The folder appears under Games as **Gen1Recomp** — NextUI hides the `(Gen1Recomp)` tag, which is what maps the folder to this pak.

## First run: your ROM

Gen1Recomp needs a cartridge dump **once**. It verifies the ROM, decodes the game data into its own cache, and never reads the ROM again.

So you do not need to move or copy anything. **Leave your dump where you already keep it** — the launcher looks in:

- `Roms/Game Boy (GB)/`
- `Roms/Game Boy Color (GBC)/`

It hashes the `.gb`/`.gbc` files it finds, copies the first match into the engine's import folder, and starts the game. Your file is only ever read: never moved, renamed or modified.

Accepted dumps (1 MiB US cartridges only). Check yours on the device with `sha256sum <file>`:

| Version | SHA-256 |
|---|---|
| Red | `5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b` |
| Blue | `2a951313c2640e8c2cb21f25d1db019ae6245d9c7121f754fa61afd7bee6452d` |
| Yellow | `8cbaa499397e4f1a679c992ea9382a2dd7942ab398b48c19829c2d9529de47bf` |

SHA-256 rather than the SHA-1 upstream publishes, because these handhelds ship `sha256sum` but not `sha1sum`. The engine still runs its own SHA-1 verification when it imports, so a dump has to satisfy both.

**If nothing matches**, the pak still starts the game and lets Gen1Recomp's own launcher take over, where its *Choose ROM* screen explains what to do. You get an explanation on screen rather than a black one. The log lists which folders were searched.

Other regions, revisions and ROM hacks are not supported by the engine.

## 3D voxel mod

The 3D look most people associate with Gen1Recomp is **not** part of the game — it comes from a separate, experimental mod, **DramaticShapeVoxelMod**, which replaces the flat overworld with a voxel one and adds camera depth, shadows and 3D battle presentation.

It **ships with this pak but is switched off by default.** Enable it from the in-game mod manager (`OPTIONS → mods`, or `F10` on a keyboard).

It is off by default for one specific reason: **memory.**

### Memory: Swap.pak is required, not optional

Measured across a session on a Smart Pro S (962 MB RAM), voxel mod on:

| Point in session | LÖVE RSS | Free | Paging |
|---|---|---|---|
| Start | 151 MB | 619 MB | none |
| A few minutes in | 524 MB | 143 MB | none |
| Later | **722 MB** | 35 MB | **22 of 30 samples** |

At the end: `VmPeak` 1.58 GB virtual, 108 MB actually swapped out, and `pswpout` spikes of up to 4,730 pages per sample. **The 1 GB swap is the only reason it was not OOM-killed.**

So: **install [Swap.pak](https://github.com/carroarmato0/NextUI-Swap-Pak) before using the voxel mod.** 512 MB on internal storage, boot hook enabled. Internal rather than the card matters here — swap-in runs ~17.3 MB/s internally against ~2.8 MB/s from an SD card.

This README previously said the mod peaked around 183 MB and that swap was probably unnecessary. That was drawn from a single early sample and was wrong; the figure climbs steadily with play and the ~750 MB reported by the nx-redux project is accurate.

It is not a leak. The mod caches meshes per map and evicts down to a live set of the current map plus connected neighbours, so the working set is bounded — but on a large, well-connected outdoor area that bound is around 700 MB. Expect indoor and small maps to be far lighter, and expect the worst on open routes.

Once it starts paging, the stalls are disk waits and no graphics setting will touch them. Swap keeps the session alive; it does not make it smooth.

### Why the mod's update check fails

Two separate things, worth telling apart:

**Certificates.** These handhelds ship no CA store at all, and the engine does HTTPS by shelling out to `curl`. Every request therefore failed verification (`curl` exit 60), which the mod manager reported simply as a failed check. This pak ships a CA bundle and points `curl` at it, so HTTPS works.

**The mod's repository is gone.** `DramaticShape/DramaticShapeVoxelMod` returns 404, so its update check fails even with working TLS — there is nothing left to check against. That is not something this pak can fix, and it does not stop the mod working. The copy bundled here (1.7.2) comes from a community archive.

So: a failed update check on the voxel mod specifically is expected. The mod itself still loads and runs.

### Performance: the bottleneck differs by device

Measured with `scripts/profile-device.sh`, sampling only while rendering.

**TrimUI Brick** (A133, PowerVR GE8300, 4 cores) — **GPU-bound:**

| Setting | GPU median | GPU p75 |
|---|---|---|
| MAX FPS 60 | 91% | 96% |
| MAX FPS 30 | 92% | 99% |

Capping the frame rate changed nothing, and that is worth understanding rather than retrying. The cap is a sleep budget in the run loop, so it only binds when frames are produced *faster* than the target. With the GPU pinned near 99% under a 30 cap, the device is already below 30 fps and there is nothing to hold back — and 30 is the floor of the ladder (`FrameCap.MIN`). An earlier version of this README recommended capping at 30 as the biggest win; measurement says it is not.

**TrimUI Smart Pro S** (sun55iw3, Mali-G57 single core, 8 cores, big.LITTLE) — **not GPU-bound, until it runs out of memory:**

| | GPU median | GPU p75 | System CPU p75 |
|---|---|---|---|
| Default scheduling | 67% | 72% | 19% |
| Threads pinned to the big cluster | **83%** | **88%** | 20% |

NextUI leaves only three cores online and the scheduler parked LÖVE's main thread — the one driving rendering — on a *little* core at 936 MHz while the big cluster idled at 2160 MHz. This pak now brings all eight cores online and pins every LÖVE thread to the big cluster with a cpuset, which lifted GPU utilisation by about 16 points: more frames getting through.

(That comparison is imperfect. The pinned run was also deep enough into the session to be swapping, so some of the difference is confounded by memory pressure.)

On both devices the CPU as a whole is nowhere near saturated — 19–39% across all cores. Single-thread speed and thread placement matter; total CPU capacity does not.

Remaining levers, in order: **make sure swap exists** (see above — on the Smart Pro S it is the binding constraint), then lower the voxel mod's own quality settings, then a cheaper **VOID FILL**. The mod's mesh ring is a hardcoded constant, so draw distance is not adjustable.

Be realistic: this is a 3D renderer on budget handheld silicon. The 2D game runs comfortably on both.

## Controls

Standard Game Boy controls. **Physical A confirms**, matching the rest of NextUI, rather than SDL's positional default which would put confirm on B.

| Action | Button |
|---|---|
| Move | D-pad / left stick |
| A | A |
| B | B |
| Start / Select | Start / Select |

Everything is rebindable in-game under `OPTIONS → CONTROLS`.

Prefer the positional (Xbox) layout? Create an empty file named `xbox_layout` in `/mnt/SDCARD/.userdata/shared/Gen1Recomp/` and the override is skipped.

## Saves

Saves, options and the ROM-derived cache live in:

```
/mnt/SDCARD/.userdata/shared/Gen1Recomp/
```

Deliberately outside the pak directory, so **updating or reinstalling the pak does not touch your saves.** (Upstream's portable-mode marker, which would put them next to the game files inside the pak, is removed at build time for exactly this reason.)

## Limitations

Stated plainly, because they are structural rather than bugs:

- **MENU does not quit the game.** NextUI does not intercept MENU for standalone applications, so it reaches the game as an ordinary button. Quit through Gen1Recomp's own launcher.
- **Sleep does not work.** All power handling lives inside the NextUI frontend, which has exited while the game runs.
- **Brightness and volume do work.** Those are handled by a background daemon that keeps running.
- **The frame rate is what the hardware gives you.** This is a real 3D-capable engine on a handheld GPU, not an emulator with a frame limiter.

## Troubleshooting

Every launch overwrites a log:

```
/mnt/SDCARD/.userdata/<platform>/logs/Gen1Recomp.txt
```

It records the platform, resolved paths, memory and swap state, what the CPU section did, and the entire ROM scan. Over ADB:

```sh
adb shell cat /mnt/SDCARD/.userdata/tg5050/logs/Gen1Recomp.txt
```

| Symptom | Look for |
|---|---|
| Entry does nothing | `FATAL` in the log — usually an incomplete install |
| Game asks for a ROM you already have | `rom` lines: the scan reports every folder it searched |
| Audio crackles or distorts | `XRUN`. Try removing `no-cpu-tuning` from the state dir if you created it |
| Killed during a voxel session | `SwapTotal` in the log. Set up Swap.pak as above |
| A and B feel swapped | The controller GUID may differ on your unit — see [Contributing](#contributing) |

## Tested on

Honest status. An untested device is listed as untested, not assumed to work.

| Device | Platform | Screen | Status |
|---|---|---|---|
| TrimUI Brick | `tg5040` | 1024×768 | **Runs.** GLES 3 context, ROM import, 2D game, voxel mod and controller mapping (A confirms) all verified on hardware. Audio not yet confirmed |
| TrimUI Smart Pro | `tg5040` | 1280×720 | Not tested — same platform as the Brick, so likely fine, but unverified |
| TrimUI Brick Pro | `tg5040` | 1024×768 | Not tested |
| TrimUI Smart Pro S | `tg5050` | 1280×720 | **Runs.** Profiled with the voxel mod; needs swap. Audio not yet confirmed |

The runtime itself is known to work on this hardware class — the LÖVE 11.5 ARM64 build here is the same one shipped by [PortMaster](https://portmaster.games/), and [nx-redux](https://github.com/mohammadsyuhada/nx-redux) runs Gen1Recomp with the voxel mod on both platforms. What is untested is *this pak*.

## Building from source

No compiler and no cross-toolchain. Everything is fetched from pinned, hash-verified upstream artifacts and rearranged.

```sh
scripts/build.sh                 # fetch + stage into build/Gen1Recomp.pak/
scripts/build.sh --no-voxel      # skip the ~19 MB voxel mod
scripts/verify.sh                # static + contract checks
test/test-launch.sh              # launch.sh behaviour against a fake SD card
scripts/release.sh               # -> dist/Gen1Recomp.pak.zip and dist/Gen1Recomp.pakz
scripts/deploy.sh                # adb push to a device
scripts/verify-device.sh         # the real functional test, on hardware
scripts/profile-device.sh 60     # sample GPU/CPU/memory while playing
```

Needs `curl`, `jq`, `zip`, `unzip`, `sha256sum`, `readelf`.

`upstream.lock` pins every third-party artifact by SHA-256 and every assumption the launcher makes about upstream's payload. `verify.sh` re-checks all of it, so an upstream change that would break the pak fails the build with a name attached instead of producing a black screen on your device. A scheduled workflow watches upstream for new releases and prepares a **draft** release plus a device checklist — it never publishes, because CI cannot test any of what matters.

## Contributing

The most useful thing you can contribute is a device report, especially on a Brick or Brick Pro. Run `scripts/verify-device.sh` and open an issue with the output.

If A and B are swapped for you, the controller GUID in `launch.sh` is wrong for your unit — the smoke test prints the real one, and that is exactly the fix to send.

## Credits and licences

This pak is **MIT**. It bundles:

- **[Gen1Recomp](https://github.com/bryanthaboi/gen1recomp)** by bryanthaboi — MIT. The actual game. Upstream credits the [pret](https://github.com/pret) group's `pokered` disassembly as making the project possible.
- **[LÖVE](https://love2d.org/) 11.5** — zlib. The ARM64 build comes from **[PortMaster](https://portmaster.games/)**, which is why this pak needs no compiler.
- **DramaticShapeVoxelMod** 1.7.2 — the 3D mod. Its original repository is no longer available; the copy used here comes from the community archive [`linkfy/DramaticShapeVoxelModBackup`](https://github.com/linkfy/DramaticShapeVoxelModBackup).
- **[NextUI](https://github.com/LoveRetro/NextUI)** — the firmware this targets.
- **[Swap.pak](https://github.com/carroarmato0/NextUI-Swap-Pak)** — recommended for the voxel mod. The swap performance figures quoted above are its measurements.

The TrimUI-specific settings in `launch.sh` — the controller GUID, the audio routing, the CPU behaviour behind the audio fix — were worked out first by **[nx-redux](https://github.com/mohammadsyuhada/nx-redux)** (GPL-3.0). This pak was written independently from those published findings; no code was copied, and the credit for figuring them out is theirs.

Pokémon is a trademark of Nintendo/Creatures/GAME FREAK. This project is unaffiliated, ships no copyrighted game content, and requires you to supply your own legally obtained cartridge dump.
