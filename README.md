# Gen1Recomp for NextUI

**Play Pokémon Red, Blue and Yellow natively on the TrimUI Brick, Smart Pro and Smart Pro S** — no emulator, and optionally with a 3D voxel overworld. **Gold** is included too, as an upstream **beta**.

![A shop interior from Pokémon Blue rendered as 3D voxels — shelves, an attendant and two player sprites, all in the original monochrome palette](docs/screenshots/main.png)

*Captured on a TrimUI Brick at its native 1024×768, with the optional [3D voxel mod](#3d-voxel-mod) enabled. The 2D game looks exactly like the original.*

> **This screenshot is out of date.** It was taken with the voxel mod v0.4.0 replaced, which rendered people as 3D figures; the mod bundled now draws them as flat sprites. Still to be retaken — the framebuffer grab this project uses returns a blank image for a GLES surface, so it needs a camera or a capture path we do not have yet.

This is a [NextUI](https://github.com/LoveRetro/NextUI) pak that packages [Gen1Recomp](https://github.com/bryanthaboi/gen1recomp), a from-scratch recreation of the Generation 1 Pokémon games written in Lua on the LÖVE engine. It runs as native ARM64 code at your handheld's own resolution and frame rate, rather than emulating a Game Boy.

> **Status: verified on a TrimUI Brick and a Smart Pro S.** The runtime, ROM import, 2D game, controller mapping and audio have all been exercised on real hardware. The Smart Pro and Brick Pro are untested. **The voxel mod changed in v0.4.0** and has been profiled on both devices: it renders fine, and it is **no lighter on memory** than the mod it replaced, so [Swap.pak](https://github.com/carroarmato0/NextUI-Swap-Pak) is still required — see [Tested on](#tested-on) and [Why the mod changed](#why-the-mod-changed).

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
- **Your own US Red, Blue, Yellow, Gold or Silver cartridge dump.** Only the canonical US ROMs are accepted — the three 1 MiB Gen 1 carts and the 2 MiB Gen 2 ones; the engine verifies by SHA-1 and refuses anything else. **Crystal** is declared by the engine but not supported here yet — see [Crystal](#crystal)
- ~29 MB of card space, or ~27 MB if you build without the 3D mod
- For the 3D voxel mod: [Swap.pak](https://github.com/carroarmato0/NextUI-Swap-Pak). See [3D voxel mod](#3d-voxel-mod)

## Install

**Pak Store** (easiest): find **Gen1Recomp** and install.

**Manual, from a release:**

- `Gen1Recomp.pakz` — unzip at the root of your SD card. This lays out both platforms, ready to go.
- `Gen1Recomp.pak.zip` — extract into the platform folder yourself:

```
/mnt/SDCARD/Tools/tg5050/Gen1Recomp.pak/    # or tg5040
```

Then open **Tools → Gen1Recomp**.

That is the whole install. There is no ROM folder to create and no stub file to place — the pak is self-contained and imports your dump from wherever you already keep it.

### Upgrading from v0.1.0

v0.1.0 was an Emu pak. That needed a `Roms/Gen1Recomp (Gen1Recomp)/` folder containing a 0-byte `Gen1Recomp.g1r` file before NextUI would show anything at all, and anyone whose card did not end up with both saw no entry under Games. It is a Tool pak now, so there is nothing to create.

**The first launch cleans up after itself.** `Roms/Gen1Recomp (Gen1Recomp)/` is deleted, because everything in it came from this project — the 0-byte stub, and a `.media/README.txt` explaining where box art goes — and leaving it behind means a second Gen1Recomp under Games that runs the old copy. If you put your own box art in that folder, it goes too; the log names the folder before removing it.

One thing is left for you:

```
/mnt/SDCARD/Emus/<platform>/Gen1Recomp.pak/     # ~31 MB, no longer read by anything
```

Deleting the ROM folder already removes the stale entry, so this is only disk space — and removing a whole installed pak on your behalf is a bigger assumption than this pak should make. The log names the path.

**Your saves are not affected.** They have always lived in `.userdata/shared/Gen1Recomp/`, which none of this touches.

## Updating from v0.4.1 or earlier: you will re-import

**Your games will look like they have vanished. They have not, and your save files are safe.**

Gen1Recomp 0.2.x needs more data out of a cartridge than earlier versions did — upstream added entries to its cache contract (`CacheContract.REQUIRED_FILES`), including one specifically so that caches built before a Gen 2 text extractor get rebuilt. The decoded copy the engine made from your dump is therefore incomplete, `CacheContract.isReady()` goes false, and the version reappears on the launcher asking to be imported.

Only that decoded copy is rebuilt. Measured on a Brick upgrading 0.1.98 → 0.2.43: Blue was short 2 required files, Yellow 4, Gold 9, and the `saves/` folder was untouched throughout.

Pick each version once on the Choose ROM screen and it comes back. Your dumps are still staged where the pak put them, so nothing is copied again and the rebuild takes about a minute per version. The launcher imports one version per visit, so expect to do it once per game you own.

## First run: your ROM

Gen1Recomp needs your cartridge dump **once**. It verifies the ROM, decodes the game data into its own cache, and never reads the ROM again.

**You pick the file yourself, in the game.** On the Choose ROM screen, select a version and Gen1Recomp opens its own file browser, starting at `/mnt/SDCARD`. Navigate to wherever you keep your dumps — typically `Roms/Game Boy (GB)/` — and choose the file. It is imported and decoded, which takes a minute or so per version.

**The pak tells you where your dumps are.** On every launch it hashes the `.gb`/`.gbc` files in your Game Boy folders and writes the path of each recognised cartridge to its log, so you know exactly what to navigate to:

```
rom       your dumps, for the game's Choose ROM browser
rom       (it opens at /mnt/SDCARD -- navigate to the path shown):
rom         Red  ->  /mnt/SDCARD/Roms/Game Boy (GB)/Pokemon - Red Version.gb
```

It looks in whichever folders NextUI itself considers Game Boy or Game Boy Color: ones whose name ends in `(GB)` or `(GBC)`, plus a folder named exactly `GB` or `GBC`. The display name in front of the tag is yours — `Game Boy (GB)`, `Nintendo Game Boy (GB)` and `GB` all work, the same rule the frontend uses to decide which emulator opens a ROM.

Only files of exactly 1 MiB (Gen 1) or 2 MiB (Gen 2) are hashed, since the engine accepts no other size, so a large homebrew library costs almost nothing to scan. **Your files are only ever read** — never moved, renamed, copied or deleted.

Accepted dumps (US cartridges only). Check yours on the device with `sha256sum <file>`:

| Version | SHA-256 |
|---|---|
| Red | `5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b` |
| Blue | `2a951313c2640e8c2cb21f25d1db019ae6245d9c7121f754fa61afd7bee6452d` |
| Yellow | `8cbaa499397e4f1a679c992ea9382a2dd7942ab398b48c19829c2d9529de47bf` |
| Gold | `fb0016d27b1e5374e1ec9fcad60e6628d8646103b5313ca683417f52b97e7e4e` |
| Silver | `72b190859a59623cbef6c49d601f8de52c1d2331b4f08a8d2acc17274fc19a8c` |

The engine verifies by SHA-1; the pak matches by SHA-256 because these devices ship no `sha1sum`. Other regions, revisions and ROM hacks are not supported by the engine.

### Why the pak no longer imports for you

Through v0.4.3 the pak copied a matching dump into the engine's import folder and the engine picked it up unattended — you never saw a file browser. Gen1Recomp 0.2.x changed that: the Choose ROM flow now opens the engine's own browser and returns before it ever reaches the pending-ROM scan it used to rely on (`findPendingRom`, still present but unreachable on Linux; its other callers are Android-only).

So a staged copy imports nothing and just duplicates 1–2 MiB per version. The pak reports paths instead. If you are updating and find leftover dumps in `.userdata/shared/Gen1Recomp/love/pokemon-love2d/`, they are those old copies — the log names them and they are safe to delete. **The pak will not delete them for you**, because a dump you placed there by hand is indistinguishable from one it copied.

Worth knowing: the same upstream change fixed a real annoyance. Picking a version used to import whichever edition happened to be first in folder order, so choosing Red could decode Blue. Now you choose the file, so you get what you picked.

### Crystal

Gen1Recomp 0.2.x added **Silver and Crystal**. Silver is supported here as of v0.4.3. **Crystal is not**, and a Crystal dump on your card is ignored.

The reason is mundane. These devices have no `sha1sum`, so the pak's ROM scan matches candidate dumps by **SHA-256** before copying them, while everything upstream publishes — `GameVersion.lua` and every `tools/rom_manifest_*.json` — is SHA-1. One cannot be derived from the other, so each version needs its SHA-256 taken from a real cartridge dump. Silver's was measured on a Brick against the owner's own dump, whose SHA-1 matched the engine's `silver` row exactly. No Crystal dump has been available to do the same with, and inventing a value would be worse than leaving it out: the scan would match nothing and say nothing, which is exactly how the Gold gap went unnoticed for two releases.

Everything else is unaffected.

## 3D voxel mod

The 3D look most people associate with Gen1Recomp is **not** part of the game — it comes from a separate, experimental mod, which replaces the flat overworld with a voxel one and adds camera depth, shadows and 3D battle presentation.

Since v0.4.0 that mod is **[Dramaless Shape](https://github.com/artyrambles/DRAMALESS_SHAPE)**, bundled at **2.0.3** as of v0.4.4. Note that every performance figure below was measured against **2.0.1**, the version bundled through v0.4.3 — 2.0.3 has not been profiled on either device, and its author described the intervening 2.0.2 as slightly slower, so treat the numbers as indicative of the mod in general rather than of this exact build. Step the **VOXEL** row on the in-game OPTIONS menu to turn the 3D world on.

### Why the mod changed

Through v0.3.0 this pak bundled **DramaticShapeVoxelMod** 1.7.2. It should not have: that mod carries no licence file at all, and line 3 of its own README reads *"Redistribution of non-derivative code is expressly prohibited after v1.6.0 without permission."* Its author deleted the repository, and the copy here came from a community mirror. Bundling it was the maintainer's mistake, and v0.4.0 corrects it.

Of the forks that appeared afterwards, only Dramaless Shape is redistributable. It rebased onto the last openly licensed upstream code, reverted the changes made after the licence was withdrawn, and publishes under the MIT licence — included in the pak at `licenses/LICENSE.DRAMALESS_SHAPE.txt`. The others (`BATTLE_ART_VOXEL_FORK`, `PotatoVoxel`, `TERRARIUM`) carry no licence and cannot be bundled, however good they are; PotatoVoxel in particular is the one built for hardware like this, and it is a genuine loss that it cannot ship here. All three remain installable by hand — see [More mods](#more-mods).

### What you gain and lose

Dramaless 2.0 is deliberately voxel-only. Compared with the mod it replaces:

- **Gone:** Pokémon Stadium battle models and disc stages, the multi-mode `3D-BTL` selector, replacement battle art and move animations, VR, horde mode, and **voxelised character models** — people in the overworld are now flat sprites with silhouettes rather than 3D figures.
- **Gained:** defaults chosen for weak hardware (the 3D pass renders at half resolution, shadows are held on their cheap path, expensive effects start off), a new **RENDER DIST** setting, a working update check, and a pak that is 22 MB instead of 39 MB.

If you preferred the old mod, nothing stops you installing it yourself; this pak simply will not ship it for you.

### Memory: Swap.pak is required, not optional

> **Re-measured on v0.4.0, on both devices. The swap requirement stands.** Changing the voxel mod did not reduce memory use on the Smart Pro S: peak RSS is 726 MB against the old mod's 722 MB. Whatever else Dramaless is lighter on, it is not this.

**Smart Pro S, v0.4.0, Dramaless Shape 2.0.1**, walking the overworld with VOXEL on, 60 s:

| | Dramaless 2.0.1 | DramaticShapeVoxelMod 1.7.2 |
|---|---|---|
| LÖVE peak RSS | **726 MB** | 722 MB |
| MemAvailable at worst | 37 MB | 35 MB |
| Samples showing paging | **9 of 30** | 22 of 30 |
| GPU p75 | 85% | 83% |

**No meaningful improvement.** The working set is the same size, and the device pages just as it did before — the profiler's verdict is *swap thrashing*, and the stalls you feel are disk waits that no graphics setting will touch. Read the lower paging count with care: this run began at 726 MB, already deep into a session, and the two samples cover different routes and lengths. It is not evidence of a fix.

Note the shape of the load differs from the Brick: here the GPU sits at 85% with LÖVE pinned at 98% of a single core out of eight, so this device is bound by one thread and by memory, not by the GPU.

**Brick, v0.4.0, Dramaless Shape 2.0.1**, walking Route 1 with VOXEL on, sampled over 60 s and then tracked for three minutes more:

| | Measured |
|---|---|
| LÖVE RSS | 38 MB at launch → **~440 MB peak** |
| MemAvailable at worst | 88 MB of 998 MB |
| Swap used | **3 MB** of 1 GB — essentially no paging |

Memory is **not monotonic**: RSS fell from ~410 MB back to 75 MB inside a single session, which is the mod's per-map mesh eviction doing its job. That drop coincided with the player changing the voxel level, though, so it is not clean evidence of eviction under plain walking.

This window did not establish a ceiling — RSS was still climbing when it closed, and on the Brick the old mod peaked at a comparable 386 MB. Between the two devices the picture is consistent: the new mod is not measurably lighter than the one it replaced.

Measured across a session on a Smart Pro S (962 MB RAM), **DramaticShapeVoxelMod 1.7.2** on:

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

### Recommended settings

Short version: **install Swap.pak, and leave the in-game settings alone.** Everything that measurably helps, the pak already does for you.

| Setting | Recommendation | Why |
|---|---|---|
| **Swap.pak** | **Required** for the voxel mod. 512 MB, internal storage, boot hook on | RSS reaches ~700 MB on a 962 MB device and pages regardless of any setting we found. Without swap the session is OOM-killed |
| **MAX FPS** | Leave at 60 | 30 vs 60 measured identical. The cap only binds when frames are produced *faster* than the target, and neither device reaches 30 with the mod on |
| **PERFORMANCE** | Leave at **AUTO** | Already resolves to `LOW` on ARM Linux. Setting it explicitly changes nothing |
| **VOID FILL** | Try **BLACK** only if you are paging | Inconsistent: ~133 MB saved on a Brick, only ~28 MB on a Smart Pro S, which kept paging anyway. See below |

Automatic, no action needed: all CPU cores brought online, cluster frequency ceilings raised, and on big.LITTLE hardware every LÖVE thread pinned to the big cluster — worth about 16 points of GPU utilisation on the Smart Pro S.

**On VOID FILL, and a measurement caveat worth stating.** The Brick showed peak RSS falling from 386 MB to 253 MB with BLACK, which looked like a solid win. It did not replicate on the Smart Pro S: 722 MB to 694 MB, still paging. The likely explanation is that the two Brick runs were not comparable — one began mid-session at 385 MB, the other from a fresh launch at 233 MB — and what I was really measuring was **how many maps had been visited**, not the void fill.

That is the more useful finding: memory scales with the maps in the mod's live set (current map, its connected neighbours, and the previous set), so a long trek costs far more than any graphics option saves. If you are paging, quitting and relaunching reclaims more than VOID FILL does.

There is no in-game FPS counter to compare against: it was requested twice upstream ([#963](https://github.com/bryanthaboi/gen1recomp/issues/963), folded into [#225](https://github.com/bryanthaboi/gen1recomp/issues/225)) and closed `not_planned`. That is why `scripts/profile-device.sh` measures GPU utilisation, CPU and memory rather than frame rate — those are the only signals the device actually exposes.

Every figure here is one or two runs on one or two devices. Treat the directions as real and the exact numbers as indicative, and measure your own with `scripts/profile-device.sh 60`.

**The pak does not write any of these for you.** It could — the engine merges a partial `options.lua` over its defaults, so seeding on first run would be safe. It does not, because nothing we measured justifies it: the two settings that would have been invisible technical wins do nothing, and the one with any effect is a visible change with an unreliable payoff.

The one exception is the mod catalogue, and only on a brand-new install — see [More mods](#more-mods). No graphics or gameplay setting is ever written for you.

### The mod's update check

These handhelds ship no CA store at all, and the engine does HTTPS by shelling out to `curl`. Every request therefore failed verification (`curl` exit 60), which the mod manager reported simply as a failed check. Since v0.2.2 this pak ships a CA bundle and points `curl` at it, so HTTPS works.

Until v0.3.0 the check failed anyway, because `DramaticShape/DramaticShapeVoxelMod` returns 404 — there was nothing left to check against. **That is fixed in v0.4.0 by the mod swap:** Dramaless Shape has a live repository, so the update check now resolves.

One consequence worth expecting: it releases *fast*. Five releases in six days at the time of writing, so the manager may well tell you an update is available shortly after you install the pak.

### Performance: the bottleneck differs by device

Measured with `scripts/profile-device.sh`, sampling only while rendering.

**TrimUI Brick** (A133, PowerVR GE8300, 4 cores) — **GPU-bound**, on both mods:

| Mod | GPU median | GPU p75 | GPU peak |
|---|---|---|---|
| **Dramaless Shape 2.0.1** (v0.4.0, MAX FPS 60) | **68%** | **96%** | 100% |
| DramaticShapeVoxelMod 1.7.2 (MAX FPS 60) | 91% | 96% | 100% |
| DramaticShapeVoxelMod 1.7.2 (MAX FPS 30) | 92% | 99% | — |

The p75 is identical at 96%, so the new mod is still GPU-saturated while rendering. Its lower median reflects a session that included indoor and menu stretches rather than a controlled comparison — do not read it as a 23-point win. Its CPU use is genuinely multi-threaded: 235% of one core across four, with system CPU p75 at 45%.

(The profiler's first sample reports an impossible GPU figure — 649% here — because the utilisation counter has no previous delta to difference against. The same row reads 0% CPU. Ignore row one.)

Capping the frame rate changed nothing, and that is worth understanding rather than retrying. The cap is a sleep budget in the run loop, so it only binds when frames are produced *faster* than the target. With the GPU pinned near 99% under a 30 cap, the device is already below 30 fps and there is nothing to hold back — and 30 is the floor of the ladder (`FrameCap.MIN`). An earlier version of this README recommended capping at 30 as the biggest win; measurement says it is not.

**TrimUI Smart Pro S** (sun55iw3, Mali-G57 single core, 8 cores, big.LITTLE) — **not GPU-bound, until it runs out of memory:**

| | GPU median | GPU p75 | System CPU p75 |
|---|---|---|---|
| Default scheduling | 67% | 72% | 19% |
| Threads pinned to the big cluster | **83%** | **88%** | 20% |

NextUI leaves only three cores online and the scheduler parked LÖVE's main thread — the one driving rendering — on a *little* core at 936 MHz while the big cluster idled at 2160 MHz. This pak now brings all eight cores online and pins every LÖVE thread to the big cluster with a cpuset, which lifted GPU utilisation by about 16 points: more frames getting through.

(That comparison is imperfect. The pinned run was also deep enough into the session to be swapping, so some of the difference is confounded by memory pressure.)

On both devices the CPU as a whole is nowhere near saturated — 19–39% across all cores. Single-thread speed and thread placement matter; total CPU capacity does not.

The one lever that matters is **swap** — on the Smart Pro S memory is the binding constraint, not the GPU. VOID FILL = BLACK helps inconsistently and does not move the frame rate; the mod's mesh ring is a hardcoded constant, so draw distance is not adjustable. See [Recommended settings](#recommended-settings).

Be realistic: this is a 3D renderer on budget handheld silicon. The 2D game runs comfortably on both.

## More mods

The voxel mod is the only one this pak bundles, but it is one of over a hundred. Gen1Recomp keeps an official catalogue at [`bryanthaboi/gen1recomp-mod-index`](https://github.com/bryanthaboi/gen1recomp-mod-index) — quality-of-life tweaks, UI replacements, alternative voxel forks, extra music — and the game installs from it directly, under **Find mods** in the in-game mod manager.

**On a brand-new install the pak adds that catalogue for you**, and says so in the log. The engine ships none configured, on purpose: adding one is an act of trusting whoever publishes it, so it asks rather than assuming. That default is right for a desktop, but on a handheld the "ask" means typing a URL on a d-pad keyboard, and this particular catalogue is published by the engine's own author. Remove it in-game and it stays removed — it is entered once, never re-added.

It is added in one of two situations, and **only once either way**. On a genuinely fresh install, where no options file exists at all — backups included. Or on an existing install whose catalogue list is empty, which is what you get if the pak was installed before this feature existed, or if the engine wrote its options file before the pak ever ran. In the second case the pak edits your existing options file in place, keeps a copy of the original beside it as `options.lua.pak-preseed`, and leaves every other setting untouched.

It never writes `options.lua.bak`. That file is the engine's own recovery copy: if your options file is missing but a `.bak` or `.tmp` survives, the engine heals your settings from those, and writing over that would destroy them.

**Remove the catalogue in-game and it stays removed.** The pak records that it has had its one go, so an empty list on a later launch is read as your decision rather than as something to fix.

To add it by hand — on an existing install, or after removing it — you do **not** need the full URL. **Find mods** accepts a bare `owner/repo`:

```
bryanthaboi/gen1recomp-mod-index
```

Worth keeping in mind either way: an index is only metadata, but every mod it lists is code from a stranger's repository, running with access to your save data.

**Browsing it can freeze the game for up to a minute. That is not a crash — wait it out.** The engine fetches over HTTPS by shelling out to `curl` and reading the pipe to completion, and some of those calls still run on the drawing thread, so the picture stops until the request finishes or times out (`--max-time 40`, plus up to 10 s to connect). Opening a mod's **details** is the case we confirmed in the code; players have also seen it on the first load of the listing and when paging through it, which we have not pinned down. Nothing is lost when it happens.

Three caveats specific to this hardware:

- This works here **only because of the CA bundle** added in v0.2.2. Without it every fetch fails verification, and the manager reports it as a failed download with no mention of certificates.
- **Check what you install.** Several popular mods are bound to keyboard keys and are unreachable on a handheld; the music packs run to 300 MB; and a few need a network connection to a server. Nothing about the catalogue filters for a 1 GB gamepad-only device.
- **A mod you install can disable the bundled one**, silently, if the two declare a conflict. See below.

Mods you install yourself land in your save directory, not in the pak, so a pak update will not remove them.

### Installing a mod by hand

You do not have to use the in-game manager. The pak ships an empty folder for mods you want to add yourself:

```
Tools/<platform>/Gen1Recomp.pak/mods/
```

Unzip the mod so its `manifest.json` sits directly inside its own folder — `mods/SomeMod/manifest.json` — then start the game and open **MODS** once. The engine copies anything new into your save data and reports *"Imported from the game folder: …"*. From then on the mod lives with your saves, survives pak updates, and toggles from the MODS screen like any other. The copy left in `mods/` does nothing afterwards and can be deleted.

This is the engine's own mechanism, not something this pak bolted on: `adoptStrays()` scans the folder the game was launched from once per session, which for this pak is the `.pak` directory. The pak only creates the folder, ships a `README.txt` in it, and reports in its log what it found — including the two mistakes that otherwise produce silence: a mod left zipped, and a mod unzipped one level too deep (`mods/SomeMod/SomeMod/manifest.json`).

Nothing is copied by the pak itself, deliberately. A mod already installed under the same id always wins, so a folder left here can never quietly replace something you installed in-game.

The usual caution applies and is not reduced by installing this way: a mod is code from a stranger, running with access to your save data. Note also that a mod installed by hand is **not** the bundled voxel mod — if you hand-install Dramaless yourself, you get the released version, which is missing the fix described under [The voxel mod](#the-voxel-mod).

### The catalogue lists the mod this pak removed

`DRAMATIC_SHAPE` is in there, at **1.8.2** — newer than the 1.7.2 v0.3.0 shipped. It is the same mod: same id, same `github` field pointing at the deleted original, and **196 of its 222 files are byte-identical** to the copy this pak used to bundle. It is hosted by a preservation mirror rather than its author.

Two things worth knowing before you install it.

**It will silently disable the bundled voxel mod.** Dramaless declares a conflict with it, and the engine's rule is that the *declaring* mod loses — so with both installed, Dramaless is the one that fails, and you end up on the old mod with nothing on screen to say so. The pak notices a copy in your save directory and says so in the log, but it will not touch it: your install is yours.

**Its licence position is unchanged, and it is no longer this pak's to resolve.** 1.8.2 still ships no licence file of any kind. The line in the 1.7.2 README that said *"Redistribution of non-derivative code is expressly prohibited after v1.6.0 without permission"* is **absent** from 1.8.2 — whether the author removed it before the repository disappeared, or the mirror dropped it, cannot be established now that the original is gone. Installing it is a direct download from a third party to your device: this pak neither ships it nor hosts it. It is listed here because it is a fact about the catalogue, not a recommendation.

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

Stated plainly, because these are structural rather than bugs, and knowing them up front is cheaper than discovering them.

### On the device

- **MENU does not quit the game.** NextUI does not intercept MENU for standalone applications, so it arrives as an ordinary button. Quit through Gen1Recomp's own launcher.
- **Sleep does not work.** All power handling lives inside the NextUI frontend, which has exited while the game runs. Brightness and volume *do* keep working — a background daemon handles those.
- **Shader presets are unavailable, and that is the engine's decision, not ours.** Gen1Recomp 0.2.x replaced its old GBC FX option with libretro slang-shader presets. `Performance.detect()` resolves ARM Linux handhelds to the `low` tier, whose caps set `shaderfx = false` — a hard off, checked before any preset is looked at. Because nothing on this hardware can reach that code path, the pak does not ship the 8.4 MB `liblibrashader_bridge.so` that only exists to translate presets; that keeps the download at ~29 MB rather than ~37 MB. If you force PERFORMANCE to HIGH and supply your own presets, preset conversion fails gracefully — a logged `ffi.load` failure and no shader, not a crash — and you can point `LIBRASHADER_BRIDGE_DLL` at your own build of the bridge.
- **The pak changes CPU state while running.** It brings all cores online, raises cluster frequency ceilings, and on big.LITTLE hardware pins LÖVE to the big cluster. Governor, ceilings, floors and which cores are online are all recorded at launch and put back on exit. The online mask is the one that matters: NextUI offlines five of the Smart Pro S's eight cores at boot and never repeats it, so a core left up by this pak would stay up for the rest of your session. **Through v0.4.1 none of it was actually put back** — the launcher handed the process over to the game in a way that discarded its own cleanup step, which v0.4.3 fixes; measured on a Brick, the frequency ceiling now returns to where it started. Create `no-cpu-tuning` in the state dir to disable.

### The voxel mod

- **Its hotkeys do not work on a handheld — use the OPTIONS menu.** Every shortcut the mod defines is a letter key (`v` voxel, `g` grid, `t` tilt-shift, `c` curve) bound to the keyboard only; there is no gamepad binding anywhere in it. The mod this replaced bound **SELECT** to step the voxel ladder precisely because pads have no number row, and Dramaless dropped that. Nothing is unreachable — every hotkey is also a row on the OPTIONS menu — but it is two more button presses than it used to be. Confirmed on a Brick.
- **It is not smooth on a Brick, and no setting fixes that.** Measured on v0.4.0: GPU p75 96%, peak 100% while rendering. There is no userspace clock control on this PowerVR part, so the only lever is drawing less — lower RENDER DIST, or set WATER to OFF, which the mod's author calls the biggest single win.
- **Swapping the mod did not reduce memory use.** Measured on v0.4.0: 726 MB peak on a Smart Pro S against the old mod's 722 MB, paging in 9 of 30 samples. Dramaless halves its render scale by default and drops the VR and Stadium payloads, but the voxel working set is what fills a 1 GB device, and that has not changed.
- **It needs swap, and the new mod did not change that.** Measured on v0.4.0: 726 MB peak on a Smart Pro S with active paging, against the old mod's 722 MB. Without [Swap.pak](https://github.com/carroarmato0/NextUI-Swap-Pak) the session is OOM-killed. The Brick is easier on memory (~440 MB, 3 MB of swap touched) but is GPU-bound instead. The 2D game runs comfortably on both.
- **No Stadium models, 3D battle modes, VR or voxel characters.** Dramaless 2.0 dropped all of them; see [What you gain and lose](#what-you-gain-and-lose).
- **The mod releases faster than this pak does.** Expect the in-game update check to offer a newer version than the bundled one.
- **The bundled copy carries a fix that the released mod does not.** Gen1Recomp deleted `src/render/GBCFX.lua` after 0.2.20, and Dramaless still requires it in two places — one of them looks guarded but is not, because the `pcall` wraps the call rather than the `require`. Unpatched, that throws inside the mod's OPTIONS hook, the engine logs-and-skips the whole hook, and the mod's rows vanish from OPTIONS with nothing on screen to say why — which, given the hotkeys are keyboard-only, leaves no way at all to reach the 3D toggle on a handheld. The pak patches both call sites at build time (`patches/DRAMALESS_SHAPE-gbcfx.patch`). Reported as [DRAMALESS_SHAPE#53](https://github.com/artyrambles/DRAMALESS_SHAPE/issues/53); the patch is deleted, not carried, once a mod release fixes it. **If you install Dramaless yourself from the in-game mod manager, you get the unpatched version** and the OPTIONS rows will be missing.

### Measurement

- **There is no in-game FPS counter**, and none is planned ([#225](https://github.com/bryanthaboi/gen1recomp/issues/225) closed `not_planned`). `scripts/profile-device.sh` reports GPU utilisation, CPU and memory instead, because that is what the device exposes.
- **Performance figures here are one or two runs on one or two devices.** Directions are trustworthy; exact numbers are indicative. Three recommendations in this project were withdrawn after wider measurement — cap FPS at 30, swap unnecessary, VOID FILL saves memory — so treat single-run results, including ours, with suspicion.

### Scope

- **Only canonical US Red, Blue, Yellow and Gold are accepted.** Other regions, revisions and ROM hacks are refused by the engine, not by this pak.
- **Gold is an upstream beta.** The launcher labels it `Gold (Beta)`. It is Generation 2 and still being worked on upstream — expect rough edges that are not this pak's to fix. Red, Blue and Yellow are unaffected by it.
- **Two of four devices are untested.** The Smart Pro and Brick Pro share a platform with the Brick and are likely fine, but nobody has run them. See [Tested on](#tested-on).
- **Updating from v0.1.0 deletes `Roms/Gen1Recomp (Gen1Recomp)/`, box art included.** That folder was entirely this project's doing and leaves a stale duplicate entry otherwise. The old pak under `Emus/` is left for you to remove. See [Upgrading from v0.1.0](#upgrading-from-v010).
- **A `.love` file dropped in the state directory will run instead of the game**, but that is a diagnostics hook for the smoke test, not a feature. There is no per-game save isolation or controller profile behind it; this pak is Gen1Recomp-specific. Delete it to get the game back.
- **The bundled CA certificate bundle is pinned and will age.** Roots expire, and a stale bundle fails exactly as silently as having none. Refresh with `scripts/build.sh --refresh-ca`.
- **Upstream has an AI-generated-code controversy attached.** It changes nothing technically and this pak takes no position; it is mentioned so the decision is yours rather than a surprise.

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
| Nothing happens when launched | `FATAL` in the log — usually an incomplete install. On **v0.2.1 and earlier** it could instead be `error while loading shared libraries: libmpg123.so.0`, with the log ending right after `=== love output follows ===`: that firmware image ships no `libmpg123`, which LÖVE needs. Later versions bundle a fallback copy |
| Two Gen1Recomp entries, one under Games | A leftover v0.1.0 install. The `legacy` lines say what was removed and what is left |
| Game asks for a ROM you already have | `rom` lines: the scan reports every folder it searched, and says so explicitly when it found no Game Boy folder at all |
| Audio crackles or distorts | `XRUN`. Try removing `no-cpu-tuning` from the state dir if you created it |
| Killed during a voxel session | `SwapTotal` in the log. Set up Swap.pak as above |
| A and B feel swapped | The controller GUID may differ on your unit — see [Contributing](#contributing) |

Two lines in the log look like errors and are not. `libz.so.1: no version information available` is a symbol-versioning notice from the firmware's zlib. `AL lib: (EE) mmap commit error: Broken pipe` appears a handful of times as OpenAL starts; a Brick session with ten of them had audio working normally throughout. Neither indicates a problem on its own.

## Tested on

Honest status. An untested device is listed as untested, not assumed to work.

| Device | Platform | Screen | Status |
|---|---|---|---|
| TrimUI Brick | `tg5040` | 1024×768 | **Runs.** GLES 3 context, ROM import, 2D game, voxel mod, controller mapping (A confirms) and audio all verified on hardware. Re-verified as a Tool pak on v0.2.0: launches from Tools, imports both Red and Blue out of an 89-ROM library, removes a v0.1.0 ROM folder without touching any of 1061 save files, and returns cleanly to the frontend. On v0.2.2, verified that the bundled libmpg123 fallback is correctly *not* used where the firmware ships its own. **Gold verified on v0.3.0.** Its import and decode were first confirmed on Gen1Recomp 0.1.79 with a dump staged by hand — complete cache in about a minute, memory never a concern (~677 MB free, LÖVE RSS ~71 MB) |
| TrimUI Smart Pro | `tg5040` | 1280×720 | Not tested — same platform as the Brick, so likely fine, but unverified |
| TrimUI Brick Pro | `tg5040` | 1024×768 | Not tested |
| TrimUI Smart Pro S | `tg5050` | 1280×720 | **Runs.** Profiled with the voxel mod; needs swap. Audio verified. Yellow import verified end to end on hardware: a dump added after Red and Blue were already imported is picked up on the next launch and decoded (cache complete in ~50 s). **Gold's automatic import verified on v0.3.0 / Gen1Recomp 0.1.81**: the scan found a 2 MiB Gold dump in `Game Boy Color (GBC)/` unaided (`rom  matched Gold:` in the log), staged it, and the engine decoded it to `gold/rom-cache.complete` with 32 generated files |

The runtime itself is known to work on this hardware class — the LÖVE 11.5 ARM64 build here is the same one shipped by [PortMaster](https://portmaster.games/), and [nx-redux](https://github.com/mohammadsyuhada/nx-redux) runs Gen1Recomp with the voxel mod on both platforms. What is untested is *this pak*.

**On v0.4.0 specifically:** the new voxel mod **loads and renders on a Brick** — verified on hardware, walking the overworld in 3D, with the engine logging `loaded mod DRAMALESS_SHAPE 2.0.1` and persisting the voxel setting. The in-place upgrade from v0.3.0 was verified on **both** devices: merged over the old install, the superseded mod is removed on first launch, and no save was touched.

**On v0.4.4, both devices were re-verified over ADB.** Smart Pro S: GLES 3.2 on **Mali-G57**, window at the panel's native 1280×720, audio initialised with no underruns, and the pak's own controller mapping confirmed live. Brick: GLES 3.2 on **PowerVR Rogue GE8300**, 1024×768, same result — which is also why `MALI_CreateWindow` in a Brick log means nothing about the GPU.

**The CPU restore was measured on the Smart Pro S, and it is the device that needed it.** Through v0.4.3 the launcher never undid its own CPU changes at all. Measured across a full launch here: cores `0-1,4` before, `0-7` while running, back to `0-1,4` after; cluster ceilings 1320/2088 MHz raised to 1416/2160 and restored; the cpuset created with 20 tasks and removed on exit. NextUI resets governors and ceilings by itself but never re-offlines those five cores, so before the fix they stayed up for the rest of the session — invisible on a Brick, where all four cores are always online.

Both devices report the same controller GUID and the same live mapping, but a **different button count** — 11 on the Smart Pro S against 15 on the Brick. The shipped mapping only reaches `b10`, so it fits both.

**Both devices are now profiled on v0.4.0.** Brick: still GPU-bound (p75 96%, peak 100%), RSS around 440 MB, 3 MB of swap touched. Smart Pro S: 726 MB peak and paging in 9 of 30 samples, against the old mod's 722 MB and 22 of 30 — memory-bound and swap-thrashing, essentially unchanged. Swap remains a requirement, not a suggestion.

## Building from source

No compiler and no cross-toolchain. Everything is fetched from pinned, hash-verified upstream artifacts and rearranged.

There is genuinely nothing to compile: Gen1Recomp is LÖVE 11.5 / LuaJIT, so the game is Lua and upstream's `.love` **is** the from-source build. That is where the game payload comes from. The RG34XXSP port zip is fetched only for the aarch64 LÖVE runtime — the exact build upstream tested this game version against — and its LÖVE licence file.

```sh
scripts/build.sh                 # fetch + stage into build/Gen1Recomp.pak/
scripts/build.sh --no-voxel      # skip the voxel mod (~1.8 MB of the 29 MB pak)
scripts/verify.sh                # static + contract checks
test/test-launch.sh              # launch.sh behaviour against a fake SD card
scripts/release.sh               # -> dist/Gen1Recomp.pak.zip and dist/Gen1Recomp.pakz
scripts/deploy.sh                # adb push to a device
scripts/verify-device.sh         # the real functional test, on hardware
scripts/profile-device.sh 60     # sample GPU/CPU/memory while playing
```

Needs `curl`, `jq`, `zip`, `unzip`, `sha256sum`, `readelf`, `ar`, `tar` and `patch` (`ar`/`tar` unpack the bundled `libmpg123` from its `.deb`; `patch` applies the fixes in `patches/`).

`upstream.lock` pins every third-party artifact by SHA-256 and every assumption the launcher makes about upstream's payload. `verify.sh` re-checks all of it, so an upstream change that would break the pak fails the build with a name attached instead of producing a black screen on your device. A scheduled workflow watches upstream for new releases and prepares a **draft** release plus a device checklist — it never publishes, because CI cannot test any of what matters.

## Contributing

The most useful thing you can contribute is a **device report** — especially on a **Smart Pro** or **Brick Pro**, neither of which has ever been run on hardware. There is an issue template for it, and "it just works" is as useful as a bug.

If you can, include `scripts/profile-device.sh 60` output. Everything this README claims about performance rests on one or two runs on one or two devices, so a second data point genuinely changes what it says.

If A and B are swapped for you, the controller GUID in `launch.sh` is wrong for your unit — the smoke test prints the real one, and that is exactly the fix to send.

## Credits and licences

This pak is **MIT**. It bundles:

- **[Gen1Recomp](https://github.com/bryanthaboi/gen1recomp)** by bryanthaboi — MIT. The actual game; version **0.1.81** is bundled here. Upstream credits the [pret](https://github.com/pret) group's `pokered` disassembly as making the project possible.
- **[LÖVE](https://love2d.org/) 11.5** — zlib. The ARM64 build comes from **[PortMaster](https://portmaster.games/)**, which is why this pak needs no compiler.
- **[mpg123](https://www.mpg123.de/)** (`libmpg123.so.0`) — LGPL-2.1. A dependency of LÖVE that some TrimUI firmware images do not ship, so the pak carries a fallback copy in `bin/lib/`; without it the game cannot load on those images. Where the firmware provides its own, that one is used. The aarch64 build comes unmodified from the Ubuntu 18.04 `libmpg123-0` package.
- **[Dramaless Shape](https://github.com/artyrambles/DRAMALESS_SHAPE)** 2.0.3 by Stahltier (artyrambles) — MIT. The 3D voxel mod. Derived from DramaticShapeVoxelMod's openly licensed code and from MIT-licensed work in [TERRARIUM](https://github.com/BrenoBertucci/Terrarium) by BrenoBertucci. Full licence text ships in the pak at `licenses/LICENSE.DRAMALESS_SHAPE.txt`.
- **[The Gen1Recomp mod index](https://github.com/bryanthaboi/gen1recomp-mod-index)** — not bundled, but the catalogue this README points you at for everything else.
- **[NextUI](https://github.com/LoveRetro/NextUI)** — the firmware this targets.
- **[Swap.pak](https://github.com/carroarmato0/NextUI-Swap-Pak)** — recommended for the voxel mod. The swap performance figures quoted above are its measurements.

The TrimUI-specific settings in `launch.sh` — the controller GUID, the audio routing, the CPU behaviour behind the audio fix — were worked out first by **[nx-redux](https://github.com/mohammadsyuhada/nx-redux)** (GPL-3.0). This pak was written independently from those published findings; no code was copied, and the credit for figuring them out is theirs.

Pokémon is a trademark of Nintendo/Creatures/GAME FREAK. This project is unaffiliated, ships no copyrighted game content, and requires you to supply your own legally obtained cartridge dump.
