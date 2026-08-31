`scripts/verify.sh` failed after repinning to upstream **@TAG@**, so no draft release was created.

This almost always means one of the assumptions `launch.sh` hard-codes has changed upstream. On device that failure mode is a black screen with no explanation, which is exactly why these are checked here instead. Likely suspects, in rough order of probability:

- **LÖVE version drift.** `conf.lua`'s `t.version` no longer includes `11.5`. Our runtime is pinned to 11.5, so this needs a new runtime *and* a device test.
- **ROM discovery moved.** `findPendingRom` is gone, or it no longer scans the PhysFS root, or `baseRomDiscovery` stopped being Xbox-only. We stage dumps at the save-dir root precisely because that is the only place Linux looks; if that changes, the pak copies a dump somewhere the engine never reads and the player just sees "no ROM".
- The LÖVE identity is no longer `pokemon-love2d`, which would move the save path and orphan every existing save.
- `POKEPORT_GBCFX` is no longer honoured, so GBC FX could render black frames on PowerVR/Mali.
- **The canonical ROM SHA-1s no longer appear in the payload**, i.e. the engine accepts a different set of dumps. Our scan matches on SHA-256 (the device has no `sha1sum`), so the two lists have to be kept in step by hand in `upstream.lock`.
- The LÖVE runtime bundled in the release zip is a different build than the one pinned in `upstream.lock`.

Check the workflow run for which assertion failed. Do not release until it is resolved.
