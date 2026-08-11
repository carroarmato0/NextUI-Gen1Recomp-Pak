Bundles **Gen1Recomp @UPSTREAM@**.

**This is a draft on purpose.** Static and contract checks passed, but CI cannot
test this pak: no aarch64 TrimUI, no Mali/PowerVR GPU, no NextUI. GLES context
creation, audio, controller mapping, frame rate and the voxel mod's memory ceiling
are all unverified until someone runs `scripts/verify-device.sh` on hardware.

Publishing makes this live in the Pak Store for every installed user, so work the
device checklist issue first.

### Which file do I want?

| File | Use |
|---|---|
| `Gen1Recomp.pak.zip` | Pak Store, or manual install into `Emus/<platform>/Gen1Recomp.pak/` |
| `Gen1Recomp.pakz` | Unzip at the SD card root — lays out both platforms and the ROM folder |

You supply your own US Red, Blue or Yellow cartridge dump. No ROM is included.
