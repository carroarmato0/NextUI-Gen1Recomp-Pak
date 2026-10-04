`scripts/verify.sh` failed after repinning to upstream **@TAG@**, so no draft release was created.

Failed run: @RUN@

This almost always means one of the assumptions `launch.sh` or `build.sh` hard-codes has changed upstream. On device that failure mode is a black screen with no explanation, which is exactly why these are checked here instead. Likely suspects, in rough order of probability:

- **LÖVE version drift.** `conf.lua`'s `t.version` no longer includes `11.5`. Our runtime is pinned to 11.5, so this needs a new runtime *and* a device test.
- **A new library in `libs.aarch64/`.** It is checked by exact name against `love_runtime.files`. Find out what loads it before adding it, or strip it like `liblibrashader_bridge.so`.
- **The shader guard moved.** `Performance.detect()` no longer returns `low` on ARM Linux, or `CAPS.low.shaderfx` is no longer `false`, or a `.slangp` preset ships. That is what keeps upstream #136's black frame off PowerVR/Mali.
- **`src/render/GBCFX.lua` came back.** Then the voxel mod's GBCFX patch is obsolete. Drop it from `upstream.lock`.
- **ROM import changed.** The Linux Choose flow no longer opens `Kit.FileBrowser`, or `findPendingRom` is gone. `launch.sh` only reports where dumps are, on the grounds that the engine browses for them itself.
- **The canonical ROM SHA-1s no longer appear in the payload**, i.e. the engine accepts a different set of dumps. Our scan matches on SHA-256 (the device has no `sha1sum`), so the two lists are kept in step by hand in `upstream.lock`.
- The LÖVE identity is no longer `pokemon-love2d`, which would move the save path and orphan every existing save.
- A game manifest that `GameVersion.lua` declares is missing from `tools/`, which fails an import with "ROM import metadata is missing".

Check the workflow run for which assertion failed. Do not release until it is resolved. This issue is rolling: a later failure updates it, and the next repin that passes the checks closes it.
