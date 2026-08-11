#!/usr/bin/env bash
# The functional test. This is the only thing in the repo that can tell you the
# pak actually works, because everything that matters -- GLES context creation,
# OpenAL/ALSA audio, the controller mapping, frame rate, the voxel mod's memory
# ceiling -- exists only on the device. CI is structurally blind to all of it.
#
# What this automates: deploying, launching, and reading the log back with named
# pass/fail checks. What it cannot automate: whether the audio actually sounds
# clean and whether the frame rate is actually playable. Those stay human, and are
# printed as prompts at the end.
#
# Usage:
#   scripts/verify-device.sh              # full run: deploy, smoke test, then the game
#   scripts/verify-device.sh --smoke      # smoke test only (renderer / audio / joystick GUID)
#   scripts/verify-device.sh --no-deploy  # use whatever is already on the device
#
# Env: DEPLOY_PLATFORM (default tg5050), ANDROID_SERIAL
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLATFORM="${DEPLOY_PLATFORM:-tg5050}"
SD=/mnt/SDCARD
LOG="$SD/.userdata/$PLATFORM/logs/Gen1Recomp.txt"
STATE="$SD/.userdata/shared/Gen1Recomp"

SMOKE_ONLY=0; DO_DEPLOY=1
for a in "$@"; do
    case "$a" in
        --smoke)     SMOKE_ONLY=1 ;;
        --no-deploy) DO_DEPLOY=0 ;;
        -h|--help)   sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)           echo "unknown argument: $a" >&2; exit 2 ;;
    esac
done

PASS=0; FAIL=0; WARN=0
ok()   { PASS=$((PASS+1)); printf '  \033[1;32mok\033[0m    %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m  %s\n' "$1"; }
warn() { WARN=$((WARN+1)); printf '  \033[1;33mwarn\033[0m  %s\n' "$1"; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# See scripts/verify.sh: `grep -q` early-exits and SIGPIPEs its producer, which
# under pipefail turns a match into exit 141. grep -c consumes all input.
matches() { [ "$(grep -cE "$1" 2>/dev/null || true)" -gt 0 ]; }

command -v adb >/dev/null || die "adb is required"
adb get-state >/dev/null 2>&1 || die "no device over adb"

logtext() { adb shell "cat '$LOG' 2>/dev/null"; }

cpu_state() {
    # Single-quoted on purpose: it runs on the device, not here. (SC2016)
    # shellcheck disable=SC2016
    adb shell 'echo "online=$(cat /sys/devices/system/cpu/online 2>/dev/null)"
               for p in /sys/devices/system/cpu/cpufreq/policy*; do
                   echo "$(basename "$p")=$(cat "$p/scaling_governor" 2>/dev/null)/$(cat "$p/scaling_max_freq" 2>/dev/null)"
               done' 2>/dev/null | tr -d '\r'
}

# Sampled before anything of ours has run, so the comparison after the session is
# against the frontend's own idea of CPU state rather than a value we set.
CPU_BEFORE="$(cpu_state)"

wait_for_exit() {
    # The frontend relaunches itself when the game exits, so poll for nextui.elf
    # coming back rather than guessing with a fixed sleep.
    local waited=0 limit="${1:-180}"
    printf '  waiting for the game to exit (press MENU/quit on the device)'
    while [ "$waited" -lt "$limit" ]; do
        if adb shell 'pidof love.aarch64' 2>/dev/null | grep -qE '[0-9]'; then
            printf '.'; sleep 3; waited=$((waited+3))
        else
            printf ' exited\n'; return 0
        fi
    done
    printf ' timed out\n'; return 1
}

if [ "$DO_DEPLOY" = 1 ]; then
    say "deploying"
    DEPLOY_PLATFORM="$PLATFORM" "$ROOT/scripts/deploy.sh" || die "deploy failed"
fi

# --------------------------------------------------------------- smoke test
# smoke.love exercises Section A of launch.sh only. It answers the questions the
# real game would answer far more slowly and ambiguously: did a GLES context get
# created, what resolution, what is the controller's real GUID.
#
# Built here from test/smoke/ rather than committed as a binary .love, so the
# diagnostic stays reviewable in diffs.
#
# It goes into the state directory: a Tool pak is launched with no arguments, so
# there is no entry to select and launch.sh discovers the .love there instead.
# Removed again below, or the pak would keep running the diagnostic.
say "building and installing the smoke test"
command -v zip >/dev/null || die "zip is required to build the smoke test"
SMOKE_LOVE="$(mktemp -d)/smoke.love"
( cd "$ROOT/test/smoke" && zip -qr9 "$SMOKE_LOVE" . ) || die "could not build smoke.love"
adb shell "mkdir -p '$STATE'" >/dev/null 2>&1
adb push "$SMOKE_LOVE" "$STATE/_smoke.love" >/dev/null 2>&1 \
    || warn "could not push smoke.love"

cat <<EOF

  On the device: Tools > Gen1Recomp   (it runs the smoke test, not the game)
  It draws a moving square and plays a tone for a few seconds, then quits.
  Listen for a clean tone with no pop and no crackle.

EOF
read -r -p "  Press Enter once the smoke test has run and exited... " _

group "Smoke test"
SMOKE="$(logtext)"
if [ -z "$SMOKE" ]; then
    bad "no log at $LOG -- the pak did not run at all"
else
    printf '%s\n' "$SMOKE" | matches 'renderer:.*(OpenGL ES|GLES)' \
        && ok "a GLES renderer was created" \
        || bad "no GLES renderer in the log (LOVE could not make a GL context)"

    res="$(printf '%s\n' "$SMOKE" | sed -n 's/.*window: *\([0-9]*x[0-9]*\).*/\1/p' | head -1)"
    case "$res" in
        1280x720|1024x768) ok "window is the panel's native resolution ($res)" ;;
        "")                warn "could not read the window size from the log" ;;
        *)                 warn "unexpected window size: $res (expected 1280x720 or 1024x768)" ;;
    esac

    printf '%s\n' "$SMOKE" | matches 'audio: *ok' \
        && ok "audio initialised" \
        || bad "audio did not initialise"

    printf '%s\n' "$SMOKE" | matches 'XRUN|underrun|ALSA lib.*error' \
        && bad "audio underruns/XRUN in the log -- the CPU tuning block is load-bearing" \
        || ok "no audio underruns logged"

    # The GUID in launch.sh was taken from a third-party implementation and has
    # never been confirmed here. If it is wrong the mapping silently does nothing
    # and A/B are swapped, so this check matters more than it looks.
    guid="$(printf '%s\n' "$SMOKE" | sed -n 's/.*joystick.*guid=\([0-9a-fA-F]*\).*/\1/p' | head -1)"
    expected="$(sed -n 's/.*SDL_GAMECONTROLLERCONFIG="\([0-9a-f]*\),.*/\1/p' "$ROOT/launch.sh" | head -1)"
    if [ -z "$guid" ]; then
        warn "no joystick reported -- check the controller is seen at all"
    elif [ "$guid" = "$expected" ]; then
        ok "controller GUID matches the mapping shipped in launch.sh ($guid)"
    else
        bad "controller GUID is $guid but launch.sh ships $expected
        -> update SDL_GAMECONTROLLERCONFIG in launch.sh to this GUID, or A and B
           will be swapped and the mapping will silently do nothing"
    fi

    printf '%s\n' "$SMOKE" | matches 'memory .*SwapTotal' \
        && ok "memory/swap state reported" || warn "no memory line in the log"
fi

# Must go, or every later launch runs the diagnostic instead of the game.
adb shell "rm -f '$STATE/_smoke.love'" >/dev/null 2>&1

if [ "$SMOKE_ONLY" = 1 ]; then
    printf '\n\033[1m%d passed, %d failed, %d warnings\033[0m\n' "$PASS" "$FAIL" "$WARN"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
fi

# ------------------------------------------------------------------- the game
cat <<EOF

  Now launch the real thing: Tools > Gen1Recomp
  Start a new game, walk around a little, save, then quit.

EOF
read -r -p "  Press Enter once you have quit Gen1Recomp... " _

group "Gen1Recomp"
GLOG="$(logtext)"
if [ -z "$GLOG" ]; then
    bad "no log -- the pak did not run"
else
    printf '%s\n' "$GLOG" | matches 'FATAL' \
        && bad "launch.sh reported FATAL: $(printf '%s\n' "$GLOG" | grep -m1 FATAL)" \
        || ok "no fatal launcher errors"

    if printf '%s\n' "$GLOG" | matches 'rom .*matched (Red|Blue|Yellow)'; then
        ok "a cartridge dump was found and staged (matched by SHA-256)"
    elif printf '%s\n' "$GLOG" | matches 'rom .*already imported'; then
        ok "ROM already imported; the scan was skipped as intended"
    elif printf '%s\n' "$GLOG" | matches 'rom .*no match found'; then
        warn "no ROM matched -- put a US Red/Blue/Yellow dump in any (GB)/(GBC) folder to test the import path"
    else
        bad "no ROM handling in the log at all"
    fi

    printf '%s\n' "$GLOG" | matches 'cpu .*(all cores online|tuning skipped)' \
        && ok "CPU section ran" || warn "no CPU line in the log"

    # State must never land inside the pak, or the next update deletes the saves.
    adb shell "[ -d '$SD/.userdata/shared/Gen1Recomp' ] && echo yes" 2>/dev/null | matches yes \
        && ok "saves live in .userdata/shared/Gen1Recomp (survive pak updates)" \
        || bad "no state directory under .userdata/shared"

    adb shell "ls '$SD/Tools/$PLATFORM/Gen1Recomp.pak/game/' 2>/dev/null" | matches 'portable.txt' \
        && bad "portable.txt is present in the payload -- saves would be wiped by an update" \
        || ok "no portable.txt in the payload"

    # launch.sh deletes the v0.1.0 ROM folder and reports the old Emu pak. If it
    # said it removed something, the folder had better actually be gone.
    if printf '%s\n' "$GLOG" | matches '^legacy'; then
        adb shell "[ -d '$SD/Roms/Gen1Recomp (Gen1Recomp)' ] && echo left" 2>/dev/null | matches left \
            && bad "the v0.1.0 ROM folder is still there after launch.sh reported it" \
            || ok "the v0.1.0 ROM folder was cleaned up (see the 'legacy' lines)"
    else
        ok "no v0.1.0 leftovers on this card"
    fi
fi

group "Frontend integration"
adb shell 'pidof nextui.elf' 2>/dev/null | matches '[0-9]' \
    && ok "the frontend relaunched after the game exited" \
    || bad "nextui.elf is not running -- the launch loop did not recover"

# The online mask is the part worth checking. NextUI's boot script offlines five
# of the Smart Pro S's eight cores (skeleton/SYSTEM/tg5050/paks/MinUI.pak/launch.sh)
# and never repeats it, so a core we bring up and fail to put back stays up for
# the rest of the session, costing battery in every app that follows.
#
# The governor and ceiling lines are weaker evidence: NextUI runs
# `governor.sh performance` immediately before launching a pak and the UI resets
# to `auto` once it returns, so those fields are set by the frontend on both
# sides of this comparison whatever we do. A mismatch there is still worth
# seeing; a match does not prove our restore ran.
CPU_AFTER="$(cpu_state)"
if [ "$CPU_BEFORE" = "$CPU_AFTER" ]; then
    ok "CPU state matches what it was before the pak ran"
else
    bad "CPU state was not restored:
        before: $(printf '%s' "$CPU_BEFORE" | tr '\n' ' ')
        after:  $(printf '%s' "$CPU_AFTER" | tr '\n' ' ')"
fi

# ------------------------------------------------------------------ human bits
cat <<'EOF'

Human judgement -- nothing here can be automated. Record the answers in the
README's "Tested on" table; leave a device untested rather than assuming.

  [ ] Audio was clean: no pop at start, no crackle or distortion in-game.
  [ ] Physical A confirmed menu selections (not B).
  [ ] Frame rate in the overworld was playable. Note the number.
  [ ] Re-run with $STATE/no-cpu-tuning present. Is audio still clean?
      If yes on stock NextUI, DELETE the CPU block from launch.sh.
  [ ] Voxel mod: install Swap.pak, 512 MB on INTERNAL storage, boot hook on.
      Enable the mod in-game, play for several minutes, watch for an OOM kill:
        adb shell 'while :; do grep MemAvailable /proc/meminfo; sleep 5; done'
      Note peak usage and frame rate.
  [ ] The pak appears under Tools as "Gen1Recomp" and launches from there.
EOF

printf '\n\033[1m%d passed, %d failed, %d warnings\033[0m\n' "$PASS" "$FAIL" "$WARN"
[ "$FAIL" -eq 0 ] || exit 1
