#!/bin/sh
# Gen1Recomp.pak -- NextUI Emu pak launcher (tg5040 / tg5050)
#
# POSIX sh on purpose, NOT bash. On cards that have had PortMaster installed,
# /bin/bash can be a symlink into PortMaster's vendored bin, so a bash shebang
# would quietly reintroduce the dependency this pak exists to avoid.
#
# NextUI invokes this as:  launch.sh '<path to the selected ROM-folder entry>'
# The entry is a 0-byte stub (Gen1Recomp.g1r); the real payload lives here in
# the pak. NextUI cannot launch a directory, which is why a stub file exists.
#
# Section A is the generic LOVE 11.5 runtime bring-up and is deliberately free
# of any Gen1Recomp knowledge, so it can be lifted into a generic LOVE pak.
# Section B is everything specific to this game.

PAK_DIR="$(cd "$(dirname "$0")" && pwd)"
ENTRY="${1:-}"

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
echo "entry     ${ENTRY:-<none>}"

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
# love.aarch64 needs only libc plus the bundled liblove/libluajit. liblove's
# remaining dependencies come from the firmware: SDL2 and mpg123 from
# /usr/trimui/lib, and freetype, openal, theoradec, vorbisfile, z and stdc++
# from /usr/lib. Nothing else has to be shipped.
#
# Keep the original path: system helpers spawned below load libmsettings.so from
# .system/lib, which a game-first override would shadow.
ORIG_LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$PAK_DIR/libs.aarch64:/usr/trimui/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

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
# CPU state is restored here, not left to the frontend. Measured on a Brick: after
# the game exits, the governor was still schedutil with the ceiling we raised --
# NextUI does not put it back, so without this the pak silently changes how the
# device behaves for everything the player does afterwards.
CPU_SAVED=""
save_cpu_state() {
    for pol in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$pol" ] || continue
        CPU_SAVED="$CPU_SAVED$pol	$(cat "$pol/scaling_governor" 2>/dev/null)	$(cat "$pol/scaling_max_freq" 2>/dev/null)	$(cat "$pol/scaling_min_freq" 2>/dev/null)
"
    done
}
restore_cpu_state() {
    [ -n "$CPU_SAVED" ] || return 0
    printf '%s' "$CPU_SAVED" | while IFS="$(printf '\t')" read -r pol gov mx mn; do
        [ -d "$pol" ] || continue
        # Floor before ceiling on the way back down, mirroring the order used when
        # raising them: a min above the incoming max is rejected by the driver.
        [ -n "$mn" ] && echo "$mn" > "$pol/scaling_min_freq" 2>/dev/null
        [ -n "$mx" ] && echo "$mx" > "$pol/scaling_max_freq" 2>/dev/null
        [ -n "$gov" ] && echo "$gov" > "$pol/scaling_governor" 2>/dev/null
    done
}

cleanup() {
    echo 0 > /sys/class/speaker/mute 2>/dev/null
    rm -f "$HOME/.asoundrc" 2>/dev/null
    restore_cpu_state
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
# UNVERIFIED: this GUID was taken from a working third-party implementation but
# has not been confirmed against real hardware here. test/smoke.love prints the
# name and GUID of every connected joystick -- run it and correct this if they
# disagree, otherwise the mapping silently does nothing.
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
# PROVISIONAL. On the nx-redux fork, the frontend leaves clocks capped low and
# cores hotplugged out at idle; at that clock LOVE starves its 48 kHz OpenAL
# mixer thread into XRUN underruns, which is audible as distortion. Raising every
# cluster's frequency ceiling and bringing all cores online fixes it.
#
# Stock NextUI already selects the 'performance' governor before running a pak,
# so this may be redundant here. Create the no-cpu-tuning file to skip the block
# and A/B the audio; if it is clean either way on stock NextUI, DELETE this
# section rather than carrying tuning nobody can justify.
#
# The governor is left on schedutil rather than pinned to performance: the clock
# still scales with load, which is cooler and easier on the battery, while still
# reaching full speed under the game's sustained load.
TASKSET=""
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

    # Big-core affinity is tg5050-only; tg5040 is a single cluster with nothing
    # to pin onto.
    if [ "${PLATFORM:-}" = "tg5050" ] && command -v taskset >/dev/null 2>&1; then
        TASKSET="taskset -c 4-7"
        echo "cpu       pinned to big cores (4-7)"
    fi
fi

# --- memory ----------------------------------------------------------------
# The voxel mod pushes peak usage to roughly 750 MB, and Brick and Smart Pro S
# have 1 GB total. Creating swap is Swap.pak's job, not ours -- we only point at
# it. Writing 512 MB into someone's internal storage without asking is not this
# pak's business.
SWAP_TOTAL=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
MEM_TOTAL=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
echo "memory    MemTotal ${MEM_TOTAL:-?} kB, SwapTotal ${SWAP_TOTAL:-?} kB"
if [ "${SWAP_TOTAL:-0}" -eq 0 ] 2>/dev/null; then
    echo "memory    no swap configured. The Dramatic Shape voxel mod peaks around"
    echo "memory    750 MB and may be OOM-killed on a 1 GB device. Install Swap.pak"
    echo "memory    and create 512 MB on INTERNAL storage if you want to enable it."
fi

###############################################################################
# Section B -- Gen1Recomp specifics
###############################################################################

GAME="$PAK_DIR/game"

# Diagnostic passthrough, NOT a feature.
#
# If the selected entry is a .love archive, run that instead of the bundled game.
# This exists so test/smoke.love can exercise Section A through the real launch
# path -- which is the only way to see GLES context creation and the controller's
# true GUID, since running LOVE from an adb shell would fight the frontend for
# the display.
#
# This pak is Gen1Recomp-specific and makes no promise about arbitrary LOVE games:
# no per-game save isolation, no controller profiles, nothing. If you want a
# general-purpose LOVE runtime, Section A is the part worth lifting into one.
case "$ENTRY" in
    *.love)
        if [ -f "$ENTRY" ]; then
            echo "diag      running .love passthrough: $ENTRY"
            echo "diag      (diagnostics only -- arbitrary LOVE games are unsupported)"
            cd "$PAK_DIR" || exit 1
            # shellcheck disable=SC2086
            exec $TASKSET "$PAK_DIR/bin/love.aarch64" "$ENTRY"
        fi
        echo "diag      entry looks like a .love but does not exist: $ENTRY"
        ;;
esac

[ -f "$GAME/main.lua" ] || { echo "FATAL: $GAME/main.lua is missing."; exit 1; }

# GBC FX compiles its present pass on this GPU class and then displays a black
# frame (upstream issue #136). Upstream's own RG34XXSP port disables it for the
# same reason. love.system.getOS() returns "Linux" here, so upstream's Android
# gate does not fire on its own. Setting this to 0 hides the OPTIONS row, pins
# the level off, and heals a level persisted from another machine.
export POKEPORT_GBCFX="${POKEPORT_GBCFX:-0}"

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
# is found; anything in a subfolder is invisible.
SAVEROOT="$STATE/love/pokemon-love2d"
GENERATED="$SAVEROOT/data/generated"
ROM_SHA256_RED=5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b
ROM_SHA256_BLUE=2a951313c2640e8c2cb21f25d1db019ae6245d9c7121f754fa61afd7bee6452d
ROM_SHA256_YELLOW=8cbaa499397e4f1a679c992ea9382a2dd7942ab398b48c19829c2d9529de47bf

rom_already_present() {
    # Decoded cache exists: nothing more to do, ever.
    [ -d "$GENERATED" ] && return 0
    # A dump is already staged where the engine looks. Leaving it there is
    # deliberate: findPendingRom() skips versions already imported, so it is inert
    # afterwards, and it lets the engine re-import if the cache is ever cleared.
    for f in "$SAVEROOT"/*.gb "$SAVEROOT"/*.gbc; do
        [ -f "$f" ] && return 0
    done
    return 1
}

if rom_already_present; then
    echo "rom       already imported; skipping the scan"
elif ! command -v sha256sum >/dev/null 2>&1; then
    # Degrade rather than guess. Copying an unverified 1 MiB file into the import
    # folder would just make the engine reject it later with less explanation.
    echo "rom       sha256sum unavailable on this device; skipping the scan."
    echo "rom       Use the game's Choose ROM screen instead."
else
    echo "rom       scanning for US Red/Blue/Yellow dumps"
    ROMS="${ROMS_PATH:-${SDCARD_PATH:-/mnt/SDCARD}/Roms}"
    imported=0
    # Import EVERY version found, not just the first. The engine keeps the three
    # games' data side by side and its launcher lets the player pick, so stopping
    # at the first hit would arbitrarily hide the others -- and since the scan runs
    # in alphabetical order, "first" would silently mean Blue over Red.
    for dir in "$ROMS/Game Boy (GB)" "$ROMS/Game Boy Color (GBC)"; do
        [ -d "$dir" ] || continue
        echo "rom         looking in $dir"
        for rom in "$dir"/*.gb "$dir"/*.gbc; do
            [ -f "$rom" ] || continue
            # Skip AppleDouble junk: a macOS "._cart.gb" ends in .gb and would
            # otherwise be hashed pointlessly.
            case "$(basename "$rom")" in ._*) continue ;; esac
            sha=$(sha256sum "$rom" 2>/dev/null | cut -d' ' -f1)
            case "$sha" in
                "$ROM_SHA256_RED")    version=Red ;;
                "$ROM_SHA256_BLUE")   version=Blue ;;
                "$ROM_SHA256_YELLOW") version=Yellow ;;
                *) continue ;;
            esac
            echo "rom       matched $version: $rom"
            mkdir -p "$SAVEROOT"
            if cp -f "$rom" "$SAVEROOT/$(basename "$rom")"; then
                imported=$((imported + 1))
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
        echo "rom       no match found. Starting the built-in launcher so you can"
        echo "rom       use its Choose ROM screen."
        echo "rom       Accepted dumps (1 MiB US cartridges only), by SHA-256:"
        echo "rom         Red    $ROM_SHA256_RED"
        echo "rom         Blue   $ROM_SHA256_BLUE"
        echo "rom         Yellow $ROM_SHA256_YELLOW"
        echo "rom       Check yours on the device with: sha256sum <file>"
    fi
fi

# --- launch ----------------------------------------------------------------
# On return, simply exit: NextUI's launch loop relaunches the frontend itself.
# Never remove /tmp/nextui_exec -- that is the poweroff signal.
cd "$GAME" || { echo "FATAL: cannot cd to $GAME"; exit 1; }
echo "launch    $TASKSET $PAK_DIR/bin/love.aarch64 $GAME"
echo "=== love output follows ==="
# shellcheck disable=SC2086
# TASKSET is intentionally word-split: it is either empty or "taskset -c 4-7".
exec $TASKSET "$PAK_DIR/bin/love.aarch64" "$GAME"
