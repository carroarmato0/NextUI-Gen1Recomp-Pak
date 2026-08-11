#!/usr/bin/env bash
# Capture whatever is on the device's screen right now, over ADB.
#
# Reads the framebuffer directly and converts it host-side. Nothing is installed
# on the device and nothing is killed, so this is safe to run mid-game.
#
# Usage:
#   scripts/screenshot.sh [-o out.png]
#
# Env: ANDROID_SERIAL to pick a device when several are attached.
#
# Note on where output goes: this writes to /tmp by default, never into
# docs/screenshots/. Promoting a capture into the repo is a deliberate act -- the
# framebuffer shows whatever happened to be on screen, including a save file's
# nickname or a half-open menu, so it wants a human look first.
set -uo pipefail

OUT=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o|--out) OUT="${2:?}"; shift ;;
        -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done

command -v adb >/dev/null    || { echo "adb is required" >&2; exit 2; }
command -v ffmpeg >/dev/null || { echo "ffmpeg is required (converts the raw framebuffer)" >&2; exit 2; }

DEVS="$(adb devices | awk 'NR>1 && $2=="device"{print $1}')"
NDEV="$(printf '%s\n' "$DEVS" | grep -c .)"
if [ "$NDEV" -eq 0 ]; then
    echo "no device over adb" >&2; exit 2
elif [ "$NDEV" -gt 1 ] && [ -z "${ANDROID_SERIAL:-}" ]; then
    echo "$NDEV devices attached; set ANDROID_SERIAL to pick one:" >&2
    for d in $DEVS; do
        m="$(adb -s "$d" shell 'strings /usr/trimui/bin/MainUI 2>/dev/null | grep -m1 "^Trimui"' 2>/dev/null | tr -d '\r')"
        printf '  ANDROID_SERIAL=%s %s   # %s\n' "$d" "$0" "${m:-unknown}" >&2
    done
    exit 2
fi

MODEL="$(adb shell 'strings /usr/trimui/bin/MainUI 2>/dev/null | grep -m1 "^Trimui"' 2>/dev/null | tr -d '\r')"

# Geometry from the device rather than a per-model table: fb0 reports it, and a
# wrong guess produces a skewed image that is easy to miss at a glance.
GEO="$(adb shell 'cat /sys/class/graphics/fb0/virtual_size 2>/dev/null' | tr -d '\r')"
W="${GEO%%,*}"
H_VIRT="${GEO##*,}"
# virtual_size's height is the scrollback allocation (e.g. 16384), not the panel,
# so take the real height from the DRM mode or fall back on the platform.
# Loop rather than `head -1 .../*/modes`: the Smart Pro S has several connectors
# (card0-DP-1, card0-DSI-1) and head then emits "==> file <==" banners, which the
# arithmetic below happily choked on. Take the first connector reporting a mode.
# Single-quoted on purpose: it runs on the device, not here. (SC2016)
# shellcheck disable=SC2016
H="$(adb shell 'for f in /sys/class/drm/*/modes; do [ -s "$f" ] || continue; read -r m < "$f"; [ -n "$m" ] && { echo "$m"; break; }; done' 2>/dev/null | tr -d '\r' | head -1 | cut -dx -f2)"
if [ -z "${H:-}" ] || [ "$H" -le 0 ] 2>/dev/null; then
    case "$W" in
        1280) H=720 ;;
        1024) H=768 ;;
        640)  H=480 ;;
        *)    echo "cannot determine panel height (virtual_size=$GEO)" >&2; exit 1 ;;
    esac
fi
[ -n "${W:-}" ] && [ "$W" -gt 0 ] 2>/dev/null || { echo "cannot read framebuffer width" >&2; exit 1; }

BYTES=$((W * H * 4))
BLOCKS=$(( (BYTES + 4095) / 4096 ))
: "$H_VIRT"

echo "==> ${MODEL:-device}: capturing ${W}x${H} (${BLOCKS} x 4096-byte blocks)"
adb shell "dd if=/dev/fb0 bs=4096 count=$BLOCKS of=/tmp/g1r-screen.raw 2>/dev/null" || {
    echo "framebuffer read failed -- /dev/fb0 may not be readable on this device" >&2; exit 1; }

RAW="$(mktemp)"
adb pull /tmp/g1r-screen.raw "$RAW" >/dev/null 2>&1 || { echo "adb pull failed" >&2; exit 1; }
adb shell 'rm -f /tmp/g1r-screen.raw' >/dev/null 2>&1

got=$(wc -c < "$RAW")
[ "$got" -ge "$BYTES" ] || echo "warning: pulled $got bytes, expected $BYTES -- image may be truncated" >&2

[ -n "$OUT" ] || OUT="/tmp/g1r-screenshot-$(date +%H%M%S).png"
mkdir -p "$(dirname "$OUT")"
ffmpeg -y -f rawvideo -pix_fmt bgra -s "${W}x${H}" -i "$RAW" "$OUT" 2>/dev/null \
    || { echo "ffmpeg conversion failed" >&2; rm -f "$RAW"; exit 1; }
rm -f "$RAW"

echo "Saved: $OUT ($(du -h "$OUT" | cut -f1))"
