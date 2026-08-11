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

# --------------------------------------------------------------------------
echo
echo "no ROM present -- must still launch, and say why"
SB="$(make_sandbox)"
run_launch "$SB" "$SB/SDCARD/Roms/Pokemon Gen 1 (Gen1Recomp)/Gen1Recomp.g1r"
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
run_launch "$SB" ""
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
run_launch "$SB" ""
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

run_launch "$SB" ""
log_of "$SB" | grep -q "matched Red"
check $? "identifies the version by SHA-256 through a path with spaces and parens"
log_of "$SB" | grep -q "imported 1 dump"
check $? "reports how many dumps were imported"
[ -f "$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d/baseroms/Pokemon Red (USA).gb" ]
check $? "copies the dump into the engine's import folder"
[ -f "$FIXTURE" ] && [ "$(sha256sum "$FIXTURE" | cut -d' ' -f1)" = "$FIX_SHA" ]
check $? "leaves the user's own file untouched"
# The decoy sorts ahead of the real dump, so a naive scan would copy it. Assert
# on the import folder's actual contents rather than on log text, which would
# pass for the wrong reason.
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d/baseroms"
[ -z "$(find "$BR" -name '._*' 2>/dev/null)" ] && [ "$(find "$BR" -type f | wc -l)" -eq 1 ]
check $? "skips the AppleDouble decoy and imports exactly one file"

# Second launch must not rescan.
run_launch "$SB" ""
log_of "$SB" | grep -q "already imported"
check $? "skips the scan once a ROM has been imported"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "opt-out toggles"
SB="$(make_sandbox)"
mkdir -p "$SB/SDCARD/.userdata/shared/Gen1Recomp"
touch "$SB/SDCARD/.userdata/shared/Gen1Recomp/no-cpu-tuning"
run_launch "$SB" ""
log_of "$SB" | grep -q "tuning skipped"
check $? "no-cpu-tuning disables the CPU block (needed to A/B the audio fix)"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo "missing payload fails loudly rather than silently"
SB="$(make_sandbox)"
rm -f "$SB/pak/bin/love.aarch64"
run_launch "$SB" ""
[ $? -ne 0 ] && log_of "$SB" | grep -q "FATAL"
check $? "exits non-zero with FATAL when the runtime is missing"
rm -rf "$SB"

SB="$(make_sandbox)"
rm -f "$SB/pak/game/main.lua"
run_launch "$SB" ""
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
run_launch "$SB" ""
BR="$SB/SDCARD/.userdata/shared/Gen1Recomp/love/pokemon-love2d/baseroms"
[ "$(find "$BR" -type f | wc -l)" -eq 2 ]
check $? "both dumps imported (Blue sorts first but must not hide Red)"
log_of "$SB" | grep -q "imported 2 dump"
check $? "reports both imports"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
echo ".love diagnostic passthrough"
SB="$(make_sandbox)"
mkdir -p "$SB/SDCARD/Roms/Pokemon Gen 1 (Gen1Recomp)"
printf 'not-really-a-zip' > "$SB/SDCARD/Roms/Pokemon Gen 1 (Gen1Recomp)/_smoke.love"
run_launch "$SB" "$SB/SDCARD/Roms/Pokemon Gen 1 (Gen1Recomp)/_smoke.love"
grep -q "LOVE_ARGV: .*_smoke.love" "$SB/stub.out" 2>/dev/null
check $? "a .love entry is passed through to the runtime"
log_of "$SB" | grep -q "diagnostics only"
check $? "logs that the passthrough is diagnostics-only, not a supported feature"
rm -rf "$SB"

SB="$(make_sandbox)"
run_launch "$SB" "$SB/SDCARD/Roms/does-not-exist.love"
grep -q "LOVE_ARGV: $SB/pak/game" "$SB/stub.out" 2>/dev/null
check $? "a missing .love falls back to the bundled game rather than failing"
rm -rf "$SB"

# --------------------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
