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
/mnt/SDCARD/Roms/Pokemon Gen 1 (Gen1Recomp)/
    Gen1Recomp.g1r                          # empty file; this is the launchable entry
```

The `.g1r` file is a 0-byte stub, and it has to exist: NextUI can only launch *files* from a ROM folder, never directories, so the stub is what appears as an entry. The game itself lives in the pak.

Then open **Games → Pokemon Gen 1 → Gen1Recomp**.

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

### Why it needs Swap.pak

Game plus voxel mod peaks at roughly **750 MB**. The TrimUI Brick and Smart Pro S have **1 GB total**, shared with the operating system. That does not fit comfortably, so without swap a long session can be killed by the kernel partway through.

Install [**Swap.pak**](https://github.com/carroarmato0/NextUI-Swap-Pak) and configure it like this:

| Setting | Use | Why |
|---|---|---|
| **Location** | **Internal storage** — *not* the SD card | Swap-in runs at ~17.3 MB/s internally versus ~2.8 MB/s from a card, roughly 6× faster. Faulting 10 MB back in costs about 0.6 s internally and 3.6 s from a card — the difference between a hitch and a freeze |
| **Size** | **512 MB** | Enough headroom for the ~750 MB peak. Bigger buys very little; swap is a spillover reserve, not extra RAM |
| **Boot hook** | **Enabled** | Otherwise swap is gone after a reboot and the next session is back to being killed |
| **Swappiness** | Leave Swap.pak's default (**10**) | Keeps swap as an emergency reserve instead of somewhere the kernel parks things pre-emptively |

Worth knowing before you commit to it:

- Creating a 512 MB swapfile on internal storage takes roughly **30 seconds**, once.
- **Swap does not survive a NextUI firmware update.** Re-enable it afterwards.
- Swap writes cause flash wear. Swap.pak's Storage screen shows how much has been written.
- **Swap does not make anything faster.** It trades storage speed for capacity. It stops the voxel mod being killed; it does not raise your frame rate.

### Performance expectations

Be realistic about this. Gen1Recomp's `AUTO` performance tier classifies ARM handhelds as `LOW`, which turns off 3D tilt and survey zoom and caps the frame rate. To get the full voxel effect you have to raise the tier by hand (`OPTIONS → PERFORMANCE`), and that costs frames.

Measured frame rates will be published here once the pak has been verified on hardware. They are deliberately absent rather than estimated — if the mod turns out to be unplayable on a given device, this section will say so.

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
| TrimUI Smart Pro S | `tg5050` | 1280×720 | **Not yet tested** |
| TrimUI Smart Pro | `tg5040` | 1280×720 | **Not yet tested** |
| TrimUI Brick | `tg5040` | 1024×768 | **Not yet tested** |
| TrimUI Brick Pro | `tg5040` | 1024×768 | **Not yet tested** |

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
