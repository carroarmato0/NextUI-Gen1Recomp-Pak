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
#   scripts/build.sh [--no-voxel] [--tag vX.Y.Z] [--refresh-lock]
#
#   --no-voxel      skip the ~8 MB voxel mod (smaller pak, no 3D)
#   --tag           build a specific upstream tag instead of upstream.lock's
#   --refresh-lock  resolve the LATEST upstream release and rewrite upstream.lock
#                   with the new tag/asset/sha256 (what upstream-watch.yml uses)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/upstream.lock"
CACHE="$ROOT/.cache"
BUILD="$ROOT/build"
PAK="$BUILD/Gen1Recomp.pak"

WITH_VOXEL=1
WANT_TAG=""
REFRESH_LOCK=0

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarn:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --no-voxel)     WITH_VOXEL=0 ;;
    --tag)          WANT_TAG="${2:?--tag needs a value}"; shift ;;
    --refresh-lock) REFRESH_LOCK=1 ;;
    -h|--help)      sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)              fail "unknown argument: $1" ;;
  esac
  shift
done

for t in curl unzip zip jq sha256sum readelf; do
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
  curl -fL --connect-timeout 20 --max-time 600 --retry 3 --retry-delay 2 \
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

  new_ver="${new_tag#v}"
  tmp="$LOCK.tmp"
  jq --arg tag "$new_tag" --arg ver "$new_ver" --arg asset "$new_asset" \
     --arg sha "$new_sha" --argjson size "$new_size" \
     '.gen1recomp.tag=$tag | .gen1recomp.version=$ver | .gen1recomp.asset=$asset
      | .gen1recomp.sha256=$sha | .gen1recomp.size=$size' "$LOCK" > "$tmp"
  mv "$tmp" "$LOCK"
  say "upstream.lock now pins $new_tag ($new_asset)"
fi

TAG="${WANT_TAG:-$(jqlock '.gen1recomp.tag')}"
VERSION="$(jqlock '.gen1recomp.version')"
ASSET="$(jqlock '.gen1recomp.asset')"
ASSET_SHA="$(jqlock '.gen1recomp.sha256')"
REPO="$(jqlock '.gen1recomp.repo')"

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
fi

# ------------------------------------------------------------------- downloads
PORT_ZIP="$CACHE/$ASSET"
fetch "https://github.com/$REPO/releases/download/$TAG/$ASSET" \
      "$PORT_ZIP" "$ASSET_SHA" "Gen1Recomp $VERSION port ($((  $(jqlock '.gen1recomp.size') / 1024 / 1024 )) MB)"

if [ "$WITH_VOXEL" = 1 ]; then
  VOXEL_ZIP="$CACHE/DRAMATIC_SHAPE-$(jqlock '.voxel_mod.version').zip"
  fetch "$(jqlock '.voxel_mod.url')" "$VOXEL_ZIP" "$(jqlock '.voxel_mod.sha256')" \
        "voxel mod $(jqlock '.voxel_mod.version') (~8 MB)"
fi

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

# Game payload.
cp -R "$SRC/lovegame" "$PAK/game"

# portable.txt makes LOVE write beside main.lua -- i.e. inside the pak directory,
# where the next pak update would delete every save. launch.sh points
# XDG_DATA_HOME at .userdata/shared/Gen1Recomp instead, so this must go.
rm -f "$PAK/game/portable.txt"

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
