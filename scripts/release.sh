#!/usr/bin/env bash
# Package build/Gen1Recomp.pak/ into the two release artifacts.
#
#   dist/Gen1Recomp.pak.zip   Pak Store. Pak contents at the ZIP ROOT, not nested.
#                             Filename must equal pak.json's release_filename.
#   dist/Gen1Recomp.pakz      Manual SD install: unzip at the card root to get
#                             Tools/<platform>/Gen1Recomp.pak/. One copy per
#                             platform -- the aarch64 runtime is identical on
#                             tg5040 and tg5050, so this only duplicates files,
#                             it does not build anything twice.
#
# Usage: scripts/release.sh [--skip-verify]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PAK="$ROOT/build/Gen1Recomp.pak"
DIST="$ROOT/dist"
PLATFORMS="tg5040 tg5050"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

SKIP_VERIFY=0
[ "${1:-}" = "--skip-verify" ] && SKIP_VERIFY=1

command -v zip >/dev/null || fail "zip is required"
command -v jq  >/dev/null || fail "jq is required"
[ -d "$PAK" ] || fail "build/Gen1Recomp.pak not found -- run scripts/build.sh first"

VERSION="$(jq -r .version "$ROOT/pak.json")"
STORE_NAME="$(jq -r .release_filename "$ROOT/pak.json")"

# Clear dist/ before verifying, not after. verify.sh inspects whatever artifacts
# are in dist/, so a leftover from a previous release gets checked against the
# current contracts -- which fails on a layout change, and worse, can pass on a
# stale artifact and read as confidence in one we have not built yet.
rm -rf "$DIST"
mkdir -p "$DIST"

# Verify before packaging, not after: a contract failure means we should not be
# producing artifacts at all.
if [ "$SKIP_VERIFY" = 0 ]; then
    say "running static checks"
    "$ROOT/scripts/verify.sh" || fail "verify.sh failed -- refusing to package"
fi

# ------------------------------------------------------------------ store zip
say "packing $STORE_NAME (contents at zip root)"
STAGE="$DIST/.store"
mkdir -p "$STAGE"
# -L dereferences: exFAT and FAT32 cards cannot store symlinks, so a symlink that
# survived into the zip would arrive on the card as a broken file.
cp -RL "$PAK"/. "$STAGE"/
# README.md is deliberately excluded from the installed pak: its screenshots are
# not shipped, so it would render on-device with broken images.
rm -f "$STAGE/README.md"
chmod +x "$STAGE/launch.sh" "$STAGE/bin/love.aarch64"
( cd "$STAGE" && zip -qr9 "$DIST/$STORE_NAME" . )
rm -rf "$STAGE"

# ------------------------------------------------------------------ pakz
say "packing Gen1Recomp.pakz (Tools/<platform>/Gen1Recomp.pak/)"
PZ="$DIST/.pakz"
for p in $PLATFORMS; do
    mkdir -p "$PZ/Tools/$p"
    cp -RL "$PAK" "$PZ/Tools/$p/Gen1Recomp.pak"
    rm -f "$PZ/Tools/$p/Gen1Recomp.pak/README.md"
    chmod +x "$PZ/Tools/$p/Gen1Recomp.pak/launch.sh" \
             "$PZ/Tools/$p/Gen1Recomp.pak/bin/love.aarch64"
done

# No ROM folder and no stub file. A Tool pak is the whole entry: NextUI lists the
# .pak directory itself under Tools. The v0.1.0 Emu layout needed a Roms folder
# with a 0-byte Gen1Recomp.g1r inside it, because NextUI will not launch a
# directory -- and users who never got that folder saw no entry at all.
( cd "$PZ" && zip -qr9 "$DIST/Gen1Recomp.pakz" Tools )
rm -rf "$PZ"

# ------------------------------------------------------------------- report
say "verifying the packaged artifacts"
"$ROOT/scripts/verify.sh" --skip-lint >/dev/null || fail "post-package verification failed"

say "done. $VERSION"
for f in "$DIST/$STORE_NAME" "$DIST/Gen1Recomp.pakz"; do
    printf '  %-28s %s\n' "$(basename "$f")" "$(du -h "$f" | cut -f1)"
done
cat <<EOF

These artifacts are NOT verified to work. Static checks cannot observe GLES,
audio, input or frame rate. Run scripts/verify-device.sh on hardware before
publishing the release.
EOF
