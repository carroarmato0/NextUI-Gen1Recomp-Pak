#!/usr/bin/env bash
# Exercise launch.sh off-device against a fake SD card.
#
# This is the only part of launch.sh that can be tested without TrimUI hardware,
# and it is the part most likely to break: the ROM scan globs directories whose
# names contain spaces and parentheses ("Game Boy (GB)"), and the whole thing
# runs under busybox sh on the device.
#
# love.aarch64 is replaced by a stub that records its argv, so we verify what
# would have been launched without needing an aarch64 binary.
#
# Real cartridge dumps cannot be committed, and their SHA-1s cannot be forged, so
# the match path is tested by patching a copy of launch.sh to expect the hash of a
# generated fixture. The scan/copy/quoting logic under test is identical; only the
# constant differs.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

# Prefer a real POSIX shell. bash-as-sh hides bashisms that busybox would reject.
# shellcheck disable=SC2209  # the literal name of an interpreter, not a command substitution
SH=sh
for c in dash busybox ash; do
    if command -v "$c" >/dev/null 2>&1; then
        [ "$c" = busybox ] && SH="busybox sh" || SH="$c"
        break
    fi
done
echo "# shell under test: $SH"

ok()   { PASS=$((PASS+1)); printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; }
check() { if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }

# Build a throwaway SD card + installed pak. Echoes the sandbox root.
make_sandbox() {
    local sb; sb="$(mktemp -d)"
    mkdir -p "$sb/SDCARD/.userdata/shared" \
             "$sb/SDCARD/.userdata/tg5050/logs" \
             "$sb/SDCARD/Roms/Game Boy (GB)" \
             "$sb/SDCARD/Roms/Game Boy Color (GBC)" \
             "$sb/pak/bin" "$sb/pak/game"

    cp "$ROOT/launch.sh" "$sb/pak/launch.sh"
    chmod +x "$sb/pak/launch.sh"
    echo "-- stub" > "$sb/pak/game/main.lua"

    # Stub runtime: record argv and cwd instead of executing.
    cat > "$sb/pak/bin/love.aarch64" <<'STUB'
#!/bin/sh
echo "LOVE_ARGV: $*" > "$LOVE_STUB_OUT"
echo "LOVE_CWD: $PWD" >> "$LOVE_STUB_OUT"
STUB
    chmod +x "$sb/pak/bin/love.aarch64"
    echo "$sb"
}

run_launch() {
    local sb="$1"; shift
    LOVE_STUB_OUT="$sb/stub.out" \
    SDCARD_PATH="$sb/SDCARD" \
    ROMS_PATH="$sb/SDCARD/Roms" \
    SHARED_USERDATA_PATH="$sb/SDCARD/.userdata/shared" \
    USERDATA_PATH="$sb/SDCARD/.userdata/tg5050" \
    LOGS_PATH="$sb/SDCARD/.userdata/tg5050/logs" \
    PLATFORM="${TEST_PLATFORM:-tg5050}" \
    DEVICE=smartpros \
    $SH "$sb/pak/launch.sh" "$@" >/dev/null 2>&1
    return $?
}

log_of() { cat "$1/SDCARD/.userdata/tg5050/logs/Gen1Recomp.txt" 2>/dev/null; }

# Cartridge dumps staged in the save root. Counts dumps rather than every file,
# because launch.sh also seeds options.lua into this directory on a fresh
# install -- and these assertions have always been about how many dumps landed.
count_dumps() {
    find "$1" -maxdepth 1 -type f \( -name '*.gb' -o -name '*.gbc' \) 2>/dev/null | wc -l
}

# --------------------------------------------------------------------------
echo
echo "no ROM present -- must still launch, and say why"
SB="$(make_sandbox)"
run_launch "$SB"
grep -q "LOVE_ARGV: $SB/pak/game" "$SB/stub.out" 2>/dev/null
check $? "launches the game even with no ROM (never a black screen)"
log_of "$SB" | grep -q "no match found"
check $? "logs that no ROM matched"
log_of "$SB" | grep -q "5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b"
check $? "logs the accepted SHA-256s so the user can check their dump"
log_of "$SB" | grep -q "Game Boy (GB)"
check $? "logs which folders were searched"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "environment and state"
SB="$(make_sandbox)"
run_launch "$SB"
[ -d "$SB/SDCARD/.userdata/shared/Gen1Recomp" ]
check $? "creates its state dir under shared userdata, not in the pak"
grep -q "LOVE_CWD: $SB/pak/game" "$SB/stub.out" 2>/dev/null
check $? "runs with the game directory as cwd"
log_of "$SB" | grep -q "SwapTotal"
check $? "reports memory/swap state"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "swap hint fires only when there is no swap"
SB="$(make_sandbox)"
run_launch "$SB"
if [ "$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)" -eq 0 ]; then
    log_of "$SB" | grep -q "Install Swap.pak"
    check $? "points at Swap.pak when swap is absent"
else
    log_of "$SB" | grep -q "Install Swap.pak"
    if [ $? -eq 0 ]; then bad "suggested Swap.pak despite swap being present"
    else ok "stays quiet about Swap.pak when swap exists"; fi
fi
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "ROM scan matches by hash and copies into the import folder"
SB="$(make_sandbox)"
FIXTURE="$SB/SDCARD/Roms/Game Boy (GB)/Pokemon Red (USA).gb"
head -c 1048576 /dev/urandom > "$FIXTURE"
FIX_SHA="$(sha256sum "$FIXTURE" | cut -d' ' -f1)"
# Stand the fixture's hash in for Red's. Everything else -- the globbing over a
# path with spaces and parens, the ._ filter, the copy -- is the real code path.
#
# SHA-256, not SHA-1: the device ships no sha1sum, which is why the scan matches
# on sha256 (see upstream.lock contracts.rom_sha256).
sed -i "s/5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b/$FIX_SHA/" "$SB/pak/launch.sh"
# AppleDouble decoy, deliberately sorted ahead of the real dump.
printf 'junk' > "$SB/SDCARD/Roms/Game Boy (GB)/._Pokemon Red (USA).gb"

run_launch "$SB"
log_of "$SB" | grep -q "matched Red"
check $? "identifies the version by SHA-256 through a path with spaces and parens"
log_of "$SB" | grep -q "staged 1 dump"
check $? "reports how many dumps were imported"
[ -f "$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d/Pokemon Red (USA).gb" ]
check $? "stages the dump at the save-dir root, where findPendingRom looks"
[ -f "$FIXTURE" ] && [ "$(sha256sum "$FIXTURE" | cut -d' ' -f1)" = "$FIX_SHA" ]
check $? "leaves the user's own file untouched"
# The decoy sorts ahead of the real dump, so a naive scan would copy it. Assert
# on the import folder's actual contents rather than on log text, which would
# pass for the wrong reason.
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d"
[ -z "$(find "$BR" -name '._*' 2>/dev/null)" ] && [ "$(count_dumps "$BR")" -eq 1 ]
check $? "skips the AppleDouble decoy and imports exactly one file"

# A rerun must not re-stage the dump that is already sitting there waiting to be
# decoded. (It must still scan: see "imports a version added after an earlier
# one" below for why skipping outright is wrong.)
run_launch "$SB"
[ "$(count_dumps "$BR")" -eq 1 ]
check $? "a rerun leaves the already-staged dump alone"
rm -rf "$SB"

# --------------------------------------------------------------------------
# The scan is the only way a dump ever gets imported, so which folders it
# considers is load-bearing. NextUI resolves a ROM folder to a system by the tag
# in its last parentheses, or the whole name when there are none, so the display
# name in front of the tag is the player's to choose.
echo
echo "finds dumps in any folder NextUI would call GB or GBC"
for folder in "Nintendo Game Boy (GB)" "GB" "gbc" "Handhelds - Game Boy Color (GBC)"; do
    SB="$(make_sandbox)"
    mkdir -p "$SB/SDCARD/Roms/$folder"
    head -c 1048576 /dev/urandom > "$SB/SDCARD/Roms/$folder/cart.gb"
    SHA="$(sha256sum "$SB/SDCARD/Roms/$folder/cart.gb" | cut -d' ' -f1)"
    sed -i "s/5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b/$SHA/" "$SB/pak/launch.sh"
    run_launch "$SB"
    [ -f "$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d/cart.gb" ]
    check $? "imports from \"$folder\""
    rm -rf "$SB"
done

SB="$(make_sandbox)"
# "(GBA)" ends in a tag we do not want; "Game Boy Advance" has no parens at all,
# so getEmuName would return the whole name. Neither is ours to hash.
mkdir -p "$SB/SDCARD/Roms/Game Boy Advance (GBA)" "$SB/SDCARD/Roms/Game Boy Advance"
head -c 1048576 /dev/urandom > "$SB/SDCARD/Roms/Game Boy Advance (GBA)/x.gb"
run_launch "$SB"
log_of "$SB" | grep -q "looking in .*GBA"
if [ $? -eq 0 ]; then bad "scanned a GBA folder"; else ok "ignores folders tagged for other systems"; fi
rm -rf "$SB"

SB="$(make_sandbox)"
rm -rf "$SB/SDCARD/Roms/Game Boy (GB)" "$SB/SDCARD/Roms/Game Boy Color (GBC)"
run_launch "$SB"
log_of "$SB" | grep -q "no Game Boy folder found"
check $? "says so when there is nowhere to look, not just 'no match'"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "opt-out toggles"
SB="$(make_sandbox)"
mkdir -p "$SB/SDCARD/.userdata/shared/Gen1Recomp"
touch "$SB/SDCARD/.userdata/shared/Gen1Recomp/no-cpu-tuning"
run_launch "$SB"
log_of "$SB" | grep -q "tuning skipped"
check $? "no-cpu-tuning disables the CPU block (needed to A/B the audio fix)"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "missing payload fails loudly rather than silently"
SB="$(make_sandbox)"
rm -f "$SB/pak/bin/love.aarch64"
run_launch "$SB"
[ $? -ne 0 ] && log_of "$SB" | grep -q "FATAL"
check $? "exits non-zero with FATAL when the runtime is missing"
rm -rf "$SB"

SB="$(make_sandbox)"
rm -f "$SB/pak/game/main.lua"
run_launch "$SB"
[ $? -ne 0 ] && log_of "$SB" | grep -q "FATAL"
check $? "exits non-zero with FATAL when the game payload is missing"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "imports every version present, not just the first"
SB="$(make_sandbox)"
GB="$SB/SDCARD/Roms/Game Boy (GB)"
head -c 1048576 /dev/urandom > "$GB/Pokemon - Blue Version.gb"
head -c 1048576 /dev/urandom > "$GB/Pokemon - Red Version.gb"
B_SHA="$(sha256sum "$GB/Pokemon - Blue Version.gb" | cut -d' ' -f1)"
R_SHA="$(sha256sum "$GB/Pokemon - Red Version.gb" | cut -d' ' -f1)"
sed -i "s/2a951313c2640e8c2cb21f25d1db019ae6245d9c7121f754fa61afd7bee6452d/$B_SHA/" "$SB/pak/launch.sh"
sed -i "s/5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b/$R_SHA/" "$SB/pak/launch.sh"
run_launch "$SB"
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d"
[ "$(count_dumps "$BR")" -eq 2 ]
check $? "both dumps imported (Blue sorts first but must not hide Red)"
log_of "$SB" | grep -q "staged 2 dump"
check $? "reports both imports"
rm -rf "$SB"

# --------------------------------------------------------------------------
# Regression, found on a Smart Pro S (2026-08-12). The gate used to be
# all-or-nothing: one staged dump, or one decoded cache, skipped the entire scan
# for good. A player who imported Red and Blue and only later added a Yellow
# dump never got it -- the scan that would have matched it never ran again, and
# the log said "already imported" as if everything were fine.
echo
echo "imports a version added after an earlier one"
SB="$(make_sandbox)"
GB="$SB/SDCARD/Roms/Game Boy (GB)"
GBC="$SB/SDCARD/Roms/Game Boy Color (GBC)"
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d"
head -c 1048576 /dev/urandom > "$GB/Pokemon - Red Version.gb"
R_SHA="$(sha256sum "$GB/Pokemon - Red Version.gb" | cut -d' ' -f1)"
sed -i "s/5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b/$R_SHA/" "$SB/pak/launch.sh"
run_launch "$SB"
[ -f "$BR/Pokemon - Red Version.gb" ]
check $? "fixture: the first launch stages Red"

# The engine decodes Red on boot, writing its cache under red/. The staged dump
# stays where it is -- leaving it is deliberate (findPendingRom skips versions
# already imported), and it is exactly what tripped the old gate.
mkdir -p "$BR/red/data/generated"

# Only now does the player drop a Yellow dump onto the card.
head -c 1048576 /dev/urandom > "$GBC/Pokemon - Yellow Version.gbc"
Y_SHA="$(sha256sum "$GBC/Pokemon - Yellow Version.gbc" | cut -d' ' -f1)"
sed -i "s/8cbaa499397e4f1a679c992ea9382a2dd7942ab398b48c19829c2d9529de47bf/$Y_SHA/" "$SB/pak/launch.sh"
run_launch "$SB"
[ -f "$BR/Pokemon - Yellow Version.gbc" ]
check $? "stages a dump added after an earlier version was imported"
log_of "$SB" | grep -q "matched Yellow"
check $? "identifies it as Yellow"
log_of "$SB" | grep -q "matched Red"
if [ $? -eq 0 ]; then bad "re-staged Red, which the engine had already decoded"
else ok "leaves the already-decoded Red alone"; fi
[ "$(count_dumps "$BR")" -eq 2 ]
check $? "ends up with exactly the two dumps, Red staged and Yellow added"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "stops scanning only when there is genuinely nothing left to import"
SB="$(make_sandbox)"
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d"
# Every version launch.sh knows about, read from launch.sh itself rather than
# listed here: this test is about "all of them", and hard-coding three is what
# made the scan stop before it ever looked for Gold.
ALL_VERSIONS="$(sed -n 's/^VERSIONS="\(.*\)"/\1/p' "$ROOT/launch.sh")"
# shellcheck disable=SC2086  # deliberate word split: VERSIONS is a space-separated list
for v in $ALL_VERSIONS; do
    mkdir -p "$BR/$v/data/generated"
done
# Either marker counts: the engine writes rom-cache.complete beside the
# generated data (RomImporter.lua MARKER_PATH, CacheFs.lua:425).
rm -rf "$BR/yellow/data"; mkdir -p "$BR/yellow"; touch "$BR/yellow/rom-cache.complete"
head -c 1048576 /dev/urandom > "$SB/SDCARD/Roms/Game Boy (GB)/cart.gb"
run_launch "$SB"
log_of "$SB" | grep -q "every version already imported"
check $? "skips the scan once every version is imported"
log_of "$SB" | grep -q "looking in"
if [ $? -eq 0 ]; then bad "hashed ROM folders with nothing left to import"
else ok "hashes nothing when there is nothing left to import"; fi
rm -rf "$SB"

# --------------------------------------------------------------------------
# The engine refuses anything that is not exactly 1 MiB (findPendingRom checks
# #data == 1024*1024), so staging one would only produce a file it silently
# ignores. Skipping them by size also keeps the now-repeating scan cheap: on a
# real card it takes the hashing from 90 files down to 20.
echo
echo "ignores files that cannot be a cartridge dump"
SB="$(make_sandbox)"
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d"
head -c 524288 /dev/urandom > "$SB/SDCARD/Roms/Game Boy (GB)/homebrew.gb"
H_SHA="$(sha256sum "$SB/SDCARD/Roms/Game Boy (GB)/homebrew.gb" | cut -d' ' -f1)"
# Even with a hash the scan would otherwise accept.
sed -i "s/2a951313c2640e8c2cb21f25d1db019ae6245d9c7121f754fa61afd7bee6452d/$H_SHA/" "$SB/pak/launch.sh"
run_launch "$SB"
[ ! -f "$BR/homebrew.gb" ]
check $? "does not stage a file of the wrong size"
rm -rf "$SB"

# --------------------------------------------------------------------------
# Gen 2 carts are 2 MiB, and the size pre-filter used to accept only 1 MiB. A
# Gold dump was therefore skipped before its hash was ever computed, so the scan
# found nothing and reported nothing wrong. Confirmed on a Brick, 2026-08-13:
# the log said "all three versions already imported" with a Gold dump sitting in
# the GBC folder. The engine accepts both sizes (RomImporter.isAcceptedRomSize).
echo
echo "imports a 2 MiB Gen 2 dump (Gold), not just 1 MiB Gen 1 ones"
SB="$(make_sandbox)"
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d"
GBC="$SB/SDCARD/Roms/Game Boy Color (GBC)"
head -c 2097152 /dev/urandom > "$GBC/Pokemon - Gold Version.gbc"
G_SHA="$(sha256sum "$GBC/Pokemon - Gold Version.gbc" | cut -d' ' -f1)"
sed -i "s/fb0016d27b1e5374e1ec9fcad60e6628d8646103b5313ca683417f52b97e7e4e/$G_SHA/" "$SB/pak/launch.sh"
run_launch "$SB"
[ -f "$BR/Pokemon - Gold Version.gbc" ]
check $? "stages a 2 MiB Gold dump"
log_of "$SB" | grep -q "matched Gold"
check $? "identifies it as Gold"
# And the scan must not declare itself finished while Gold is still missing.
rm -rf "$SB"
SB="$(make_sandbox)"
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d"
mkdir -p "$BR/red/data/generated" "$BR/blue/data/generated" "$BR/yellow/data/generated"
run_launch "$SB"
log_of "$SB" | grep -q "every version already imported"
if [ $? -eq 0 ]; then bad "called it done with Gold still not imported"
else ok "keeps scanning while a known version is still missing"; fi
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo ".love diagnostic hook (state dir, since a Tool pak gets no arguments)"
SB="$(make_sandbox)"
mkdir -p "$SB/SDCARD/.userdata/shared/Gen1Recomp"
printf 'not-really-a-zip' > "$SB/SDCARD/.userdata/shared/Gen1Recomp/_smoke.love"
run_launch "$SB"
grep -q "LOVE_ARGV: .*_smoke.love" "$SB/stub.out" 2>/dev/null
check $? "a .love in the state dir is run instead of the game"
log_of "$SB" | grep -q "diagnostics only"
check $? "logs that the hook is diagnostics-only, not a supported feature"
rm -rf "$SB"

SB="$(make_sandbox)"
run_launch "$SB"
grep -q "LOVE_ARGV: $SB/pak/game" "$SB/stub.out" 2>/dev/null
check $? "an empty state dir runs the bundled game (the unexpanded glob is not a file)"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "the v0.1.0 ROM folder is removed; the old Emu pak is only reported"
SB="$(make_sandbox)"
mkdir -p "$SB/SDCARD/Emus/tg5050/Gen1Recomp.pak" \
         "$SB/SDCARD/Roms/Gen1Recomp (Gen1Recomp)/.media"
: > "$SB/SDCARD/Roms/Gen1Recomp (Gen1Recomp)/Gen1Recomp.g1r"
printf 'art' > "$SB/SDCARD/Roms/Gen1Recomp (Gen1Recomp)/.media/Gen1Recomp.png"
run_launch "$SB"
[ ! -d "$SB/SDCARD/Roms/Gen1Recomp (Gen1Recomp)" ]
check $? "removes the ROM folder outright, contents included"
log_of "$SB" | grep -q "removed. Saves are untouched"
check $? "says in the log that it removed it"
[ -d "$SB/SDCARD/Emus/tg5050/Gen1Recomp.pak" ]
check $? "leaves the old Emu pak in place -- removing a whole pak is not ours to assume"
log_of "$SB" | grep -q "Emus/tg5050/Gen1Recomp.pak"
check $? "names the old Emu pak so it can be reclaimed"
# Deleting the ROM folder must never reach the save directory.
[ -d "$SB/SDCARD/.userdata/shared/Gen1Recomp" ]
check $? "saves are untouched"
rm -rf "$SB"

SB="$(make_sandbox)"
# A card that never had v0.1.0 must not see any of this.
run_launch "$SB"
log_of "$SB" | grep -q "^legacy"
if [ $? -eq 0 ]; then bad "warned about a legacy install that is not there"
else ok "stays quiet on a clean card"; fi
rm -rf "$SB"

# --------------------------------------------------------------------------
# A pak update merges over the old install, so the mod this pak used to ship is
# still sitting in game/mods/ afterwards. Left there it disables the mod that
# replaced it -- the new mod declares the conflict, and the declaring mod loses.
echo
echo "a mod this pak no longer ships is removed from the pak, reported in the save dir"
SB="$(make_sandbox)"
mkdir -p "$SB/pak/game/mods/DRAMATIC_SHAPE"
printf 'stale' > "$SB/pak/game/mods/DRAMATIC_SHAPE/main.lua"
mkdir -p "$SB/pak/game/mods/DRAMALESS_SHAPE"
printf 'current' > "$SB/pak/game/mods/DRAMALESS_SHAPE/main.lua"
run_launch "$SB"
[ ! -d "$SB/pak/game/mods/DRAMATIC_SHAPE" ]
check $? "removes the superseded mod from the pak"
[ -d "$SB/pak/game/mods/DRAMALESS_SHAPE" ]
check $? "leaves the mod that replaced it alone"
log_of "$SB" | grep -q "removing DRAMATIC_SHAPE"
check $? "says in the log which mod it removed"
rm -rf "$SB"

SB="$(make_sandbox)"
# The player's own install is theirs. Report the consequence, delete nothing.
mkdir -p "$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d/mods/DRAMATIC_SHAPE"
run_launch "$SB"
[ -d "$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d/mods/DRAMATIC_SHAPE" ]
check $? "never deletes a copy the player installed themselves"
log_of "$SB" | grep -q "you have your own copy of DRAMATIC_SHAPE"
check $? "warns that the bundled mod will lose the conflict"
rm -rf "$SB"

# --------------------------------------------------------------------------
# The mod catalogue is entered once, on a fresh install, and must never step in
# front of the engine's own options recovery.
echo
echo "the mod catalogue is seeded once, and never over a recoverable options file"
SAVE_REL=".userdata/shared/Gen1Recomp/love/pokemon-love2d"

SB="$(make_sandbox)"
run_launch "$SB"
OPTS="$SB/SDCARD/$SAVE_REL/options.lua"
[ -f "$OPTS" ]
check $? "writes an options.lua on a fresh install"
grep -q 'bryanthaboi/gen1recomp-mod-index' "$OPTS" 2>/dev/null
check $? "seeds the official catalogue"
grep -q 'feed = "https://bryanthaboi.github.io/gen1recomp-mod-index/data/index.json"' "$OPTS" 2>/dev/null
check $? "expands the feed URL the way ModIndex.resolveSource does"
# Decode it with the ENGINE'S OWN parser, not with Lua and not by eye.
# options.lua is read by src/core/SaveSerializer.lua, a restricted reader that
# rejects positional table entries -- and asserting on the text we wrote is
# exactly what let a bare "{" ship: every text check passed while the engine
# failed at byte 31, fell back to defaults, and erased the seed.
SER="$ROOT/build/Gen1Recomp.pak/game/src/core/SaveSerializer.lua"
if [ -f "$SER" ] && command -v lua >/dev/null 2>&1; then
    lua -e '
      package.path = "'"$ROOT/build/Gen1Recomp.pak/game"'/?.lua;" .. package.path
      local S = dofile("'"$SER"'")
      local f = assert(io.open("'"$OPTS"'", "r"))
      local body = f:read("*a"); f:close()
      local t, err = S.decode(body)
      if not t then error("engine parser rejected options.lua: " .. tostring(err)) end
      local rows = t.modIndexes
      assert(type(rows) == "table", "modIndexes missing")
      assert(type(rows[1]) == "table", "modIndexes[1] is not a table -- positional entry lost")
      assert(type(rows[1].feed) == "string", "row.feed must be a string or ModIndex.sources() drops it")
    ' >/dev/null 2>&1
    check $? "the engine's own SaveSerializer decodes it, with a usable modIndexes[1].feed"
else
    echo "  --   engine parser check skipped (need lua and a staged build)"
fi
log_of "$SB" | grep -q "added the official mod catalogue"
check $? "says so in the log rather than doing it silently"
rm -rf "$SB"

SB="$(make_sandbox)"
# Second launch: the player may have deleted the index. Never re-add it.
mkdir -p "$SB/SDCARD/$SAVE_REL"
printf 'return {\n  musicVol = 3,\n}\n' > "$SB/SDCARD/$SAVE_REL/options.lua"
run_launch "$SB"
grep -q 'modIndexes' "$SB/SDCARD/$SAVE_REL/options.lua"
if [ $? -eq 0 ]; then bad "re-added the catalogue over an existing options.lua"
else ok "leaves an existing options.lua alone"; fi
grep -q 'musicVol = 3' "$SB/SDCARD/$SAVE_REL/options.lua"
check $? "does not disturb settings already there"
rm -rf "$SB"

SB="$(make_sandbox)"
# The hazard: options.lua missing but a backup present. SaveData.loadOptions
# heals from .bak, so writing ours here would destroy every setting.
mkdir -p "$SB/SDCARD/$SAVE_REL"
printf 'return {\n  musicVol = 5,\n}\n' > "$SB/SDCARD/$SAVE_REL/options.lua.bak"
run_launch "$SB"
[ ! -e "$SB/SDCARD/$SAVE_REL/options.lua" ]
check $? "writes nothing when only a .bak survives, so recovery still runs"
[ -f "$SB/SDCARD/$SAVE_REL/options.lua.bak" ]
check $? "leaves the backup untouched"
rm -rf "$SB"

SB="$(make_sandbox)"
mkdir -p "$SB/SDCARD/$SAVE_REL"
printf 'return {}\n' > "$SB/SDCARD/$SAVE_REL/options.lua.tmp"
run_launch "$SB"
[ ! -e "$SB/SDCARD/$SAVE_REL/options.lua" ]
check $? "writes nothing when only a staged .tmp survives"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
# --------------------------------------------------------------------------
echo
echo "mods dropped into the pak's mods/ folder by hand"

SB="$(make_sandbox)"
rm -rf "$SB/pak/mods"
run_launch "$SB"
[ -d "$SB/pak/mods" ]
check $? "creates the drop folder if a player deleted it"
rm -rf "$SB"

SB="$(make_sandbox)"
# build.sh ships the note; launch.sh must not rewrite it. Stand in for it here.
mkdir -p "$SB/pak/mods"
echo "shipped note" > "$SB/pak/mods/README.txt"
mkdir -p "$SB/pak/mods/CoolMod"
echo '{"id":"CoolMod"}' > "$SB/pak/mods/CoolMod/manifest.json"
run_launch "$SB"
log_of "$SB" | grep -q "hand-installed mod ready to import: CoolMod"
check $? "reports a valid hand-installed mod"
[ "$(cat "$SB/pak/mods/README.txt")" = "shipped note" ]
check $? "does not rewrite the shipped README.txt"
log_of "$SB" | grep -q "README.txt"
if [ $? -eq 0 ]; then bad "warned about its own README.txt"
else ok "does not mistake README.txt for a mod"; fi
# Adoption is the engine's job -- launch.sh must not pre-empt its
# "already installed wins" rule by copying anything itself.
[ ! -e "$SB/SDCARD/$SAVE_REL/mods/CoolMod" ]
check $? "copies nothing into the save dir (adoption is the engine's)"
[ -f "$SB/pak/mods/CoolMod/manifest.json" ]
check $? "leaves the player's files where they put them"
rm -rf "$SB"

SB="$(make_sandbox)"
mkdir -p "$SB/pak/mods"
echo "PK" > "$SB/pak/mods/SomeMod.zip"
run_launch "$SB"
log_of "$SB" | grep -q "SomeMod.zip is still zipped"
check $? "warns about a mod left zipped"
rm -rf "$SB"

SB="$(make_sandbox)"
mkdir -p "$SB/pak/mods/Outer/Inner"
echo '{"id":"Inner"}' > "$SB/pak/mods/Outer/Inner/manifest.json"
run_launch "$SB"
log_of "$SB" | grep -q "Outer is nested one level too deep"
check $? "warns about a mod unzipped one level too deep"
rm -rf "$SB"

SB="$(make_sandbox)"
mkdir -p "$SB/pak/mods/NotAMod"
echo "junk" > "$SB/pak/mods/NotAMod/readme.md"
run_launch "$SB"
log_of "$SB" | grep -q "NotAMod has no manifest.json"
check $? "warns about a folder with no manifest.json"
rm -rf "$SB"

SB="$(make_sandbox)"
mkdir -p "$SB/pak/mods"
run_launch "$SB"
# Scoped to mods lines: the sandbox ships no CA bundle, so the log
# legitimately carries an unrelated "tls WARNING".
log_of "$SB" | grep -q "^mods .*WARNING"
if [ $? -eq 0 ]; then bad "warned about an empty drop folder"
else ok "stays quiet when the drop folder is empty"; fi
rm -rf "$SB"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
