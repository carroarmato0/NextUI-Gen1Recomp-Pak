#!/usr/bin/env bash
# Assemble the pak contents into build/Gen1Recomp.pak/.
#
# There is no compiler involved. Everything is fetched from pinned, hash-verified
# upstream artifacts and rearranged:
#
#   upstream release zip  ->  bin/love.aarch64, libs.aarch64/, game/
#   voxel mod backup zip  ->  game/mods/DRAMATIC_SHAPE/
#   this repo             ->  launch.sh, pak.json, LICENSE, README.md
#
# Usage:
#   scripts/build.sh [--no-voxel] [--tag vX.Y.Z] [--refresh-lock] [--refresh-ca]
#
#   --no-voxel      skip the voxel mod: 7.8 MB to download, 18 MB of the 31 MB pak
#   --tag           build a specific upstream tag instead of upstream.lock's
#   --refresh-lock  resolve the LATEST upstream release and rewrite upstream.lock
#                   with the new tag/asset/sha256 (what upstream-watch.yml uses)
#   --refresh-ca    re-fetch the CA bundle and repin its hash (roots expire)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/upstream.lock"
CACHE="$ROOT/.cache"
BUILD="$ROOT/build"
PAK="$BUILD/Gen1Recomp.pak"

WITH_VOXEL=1
WANT_TAG=""
REFRESH_LOCK=0
REFRESH_CA=0

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-voxel)     WITH_VOXEL=0 ;;
    --tag)          WANT_TAG="${2:?--tag needs a value}"; shift ;;
    --refresh-lock) REFRESH_LOCK=1 ;;
    --refresh-ca)   REFRESH_CA=1 ;;
    -h|--help)      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              fail "unknown argument: $1" ;;
  esac
  shift
done

for t in curl unzip zip jq sha256sum readelf ar tar; do
  command -v "$t" >/dev/null || fail "$t is required"
done

mkdir -p "$CACHE"

# jqlock <filter> -- read a value out of upstream.lock
jqlock() { jq -r "$1" "$LOCK"; }

# fetch <url> <dest> <sha256|""> <label>
# Always timeout-bounded: an untimed curl in CI hangs the whole job.
fetch() {
  local url="$1" dest="$2" want="$3" label="$4" got
  if [ -f "$dest" ] && [ -n "$want" ]; then
    got="$(sha256sum "$dest" | cut -d' ' -f1)"
    [ "$got" = "$want" ] && { say "cached $label"; return 0; }
    rm -f "$dest"
  fi
  say "downloading $label"
  # --retry-all-errors so a mid-transfer "connection reset" (seen intermittently
  # from Launchpad's librarian) is retried, not just the HTTP codes --retry covers.
  curl -fL --connect-timeout 20 --max-time 600 \
    --retry 3 --retry-delay 2 --retry-all-errors --retry-connrefused \
    --progress-bar "$url" -o "$dest.part" || fail "download failed: $url"
  mv "$dest.part" "$dest"
  if [ -n "$want" ]; then
    got="$(sha256sum "$dest" | cut -d' ' -f1)"
    [ "$got" = "$want" ] || fail "sha256 mismatch for $label
  expected $want
  got      $got"
    say "verified $label"
  fi
}

# ------------------------------------------------------------------ lock refresh
# Resolving "latest" is deliberately opt-in. A plain build is fully reproducible
# from the committed lock and touches no mutable upstream state.
if [ "$REFRESH_LOCK" = 1 ]; then
  repo="$(jqlock '.gen1recomp.repo')"
  say "resolving latest release of $repo"
  api="$CACHE/latest.json"
  curl -fsL --connect-timeout 20 --max-time 120 \
    -H 'Accept: application/vnd.github+json' \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} \
    "https://api.github.com/repos/$repo/releases/latest" -o "$api" \
    || fail "could not query the GitHub release API"

  new_tag="$(jq -r '.tag_name' "$api")"
  # The digest field pairs each asset with its own sha256, so we never have to
  # trust a hash computed from the same unverified download we are checking.
  read -r new_asset new_sha new_size <<EOF
$(jq -r '.assets[] | select(.name|test("rg34xxsp-stockos64-mod\\.zip$"))
         | [.name, (.digest // "" | sub("^sha256:";"")), (.size|tostring)] | @tsv' "$api")
EOF
  [ -n "$new_tag" ] && [ "$new_tag" != null ] || fail "no tag_name in the release API response"
  [ -n "${new_asset:-}" ] || fail "release $new_tag has no *rg34xxsp-stockos64-mod.zip asset"
  [ -n "${new_sha:-}" ] || fail "release $new_tag ships no sha256 digest for $new_asset"

  # The .love asset of the SAME release, for Yellow's import manifest -- the
  # rg34xxsp zip omits it. Repinned here rather than in a separate step because a
  # manifest and the engine that reads it must come from one release.
  read -r ym_asset ym_sha ym_size <<EOF
$(jq -r '.assets[] | select(.name|test("\\.love$"))
         | [.name, (.digest // "" | sub("^sha256:";"")), (.size|tostring)] | @tsv' "$api")
EOF
  [ -n "${ym_asset:-}" ] || fail "release $new_tag has no .love asset (needed for Yellow's manifest)"
  [ -n "${ym_sha:-}" ] || fail "release $new_tag ships no sha256 digest for $ym_asset"

  new_ver="${new_tag#v}"
  tmp="$LOCK.tmp"
  jq --arg tag "$new_tag" --arg ver "$new_ver" --arg asset "$new_asset" \
     --arg sha "$new_sha" --argjson size "$new_size" \
     --arg yasset "$ym_asset" --arg ysha "$ym_sha" --argjson ysize "$ym_size" \
     '.gen1recomp.tag=$tag | .gen1recomp.version=$ver | .gen1recomp.asset=$asset
      | .gen1recomp.sha256=$sha | .gen1recomp.size=$size
      | .yellow_manifest.asset=$yasset | .yellow_manifest.sha256=$ysha
      | .yellow_manifest.size=$ysize' "$LOCK" > "$tmp"
  mv "$tmp" "$LOCK"
  say "upstream.lock now pins $new_tag ($new_asset, $ym_asset)"
fi

TAG="${WANT_TAG:-$(jqlock '.gen1recomp.tag')}"
VERSION="$(jqlock '.gen1recomp.version')"
ASSET="$(jqlock '.gen1recomp.asset')"
ASSET_SHA="$(jqlock '.gen1recomp.sha256')"
REPO="$(jqlock '.gen1recomp.repo')"
LOVE_ASSET="$(jqlock '.yellow_manifest.asset')"
LOVE_ASSET_SHA="$(jqlock '.yellow_manifest.sha256')"
YELLOW_MEMBER="$(jqlock '.yellow_manifest.member')"

# An explicit --tag cannot be hash-checked against the lock, so it is a
# developer escape hatch only -- never a release path.
if [ -n "$WANT_TAG" ] && [ "$WANT_TAG" != "$(jqlock '.gen1recomp.tag')" ]; then
  warn "--tag $WANT_TAG differs from upstream.lock; skipping the asset hash check."
  warn "This build is NOT reproducible and must not be released."
  ASSET_SHA=""
  ASSET="$(basename "$(curl -fsL --connect-timeout 20 --max-time 120 \
    "https://api.github.com/repos/$REPO/releases/tags/$WANT_TAG" \
    | jq -r '.assets[]|select(.name|test("rg34xxsp-stockos64-mod\\.zip$")).name')")"
  [ -n "$ASSET" ] || fail "no rg34xxsp asset on tag $WANT_TAG"
  LOVE_ASSET_SHA=""
  LOVE_ASSET="$(basename "$(curl -fsL --connect-timeout 20 --max-time 120 \
    "https://api.github.com/repos/$REPO/releases/tags/$WANT_TAG" \
    | jq -r '.assets[]|select(.name|test("\\.love$")).name')")"
  [ -n "$LOVE_ASSET" ] || fail "no .love asset on tag $WANT_TAG"
fi

# ------------------------------------------------------------------- downloads
PORT_ZIP="$CACHE/$ASSET"
fetch "https://github.com/$REPO/releases/download/$TAG/$ASSET" \
      "$PORT_ZIP" "$ASSET_SHA" "Gen1Recomp $VERSION port ($((  $(jqlock '.gen1recomp.size') / 1024 / 1024 )) MB)"

# The port zip ships Red's and Blue's import manifests but not Yellow's, so a
# Yellow dump fails at RomImporter.lua with "ROM import metadata is missing".
# Take that one member from the same release's .love, which does carry it.
LOVE_ZIP="$CACHE/$LOVE_ASSET"
fetch "https://github.com/$REPO/releases/download/$TAG/$LOVE_ASSET" \
      "$LOVE_ZIP" "$LOVE_ASSET_SHA" "Gen1Recomp $VERSION .love (for $YELLOW_MEMBER)"

# CA bundle. The device has no certificate store whatsoever, so without this every
# HTTPS call the engine makes (mod index, update checks) dies with curl exit 60.
CA_FILE="$CACHE/cacert.pem"
if [ "$REFRESH_CA" = 1 ]; then
  say "refreshing the CA bundle"
  rm -f "$CA_FILE"
  curl -fL --connect-timeout 20 --max-time 120 --progress-bar \
    "$(jqlock '.ca_bundle.url')" -o "$CA_FILE" || fail "could not fetch the CA bundle"
  newsha="$(sha256sum "$CA_FILE" | cut -d' ' -f1)"
  tmp="$LOCK.tmp"
  jq --arg s "$newsha" '.ca_bundle.sha256=$s' "$LOCK" > "$tmp" && mv "$tmp" "$LOCK"
  say "CA bundle repinned: $newsha"
  warn "Commit upstream.lock, and re-test HTTPS on a device before releasing."
else
  fetch "$(jqlock '.ca_bundle.url')" "$CA_FILE" "$(jqlock '.ca_bundle.sha256')" \
        "CA bundle (Mozilla via curl.se, $(jqlock '.ca_bundle.mozilla_date'))"
fi

if [ "$WITH_VOXEL" = 1 ]; then
  VOXEL_ZIP="$CACHE/DRAMATIC_SHAPE-$(jqlock '.voxel_mod.version').zip"
  fetch "$(jqlock '.voxel_mod.url')" "$VOXEL_ZIP" "$(jqlock '.voxel_mod.sha256')" \
        "voxel mod $(jqlock '.voxel_mod.version') (~8 MB)"
fi

# libmpg123: liblove needs it and the firmware does not ship it (see the mpg123
# note in upstream.lock). Fetched as a Debian/Ubuntu .deb and unpacked below.
MPG_DEB="$CACHE/$(basename "$(jqlock '.mpg123.url')")"
fetch "$(jqlock '.mpg123.url')" "$MPG_DEB" "$(jqlock '.mpg123.deb_sha256')" \
      "libmpg123 $(jqlock '.mpg123.version') (aarch64 .deb)"

# --------------------------------------------------------------------- staging
say "staging $PAK"
rm -rf "$BUILD"
mkdir -p "$PAK"

WORK="$BUILD/.work"
mkdir -p "$WORK"
unzip -q "$PORT_ZIP" -d "$WORK" || fail "could not unpack $ASSET"

SRC="$WORK/gen1recomp"
[ -d "$SRC/lovegame" ] || fail "unexpected upstream layout: $SRC/lovegame is missing.
The RG34XXSP port structure changed; build.sh needs updating."

# Runtime: taken from the port zip rather than fetched separately from
# PortMaster. See the note in upstream.lock -- these are byte-identical, so this
# is one pinned download instead of six branch-tracked raw URLs, and the runtime
# is guaranteed to be the build upstream tested this game version against.
mkdir -p "$PAK/bin" "$PAK/libs.aarch64" "$PAK/licenses"
cp "$SRC/bin/love.aarch64" "$PAK/bin/love.aarch64"
chmod +x "$PAK/bin/love.aarch64"
cp "$SRC"/libs.aarch64/*.so* "$PAK/libs.aarch64/"

say "verifying the bundled LOVE runtime against upstream.lock"
while IFS=$'\t' read -r rel want; do
  [ -f "$PAK/$rel" ] || fail "runtime file missing from the port zip: $rel"
  got="$(sha256sum "$PAK/$rel" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || fail "the LOVE runtime in $ASSET is not the pinned build.
  file     $rel
  expected $want
  got      $got
Upstream changed its bundled LOVE runtime. Verify it on device, then update
love_runtime.files in upstream.lock."
done < <(jq -r '.love_runtime.files | to_entries[] | [.key, .value] | @tsv' "$LOCK")

# Firmware-supplement library: libmpg123.so.0.
#
# liblove NEEDs it and neither the port zip nor the firmware provides it, so
# love.aarch64 fails to load without this one file (see the mpg123 note in
# upstream.lock). It goes in its own bin/lib/ rather than libs.aarch64/, which
# stays exactly the pinned LOVE runtime; launch.sh adds bin/lib to LD_LIBRARY_PATH.
say "unpacking the bundled libmpg123 into bin/lib/"
mkdir -p "$PAK/bin/lib"
MPG_MEMBER="$(jqlock '.mpg123.member')"
MPG_WORK="$WORK/mpg123"
mkdir -p "$MPG_WORK"
# .deb = an ar archive whose data.tar.xz holds the files. `ar p` streams that
# member to tar; the pinned deb uses xz, so -J is correct and asserts it.
ar p "$MPG_DEB" data.tar.xz | tar -xJ -C "$MPG_WORK" "./$MPG_MEMBER" \
  || fail "could not extract $MPG_MEMBER from $(basename "$MPG_DEB")"
[ -s "$MPG_WORK/$MPG_MEMBER" ] || fail "$MPG_MEMBER came out empty from $(basename "$MPG_DEB")"
# Install under the SONAME liblove looks up (libmpg123.so.0), as a real file --
# never a symlink, which exFAT/FAT32 cards cannot store.
cp "$MPG_WORK/$MPG_MEMBER" "$PAK/$(jqlock '.mpg123.install_path')"
got="$(sha256sum "$PAK/$(jqlock '.mpg123.install_path')" | cut -d' ' -f1)"
want="$(jqlock '.mpg123.so_sha256')"
[ "$got" = "$want" ] || fail "the extracted libmpg123 is not the pinned build.
  expected $want
  got      $got"
say "verified bin/lib/libmpg123.so.0 against upstream.lock"

# Game payload.
cp -R "$SRC/lovegame" "$PAK/game"

# portable.txt makes LOVE write beside main.lua -- i.e. inside the pak directory,
# where the next pak update would delete every save. launch.sh points
# XDG_DATA_HOME at .userdata/shared/Gen1Recomp instead, so this must go.
rm -f "$PAK/game/portable.txt"

# Yellow's import manifest, from the .love (see the downloads section). Assert it
# was actually absent first: if upstream starts shipping it in the port zip, this
# whole detour should go, and silently overwriting theirs would hide that.
if [ -e "$PAK/game/$YELLOW_MEMBER" ]; then
  warn "the port zip now ships $YELLOW_MEMBER itself -- the .love detour can be dropped"
else
  unzip -q -o "$LOVE_ZIP" "$YELLOW_MEMBER" -d "$PAK/game" \
    || fail "could not extract $YELLOW_MEMBER from $LOVE_ASSET"
  [ -s "$PAK/game/$YELLOW_MEMBER" ] \
    || fail "$YELLOW_MEMBER came out empty from $LOVE_ASSET"
  say "added $YELLOW_MEMBER from $LOVE_ASSET"
fi

# Never ship ROM-derived data. Upstream already excludes it, so finding any here
# means something changed and a human should look before we publish.
for gen in "$PAK/game/data/generated" "$PAK/game/assets/generated"; do
  if [ -e "$gen" ]; then
    fail "the upstream payload contains ROM-derived data at ${gen#"$PAK/"} -- refusing to build"
  fi
done

# Licences: keep upstream's LOVE notice and add our own attribution.
[ -f "$SRC/licenses/LICENSE.love2d.txt" ] \
  && cp "$SRC/licenses/LICENSE.love2d.txt" "$PAK/licenses/"

# ------------------------------------------------------------------- voxel mod
if [ "$WITH_VOXEL" = 1 ]; then
  MOD_DIR="$PAK/$(jqlock '.voxel_mod.install_path' | sed 's|^game/|game/|')"
  say "installing voxel mod -> ${MOD_DIR#"$PAK/"}"
  mkdir -p "$MOD_DIR"
  unzip -q "$VOXEL_ZIP" -d "$MOD_DIR" || fail "could not unpack the voxel mod"
  [ -f "$MOD_DIR/main.lua" ] || fail "voxel mod has no main.lua -- unexpected archive layout"
else
  say "skipping voxel mod (--no-voxel)"
fi

# ----------------------------------------------------------------- pak sources
mkdir -p "$PAK/assets"
cp "$CA_FILE" "$PAK/$(jqlock '.ca_bundle.install_path')"

cp "$ROOT/launch.sh" "$PAK/launch.sh"
chmod +x "$PAK/launch.sh"
cp "$ROOT/pak.json" "$ROOT/LICENSE" "$PAK/"
[ -f "$ROOT/README.md" ] && cp "$ROOT/README.md" "$PAK/"

cat > "$PAK/licenses/ATTRIBUTION.txt" <<EOF
NextUI-Gen1Recomp-Pak -- MIT. https://github.com/carroarmato0/NextUI-Gen1Recomp-Pak

Bundles:

  Gen1Recomp $VERSION ($TAG) -- MIT
    https://github.com/bryanthaboi/gen1recomp
    Credits the pret group's pokered disassembly.

  LOVE $(jqlock '.love_runtime.version') aarch64 runtime -- zlib
    https://love2d.org/  --  aarch64 build from PortMaster
    https://github.com/PortsMaster/PortMaster-GUI

  libmpg123 $(jqlock '.mpg123.version') (libmpg123.so.0, aarch64) -- LGPL-2.1
    https://www.mpg123.de/
    A dependency of liblove that the firmware does not ship; bundled unmodified
    from the Ubuntu 18.04 $(jqlock '.mpg123.package') package.

$( [ "$WITH_VOXEL" = 1 ] && cat <<VOX
  DramaticShapeVoxelMod $(jqlock '.voxel_mod.version')
    Original repository (DramaticShape/DramaticShapeVoxelMod) is no longer
    available; archived copy from
    https://github.com/linkfy/DramaticShapeVoxelModBackup
VOX
)
Device bring-up parameters for TrimUI hardware were learned from nx-redux
(GPL-3.0), https://github.com/mohammadsyuhada/nx-redux -- referenced for factual
settings only; no code was copied.
EOF

rm -rf "$WORK"

# ------------------------------------------------------------------ stamp/report
jq -n --arg tag "$TAG" --arg ver "$VERSION" --argjson voxel "$WITH_VOXEL" \
      --arg pak "$(jq -r .version "$ROOT/pak.json")" \
      '{pak_version:$pak, gen1recomp_tag:$tag, gen1recomp_version:$ver,
        voxel_mod:($voxel==1)}' > "$BUILD/build-info.json"

say "done."
printf '  pak       %s\n'  "$PAK"
printf '  upstream  %s (%s)\n' "$VERSION" "$TAG"
printf '  voxel mod %s\n'  "$( [ "$WITH_VOXEL" = 1 ] && echo "yes ($(jqlock '.voxel_mod.version'))" || echo no )"
printf '  size      %s\n'  "$(du -sh "$PAK" | cut -f1)"
