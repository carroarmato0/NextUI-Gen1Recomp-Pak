#!/bin/sh
# Gen1Recomp.pak -- NextUI Tool pak launcher (tg5040 / tg5050)
#
# POSIX sh on purpose, NOT bash. On cards that have had PortMaster installed,
# /bin/bash can be a symlink into PortMaster's vendored bin, so a bash shebang
# would quietly reintroduce the dependency this pak exists to avoid.
#
# NextUI invokes this from the Tools menu with NO arguments. This was an Emu pak
# in v0.1.0, which needed a ROM folder and a 0-byte launchable stub inside it --
# a directory NextUI will not launch and a file users had to already have for the
# entry to exist at all. The game imports the player's dump itself, so none of
# that bought anything: Tools is where a self-contained application belongs.
#
# Section A is the generic LOVE 11.5 runtime bring-up and is deliberately free
# of any Gen1Recomp knowledge, so it can be lifted into a generic LOVE pak.
# Section B is everything specific to this game.

PAK_DIR="$(cd "$(dirname "$0")" && pwd)"

###############################################################################
# Section A -- LOVE 11.5 runtime bring-up (game-agnostic)
###############################################################################

# --- logging ---------------------------------------------------------------
# NextUI redirects nothing for us. Everything from here on goes to the log so a
# failed launch leaves evidence rather than a black screen and no explanation.
LOG_DIR="${LOGS_PATH:-/tmp}"
mkdir -p "$LOG_DIR" 2>/dev/null
LOG="$LOG_DIR/Gen1Recomp.txt"
: > "$LOG"
exec >> "$LOG" 2>&1

echo "=== Gen1Recomp.pak ==="
echo "date      $(date 2>/dev/null)"
echo "platform  ${PLATFORM:-<unset>}  device ${DEVICE:-<unset>}"
echo "pak       $PAK_DIR"

[ -x "$PAK_DIR/bin/love.aarch64" ] || {
    echo "FATAL: $PAK_DIR/bin/love.aarch64 is missing or not executable."
    echo "The pak is incomplete -- reinstall it."
    exit 1
}

# --- writable state --------------------------------------------------------
# Saves and the ROM-derived cache must NOT live in the pak directory: a pak
# update replaces that whole tree. Upstream's portable.txt (which would put them
# beside main.lua) is stripped at build time for the same reason. LOVE resolves
# its save directory as $XDG_DATA_HOME/love/<identity>.
STATE="${SHARED_USERDATA_PATH:-${SDCARD_PATH:-/mnt/SDCARD}/.userdata/shared}/Gen1Recomp"
mkdir -p "$STATE" || { echo "FATAL: cannot create $STATE"; exit 1; }
export HOME="$STATE"
export XDG_DATA_HOME="$STATE"
export XDG_CONFIG_HOME="$STATE"
echo "state     $STATE"

# --- shared libraries ------------------------------------------------------
# love.aarch64 needs only libc plus the bundled liblove/libluajit. liblove in
# turn pulls in more: libs.aarch64/ ships liblove, libluajit, libmodplug and
# libogg, and the firmware supplies SDL2 from /usr/trimui/lib and freetype,
# openal, theoradec, vorbisfile, z and stdc++ from /usr/lib.
#
# The one exception is libmpg123.so.0. liblove NEEDs it and the LOVE port zip
# does not ship it, so on a firmware image that lacks one, love.aarch64 dies at
# load with "libmpg123.so.0: cannot open shared object file" -- a black screen,
# the log ending right after "=== love output follows ===". It is the only such
# gap (the loader names it, not the entries before it, which all resolve), so the
# pak bundles exactly it in bin/lib/ and that directory is added below.
#
# Whether the firmware has one VARIES BY IMAGE, so bin/lib goes LAST, after
# /usr/trimui/lib: the firmware's copy wins where it exists and ours is only a
# fallback. Measured on a Trimui Brick, 2026-08-13 -- that firmware ships
# libmpg123.so.0.44.12 (Nov 2025) while the bundled build is 0.44.8 (2018), so
# putting bin/lib first would silently downgrade the decoder on every device that
# already works. Confirmed with LD_DEBUG=libs both ways: bin/lib first loads ours,
# bin/lib last loads the firmware's, and with the firmware copy absent the loader
# falls through to ours and LOVE starts either way.
#
# bin/lib holds only libmpg123, so nothing else is shadowed -- in particular the
# vendor SDL2 in /usr/trimui/lib, which the GLES path needs. Keep /usr/trimui/lib
# on the path: system helpers spawned below load libmsettings.so from
# .system/lib, which a game-first override would shadow.
export LD_LIBRARY_PATH="$PAK_DIR/libs.aarch64:/usr/trimui/lib:$PAK_DIR/bin/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# --- audio routing ---------------------------------------------------------
# audiomon maintains the ALSA config for whichever output sink is selected in
# Settings (speaker, Bluetooth, USB DAC). ALSA finds it via $HOME/.asoundrc, so
# refresh it each launch -- and drop a stale copy when routing was reset.
if [ -f "${USERDATA_PATH:-}/.asoundrc" ]; then
    cp -f "$USERDATA_PATH/.asoundrc" "$HOME/.asoundrc" 2>/dev/null
else
    rm -f "$HOME/.asoundrc" 2>/dev/null
fi

# --- cleanup ---------------------------------------------------------------
# Put back everything the CPU block below changes, rather than leaving it to the
# frontend.
#
# The frontend does undo part of it: NextUI's launch loop runs
# `governor.sh performance` around each pak and its UI then resets to `auto`, so
# the governor and the frequency ceiling get overwritten shortly after we exit
# whatever we do. Restoring them is cheap and keeps the window between our exit
# and the frontend's own reset honest.
#
# Which cores are ONLINE is the half that nothing else puts back. NextUI offlines
# 5 of the Smart Pro S's 8 cores once, at boot; we bring them all up, so a core we
# fail to restore stays up for the remainder of the user's session, costing
# battery in every app that follows. Invisible on a Brick, where all 4 start up.
CPU_SAVED=""
CPU_ONLINE_SAVED=""
save_cpu_state() {
    # cpu0 has no `online` node -- it cannot be offlined -- so the glob skips it.
    for node in /sys/devices/system/cpu/cpu[0-9]*/online; do
        [ -r "$node" ] || continue
        CPU_ONLINE_SAVED="$CPU_ONLINE_SAVED$node	$(cat "$node" 2>/dev/null)
"
    done
    for pol in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$pol" ] || continue
        CPU_SAVED="$CPU_SAVED$pol	$(cat "$pol/scaling_governor" 2>/dev/null)	$(cat "$pol/scaling_max_freq" 2>/dev/null)	$(cat "$pol/scaling_min_freq" 2>/dev/null)
"
    done
}
# Called from cleanup() only, so shellcheck's SC2329 cascades onto it from there.
# shellcheck disable=SC2329
restore_cpu_state() {
    printf '%s' "$CPU_SAVED" | while IFS="$(printf '\t')" read -r pol gov mx mn; do
        [ -d "$pol" ] || continue
        # Floor before ceiling on the way back down, mirroring the order used when
        # raising them: a min above the incoming max is rejected by the driver.
        [ -n "$mn" ] && echo "$mn" > "$pol/scaling_min_freq" 2>/dev/null
        [ -n "$mx" ] && echo "$mx" > "$pol/scaling_max_freq" 2>/dev/null
        [ -n "$gov" ] && echo "$gov" > "$pol/scaling_governor" 2>/dev/null
    done
    # Offlining last, after the policies are back: a policy directory disappears
    # with its last online core, so doing this first would leave nothing to write.
    printf '%s' "$CPU_ONLINE_SAVED" | while IFS="$(printf '\t')" read -r node was; do
        [ -w "$node" ] || continue
        [ -n "$was" ] && echo "$was" > "$node" 2>/dev/null
    done
}

# Invoked by `trap cleanup EXIT ...` below, which shellcheck does not count as a
# call. It only began reporting SC2329 once this script stopped ending in `exec`
# -- and that trap is precisely why the exec had to go. The directive has to be
# the LAST comment line before the function or it is parsed as part of itself.
# shellcheck disable=SC2329
cleanup() {
    echo 0 > /sys/class/speaker/mute 2>/dev/null
    rm -f "$HOME/.asoundrc" 2>/dev/null
    restore_cpu_state
    # Return any stragglers to the root cpuset, then drop ours. rmdir only
    # succeeds once it is empty, which is the check we want.
    if [ -d /sys/fs/cgroup/cpuset/gen1recomp ]; then
        while read -r _t; do
            echo "$_t" > /sys/fs/cgroup/cpuset/tasks 2>/dev/null
        done < /sys/fs/cgroup/cpuset/gen1recomp/tasks 2>/dev/null
        rmdir /sys/fs/cgroup/cpuset/gen1recomp 2>/dev/null
    fi
}
trap cleanup EXIT INT TERM HUP QUIT

# --- speaker anti-pop ------------------------------------------------------
# OpenAL initialisation thumps the speaker. Mute across it, then unmute and let
# syncsettings.elf restore the user's saved volume level.
echo 1 > /sys/class/speaker/mute 2>/dev/null
# syncsettings.elf prints the whole ALSA mixer state and every SetRaw* call it
# makes; unredirected that buried love's own output under ~60 lines of noise.
( sleep 5
  echo 0 > /sys/class/speaker/mute 2>/dev/null
  syncsettings.elf >/dev/null 2>&1 ) &

# --- controller ------------------------------------------------------------
# SDL's positional mapping puts "confirm" on the physical B button. Override to
# the Nintendo layout so physical A confirms, which is what every other NextUI
# screen does. Create the xbox_layout file to opt out.
#
# UNCONFIRMED: this GUID was taken from a working third-party implementation and
# has never been compared against what the hardware reports. Physical A does
# confirm on a Brick, but that is not proof this line caused it -- the default
# mapping could produce the same result. test/smoke/ prints the name and GUID of
# every connected joystick; run it and correct this if they disagree, otherwise
# the mapping silently does nothing.
if [ ! -f "$STATE/xbox_layout" ]; then
    export SDL_GAMECONTROLLERCONFIG="030000005e0400008e02000014010000,TRIMUI Player1,a:b1,b:b0,back:b6,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b8,leftshoulder:b4,leftstick:b9,lefttrigger:a2,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b10,righttrigger:a5,rightx:a3,righty:a4,start:b7,x:b3,y:b2,platform:Linux,"
fi

# --- TLS -------------------------------------------------------------------
# These devices ship no CA store at all: /etc/ssl/certs, /etc/ssl/cert.pem and
# /etc/pki are all absent. The engine does HTTPS by shelling out to curl
# (src/net/Fetch.lua), so every request failed verification with curl exit 60 --
# which surfaced in the mod manager as a failed update check rather than as
# anything mentioning certificates.
#
# CURL_CA_BUNDLE covers curl; SSL_CERT_FILE covers the OpenSSL it links against.
CA_BUNDLE="$PAK_DIR/assets/ca-certificates.crt"
if [ -f "$CA_BUNDLE" ]; then
    export CURL_CA_BUNDLE="$CA_BUNDLE"
    export SSL_CERT_FILE="$CA_BUNDLE"
    echo "tls       CA bundle $CA_BUNDLE"
else
    echo "tls       WARNING: no CA bundle shipped; HTTPS (mod index, updates) will fail"
fi

# --- graphics --------------------------------------------------------------
# Both platforms expose GLES via the vendor SDL2 (NextUI's own renderer asks for
# a GLES 3.2 context). Do NOT set SDL_VIDEODRIVER -- NextUI never does, and the
# vendor SDL2 selects the correct backend on its own.
export LOVE_GRAPHICS_USE_OPENGLES="${LOVE_GRAPHICS_USE_OPENGLES:-1}"

# --- CPU ----------------------------------------------------------------------
# This block was inherited from nx-redux as an AUDIO fix: on that fork, clocks
# capped low and cores hotplugged out at idle starved LOVE's 48 kHz OpenAL mixer
# thread into XRUN underruns. That justification is UNVERIFIED here -- audio is
# clean on both a Brick and a Smart Pro S with the block active, but it was never
# A/B'd against the block disabled, so we do not know whether it is doing that job.
#
# It earns its place on different, measured grounds: NextUI leaves 5 of the Smart
# Pro S's 8 cores offline, and bringing them all online -- together with the cpuset
# below -- lifted GPU utilisation from a 67% median to 83%, i.e. more frames.
#
# Create no-cpu-tuning in the state dir to skip it.
#
# The governor is left on schedutil rather than pinned to performance: the clock
# still scales with load, which is cooler and easier on the battery, while still
# reaching full speed under the game's sustained load.
if [ -f "$STATE/no-cpu-tuning" ]; then
    echo "cpu       tuning skipped (no-cpu-tuning present)"
else
    save_cpu_state
    for online in /sys/devices/system/cpu/cpu[0-9]*/online; do
        [ -w "$online" ] && echo 1 > "$online" 2>/dev/null
    done
    for pol in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$pol" ] || continue
        hwmax=$(cat "$pol/cpuinfo_max_freq" 2>/dev/null)
        hwmin=$(cat "$pol/cpuinfo_min_freq" 2>/dev/null)
        echo schedutil > "$pol/scaling_governor" 2>/dev/null
        # Ceiling before floor: a min above the current (frontend-lowered) max is
        # rejected by the cpufreq driver.
        [ -n "$hwmax" ] && echo "$hwmax" > "$pol/scaling_max_freq" 2>/dev/null
        [ -n "$hwmin" ] && echo "$hwmin" > "$pol/scaling_min_freq" 2>/dev/null
    done
    echo "cpu       all cores online, ceilings raised, governor schedutil"

    # Big-core affinity, on hardware that has two clusters.
    #
    # Measured on a Smart Pro S: the scheduler left LOVE's main thread -- the one
    # that drives rendering -- on a little core at 936 MHz while the big cluster
    # sat at 2160 MHz mostly idle. Moving it across dropped that thread from 51.5%
    # to 42.5% of a core for the same work.
    #
    # taskset does not exist on these devices (not in busybox either), so this uses
    # a cpuset cgroup. Threads are moved after launch by a short background poller,
    # since the process does not exist yet at this point.
    #
    # Create big-cores-off in the state dir to disable.
    BIG_CPUS=""
    if [ -d /sys/devices/system/cpu/cpufreq/policy4 ]; then
        # The cat is not useless: `tr ... < file` on a sysfs node that is absent
        # is a redirection error, which POSIX has a non-interactive shell exit
        # on. cat lets a missing node be an empty result instead of a dead pak.
        # shellcheck disable=SC2002
        BIG_CPUS="$(cat /sys/devices/system/cpu/cpufreq/policy4/related_cpus 2>/dev/null | tr " " ",")"
    fi
    CS=/sys/fs/cgroup/cpuset
    if [ -n "$BIG_CPUS" ] && [ -d "$CS" ] && [ ! -f "$STATE/big-cores-off" ]; then
        if mkdir -p "$CS/gen1recomp" 2>/dev/null \
           && echo "$BIG_CPUS" > "$CS/gen1recomp/cpuset.cpus" 2>/dev/null; then
            cat "$CS/cpuset.mems" > "$CS/gen1recomp/cpuset.mems" 2>/dev/null
            echo "cpu       big-core cpuset ready (cpus $BIG_CPUS)"
            # Poll briefly: threads are spawned over the first second or two, and a
            # thread created after the move stays wherever it was born.
            ( i=0
              while [ "$i" -lt 20 ]; do
                  pid=$(pidof love.aarch64 2>/dev/null)
                  if [ -n "$pid" ]; then
                      for t in /proc/"$pid"/task/*; do
                          [ -e "$t" ] || continue
                          echo "${t##*/}" > "$CS/gen1recomp/tasks" 2>/dev/null
                      done
                  fi
                  i=$((i + 1))
                  sleep 0.5
              done ) &
        else
            echo "cpu       could not create a big-core cpuset; leaving placement to the scheduler"
        fi
    fi
fi

# --- memory ----------------------------------------------------------------
# A voxel renderer holds meshes for the maps around the player, so peak usage
# tracks how far they have walked, not how long they have played -- and these
# devices have 1 GB total. Creating swap is Swap.pak's job, not ours; we only
# point at it. Writing 512 MB into someone's internal storage without asking is
# not this pak's business.
#
# No number is quoted here on purpose. The ~750 MB peak this used to cite was
# measured against DRAMATIC_SHAPE, which v0.4.0 replaced; DRAMALESS_SHAPE has a
# different renderer, halves its render scale by default, and has not been
# measured on this hardware by anyone.
SWAP_TOTAL=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
echo "memory    MemTotal ${MEM_TOTAL:-?} kB, SwapTotal ${SWAP_TOTAL:-?} kB"
if [ "${SWAP_TOTAL:-0}" -eq 0 ] 2>/dev/null; then
    echo "memory    no swap configured. The voxel mod can be OOM-killed on a 1 GB"
    echo "memory    device once enough of the map is in memory. Install Swap.pak and"
    echo "memory    create 512 MB on INTERNAL storage if you want to enable it."
fi

###############################################################################
# Section B -- Gen1Recomp specifics
###############################################################################

GAME="$PAK_DIR/game"

# LOVE's save directory for this identity. Defined here rather than beside the
# ROM scan that reads it, because the legacy sweep below needs it too.
SAVEROOT="$STATE/love/pokemon-love2d"

# --- leftovers from the v0.1.0 Emu layout ----------------------------------
# An in-place upgrade installs the Tool pak but cannot remove the old one, so a
# stale Gen1Recomp entry keeps showing under Games.
#
# The ROM folder is removed rather than reported. Everything in it came from this
# project -- the 0-byte launchable stub and the .media/README.txt telling people
# where box art goes -- and leaving it behind means a duplicate entry that runs
# an older copy of the game. Anyone who did add their own art to .media/ loses
# it; that is a deliberate call by the maintainer, taken while the install base
# is small enough for the tidier upgrade to be worth more than the edge case.
#
# The Emu pak itself is only reported. Deleting the folder above already removes
# the entry (an Emu pak with no ROM folder shows nothing), so removing a whole
# installed pak would buy disk space and nothing else -- and it is not ours to
# assume nobody wants.
SD="${SDCARD_PATH:-/mnt/SDCARD}"
OLD_ROMDIR="$SD/Roms/Gen1Recomp (Gen1Recomp)"
if [ -d "$OLD_ROMDIR" ]; then
    echo "legacy    removing the v0.1.0 ROM folder, which a Tool pak does not need:"
    echo "legacy      $OLD_ROMDIR"
    if rm -rf "$OLD_ROMDIR" 2>/dev/null; then
        echo "legacy    removed. Saves are untouched -- they live in $STATE."
    else
        echo "legacy    WARNING: could not remove it. Delete it by hand, or Games will"
        echo "legacy    keep showing a second Gen1Recomp that runs the older copy."
    fi
fi

# Every platform directory, not just $PLATFORM: the leftover is whatever the old
# install put there, which need not match the platform running now.
for old in "$SD"/Emus/*/Gen1Recomp.pak; do
    [ -d "$old" ] || continue
    echo "legacy    the v0.1.0 Emu pak is still installed and now unused:"
    echo "legacy      $old"
    echo "legacy    Delete it to reclaim ~31 MB. Nothing here reads it any more."
done

# --- mods this pak used to ship --------------------------------------------
# A pak update MERGES over the old install, so a card coming from v0.3.0 still
# holds game/mods/DRAMATIC_SHAPE/ after being updated. Left alone, that breaks
# the new mod rather than the old one, and does it silently:
#
#   DRAMALESS_SHAPE's manifest declares conflicts:["DRAMATIC_SHAPE",...], and the
#   engine's rule is that the DECLARING mod loses (src/mods/Loader.lua,
#   _enforceConflicts). Neither mod sets "experimental", so the loader enables
#   both, the new one is failed for the conflict it declared, and the player
#   carries on running the old copy with nothing to say so.
#
# These folders are pak-owned -- this project put them there -- so they are
# removed outright, the same call taken for the v0.1.0 ROM folder above.
# Mirrors contracts.legacy_mod_ids in upstream.lock; verify.sh asserts the two
# agree. There is no jq on the device and the lock is not shipped, so the ids
# are spelled out here.
LEGACY_MODS="DRAMATIC_SHAPE"

for id in $LEGACY_MODS; do
    [ -d "$GAME/mods/$id" ] || continue
    echo "legacy    removing $id, which this pak no longer ships:"
    echo "legacy      $GAME/mods/$id"
    if rm -rf "$GAME/mods/$id" 2>/dev/null; then
        echo "legacy    removed. Leaving it would have disabled the mod that replaced it."
    else
        echo "legacy    WARNING: could not remove it. Delete it by hand, or the voxel mod"
        echo "legacy    will lose its own conflict check and fail to load."
    fi
done

# A copy the PLAYER installed is theirs, not ours -- report it and stop there.
# The engine looks for mods in the save directory as well as the game folder, so
# one here has exactly the same effect on the conflict check.
for id in $LEGACY_MODS; do
    [ -d "$SAVEROOT/mods/$id" ] || continue
    echo "legacy    you have your own copy of $id installed:"
    echo "legacy      $SAVEROOT/mods/$id"
    echo "legacy    It is not ours to delete, but the bundled voxel mod declares a"
    echo "legacy    conflict with it and will be the one that fails to load. Remove or"
    echo "legacy    disable it from the in-game mod manager to use the bundled mod."
done

# --- mods the player dropped in by hand ------------------------------------
# $PAK_DIR/mods is the one folder the engine already watches. adoptStrays()
# scans SaveData.gameFolders() -- getSource() and getSourceBaseDirectory() on
# Linux -- once per session just before the MODS listing, and COPIES what it
# finds into the save dir. We exec love.aarch64 with $PAK_DIR/game, so the first
# of those is game/ (skipped, already on the read path) and the second is
# $PAK_DIR itself.
#
# build.sh ships this folder with a README.txt in it; recreate the folder if a
# player deleted it, but never rewrite the note -- the text lives in build.sh.
# Nothing is copied here: adoption is the engine's job, and doing it ourselves
# would race its "already installed wins" rule.
MODDROP="$PAK_DIR/mods"
mkdir -p "$MODDROP" 2>/dev/null || echo "mods      WARNING: $MODDROP is not writable"

# Report only. A mod that never appears in-game is otherwise undiagnosable
# without a device trip, and the two mistakes below are the likely ones.
for entry in "$MODDROP"/*; do
    [ -e "$entry" ] || continue          # unmatched glob
    name="${entry##*/}"
    [ "$name" = "README.txt" ] && continue
    if [ -d "$entry" ]; then
        if [ -f "$entry/manifest.json" ]; then
            echo "mods      hand-installed mod ready to import: $name"
        else
            # The usual slip: unzipping produced mods/Foo/Foo/manifest.json.
            # Checked with a loop, not `[ -f "$entry"/*/... ]` -- an unmatched
            # glob passes the literal pattern to test, and a multi-match makes
            # it a syntax error.
            nested=0
            for sub in "$entry"/*/manifest.json; do
                [ -f "$sub" ] && nested=1
            done
            if [ "$nested" = 1 ]; then
                echo "mods      WARNING: $name is nested one level too deep"
                echo "mods        manifest.json must sit directly in $MODDROP/$name/"
            else
                echo "mods      WARNING: $name has no manifest.json; the game will ignore it"
            fi
        fi
    else
        case "$name" in
            *.zip) echo "mods      WARNING: $name is still zipped; unzip it into its own folder" ;;
            *)     echo "mods      WARNING: $name is a loose file; mods go in their own folder" ;;
        esac
    fi
done

# --- the mod catalogue, seeded once ----------------------------------------
# The engine ships no catalogue and asks the player to add one, because adding
# an index means trusting whoever publishes it (src/mods/ModIndex.lua). That is
# a sound default, but the "ask" costs a URL typed on a d-pad keyboard, and the
# official index is published by the engine's own author -- so this pak enters
# it once and leaves the choice alone thereafter.
#
# ONLY on a genuinely fresh install, and the .bak/.tmp test is not paranoia:
# SaveData.loadOptions RECOVERS from those copies when options.lua is missing
# (a guard added after an interrupted rewrite lost people every setting they
# had). Writing our file on a card that still holds a backup would step in
# front of that recovery and destroy the lot. Where no options file exists at
# all, a partial one is safe -- loadOptions merges whatever it reads over the
# defaults.
#
# Seeded once, never re-added: delete the index in-game and it stays deleted,
# because options.lua exists by then.
#
# The four URLs mirror ModIndex.resolveSource's own expansion of "owner/repo".
# Kept as a contract in upstream.lock (contracts.mod_index) so verify.sh can
# catch this copy drifting from it.
#
# THE "[1] =" IS LOAD-BEARING. options.lua is not read by Lua: the engine parses
# it with src/core/SaveSerializer.lua, a restricted reader that accepts only
# `ident = value` or `[key] = value` and fails on a positional entry. Writing
# the list element as a bare "{" cost a release-blocking bug -- the file failed
# to parse ("parse error at byte 31: expected key"), loadOptions fell back to
# defaults, and the engine then wrote that full snapshot back, erasing the seed
# and logging nothing a player would ever see. verify.sh now decodes this exact
# file with the engine's own parser.
MOD_INDEX_OWNER="bryanthaboi"
MOD_INDEX_REPO="gen1recomp-mod-index"

OPTS="$SAVEROOT/options.lua"
if [ ! -e "$OPTS" ] && [ ! -e "$OPTS.bak" ] && [ ! -e "$OPTS.tmp" ]; then
    if mkdir -p "$SAVEROOT" 2>/dev/null && cat > "$OPTS" <<EOF
return {
  modIndexes = {
    [1] = {
      url = "$MOD_INDEX_OWNER/$MOD_INDEX_REPO",
      feed = "https://$MOD_INDEX_OWNER.github.io/$MOD_INDEX_REPO/data/index.json",
      base = "https://$MOD_INDEX_OWNER.github.io/$MOD_INDEX_REPO/",
      fallback = "https://raw.githubusercontent.com/$MOD_INDEX_OWNER/$MOD_INDEX_REPO/main/site/data/index.json",
      label = "$MOD_INDEX_OWNER/$MOD_INDEX_REPO",
    },
  },
}
EOF
    then
        echo "mods      fresh install: added the official mod catalogue to Find mods"
        echo "mods        $MOD_INDEX_OWNER/$MOD_INDEX_REPO"
        echo "mods      Remove it in-game if you would rather not browse it; it is not re-added."
    else
        echo "mods      could not seed the mod catalogue (continuing without it)"
        rm -f "$OPTS" 2>/dev/null
    fi
fi

# Diagnostic hook, NOT a feature.
#
# If a .love archive is sitting at the root of the state directory, run that
# instead of the bundled game. This exists so test/smoke/ can exercise
# Section A through the real launch path -- the only way to see GLES context
# creation and the controller's true GUID, since running LOVE from an adb shell
# would fight the frontend for the display.
#
# It lives in the state dir because a Tool pak is launched with no arguments:
# there is no longer an entry to select, so the diagnostic has to be discovered.
# verify-device.sh pushes it, runs it, and removes it again.
#
# This pak is Gen1Recomp-specific and makes no promise about arbitrary LOVE games:
# no per-game save isolation, no controller profiles, nothing. If you want a
# general-purpose LOVE runtime, Section A is the part worth lifting into one.
DIAG=""
for f in "$STATE"/*.love; do
    [ -f "$f" ] && { DIAG="$f"; break; }
done
if [ -n "$DIAG" ]; then
    echo "diag      running $DIAG instead of the game"
    echo "diag      (diagnostics only -- arbitrary LOVE games are unsupported)"
    echo "diag      delete it from $STATE to get the game back"
    cd "$PAK_DIR" || exit 1
    # A child, not exec, for the same reason as the game launch below: the CPU
    # tuning above has already run, and exec would discard the trap that undoes it.
    "$PAK_DIR/bin/love.aarch64" "$DIAG"
    status=$?
    echo "diag      exited with status $status"
    exit "$status"
fi

[ -f "$GAME/main.lua" ] || { echo "FATAL: $GAME/main.lua is missing."; exit 1; }

# No shader env var is set here on purpose. POKEPORT_GBCFX used to pin GBC FX
# off, because it compiled its present pass on this GPU class and then showed a
# black frame (upstream issue #136); upstream deleted that module after 0.2.20.
# Its replacement, ShaderFX, is held off by the performance tier instead --
# arm64 Linux resolves to "low", whose caps set shaderfx false. See
# contracts.shaderfx in upstream.lock; verify.sh asserts it.

# --- one-time ROM import ---------------------------------------------------
# Gen1Recomp needs a cartridge dump exactly once: it verifies the ROM, decodes
# its data into a private cache, and never reads the ROM again. So rather than
# asking the player to copy a dump into some pak-internal folder, look in the
# Game Boy folders they already use and copy the first match across.
#
# The player's own files are only ever read -- never moved, renamed or modified.
#
# Matched by SHA-256, not the SHA-1 upstream publishes. These devices ship
# sha256sum and md5sum but NO sha1sum (verified on a Trimui Brick, 2026-08-11),
# so a SHA-1 scan silently matched nothing at all. The constants below were
# cross-checked against real Red and Blue dumps on-device.
#
# The scan is only a convenience pre-filter: the engine still performs its own
# authoritative SHA-1 check at import time. So even a wrong constant here fails
# safe -- the player lands on Choose ROM rather than importing wrong data.
# Where the engine actually looks on Linux.
#
# NOT baseroms/ -- that scan is gated behind `baseRomDiscovery`, which
# RomImporter.lua sets to `opts.launcher and Platform.isUWP()`, i.e. Xbox only.
# On Linux the engine tries zenity/kdialog (absent here), then falls back to
# findPendingRom(), which scans the PhysFS root for a 1 MiB .gb/.gbc. LOVE mounts
# the save directory into that root, so a dump dropped at the top of the save dir
# is found; anything in a subfolder is invisible. SAVEROOT is set at the top of
# this section.
# Every version the engine can import: id, display label, and the SHA-256 of the
# canonical US dump.
#
# ONE table. The version set, the staged-dump match, the scan match and the
# "accepted dumps" listing further down are all derived from it. Those used to be
# four parallel lists kept in step by hand, which is precisely what hid Gold: it
# reached some of them and not others, and the scan reported nothing wrong.
# Adding Crystal is now one line here plus one entry in upstream.lock.
#
# SHA-256, not the SHA-1 upstream publishes. These devices ship sha256sum and
# md5sum but NO sha1sum (verified on a Trimui Brick, 2026-08-11), so the original
# SHA-1 scan matched nothing at all -- silently. Every value here was taken from a
# real cartridge dump and cross-checked on-device against that version's SHA-1 in
# GameVersion.lua. verify.sh asserts they match contracts.rom_sha256.
#
# A wrong value fails SAFE: the engine still runs its own SHA-1 check at import
# time, so the player lands on Choose ROM rather than on bad data.
#
# Gen 1 carts are 1 MiB and Gen 2 (Gold, Silver) are 2 MiB. Both sizes are
# accepted by the filter in the scan below -- a 1 MiB-only filter is what made a
# Gold dump invisible when Gold first appeared.
ROM_TABLE="red Red 5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b
blue Blue 2a951313c2640e8c2cb21f25d1db019ae6245d9c7121f754fa61afd7bee6452d
yellow Yellow 8cbaa499397e4f1a679c992ea9382a2dd7942ab398b48c19829c2d9529de47bf
gold Gold fb0016d27b1e5374e1ec9fcad60e6628d8646103b5313ca683417f52b97e7e4e
silver Silver 72b190859a59623cbef6c49d601f8de52c1d2331b4f08a8d2acc17274fc19a8c"

# rom_match -- with $_sha_want set, echo "<id> <label>" for a known dump, else
# fail. It reads a global instead of taking a parameter on purpose: verify.sh
# forbids $1/$@/$* anywhere in launch.sh, because a Tool pak is invoked with no
# arguments and reading one was a real bug in the Emu layout. That check cannot
# tell a positional parameter inside a helper from a launch argument, and the
# check is worth more than the nicer signature.
#
# Fed by redirection, never a pipe: a `while read` on the right of a pipe runs in
# a subshell, and every assignment made inside it would be discarded.
rom_match() {
    while read -r _id _label _sha; do
        [ -n "$_id" ] || continue
        if [ "$_sha" = "$_sha_want" ]; then
            printf '%s %s' "$_id" "$_label"
            return 0
        fi
    done <<ROMTABLE
$ROM_TABLE
ROMTABLE
    return 1
}

VERSIONS=""
while read -r _id _label _sha; do
    [ -n "$_id" ] || continue
    VERSIONS="$VERSIONS$_id "
done <<ROMTABLE
$ROM_TABLE
ROMTABLE

# Which versions already have a dump staged at the save-dir root.
#
# THE TEST IS THE STAGED DUMP, AND DELIBERATELY NOT THE ENGINE'S CACHE. This gate
# used to check $SAVEROOT/<v>/data/generated or rom-cache.complete -- a hand copy
# of the engine's cache contract. That contract MOVES. Gen1Recomp 0.2.x added new
# entries to CacheContract.REQUIRED_FILES, so caches built by 0.1.98 became
# incomplete, CacheContract.isReady() correctly went false, and the engine asked
# for those ROMs again -- while this gate still saw the old directory, logged
# "every version already imported" and skipped the scan. Measured on a Brick,
# 2026-08-31, upgrading 0.1.98 -> 0.2.43: blue was short 2 required files,
# yellow 4, gold 9. Red had already been rebuilt and was short none.
#
# We cannot track a contract that changes every few upstream releases, and
# guessing at it is how you stranded someone. What we CAN guarantee is the one
# thing the engine needs to heal itself: a dump it can re-import. So a version
# counts as present when its dump is staged, and never otherwise.
#
# The engine ignores a staged dump for a version it has already imported
# (findPendingRom takes the first NOT-ready one), so the only cost of leaving
# them there is the disk -- about 1 MiB per Gen 1 cart and 2 MiB per Gen 2 one.
# That buys automatic recovery from every future cache invalidation.
HAVE=" "
for f in "$SAVEROOT"/*.gb "$SAVEROOT"/*.gbc; do
    [ -f "$f" ] || continue
    _sha_want=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1)
    _m=$(rom_match) || continue
    HAVE="$HAVE${_m%% *} "
done

want_count=0
have_count=0
for v in $VERSIONS; do
    want_count=$((want_count + 1))
    case "$HAVE" in *" $v "*) have_count=$((have_count + 1)) ;; esac
done

# Staging is all this pak does. Whether a version is actually IMPORTED is the
# engine's call, and it can revoke that call: an engine update that adds entries
# to CacheContract.REQUIRED_FILES invalidates an older cache, and the version
# reappears on the launcher asking to be imported. That is upstream working as
# intended, not damage -- and it is why the gate above tracks dumps rather than
# caches. Say so here, because on the launcher screen it looks like data loss.
echo "rom       staging only; the engine decides what to import. After an engine"
echo "rom       update it may rebuild a version's data and ask for it again -- the"
echo "rom       dump stays staged, so picking that version once is all it needs."

if [ "$have_count" -eq "$want_count" ]; then
    echo "rom       a dump for every version is staged; skipping the scan"
elif ! command -v sha256sum >/dev/null 2>&1; then
    # Degrade rather than guess. Copying an unverified 1 MiB file into the import
    # folder would just make the engine reject it later with less explanation.
    echo "rom       sha256sum unavailable on this device; skipping the scan."
    echo "rom       Use the game's Choose ROM screen instead."
else
    _labels=""
    while read -r _id _label _sha; do
        [ -n "$_id" ] || continue
        _labels="$_labels/$_label"
    done <<ROMTABLE
$ROM_TABLE
ROMTABLE
    echo "rom       scanning for US ${_labels#/} dumps"
    ROMS="${ROMS_PATH:-${SDCARD_PATH:-/mnt/SDCARD}/Roms}"
    imported=0
    scanned=0
    # Import EVERY version found, not just the first. The engine keeps the three
    # games' data side by side and its launcher lets the player pick, so stopping
    # at the first hit would arbitrarily hide the others -- and since the scan runs
    # in alphabetical order, "first" would silently mean Blue over Red.
    # Which folder holds the player's dumps is their choice, not ours. NextUI maps
    # a ROM folder to a system by the tag in its LAST parentheses, falling back to
    # the whole folder name when there are none (utils.c:getEmuName) -- so
    # "Game Boy (GB)", "My Game Boy Stuff (GB)" and plain "GB" are all one system
    # to the frontend. Mirror that rule rather than hard-coding two display names:
    # this scan is now the only way a dump gets imported, and against a renamed
    # folder a hard-coded name finds nothing and says nothing is wrong.
    for dir in "$ROMS"/*; do
        [ -d "$dir" ] || continue
        tag="${dir##*/}"
        case "$tag" in
            *\(*\)*) tag="${tag##*\(}"; tag="${tag%%\)*}" ;;
        esac
        case "$tag" in
            GB|GBC|gb|gbc) ;;
            *) continue ;;
        esac
        echo "rom         looking in $dir"
        scanned=$((scanned + 1))
        for rom in "$dir"/*.gb "$dir"/*.gbc; do
            [ -f "$rom" ] || continue
            # Skip AppleDouble junk: a macOS "._cart.gb" ends in .gb and would
            # otherwise be hashed pointlessly.
            case "$(basename "$rom")" in ._*) continue ;; esac
            # The engine accepts exactly two sizes and nothing else: 1 MiB for the
            # Gen 1 carts and 2 MiB for Gen 2 (RomImporter.isAcceptedRomSize). So
            # no other size can be any known version. This reads no file contents,
            # and it keeps the hashing down -- on a real 90-ROM card it leaves
            # about 30 files, which matters because the scan repeats on every
            # launch until every version is in.
            #
            # 2 MiB is NOT optional: it is the whole reason a Gold dump was
            # invisible here when Gold first shipped. A 1 MiB-only filter skipped
            # it before its hash was ever computed, so the scan reported nothing
            # wrong. Keep this in step with the engine.
            #
            # find rather than stat(1), which the device does not ship: busybox
            # find reads the c suffix as exact bytes (confirmed on a Smart Pro S
            # and a Brick, including on a name full of spaces and brackets).
            #
            # Two separate invocations rather than one `-size A -o -size B`. The
            # single-size form is what has actually been run on device; the -o
            # form relies on find applying its implicit -print across an OR, which
            # is true of GNU find but has not been checked on this busybox. This
            # project has been bitten three times by assuming a tool behaves as it
            # does on a desktop (sha1sum, stat, setsid), and the failure mode here
            # is the silent one: every dump skipped, nothing logged.
            [ -n "$(find "$rom" -size 1048576c 2>/dev/null)" ] \
                || [ -n "$(find "$rom" -size 2097152c 2>/dev/null)" ] \
                || continue
            sha=$(sha256sum "$rom" 2>/dev/null | cut -d' ' -f1)
            _sha_want="$sha"
            _m=$(rom_match) || continue
            vid="${_m%% *}"; version="${_m#* }"
            # Already imported, or already staged from another folder: copying a
            # 1 MiB file the engine would only skip buys nothing.
            case "$HAVE" in *" $vid "*) continue ;; esac
            echo "rom       matched $version: $rom"
            mkdir -p "$SAVEROOT"
            if cp -f "$rom" "$SAVEROOT/$(basename "$rom")"; then
                imported=$((imported + 1))
                HAVE="$HAVE$vid "
            else
                echo "rom       WARNING: could not copy $version into the import folder"
            fi
        done
    done

    if [ "$imported" -gt 0 ]; then
        echo "rom       staged $imported dump(s) in $SAVEROOT"
        echo "rom       the engine decodes them on boot / via Choose ROM"
    else
        # Not an error. The game's own launcher has a Choose ROM screen with
        # on-screen instructions, which is a far better failure mode than exiting
        # to a black screen.
        if [ "$scanned" -eq 0 ]; then
            # Distinguish "your dump is not one of the three" from "there is
            # nowhere to look" -- the fixes are completely different.
            echo "rom       no Game Boy folder found under $ROMS. A folder counts"
            echo "rom       when its name ends in (GB) or (GBC), or is exactly GB"
            echo "rom       or GBC -- the same rule NextUI uses to pick an emulator."
        fi
        echo "rom       no match found. Starting the built-in launcher so you can"
        echo "rom       use its Choose ROM screen."
        echo "rom       Accepted dumps (US cartridges only), by SHA-256:"
        while read -r _id _label _sha; do
            [ -n "$_id" ] || continue
            printf 'rom         %-6s %s\n' "$_label" "$_sha"
        done <<ROMTABLE
$ROM_TABLE
ROMTABLE
        echo "rom       Check yours on the device with: sha256sum <file>"
    fi
fi

# --- launch ----------------------------------------------------------------
# On return, simply exit: NextUI's launch loop relaunches the frontend itself.
# Never remove /tmp/nextui_exec -- that is the poweroff signal.
cd "$GAME" || { echo "FATAL: cannot cd to $GAME"; exit 1; }
echo "launch    $PAK_DIR/bin/love.aarch64 $GAME"
echo "=== love output follows ==="

# Run love as a CHILD and exit normally afterwards. Emphatically not `exec`:
# exec replaces this shell, and a replaced shell cannot run `trap cleanup EXIT`.
# Everything cleanup() puts back was therefore never put back -- measured on a
# Brick, 2026-08-31, where the frequency ceiling stayed at the raised 2.0 GHz
# after the game exited, with only a zombie launch.sh left behind.
#
# On tg5040 the frontend largely masks that: NextUI's launch loop resets the
# governor and ceiling shortly after a pak returns. What it does NOT redo is
# which cores are ONLINE, and on tg5050 this pak brings up five that NextUI
# offlined at boot -- so those stayed up for the rest of the user's session,
# costing battery in every app afterwards. That is the leak this closes.
#
# Foreground, not `&` + `wait`. A signal arriving while a foreground command runs
# is held until that command completes (POSIX), and it is delivered to the whole
# foreground process group, so love sees it too, exits, and THEN the trap runs.
# Backgrounding would hand us the job of forwarding signals and reaping an
# orphan, for no gain.
#
# The cost is this shell staying resident while the game runs: 3.8 MB measured on
# the Brick. On a 1 GB device that is real but it is idle, so its pages are the
# first the kernel reclaims -- a fair price for not leaking CPU state.
"$PAK_DIR/bin/love.aarch64" "$GAME"
status=$?
echo "=== love exited with status $status ==="
exit "$status"
