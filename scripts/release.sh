#!/usr/bin/env bash
# Package build/Gen1Recomp.pak/ into the two release artifacts.
#
#   dist/Gen1Recomp.pak.zip   Pak Store. Pak contents at the ZIP ROOT, not nested.
#                             Filename must equal pak.json's release_filename.
#   dist/Gen1Recomp.pakz      Manual SD install: unzip at the card root to get
#                             Emus/<platform>/Gen1Recomp.pak/. One copy per
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

# Verify before packaging, not after: a contract failure means we should not be
# producing artifacts at all.
if [ "$SKIP_VERIFY" = 0 ]; then
    say "running static checks"
    "$ROOT/scripts/verify.sh" || fail "verify.sh failed -- refusing to package"
fi

rm -rf "$DIST"
mkdir -p "$DIST"

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
say "packing Gen1Recomp.pakz (Emus/<platform>/Gen1Recomp.pak/)"
PZ="$DIST/.pakz"
for p in $PLATFORMS; do
    mkdir -p "$PZ/Emus/$p"
    cp -RL "$PAK" "$PZ/Emus/$p/Gen1Recomp.pak"
    rm -f "$PZ/Emus/$p/Gen1Recomp.pak/README.md"
    chmod +x "$PZ/Emus/$p/Gen1Recomp.pak/launch.sh" \
             "$PZ/Emus/$p/Gen1Recomp.pak/bin/love.aarch64"
done

# Ship the ROM folder skeleton so the entry exists the moment the card boots.
# NextUI cannot launch a directory (addEntries marks it ENTRY_DIR unless it ends
# .pak), so the launchable entry has to be a file -- this 0-byte stub.
ROMDIR="$PZ/Roms/Gen1Recomp (Gen1Recomp)"
mkdir -p "$ROMDIR/.media"
: > "$ROMDIR/Gen1Recomp.g1r"
cat > "$ROMDIR/.media/README.txt" <<'EOF'
Box art goes here as Gen1Recomp.png (the entry's name minus its extension).
Optional folder art: bg.png and bglist.png.
EOF
( cd "$PZ" && zip -qr9 "$DIST/Gen1Recomp.pakz" Emus Roms )
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
