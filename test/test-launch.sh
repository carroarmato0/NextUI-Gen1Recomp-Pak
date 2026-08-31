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
log_of "$SB" | grep -q "no recognised dump found"
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
# The pak REPORTS where your dumps are; it no longer copies them. Gen1Recomp
# 0.2.x opens its own file browser and never reaches findPendingRom, so a staged
# copy imports nothing. See contracts.rom_discovery in upstream.lock.
echo
echo "identifies dumps by hash and reports their path"
SB="$(make_sandbox)"
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d"
FIXTURE="$SB/SDCARD/Roms/Game Boy (GB)/Pokemon Red (USA).gb"
head -c 1048576 /dev/urandom > "$FIXTURE"
FIX_SHA="$(sha256sum "$FIXTURE" | cut -d' ' -f1)"
# Stand the fixture's hash in for Red's. Everything else -- globbing a path with
# spaces and parens, the ._ filter, the size filter -- is the real code path.
sed -i "s/5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b/$FIX_SHA/" "$SB/pak/launch.sh"
printf 'junk' > "$SB/SDCARD/Roms/Game Boy (GB)/._Pokemon Red (USA).gb"
run_launch "$SB"
log_of "$SB" | grep -q "Red  ->  .*Pokemon Red (USA).gb"
check $? "reports the version and full path, through spaces and parens"
log_of "$SB" | grep -q "Choose ROM browser"
check $? "says what the path is for"
# The point of the change: nothing is copied any more.
[ -z "$(find "$BR" -maxdepth 1 -name '*.gb' 2>/dev/null)" ]
check $? "copies nothing into the save dir (the engine browses instead)"
[ -f "$FIXTURE" ] && [ "$(sha256sum "$FIXTURE" | cut -d' ' -f1)" = "$FIX_SHA" ]
check $? "leaves the player's own file untouched"
log_of "$SB" | grep -q "._Pokemon"
if [ $? -eq 0 ]; then bad "reported an AppleDouble decoy"; else ok "skips ._ AppleDouble files"; fi
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "finds dumps in any folder NextUI would call GB or GBC"
for folder in "Nintendo Game Boy (GB)" "GB" "gbc" "Handhelds - Game Boy Color (GBC)"; do
    SB="$(make_sandbox)"
    mkdir -p "$SB/SDCARD/Roms/$folder"
    F="$SB/SDCARD/Roms/$folder/cart.gb"
    head -c 1048576 /dev/urandom > "$F"
    sed -i "s/5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b/$(sha256sum "$F" | cut -d' ' -f1)/" "$SB/pak/launch.sh"
    run_launch "$SB"
    log_of "$SB" | grep -q "Red  ->  "
    check $? "reports a dump in \"$folder\""
    rm -rf "$SB"
done

SB="$(make_sandbox)"
mkdir -p "$SB/SDCARD/Roms/Nintendo 64 (N64)"
F="$SB/SDCARD/Roms/Nintendo 64 (N64)/cart.gb"
head -c 1048576 /dev/urandom > "$F"
sed -i "s/5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b/$(sha256sum "$F" | cut -d' ' -f1)/" "$SB/pak/launch.sh"
run_launch "$SB"
log_of "$SB" | grep -q "Red  ->  "
if [ $? -eq 0 ]; then bad "looked inside a folder NextUI maps to another system"
else ok "ignores folders whose tag is not GB/GBC"; fi
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "reports every version present, not just the first"
SB="$(make_sandbox)"
R="$SB/SDCARD/Roms/Game Boy (GB)"
head -c 1048576 /dev/urandom > "$R/a-blue.gb"
head -c 1048576 /dev/urandom > "$R/z-red.gb"
sed -i "s/2a951313c2640e8c2cb21f25d1db019ae6245d9c7121f754fa61afd7bee6452d/$(sha256sum "$R/a-blue.gb" | cut -d' ' -f1)/" "$SB/pak/launch.sh"
sed -i "s/5ca7ba01642a3b27b0cc0b5349b52792795b62d3ed977e98a09390659af96b7b/$(sha256sum "$R/z-red.gb" | cut -d' ' -f1)/" "$SB/pak/launch.sh"
run_launch "$SB"
log_of "$SB" | grep -q "Blue  ->  .*a-blue.gb"
check $? "reports Blue"
log_of "$SB" | grep -q "Red  ->  .*z-red.gb"
check $? "reports Red too -- stopping at the first would hide the rest"
rm -rf "$SB"

# --------------------------------------------------------------------------
# Gen 2 carts are 2 MiB. A 1 MiB-only size filter is what made Gold invisible
# when Gold first shipped, before its hash was ever computed.
echo
echo "accepts a 2 MiB Gen 2 dump (Gold), not just 1 MiB Gen 1 ones"
SB="$(make_sandbox)"
G="$SB/SDCARD/Roms/Game Boy Color (GBC)/gold.gbc"
head -c 2097152 /dev/urandom > "$G"
sed -i "s/fb0016d27b1e5374e1ec9fcad60e6628d8646103b5313ca683417f52b97e7e4e/$(sha256sum "$G" | cut -d' ' -f1)/" "$SB/pak/launch.sh"
run_launch "$SB"
log_of "$SB" | grep -q "Gold  ->  .*gold.gbc"
check $? "reports a 2 MiB Gold dump"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "ignores files that cannot be a cartridge dump"
SB="$(make_sandbox)"
H="$SB/SDCARD/Roms/Game Boy (GB)/homebrew.gb"
head -c 524288 /dev/urandom > "$H"
sed -i "s/2a951313c2640e8c2cb21f25d1db019ae6245d9c7121f754fa61afd7bee6452d/$(sha256sum "$H" | cut -d' ' -f1)/" "$SB/pak/launch.sh"
run_launch "$SB"
log_of "$SB" | grep -q "Blue  ->  "
if [ $? -eq 0 ]; then bad "reported a file of the wrong size"; else ok "skips a file that is neither 1 nor 2 MiB"; fi
rm -rf "$SB"

# --------------------------------------------------------------------------
# Dumps older versions of this pak copied into the save dir. They import nothing
# now, but they cannot be told apart from a file the player put there, so they
# are reported and never removed.
echo
echo "previously staged dumps are reported, never deleted"
SB="$(make_sandbox)"
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d"
mkdir -p "$BR"
head -c 1048576 /dev/urandom > "$BR/old-staged.gb"
head -c 2097152 /dev/urandom > "$BR/old-staged-2.gbc"
run_launch "$SB"
log_of "$SB" | grep -q "2 dump(s) sit in"
check $? "reports how many stale copies are in the save dir"
log_of "$SB" | grep -q "Safe to delete"
check $? "says they can be removed"
[ -f "$BR/old-staged.gb" ] && [ -f "$BR/old-staged-2.gbc" ]
check $? "does not delete them -- they may be the player's own files"
rm -rf "$SB"

SB="$(make_sandbox)"
run_launch "$SB"
log_of "$SB" | grep -q "sit in"
if [ $? -eq 0 ]; then bad "reported stale dumps when the save dir was empty"
else ok "stays quiet when the save dir holds no dumps"; fi
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

# --------------------------------------------------------------------------
echo
echo "love runs as a child, so the cleanup trap can actually fire"

# The bug this guards: launch.sh used to end in `exec love`, which replaces the
# shell -- and a replaced shell cannot run `trap cleanup EXIT`. Everything
# cleanup() restores was therefore never restored. Confirmed on a Brick,
# 2026-08-31: the CPU ceiling stayed raised after the game exited.
grep -qE '^[[:space:]]*exec "[$]PAK_DIR/bin/love.aarch64"' "$ROOT/launch.sh"
if [ $? -eq 0 ]; then bad "launch.sh execs love -- that discards the cleanup trap"
else ok "launch.sh does not exec love (the trap would be discarded)"; fi

SB="$(make_sandbox)"
run_launch "$SB"
log_of "$SB" | grep -q "love exited with status 0"
check $? "carries on past love and logs its exit status"
rm -rf "$SB"

# The status has to survive, or NextUI cannot tell a crash from a clean quit.
SB="$(make_sandbox)"
cat > "$SB/pak/bin/love.aarch64" <<'STUB'
#!/bin/sh
echo "LOVE_ARGV: $*" > "$LOVE_STUB_OUT"
exit 42
STUB
chmod +x "$SB/pak/bin/love.aarch64"
run_launch "$SB"
[ $? -eq 42 ]
check $? "propagates love's exit status rather than swallowing it"
log_of "$SB" | grep -q "love exited with status 42"
check $? "records a non-zero exit in the log"
rm -rf "$SB"

printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
