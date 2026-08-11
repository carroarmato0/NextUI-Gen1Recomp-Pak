#!/usr/bin/env bash
# Push the built pak onto a device, over ADB or to a mounted SD card.
#
# Usage:
#   scripts/deploy.sh                    # adb, platform from $DEPLOY_PLATFORM (default tg5050)
#   scripts/deploy.sh /media/me/SDCARD   # copy to a mounted card instead
#
# Env:
#   DEPLOY_PLATFORM   tg5040 | tg5050  (default tg5050)
#   ANDROID_SERIAL    passed through to adb when several devices are attached
#
# Deploys build/Gen1Recomp.pak, NOT dist/. build.sh writes build/, so the two stay
# in step; there is no stale-artifact trap the way there is when a deploy script
# reads a dist/ tree that a later build never refreshed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAK="$ROOT/build/Gen1Recomp.pak"
PLATFORM="${DEPLOY_PLATFORM:-tg5050}"
DEST_REL="Emus/$PLATFORM/Gen1Recomp.pak"
ROMDIR_REL="Roms/Pokemon Gen 1 (Gen1Recomp)"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ -d "$PAK" ] || fail "build/Gen1Recomp.pak not found -- run scripts/build.sh first"
case "$PLATFORM" in tg5040|tg5050) ;; *) fail "DEPLOY_PLATFORM must be tg5040 or tg5050" ;; esac

if [ $# -ge 1 ]; then
    # ---- mounted card -----------------------------------------------------
    CARD="${1%/}"
    [ -d "$CARD" ] || fail "$CARD is not a directory"
    say "copying to $CARD/$DEST_REL"
    mkdir -p "$CARD/$DEST_REL" "$CARD/$ROMDIR_REL/.media"
    rm -rf "$CARD/$DEST_REL"
    cp -RL "$PAK" "$CARD/$DEST_REL"
    chmod +x "$CARD/$DEST_REL/launch.sh" "$CARD/$DEST_REL/bin/love.aarch64"
    [ -f "$CARD/$ROMDIR_REL/Gen1Recomp.g1r" ] || : > "$CARD/$ROMDIR_REL/Gen1Recomp.g1r"
    sync
    say "done. Eject the card and boot the device."
else
    # ---- adb --------------------------------------------------------------
    command -v adb >/dev/null || fail "adb not found (pass a mounted SD card path instead)"
    adb start-server >/dev/null 2>&1 || true
    adb get-state >/dev/null 2>&1 || fail "no device over adb. Enable it in NextUI's settings, or pass an SD card path."

    SD=/mnt/SDCARD
    say "pushing to $SD/$DEST_REL on $PLATFORM"
    # Remove first: a stale file left by an older build would otherwise survive
    # (adb push merges rather than replaces).
    adb shell "rm -rf '$SD/$DEST_REL'" >/dev/null
    adb shell "mkdir -p '$SD/Emus/$PLATFORM' '$SD/$ROMDIR_REL/.media'" >/dev/null
    adb push "$PAK" "$SD/$DEST_REL" >/dev/null || fail "adb push failed"
    adb shell "chmod +x '$SD/$DEST_REL/launch.sh' '$SD/$DEST_REL/bin/love.aarch64'"
    adb shell "[ -f '$SD/$ROMDIR_REL/Gen1Recomp.g1r' ] || : > '$SD/$ROMDIR_REL/Gen1Recomp.g1r'"
    adb shell sync
    say "done."
    cat <<EOF

Next: on the device open Games > Pokemon Gen 1 > Gen1Recomp.
Read the log with:
  adb shell cat /mnt/SDCARD/.userdata/$PLATFORM/logs/Gen1Recomp.txt
Or run the checked version:
  scripts/verify-device.sh
EOF
fi
