Draft release **@NEW@** (Gen1Recomp @UPSTREAM@) is built and statically checked.
It is **not** verified to run — CI has no aarch64 TrimUI, no Mali/PowerVR GPU and
no NextUI, so nothing below could be observed automatically.

```sh
git fetch && git checkout @BRANCH@
scripts/build.sh
DEPLOY_PLATFORM=tg5050 scripts/verify-device.sh
```

### Checked by `verify-device.sh`

- [ ] A GLES renderer was created
- [ ] Window is the panel's native resolution (1280×720, or 1024×768 on Brick)
- [ ] Audio initialised, and no XRUN/underruns in the log
- [ ] Controller GUID matches the mapping shipped in `launch.sh`
- [ ] ROM found and imported by SHA-1; the rescan is skipped on relaunch
- [ ] Saves land in `.userdata/shared/Gen1Recomp`, and no `portable.txt` is in the payload
- [ ] The frontend relaunched cleanly after the game exited

### Human judgement — cannot be automated

- [ ] Audio is clean: no pop on start, no crackle or distortion in game
- [ ] Physical **A** confirms menu selections (not B)
- [ ] Overworld frame rate is playable — **record the number**
- [ ] Re-run with `no-cpu-tuning` present in the state dir. If audio is still clean,
      **delete the CPU block from `launch.sh`** rather than keeping tuning that
      cannot be justified on stock NextUI
- [ ] Voxel mod, with Swap.pak at 512 MB on **internal** storage and the boot hook
      enabled: no OOM kill across a long session. **Record peak memory and frame rate**
- [ ] Box art renders; the folder reads "Pokemon Gen 1" and the entry "Gen1Recomp"

### Before publishing

- [ ] Update the README's **Tested on** table with what was actually run. Leave
      untested devices marked untested rather than assuming they behave the same
- [ ] Fill in the real voxel-mod numbers in the README's 3D section
- [ ] Merge the repin PR
- [ ] Publish the draft release

Publishing makes this live in the Pak Store for everyone who has the pak
installed, so an unverified publish ships a possible black screen to all of them.
