`scripts/verify.sh` failed after repinning to upstream **@TAG@**, so no draft
release was created.

This almost always means one of the assumptions `launch.sh` hard-codes has changed
upstream. On device that failure mode is a black screen with no explanation, which
is exactly why these are checked here instead. Likely suspects, in rough order of
probability:

- **LÖVE version drift.** `conf.lua`'s `t.version` no longer includes `11.5`. Our
  runtime is pinned to 11.5, so this needs a new runtime *and* a device test.
- The ROM import directory is no longer `baseroms`.
- The LÖVE identity is no longer `pokemon-love2d`, which would move the save path
  and orphan every existing save.
- `POKEPORT_GBCFX` is no longer honoured, so GBC FX could render black frames on
  PowerVR/Mali.
- The canonical ROM SHA-1s changed, so the import scan would silently match nothing.
- The LÖVE runtime bundled in the release zip is a different build than the one
  pinned in `upstream.lock`.

Check the workflow run for which assertion failed. Do not release until it is
resolved.
