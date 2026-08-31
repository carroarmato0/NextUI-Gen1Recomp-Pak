#!/usr/bin/env bash
# Assemble the pak contents into build/Gen1Recomp.pak/.
#
# There is no compiler involved. Everything is fetched from pinned, hash-verified
# upstream artifacts and rearranged:
#
#   upstream release zip  ->  bin/love.aarch64, libs.aarch64/, game/
#   voxel mod release zip ->  game/mods/DRAMALESS_SHAPE/
#   this repo             ->  launch.sh, pak.json, LICENSE, README.md
#
# Usage:
#   scripts/build.sh [--no-voxel] [--tag vX.Y.Z] [--refresh-lock] [--refresh-ca]
#
#   --no-voxel      skip the voxel mod: 0.5 MB to download, 1.8 MB of the pak
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

for t in curl unzip zip jq sha256sum readelf ar tar patch; do
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

  # The .love asset of the SAME release: that is the game payload. Repinned here
  # rather than in a separate step because the payload and the runtime it is built
  # against must come from one release.
  read -r ym_asset ym_sha ym_size <<EOF
$(jq -r '.assets[] | select(.name|test("\\.love$"))
         | [.name, (.digest // "" | sub("^sha256:";"")), (.size|tostring)] | @tsv' "$api")
EOF
  [ -n "${ym_asset:-}" ] || fail "release $new_tag has no .love asset (that is the game payload)"
  [ -n "${ym_sha:-}" ] || fail "release $new_tag ships no sha256 digest for $ym_asset"

  new_ver="${new_tag#v}"
  tmp="$LOCK.tmp"
  jq --arg tag "$new_tag" --arg ver "$new_ver" --arg asset "$new_asset" \
     --arg sha "$new_sha" --argjson size "$new_size" \
     --arg yasset "$ym_asset" --arg ysha "$ym_sha" --argjson ysize "$ym_size" \
     '.gen1recomp.tag=$tag | .gen1recomp.version=$ver | .gen1recomp.asset=$asset
      | .gen1recomp.sha256=$sha | .gen1recomp.size=$size
      | .game_payload.asset=$yasset | .game_payload.sha256=$ysha
      | .game_payload.size=$ysize' "$LOCK" > "$tmp"
  mv "$tmp" "$LOCK"
  say "upstream.lock now pins $new_tag ($new_asset, $ym_asset)"
fi

TAG="${WANT_TAG:-$(jqlock '.gen1recomp.tag')}"
VERSION="$(jqlock '.gen1recomp.version')"
ASSET="$(jqlock '.gen1recomp.asset')"
ASSET_SHA="$(jqlock '.gen1recomp.sha256')"
REPO="$(jqlock '.gen1recomp.repo')"
GAME_ASSET="$(jqlock '.game_payload.asset')"
GAME_ASSET_SHA="$(jqlock '.game_payload.sha256')"

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
  GAME_ASSET_SHA=""
  GAME_ASSET="$(basename "$(curl -fsL --connect-timeout 20 --max-time 120 \
    "https://api.github.com/repos/$REPO/releases/tags/$WANT_TAG" \
    | jq -r '.assets[]|select(.name|test("\\.love$")).name')")"
  [ -n "$GAME_ASSET" ] || fail "no .love asset on tag $WANT_TAG"
fi

# ------------------------------------------------------------------- downloads
PORT_ZIP="$CACHE/$ASSET"
fetch "https://github.com/$REPO/releases/download/$TAG/$ASSET" \
      "$PORT_ZIP" "$ASSET_SHA" "Gen1Recomp $VERSION port ($((  $(jqlock '.gen1recomp.size') / 1024 / 1024 )) MB)"

# The game payload. Upstream's .love, not the port zip's lovegame/ -- see
# upstream.lock game_payload for why the port zip cannot be trusted for this.
GAME_LOVE="$CACHE/$GAME_ASSET"
fetch "https://github.com/$REPO/releases/download/$TAG/$GAME_ASSET" \
      "$GAME_LOVE" "$GAME_ASSET_SHA" "Gen1Recomp $VERSION game payload (.love)"

# CA bundle. The device has no certificate store whatsoever, so without this every
# HTTPS call the engine makes (mod index, update checks) dies with curl exit 60.
CA_FILE="$CACHE/cacert.pem"
if [ "$REFRESH_CA" = 1 ]; then
  say "refreshing the CA bundle"
  rm -f "$CA_FILE"
  curl -fL --connect-timeout 20 --max-time 120 --progress-bar \
    "$(jqlock '.ca_bundle.url')" -o "$CA_FILE" || fail "could not fetch the CA bundle"
  newsha="$(sha256sum "$CA_FILE" | cut -d' ' -f1)"
  # Repin the date as well as the hash. It is what the non-refresh path prints and
  # the only human-readable record of how old the roots are, so leaving it behind
  # would make a fresh bundle look stale and a stale one look fresh.
  newdate="$(sed -n 's/^## Certificate data from Mozilla as of: *//p' "$CA_FILE" | head -1)"
  newdate="$(date -u -d "$newdate" +%Y-%m-%d 2>/dev/null || echo unknown)"
  tmp="$LOCK.tmp"
  jq --arg s "$newsha" --arg d "$newdate" \
     '.ca_bundle.sha256=$s | .ca_bundle.mozilla_date=$d' "$LOCK" > "$tmp" && mv "$tmp" "$LOCK"
  say "CA bundle repinned: $newsha (Mozilla $newdate)"
  warn "Commit upstream.lock, and re-test HTTPS on a device before releasing."
else
  fetch "$(jqlock '.ca_bundle.url')" "$CA_FILE" "$(jqlock '.ca_bundle.sha256')" \
        "CA bundle (Mozilla via curl.se, $(jqlock '.ca_bundle.mozilla_date'))"
fi

if [ "$WITH_VOXEL" = 1 ]; then
  VOXEL_ZIP="$CACHE/$(jqlock '.voxel_mod.name')-$(jqlock '.voxel_mod.version').zip"
  fetch "$(jqlock '.voxel_mod.url')" "$VOXEL_ZIP" "$(jqlock '.voxel_mod.sha256')" \
        "voxel mod $(jqlock '.voxel_mod.name') $(jqlock '.voxel_mod.version') (~0.5 MB)"
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
# Only the runtime and the LOVE licence are taken from here; the game comes from
# the .love. Assert what we actually read, so a layout change fails loudly.
[ -d "$SRC/bin" ] && [ -d "$SRC/libs.aarch64" ] || fail "unexpected upstream layout: \
$SRC/bin or $SRC/libs.aarch64 is missing.
The RG34XXSP port structure changed; build.sh needs updating."

# Runtime: taken from the port zip rather than fetched separately from
# PortMaster. See the note in upstream.lock -- these are byte-identical, so this
# is one pinned download instead of six branch-tracked raw URLs, and the runtime
# is guaranteed to be the build upstream tested this game version against.
mkdir -p "$PAK/bin" "$PAK/libs.aarch64" "$PAK/licenses"
cp "$SRC/bin/love.aarch64" "$PAK/bin/love.aarch64"
chmod +x "$PAK/bin/love.aarch64"
cp "$SRC"/libs.aarch64/*.so* "$PAK/libs.aarch64/"

# Everything upstream ships is copied first and the unwanted removed by name,
# rather than copying an allowlist: a library we have never seen must survive
# into the staged tree so verify.sh's exact-name check can fail on it. Dropping
# it here instead would make a new upstream dependency invisible.
while read -r rel; do
  [ -n "$rel" ] || continue
  [ -f "$PAK/$rel" ] || fail "upstream.lock says to strip $rel, but the port zip has no such file.
Upstream dropped it on its own -- remove it from love_runtime.strip in upstream.lock."
  rm -f "$PAK/$rel"
  say "stripped $rel ($(jqlock '.love_runtime._strip_reason'))"
done < <(jq -r '.love_runtime.strip[]?' "$LOCK")

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

# Game payload, straight out of upstream's .love. NOT the port zip's lovegame/:
# that is a downstream repackaging and it is trimmed, having dropped Yellow's
# import manifest in 0.1.77 and Gold's in 0.1.79 while still shipping an engine
# that declares both. See upstream.lock game_payload.
mkdir -p "$PAK/game"
unzip -q -o "$GAME_LOVE" -d "$PAK/game" || fail "could not unpack $GAME_ASSET"
[ -f "$PAK/game/main.lua" ] || fail "unexpected .love layout: no main.lua at the root of $GAME_ASSET"

# portable.txt makes LOVE write beside main.lua -- i.e. inside the pak directory,
# where the next pak update would delete every save. launch.sh points
# XDG_DATA_HOME at .userdata/shared/Gen1Recomp instead, so this must go. The .love
# does not currently carry one (the port zip did), so this is defence in depth
# against upstream adding it; verify.sh asserts the result independently.
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
# The archive is NESTED -- everything sits under a single DRAMALESS_SHAPE-<ver>/
# whose name changes every release -- where the old DRAMATIC_SHAPE zip was flat
# at its root. The folder name is pinned in the lock rather than globbed, so an
# upstream layout change fails the build instead of quietly installing a tree the
# loader finds no entry point in. unzip -j is not an option: the mod has subdirs.
if [ "$WITH_VOXEL" = 1 ]; then
  MOD_DIR="$PAK/$(jqlock '.voxel_mod.install_path')"
  MOD_WORK="$WORK/voxel"
  ROOT_DIR="$(jqlock '.voxel_mod.archive_root')"
  say "installing voxel mod -> ${MOD_DIR#"$PAK/"}"

  mkdir -p "$MOD_WORK"
  unzip -q "$VOXEL_ZIP" -d "$MOD_WORK" || fail "could not unpack the voxel mod"

  # Exactly one top-level entry, and it is the name we pinned.
  found="$(find "$MOD_WORK" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)"
  [ "$found" = "$ROOT_DIR" ] || fail "unexpected voxel mod archive layout.
upstream.lock pins archive_root '$ROOT_DIR'; the zip's top level holds:
$found"

  mkdir -p "$(dirname "$MOD_DIR")"
  mv "$MOD_WORK/$ROOT_DIR" "$MOD_DIR"

  # The LICENSE is the whole reason this mod replaced the last one -- see the
  # voxel_mod note in upstream.lock. A build that loses it must not succeed.
  for f in main.lua manifest.json LICENSE; do
    [ -f "$MOD_DIR/$f" ] || fail "voxel mod is missing $f -- refusing to build"
  done
  cp "$MOD_DIR/LICENSE" "$PAK/licenses/LICENSE.$(jqlock '.voxel_mod.name').txt"

  # Patches carried against the mod, each with its reasoning in the file header.
  # These exist only because an upstream removal broke a mod whose author has not
  # shipped since; every one is reported upstream and must be dropped, not
  # carried, once a release fixes it. Fails closed: a patch that no longer
  # applies means the mod moved and a human has to look.
  while read -r rel; do
    [ -n "$rel" ] || continue
    [ -f "$ROOT/$rel" ] || fail "upstream.lock pins patch $rel, which is not in this tree"
    patch -p1 -s --no-backup-if-mismatch -d "$MOD_DIR" < "$ROOT/$rel" \
      || fail "patch $rel did not apply to $(jqlock '.voxel_mod.name') $(jqlock '.voxel_mod.version').
The mod changed underneath it. Re-cut the patch, or drop it if upstream fixed the cause
(see the header of $rel)."
    say "applied $(basename "$rel")"
  done < <(jq -r '.voxel_mod.patches[]?' "$LOCK")
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
  $(jqlock '.voxel_mod.name') $(jqlock '.voxel_mod.version') -- $(jqlock '.voxel_mod.license')
    https://github.com/$(jqlock '.voxel_mod.repo')
    Full licence text in licenses/LICENSE.$(jqlock '.voxel_mod.name').txt.
    Derived from DramaticShapeVoxelMod (MIT-era code) and from MIT-licensed code
    in the TERRARIUM fork by BrenoBertucci, with fixes and additions by
    Stahltier (artyrambles), redistributed under the MIT licence above.
VOX
)
Device bring-up parameters for TrimUI hardware were learned from nx-redux
(GPL-3.0), https://github.com/mohammadsyuhada/nx-redux -- referenced for factual
settings only; no code was copied.
EOF

# ------------------------------------------------------- hand-installed mods
# The one folder the engine ALREADY watches for mods a player added by hand.
# LauncherMods.adoptStrays() runs once per session just before the MODS listing
# and copies what it finds into the save dir's mods/. It scans
# SaveData.gameFolders() -- on Linux getSource() and getSourceBaseDirectory().
# launch.sh runs `love.aarch64 "$PAK_DIR/game"`, so the source is game/ (skipped:
# isReadableRoot drops anything already on the read path) and the base is the pak
# directory. Shipping the folder is the feature: an empty folder with a note in it
# gets found, and a path buried in a README does not.
mkdir -p "$PAK/mods"
cat > "$PAK/mods/README.txt" <<'EOF'
Put mods you installed by hand in this folder.

One folder per mod, with the mod's manifest.json directly inside it:

    mods/SomeMod/manifest.json
    mods/SomeMod/main.lua
    ...

Unzip the mod first -- a .zip left in here is ignored. If you end up with
mods/SomeMod/SomeMod/manifest.json, move the inner folder up one level.

The game picks these up by itself. Start the game, open the mod manager
(MODS), and it copies anything new here into your save data, telling you
"Imported from the game folder: ...". After that the mod is yours: it lives
with your saves, it survives updates to this pak, and you can turn it on and
off from the MODS screen like any other.

The copy left in this folder does nothing after that point. You can delete it.

A mod already installed under the same name is left alone -- what you have
installed always wins, so nothing here can quietly replace it.

Nothing in this folder is read while you are playing, and this pak neither
downloads nor checks these mods. They are yours, and they run with the same
access any other mod has.
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
printf '  voxel mod %s\n'  "$( [ "$WITH_VOXEL" = 1 ] && echo "yes ($(jqlock '.voxel_mod.name') $(jqlock '.voxel_mod.version'))" || echo no )"
printf '  size      %s\n'  "$(du -sh "$PAK" | cut -f1)"
