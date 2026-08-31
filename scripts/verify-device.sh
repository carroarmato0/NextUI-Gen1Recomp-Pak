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

# tr -d '\r' is load-bearing: adb shell hands back CRLF, and while the regex
# checks tolerate a stray CR, any exact string comparison silently fails on it.
# That cost a false "a different gamepad mapping won" on a Brick where the two
# strings were byte-identical apart from the CR.
logtext() { adb shell "cat '$LOG' 2>/dev/null" | tr -d '\r'; }

# clear_log -- remove the device log immediately before a prompt.
#
# Every group below reads $LOG and judges the pak by it, but launch.sh only
# rewrites that file when it actually runs. So if nothing is launched at the
# prompt, the checks silently grade a log from an earlier session and report
# passes that are not evidence of anything. That happened twice on a Brick before
# this existed: six "ok"s against a thirteen-minute-old log.
#
# Deleting it costs nothing -- launch.sh truncates the log on every launch anyway
# -- and turns "you did not launch it" into the unambiguous empty-log branch.
clear_log() { adb shell "rm -f '$LOG'" >/dev/null 2>&1; }

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
    # Poll for love.aarch64 going away rather than guessing with a fixed sleep.
    # NOT "press MENU": nothing on these devices intercepts MENU, so it does not
    # quit the game -- it arrives as an ordinary joystick button. Quitting is done
    # from Gen1Recomp's own launcher.
    local waited=0 limit="${1:-180}"
    printf '  running; quit from the game'"'"'s own launcher when done'
    while [ "$waited" -lt "$limit" ]; do
        if adb shell 'pidof love.aarch64' 2>/dev/null | grep -qE '[0-9]'; then
            printf '.'; sleep 3; waited=$((waited+3))
        else
            printf ' exited\n'; return 0
        fi
    done
    printf ' timed out\n'; return 1
}

# await_launch <what> <start_limit> <exit_limit>
#
# Block until the pak has actually run and exited, instead of asking for Enter
# and trusting the sequencing. Every group below grades $LOG, and launch.sh only
# rewrites that file when it runs -- so an Enter pressed before launching had the
# checks silently grading a log from an earlier session. That produced "8 passed,
# 0 failed" against a thirteen-minute-old log on a Brick, twice.
#
# Phase 1 waits for the log to reappear, which means launch.sh started. Phase 2
# waits for love to go away, so the log is complete before anything reads it.
# Ctrl-C is the way out; both phases are bounded so a device that never launches
# fails rather than hanging the session.
await_launch() {
    local what="$1" start_limit="${2:-300}" exit_limit="${3:-600}" waited=0
    clear_log
    printf '  waiting for you to open it on the device (up to %ds)' "$start_limit"
    while [ "$waited" -lt "$start_limit" ]; do
        if adb shell "[ -f '$LOG' ] && echo seen" 2>/dev/null | grep -q seen; then
            printf ' started\n'
            wait_for_exit "$exit_limit" \
                || warn "$what did not exit within ${exit_limit}s; reading the log as it stands"
            return 0
        fi
        printf '.'; sleep 2; waited=$((waited+2))
    done
    printf ' timed out\n'
    return 1
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

  Open Tools > Gen1Recomp on the device now. It runs the smoke test, not the
  game: a moving square and a tone for a few seconds, then it quits by itself.
  Listen for a clean tone with no pop and no crackle.

  This waits for the run and reads the log afterwards -- there is nothing to
  press here. Ctrl-C to give up.

EOF
await_launch "the smoke test" 300 300 \
    || bad "nothing was launched -- open Tools > Gen1Recomp on the device when asked"

group "Smoke test"
SMOKE="$(logtext)"
# launch.sh overwrites the log every launch, so a log without the diag banner is
# not a failing smoke test -- it is a launch that ran something else, or a stale
# log from an earlier run. Reported separately, because "no GLES renderer" for a
# smoke test that never started sends you debugging the wrong thing entirely.
if [ -z "$SMOKE" ]; then
    bad "nothing was launched -- open Tools > Gen1Recomp on the device BEFORE pressing Enter"
elif ! printf '%s\n' "$SMOKE" | matches '^diag'; then
    warn "the smoke test did not run -- this log is from a different launch"
    printf '        the pak logs \033[1mdiag\033[0m lines when it runs a .love from the state dir;\n'
    printf '        this log shows: %s\n' "$(printf '%s\n' "$SMOKE" | grep -m1 -E '^(launch|diag)' || echo '(no launch line at all)')"
    printf '        Re-run and open Tools > Gen1Recomp at the prompt, before pressing Enter.\n'
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
    # Compare the MAPPING, not the GUID. Comparing GUIDs was a false alarm: SDL
    # 2.0.18+ stores a CRC16 of the device name in bytes 2-3 of the GUID and
    # falls back to matching with that field zeroed, so our zero-CRC
    # 030000005e04... legitimately matches the device's 0300a3845e04... and the
    # override IS applied. Measured on a Brick, 2026-08-31: the live mapping came
    # back as our "TRIMUI Player1" with a:b1,b:b0, re-stamped with the device CRC.
    # What matters is whether our mapping won, and only the mapping shows that.
    guid="$(printf '%s\n' "$SMOKE" | sed -n 's/.*joystick.*guid=\([0-9a-fA-F]*\).*/\1/p' | head -1)"
    live="$(printf '%s\n' "$SMOKE" | sed -n 's/^mapping [0-9]*: //p' | head -1)"
    ours="$(sed -n 's/.*SDL_GAMECONTROLLERCONFIG="\(.*\)"$/\1/p' "$ROOT/launch.sh" | head -1)"
    # Everything after the GUID: the part we actually author.
    live_body="${live#*,}"; ours_body="${ours#*,}"
    if [ -z "$guid" ]; then
        warn "no joystick reported -- check the controller is seen at all"
    elif [ -z "$live" ]; then
        warn "the smoke test reported no mapping line -- rebuild it (test/smoke/)"
    elif [ "$live_body" = "$ours_body" ]; then
        ok "launch.sh's controller mapping is the live one (${ours_body%%,*}, a:b1/b:b0)"
    else
        bad "a different gamepad mapping won, so A/B may be swapped
        live: $live
        ours: $ours"
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

  Now open Tools > Gen1Recomp again for the real thing.
  Start a new game, walk around a little, save, then quit from its launcher.

  This waits until the game exits before reading the log. Ctrl-C to give up.

EOF
await_launch "Gen1Recomp" 300 1800 \
    || bad "nothing was launched -- open Tools > Gen1Recomp on the device when asked"

group "Gen1Recomp"
GLOG="$(logtext)"
if [ -z "$GLOG" ]; then
    bad "nothing was launched -- open Tools > Gen1Recomp on the device BEFORE pressing Enter"
else
    printf '%s\n' "$GLOG" | matches 'FATAL' \
        && bad "launch.sh reported FATAL: $(printf '%s\n' "$GLOG" | grep -m1 FATAL)" \
        || ok "no fatal launcher errors"

    # The labels come from launch.sh's ROM_TABLE rather than being listed here.
    # This check hard-coded Red|Blue|Yellow, so it silently never covered Gold --
    # and it matched on log wording that v0.4.3 changed, which made a healthy card
    # report "no ROM handling in the log at all". Derive both, or it drifts again.
    rom_labels="$(sed -n '/^ROM_TABLE="/,/"$/p' "$ROOT/launch.sh" \
                  | sed -e 's/^ROM_TABLE="//' -e 's/"$//' | awk '{print $2}' | paste -sd'|' -)"
    if printf '%s\n' "$GLOG" | matches "rom .*matched (${rom_labels})"; then
        ok "a cartridge dump was found and staged (matched by SHA-256)"
    elif printf '%s\n' "$GLOG" | matches 'rom .*(a dump for every version is staged|already imported)'; then
        ok "a dump for every version is staged; the scan was skipped as intended"
    elif printf '%s\n' "$GLOG" | matches 'rom .*no match found'; then
        warn "no ROM matched -- put a US ${rom_labels%%|*} dump in any (GB)/(GBC) folder to test the import path"
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
