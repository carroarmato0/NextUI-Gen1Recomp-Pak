#!/usr/bin/env bash
# Static and contract checks over the staged pak in build/Gen1Recomp.pak/.
#
# Scope, stated plainly: this verifies PACKAGING and CONTRACTS. It cannot tell you
# the pak works. GitHub runners have no aarch64 TrimUI, no Mali/PowerVR GPU and no
# NextUI, so GLES, audio, input, frame rate and the voxel mod's memory ceiling are
# all outside what any CI job here can observe. scripts/verify-device.sh is the
# functional test.
#
# The contract checks are the valuable half. launch.sh hard-codes assumptions about
# upstream's payload; if upstream changes one, the failure mode on device is a black
# screen with no explanation. Better to fail here, loudly, with a name attached.
#
# Usage: scripts/verify.sh [--skip-lint]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/upstream.lock"
PAK="$ROOT/build/Gen1Recomp.pak"
DIST="$ROOT/dist"
SKIP_LINT=0
[ "${1:-}" = "--skip-lint" ] && SKIP_LINT=1

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[1;32mok\033[0m   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[1;31mFAIL\033[0m %s\n' "$1"; }
note() { printf '  \033[1;33m--\033[0m   %s\n' "$1"; }
check(){ if [ "$1" = 0 ]; then ok "$2"; else bad "$2"; fi; }
group(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# matches <extended-regex>  -- reads stdin, true if at least one line matches.
#
# Use this instead of `producer | grep -q`. `grep -q` exits at the first hit,
# which SIGPIPEs the producer; under `pipefail` the pipeline then reports 141 and
# a successful match is read as a failure. That bit us for real: checking the
# .pakz listing for tg5040 (match at line 649 of 1306) failed while the identical
# tg5050 check (line 1299, close enough to EOF that the producer finished) passed.
# `grep -c` consumes all of stdin, so no signal is ever delivered.
matches() { [ "$(grep -cE "$1" 2>/dev/null || true)" -gt 0 ]; }

# launch.sh with comments stripped. Checks that forbid a *behaviour* must look at
# code only: launch.sh discusses several traps in prose precisely because they are
# traps, and grepping the whole file flags the documentation instead of the thing
# being documented.
code_only() { sed 's/[[:space:]]*#.*$//' "$ROOT/launch.sh" | grep -v '^[[:space:]]*$'; }

command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }
[ -d "$PAK" ] || { echo "build/Gen1Recomp.pak not found -- run scripts/build.sh first" >&2; exit 2; }

jqlock() { jq -r "$1" "$LOCK"; }

# ---------------------------------------------------------------- manifest
group "Manifest"

jq -e . "$ROOT/pak.json" >/dev/null 2>&1
check $? "pak.json is valid JSON"

jq -e . "$LOCK" >/dev/null 2>&1
check $? "upstream.lock is valid JSON"

[ "$(jq -r .name "$ROOT/pak.json")" = "Gen1Recomp" ]
check $? "pak.json name is Gen1Recomp (must match the .pak directory)"

# TOOL, not EMU. The pak is self-contained -- it imports the player's own dump --
# so it needs no ROM folder and no launchable stub file inside one. Typing it EMU
# put it under Games, where it did not appear at all unless the user had also
# created the folder and the stub by hand.
[ "$(jq -r .type "$ROOT/pak.json")" = "TOOL" ]
check $? "pak.json type is TOOL (it belongs in Tools, not Games)"

[ "$(jq -r .release_filename "$ROOT/pak.json")" = "Gen1Recomp.pak.zip" ]
check $? "release_filename matches what release.sh produces"

[[ "$(jq -r .version "$ROOT/pak.json")" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
check $? "version is v-prefixed semver"

[ "$(jq -r '.platforms|sort|join(",")' "$ROOT/pak.json")" = "tg5040,tg5050" ]
check $? "platforms are exactly tg5040 and tg5050 (NextUI supports no others)"

jq -e --arg v "$(jq -r .version "$ROOT/pak.json")" '.changelog[$v]' "$ROOT/pak.json" >/dev/null 2>&1
check $? "the current version has a changelog entry"

# The pak's own version is independent of upstream's, so the bundled upstream
# version has to be discoverable somewhere a user will actually look.
jq -r .description "$ROOT/pak.json" | matches "$(jqlock '.gen1recomp.version')"
check $? "description names the bundled Gen1Recomp version ($(jqlock '.gen1recomp.version'))"

# A manifest that lists screenshots which are not in the repo renders as broken
# images in the Pak Store. An empty list is honest; a wrong one is not.
missing_shots=""
while IFS= read -r s; do
    [ -n "$s" ] || continue
    [ -f "$ROOT/$s" ] || missing_shots="$missing_shots $s"
done < <(jq -r '.screenshots[]?' "$ROOT/pak.json")
[ -z "$missing_shots" ]
check $? "every screenshot listed in pak.json exists${missing_shots:+ -- MISSING:$missing_shots}"

# ------------------------------------------------------------ runtime / ELF
group "LOVE runtime"

if command -v readelf >/dev/null; then
    readelf -h "$PAK/bin/love.aarch64" 2>/dev/null | matches 'AArch64'
    check $? "bin/love.aarch64 is an AArch64 ELF"

    needed="$(readelf -d "$PAK/bin/love.aarch64" 2>/dev/null \
              | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | sort | tr '\n' ' ')"
    # If this set grows, the new library must ship in libs.aarch64/ or bin/lib/,
    # or be present in the firmware -- otherwise the device gets a loader failure.
    [ "$needed" = "ld-linux-aarch64.so.1 libc.so.6 liblove-11.5.so libluajit-5.1.so.2 " ]
    check $? "love.aarch64 needs only libc + the bundled liblove/libluajit  [$needed]"

    # liblove NEEDs libmpg123.so.0 and some firmware images ship none, so the pak
    # carries a fallback (see the mpg123 note in upstream.lock). If liblove ever
    # stops needing it, drop the bundle rather than shipping a dead file.
    readelf -d "$PAK/libs.aarch64/liblove-11.5.so" 2>/dev/null \
        | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' | matches '^libmpg123\.so\.0$'
    check $? "liblove still NEEDs libmpg123.so.0 (the reason bin/lib exists)"
else
    note "readelf unavailable -- skipped ELF checks"
fi

[ -x "$PAK/bin/love.aarch64" ]
check $? "bin/love.aarch64 is executable"

# An exact name set, not a count. The pinned files ARE the allowlist, so this
# cannot be satisfied by bumping a number: an unknown library upstream starts
# shipping fails here by name, which is how liblibrashader_bridge.so was caught.
# Anything deliberately not installed is listed in love_runtime.strip and so is
# absent from love_runtime.files -- see the strip note in upstream.lock.
want_libs=$(jq -r '.love_runtime.files | keys[]
                   | select(startswith("libs.aarch64/"))
                   | sub("^libs\\.aarch64/"; "")' "$LOCK" | sort | tr '\n' ' ')
got_libs=$(find "$PAK/libs.aarch64" -maxdepth 1 -name '*.so*' -printf '%f\n' | sort | tr '\n' ' ')
libs_msg="libs.aarch64/ holds exactly the pinned LOVE runtime libraries"
[ "$got_libs" = "$want_libs" ] || libs_msg="$libs_msg -- want [$want_libs] got [$got_libs]"
[ "$got_libs" = "$want_libs" ]
check $? "$libs_msg"

# The strip actually happened. Covered by the name set above, but called out so
# a build that silently regains 8.4 MB is named rather than inferred.
strip_ok=0
while read -r rel; do
    [ -n "$rel" ] || continue
    [ ! -e "$PAK/$rel" ] || { bad "stripped library is still staged: $rel"; strip_ok=1; }
done < <(jq -r '.love_runtime.strip[]?' "$LOCK")
check $strip_ok "libraries listed in love_runtime.strip are not installed"

rt_ok=0
while IFS=$'\t' read -r rel want; do
    got=$(sha256sum "$PAK/$rel" 2>/dev/null | cut -d' ' -f1)
    [ "$got" = "$want" ] || { bad "runtime hash mismatch: $rel"; rt_ok=1; }
done < <(jq -r '.love_runtime.files | to_entries[] | [.key,.value] | @tsv' "$LOCK")
check $rt_ok "every runtime file matches its pin in upstream.lock"

# The bundled libmpg123 (see the LOVE runtime note above). It lives in bin/lib/,
# not libs.aarch64/, so the "exactly 4" check above stays about the LOVE runtime.
MPG="$PAK/$(jqlock '.mpg123.install_path')"
[ -f "$MPG" ]
check $? "$(jqlock '.mpg123.install_path') is shipped (liblove needs it; some images lack it)"

if command -v readelf >/dev/null && [ -f "$MPG" ]; then
    readelf -h "$MPG" 2>/dev/null | matches 'AArch64'
    check $? "bin/lib/libmpg123.so.0 is an AArch64 ELF"

    # SONAME must be exactly what liblove looks up, or the loader ignores the file.
    readelf -d "$MPG" 2>/dev/null | matches 'Library soname: \[libmpg123\.so\.0\]'
    check $? "bin/lib/libmpg123.so.0 has SONAME libmpg123.so.0"

    # It must not out-require the runtime the device actually has: liblove itself
    # tops out at GLIBC_2.27, so a libmpg123 needing anything newer would load-fail
    # on the same device liblove runs on. The pinned build needs only GLIBC_2.17.
    hi="$(readelf -V "$MPG" 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -V | tail -1)"
    [ "$hi" = "GLIBC_2.17" ]
    check $? "bin/lib/libmpg123.so.0 needs only GLIBC_2.17 (found ${hi:-none})"
fi

got=$(sha256sum "$MPG" 2>/dev/null | cut -d' ' -f1)
[ "$got" = "$(jqlock '.mpg123.so_sha256')" ]
check $? "bin/lib/libmpg123.so.0 matches its pin in upstream.lock"

# Bundling the library is useless unless launch.sh puts its directory on the
# loader's search path. It must also keep libs.aarch64 on the path.
code_only | matches 'LD_LIBRARY_PATH=.*PAK_DIR/bin/lib'
check $? "launch.sh adds \$PAK_DIR/bin/lib to LD_LIBRARY_PATH"
code_only | matches 'LD_LIBRARY_PATH=.*PAK_DIR/libs\.aarch64'
check $? "launch.sh keeps \$PAK_DIR/libs.aarch64 on LD_LIBRARY_PATH"

# ORDER matters, and getting it wrong is silent. bin/lib must come AFTER
# /usr/trimui/lib: firmware images that have their own libmpg123 ship a much newer
# one (0.44.12, Nov 2025, measured on a Brick) than the bundled fallback (0.44.8,
# 2018), so putting bin/lib first downgrades the decoder on every device that
# already worked. Nothing at runtime would report that -- the game just starts.
code_only | matches 'LD_LIBRARY_PATH=.*/usr/trimui/lib:[$]PAK_DIR/bin/lib'
check $? "launch.sh searches /usr/trimui/lib before \$PAK_DIR/bin/lib (bundle is a fallback)"

# ------------------------------------------------------ payload hygiene
group "Payload hygiene"

[ -f "$PAK/game/main.lua" ] && [ -f "$PAK/game/conf.lua" ]
check $? "game/main.lua and game/conf.lua are present"

[ ! -f "$PAK/game/portable.txt" ]
check $? "game/portable.txt is absent (else a pak update would delete every save)"

[ ! -e "$PAK/game/data/generated" ] && [ ! -e "$PAK/game/assets/generated" ]
check $? "no ROM-derived generated data in the payload"

# Every version the engine declares must have its import manifest on disk. The
# upstream port zip ships Red's and Blue's but NOT Yellow's, so build.sh lifts
# that one out of the same release's .love. If that ever quietly stops working
# the failure lands on the player, mid-import, as "ROM import metadata is
# missing" (RomImporter.lua) -- nothing else here would catch it.
GV="$PAK/game/src/core/GameVersion.lua"
if [ -f "$GV" ]; then
    missing=
    while IFS= read -r m; do
        [ -f "$PAK/game/$m" ] || missing="$missing $m"
    done < <(sed -n 's/.*manifest = "\([^"]*\)".*/\1/p' "$GV")
    [ -z "$missing" ]
    check $? "every import manifest GameVersion.lua declares is shipped${missing:+ -- MISSING:$missing}"
else
    bad "GameVersion.lua is missing from the payload"
fi

# 1 MiB is the exact size of the cartridges this engine accepts, so anything of
# that size and shape is treated as a possible ROM leak and blocks the build.
leak=$(find "$PAK" -type f \( -iname '*.gb' -o -iname '*.gbc' \) 2>/dev/null | head -5)
[ -z "$leak" ]
check $? "no .gb/.gbc file anywhere in the pak${leak:+ -- FOUND: $leak}"

exact1mib=$(find "$PAK" -type f -size 1048576c 2>/dev/null | head -3)
[ -z "$exact1mib" ]
check $? "no 1 MiB file that could be a mis-named ROM${exact1mib:+ -- FOUND: $exact1mib}"

[ -f "$PAK/launch.sh" ] && [ -x "$PAK/launch.sh" ]
check $? "launch.sh is present and executable"

[ -f "$PAK/LICENSE" ] && [ -f "$PAK/licenses/ATTRIBUTION.txt" ]
check $? "LICENSE and licences/ATTRIBUTION.txt are shipped"

# The device has no CA store, so without this every HTTPS call the engine makes
# dies with curl exit 60 and the mod manager just reports a failed check.
CA="$PAK/$(jqlock '.ca_bundle.install_path')"
[ -f "$CA" ]
check $? "a CA bundle is shipped ($(jqlock '.ca_bundle.install_path'))"

certs=$(grep -c 'BEGIN CERTIFICATE' "$CA" 2>/dev/null || echo 0)
[ "$certs" -gt 50 ]
check $? "the CA bundle holds a plausible number of roots ($certs)"

code_only | matches 'CURL_CA_BUNDLE'
check $? "launch.sh exports CURL_CA_BUNDLE"
code_only | matches 'SSL_CERT_FILE'
check $? "launch.sh exports SSL_CERT_FILE (curl here links OpenSSL)"

# ------------------------------------------------------------- contracts
group "Upstream contracts (assumptions launch.sh hard-codes)"

# The single most likely silent breakage. Our runtime is pinned to LOVE 11.5; if
# upstream moves to 12 the game may load and then misbehave in ways no static
# check would notice.
#
# Upstream writes this as a conditional -- currently
#   t.version = love._os == "iOS" and "12.0" or "11.5"
# -- so match the t.version assignment and require our version to appear in it,
# rather than expecting a bare literal.
want_love=$(jqlock '.contracts.love_version')
grep -E '^[[:space:]]*t\.version[[:space:]]*=' "$PAK/game/conf.lua" | matches "\"$want_love\""
check $? "conf.lua's t.version still includes LOVE $want_love"

want_ident=$(jqlock '.contracts.love_identity')
grep -q "$want_ident" "$PAK/game/conf.lua"
check $? "LOVE identity is still '$want_ident' (our XDG_DATA_HOME layout depends on it)"

# How the engine takes a dump from the player, and therefore what launch.sh may
# claim. Getting this wrong is invisible off-device: the pak used to stage a ROM
# where the engine no longer looks, and the game just says "no ROM".
IMP="$PAK/game/src/import/RomImporter.lua"

# The engine now opens its OWN file browser on Linux and returns before the
# pending-ROM scan. That is why launch.sh reports paths instead of staging
# copies -- see contracts.rom_discovery in upstream.lock.
grep -q "$(jqlock '.contracts.rom_discovery.browser')" "$IMP" 2>/dev/null
check $? "the engine still opens $(jqlock '.contracts.rom_discovery.browser') to choose a ROM"

# The moment this stops being true, an unattended import becomes possible again
# and the report-only scan should be revisited -- so it is asserted, not assumed.
# findPendingRom is unreachable while the browser exists: the Choose flow returns
# at the Kit.FileBrowser call above it (RomImporter.lua ~2765, plain-Linux
# branch), and the engine's other two call sites are Android-gated.
grep -q 'findPendingRom' "$IMP" 2>/dev/null
check $? "findPendingRom still exists upstream (unreachable on Linux, but watch it)"

# launch.sh must not go back to copying dumps into the save dir: that imports
# nothing now and duplicates 1-2 MiB per version.
code_only | matches 'cp -f "[$]rom"' \
    && bad "launch.sh copies dumps into the save dir again -- the engine no longer reads them" \
    || ok "launch.sh does not stage dumps (the engine browses for them itself)"

# And it must not delete them either. A dump at the save root is
# indistinguishable from one the player put there by hand.
code_only | matches 'rm -f "[$]SAVEROOT"/[*][.]gb' \
    && bad "launch.sh deletes dumps from the save dir -- they may be the player's own" \
    || ok "launch.sh never deletes a dump from the save dir"

code_only | matches 'baseroms' && bad "launch.sh still references baseroms/, which Linux never reads" || ok "launch.sh does not use the Xbox-only baseroms/ path"

# ShaderFX, and what holds it off. This replaced the old POKEPORT_GBCFX check
# when upstream deleted src/render/GBCFX.lua after 0.2.20; launch.sh now sets no
# shader env var at all, so the thing worth asserting is the tier rule that keeps
# the pass from running. See contracts.shaderfx in upstream.lock.
FX_MODULE="$PAK/game/$(jqlock '.contracts.shaderfx.module')"
PERF="$PAK/game/src/core/Performance.lua"

[ -f "$FX_MODULE" ]
check $? "$(jqlock '.contracts.shaderfx.module') is present (it replaced GBCFX)"

# The old module must stay gone. If upstream restores it, the voxel-mod patch
# below is obsolete and must be deleted rather than carried.
gone="$PAK/game/$(jqlock '.contracts.shaderfx.removed_module')"
[ ! -f "$gone" ]
check $? "$(jqlock '.contracts.shaderfx.removed_module') is still absent (else drop the voxel patch)"

# arm/arm64 on Linux -- every device this pak targets -- must still resolve to
# the tier we rely on.
wanted_tier=$(jqlock '.contracts.shaderfx.arm_linux_tier')
grep -qE 'isArm[[:space:]]+and[[:space:]]+os[[:space:]]*==[[:space:]]*"Linux"' "$PERF" 2>/dev/null \
    && grep -A2 -E 'isArm[[:space:]]+and[[:space:]]+os[[:space:]]*==[[:space:]]*"Linux"' "$PERF" 2>/dev/null \
       | matches "return \"$wanted_tier\""
check $? "Performance.detect still returns '$wanted_tier' for arm Linux"

# ...and that tier's cap must still be a hard off, not a resolution multiplier.
grep -E "^[[:space:]]*${wanted_tier}[[:space:]]*=" "$PERF" 2>/dev/null \
    | matches 'shaderfx[[:space:]]*=[[:space:]]*false'
check $? "Performance.CAPS.$wanted_tier still sets shaderfx = false (no shader pass on this hardware)"

# Nothing for a preset to auto-activate: the pak must ship no slang preset.
[ -z "$(find "$PAK/game" -name '*.slangp' -print -quit 2>/dev/null)" ]
check $? "no .slangp preset is shipped (nothing for POKEPORT_SHADERFX to pick up)"

# launch.sh must not resurrect the dead switch.
code_only | matches "$(jqlock '.contracts.shaderfx.removed_env')" \
    && bad "launch.sh sets $(jqlock '.contracts.shaderfx.removed_env'), which the engine no longer reads" \
    || ok "launch.sh does not set the removed $(jqlock '.contracts.shaderfx.removed_env')"

sha_ok=0
for v in $(jq -r '.contracts.rom_sha1|keys_unsorted[]' "$LOCK"); do
    h=$(jqlock ".contracts.rom_sha1.$v")
    grep -rqi "$h" "$PAK/game/" 2>/dev/null || { bad "ROM SHA-1 for $v not found upstream ($h)"; sha_ok=1; }
done
check $sha_ok "every canonical ROM SHA-1 in the lock still appears in the payload"

# launch.sh matches on SHA-256, not SHA-1, because these devices have no sha1sum.
# If a constant drifts from the lock, the scan silently imports nothing.
ls_ok=0
for v in $(jq -r '.contracts.rom_sha256|keys_unsorted[]' "$LOCK"); do
    h=$(jqlock ".contracts.rom_sha256.$v")
    grep -q "$h" "$ROOT/launch.sh" || { bad "launch.sh is missing the $v SHA-256"; ls_ok=1; }
done
check $ls_ok "launch.sh carries the same ROM SHA-256s as upstream.lock"

# Regression guard for a bug that only a device could find: launch.sh matched ROMs
# with sha1sum, which does not exist on these handhelds. It emitted nothing,
# matched nothing, and logged no error. The absent-tool list is now a contract.
tool_ok=0
while IFS= read -r t; do
    [ -n "$t" ] || continue
    if code_only | matches "(^|[^a-zA-Z0-9_-])${t}([^a-zA-Z0-9_-]|$)"; then
        # A guarded use is fine -- that is how taskset is handled.
        code_only | matches "command -v ${t}" && continue
        bad "launch.sh invokes '$t', absent on the device, with no 'command -v' guard"
        tool_ok=1
    fi
done < <(jq -r '.contracts.device_missing_tools[]?' "$LOCK")
check $tool_ok "launch.sh avoids tools known to be missing on the device"

# The scan is worthless if the hasher it needs is not there.
code_only | matches 'sha256sum'
check $? "launch.sh uses sha256sum (present on device) for the ROM scan"

# ----------------------------------------------------------- voxel mod
group "Voxel mod"

MOD_NAME=$(jqlock '.voxel_mod.name')
MOD_DIR="$PAK/$(jqlock '.voxel_mod.install_path')"

# Whether or not a mod was staged, the legacy ids must be gone. This is the check
# that matters most: a leftover DRAMATIC_SHAPE folder does not break the build,
# it silently disables the mod that replaced it (the declaring mod loses the
# conflict -- see contracts.legacy_mod_ids in upstream.lock).
legacy_ok=0
while IFS= read -r id; do
    [ -n "$id" ] || continue
    if [ -e "$PAK/game/mods/$id" ]; then
        bad "legacy mod '$id' is staged in the pak -- it would disable $MOD_NAME"
        legacy_ok=1
    fi
    # launch.sh cannot read this lock on device, so it spells the ids out. Assert
    # the copy has not drifted from the original.
    code_only | matches "(^|[^A-Z_])${id}([^A-Z_]|$)" \
        || { bad "launch.sh does not remove legacy mod '$id'"; legacy_ok=1; }
done < <(jqlock '.contracts.legacy_mod_ids[]?')
check $legacy_ok "no legacy mod is staged, and launch.sh removes each one"

if [ -d "$MOD_DIR" ]; then
    [ -f "$MOD_DIR/main.lua" ]
    check $? "voxel mod has a main.lua"
    [ -f "$MOD_DIR/manifest.json" ]
    check $? "voxel mod has a manifest.json"

    # The licence is why this mod replaced the last one. The one it replaced had
    # no LICENSE file at all and a README forbidding redistribution, and nothing
    # in the build caught that -- so it is asserted here rather than trusted.
    lic="$MOD_DIR/LICENSE"
    lic_ok=0
    [ -f "$lic" ] || { bad "voxel mod ships no LICENSE file"; lic_ok=1; }
    if [ -f "$lic" ]; then
        grep -q 'MIT License' "$lic" \
            || { bad "voxel mod LICENSE is not the MIT licence"; lic_ok=1; }
        grep -q 'Permission is hereby granted' "$lic" \
            || { bad "voxel mod LICENSE carries no grant of permission"; lic_ok=1; }
    fi
    check $lic_ok "voxel mod ships an MIT licence with a grant of permission"

    [ -f "$PAK/licenses/LICENSE.$MOD_NAME.txt" ]
    check $? "voxel mod licence is copied into licenses/"

    # Carried patches (voxel_mod.patches in upstream.lock). Assert the EFFECT on
    # the staged tree, not that build.sh ran -- a patch that applied to the wrong
    # place still applies cleanly.
    patch_ok=0
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -f "$ROOT/$rel" ] || { bad "upstream.lock pins patch $rel, which is missing"; patch_ok=1; }
    done < <(jq -r '.voxel_mod.patches[]?' "$LOCK")
    check $patch_ok "every patch upstream.lock pins is present in the tree"

    # The GBCFX patch: no unguarded require of the deleted module may survive.
    # Bare `require("src.render.GBCFX")` throws -- and at pinEngineFx, at the top
    # of the ui.options.rows hook, Hooks.lua logs-and-skips the whole wrapper, so
    # the mod's OPTIONS rows vanish. On a handheld those rows are the only way to
    # reach the 3D toggle (the mod's hotkeys are keyboard-only).
    gbcfx_ok=0
    if grep -rqE 'require\("src\.render\.GBCFX"\)[[:space:]]*\.' "$MOD_DIR" 2>/dev/null; then
        bad "voxel mod still has a bare require(\"src.render.GBCFX\").<field> -- the patch did not take"
        gbcfx_ok=1
    fi
    check $gbcfx_ok "voxel mod makes no unguarded require of the removed GBCFX module"

    grep -rq 'pcall(require, "src.render.GBCFX")' "$MOD_DIR" 2>/dev/null
    check $? "voxel mod's GBCFX requires are pcall-guarded (patch applied)"

    # Manifest against the lock and against the loader's own gates. A mod the
    # loader refuses is indistinguishable on device from one that crashed.
    man="$MOD_DIR/manifest.json"
    [ "$(jq -r .id "$man")" = "$MOD_NAME" ]
    check $? "manifest id is $MOD_NAME"
    [ "$(jq -r .version "$man")" = "$(jqlock '.voxel_mod.version')" ]
    check $? "manifest version matches upstream.lock ($(jqlock '.voxel_mod.version'))"
    [ "$(jq -r .profile "$man")" = "content" ]
    check $? "manifest profile is 'content' (the loader refuses anything else here)"
    [ "$(jq -r .api "$man")" -le 2 ]
    check $? "manifest api is <= 2, the engine's mod api"
    [ "$(jq -r '.entry' "$man")" = "main.lua" ]
    check $? "manifest entry is main.lua, which is present"

    # Every id this mod declares a conflict with must be absent from the pak --
    # shipping one would fail THIS mod, not the other.
    conflict_ok=0
    while IFS= read -r spec; do
        [ -n "$spec" ] || continue
        cid="${spec%%@*}"
        [ -e "$PAK/game/mods/$cid" ] && {
            bad "pak ships '$cid', which $MOD_NAME declares a conflict with"
            conflict_ok=1
        }
    done < <(jq -r '.conflicts[]?' "$man")
    check $conflict_ok "pak ships nothing the voxel mod declares a conflict with"

    # The catalogue launch.sh seeds on a fresh install. launch.sh cannot read
    # this lock on device, so assert its hard-coded copy has not drifted.
    idx_ok=0
    for field in owner repo; do
        want=$(jqlock ".contracts.mod_index.$field")
        code_only | matches "$want" || { bad "launch.sh's mod index $field is not '$want'"; idx_ok=1; }
    done
    # The seed must never step in front of the engine's options recovery: when
    # options.lua is missing but a .bak or .tmp survives, loadOptions heals from
    # those, and writing our file first would lose every setting the player had.
    code_only | matches '\.bak' && code_only | matches '\.tmp' \
        || { bad "launch.sh seeds options.lua without checking for .bak/.tmp -- that would eat the player's settings"; idx_ok=1; }
    check $idx_ok "mod index matches the lock, and the seed respects options recovery"

    # Regression guard. The mod this replaced carried 14 MB of Windows OpenXR
    # loader (oxr/, oxr.zip) that cannot execute on aarch64 Linux. Nothing should
    # ever bring that class of payload back in.
    [ -z "$(find "$PAK" \( -name 'oxr' -o -name 'oxr.zip' -o -name '*.dll' -o -name '*.lib' \) -print -quit)" ]
    check $? "pak carries no Windows/VR payload (oxr, .dll, .lib)"
else
    note "voxel mod not present (built with --no-voxel)"
fi

# ------------------------------------------- hand-installed mod drop folder
# $PAK_DIR/mods is what the engine's adoptStrays() scans (getSourceBaseDirectory()
# for our `love.aarch64 "$PAK_DIR/game"` launch). Shipping it with a note is the
# whole feature -- an empty folder gets found, a README path does not.
[ -d "$PAK/mods" ]
check $? "the hand-installed mod drop folder is shipped (mods/)"

[ -f "$PAK/mods/README.txt" ]
check $? "mods/README.txt tells the player what to put there"

# It must ship EMPTY. A mod staged here would be adopted into every player's
# save dir on first launch, which is not something a pak should do silently --
# bundled mods go in game/mods/ and are declared in upstream.lock.
drop_extra="$(find "$PAK/mods" -mindepth 1 ! -name 'README.txt' -print -quit)"
[ -z "$drop_extra" ]
check $? "mods/ ships empty apart from the note (nothing is adopted behind the player)"

# Creating it is launch.sh's job too: a player who deletes the folder must get
# it back rather than losing the route entirely.
code_only | matches 'mkdir -p "[$]MODDROP"'
check $? "launch.sh recreates the drop folder if it is missing"

# ------------------------------------------------------- launch.sh shape
group "launch.sh"

head -1 "$ROOT/launch.sh" | grep -q '^#!/bin/sh$'
check $? "shebang is #!/bin/sh, not bash (PortMaster can hijack /bin/bash on these cards)"

# Cheap bashism screen. CI additionally runs this under dash via test-launch.sh.
#
# Whole-line comments are dropped first. They are never executed, and leaving them
# in produced three false positives in one sitting: the pattern holds \bsource\b
# and \bfunction [a-zA-Z_], so the ordinary English "the source is game/" and
# "function parameter" each failed the build from a comment.
#
# Dropped with grep -v rather than code_only(), which strips from the first '#'
# to end of line and would corrupt every ${var##*/} and ${var%% *} in the file --
# that is exactly why this screen reads the raw script. A trailing comment on a
# line of code is still scanned, which is the rare case and worth keeping strict.
bashisms=$(grep -vE '^[[:space:]]*#' "$ROOT/launch.sh" \
           | grep -nE '\[\[|\bfunction [a-zA-Z_]|[a-zA-Z_]+\+=|<<<|\bdeclare\b|\blocal\b|\bsource\b|&>' || true)
[ -z "$bashisms" ]
check $? "no obvious bashisms${bashisms:+ -- $bashisms}"

code_only | matches 'nextui_exec' && bad "launch.sh touches /tmp/nextui_exec (removing it powers the device off)" || ok "does not touch /tmp/nextui_exec"

code_only | matches 'dd if=/dev/zero|mkswap|swapon' && bad "launch.sh creates swap -- that is Swap.pak's job" || ok "does not create swap (delegated to Swap.pak)"

code_only | matches 'SDL_VIDEODRIVER' && bad "launch.sh sets SDL_VIDEODRIVER -- NextUI never does; let the vendor SDL2 choose" || ok "does not set SDL_VIDEODRIVER"

# NextUI passes a Tool pak no arguments at all. Reading $1 was how the Emu layout
# received the selected ROM-folder entry; anything left reading it would now be
# silently empty rather than obviously broken.
code_only | matches '\$\{?[1@*]' && bad "launch.sh still reads a launch argument -- a Tool pak is invoked with none" || ok "launch.sh takes no launch argument"

# The scan filters candidates by size BEFORE hashing, so a size the engine
# accepts but the filter does not is invisible: the dump is skipped before its
# hash is ever computed and nothing is logged. That is exactly how Gold went
# missing -- Gen 2 carts are 2 MiB and the filter was 1 MiB only. Keep the two
# in step with RomImporter.isAcceptedRomSize.
for want in 1048576 2097152; do
    code_only | matches "size ${want}c"
    check $? "launch.sh's ROM scan accepts ${want}-byte dumps (engine accepts them)"
done

sh -n "$ROOT/launch.sh" 2>/dev/null
check $? "launch.sh parses"

# ----------------------------------------------------------------- dist
if [ -d "$DIST" ]; then
    group "Release artifacts"
    store="$DIST/Gen1Recomp.pak.zip"
    pakz="$DIST/Gen1Recomp.pakz"

    if [ -f "$store" ]; then
        # The Pak Store expects the pak's contents at the zip root.
        unzip -Z1 "$store" | matches '^launch\.sh$'
        check $? "Gen1Recomp.pak.zip has launch.sh at the zip root"
        unzip -Z1 "$store" | matches '^pak\.json$'
        check $? "Gen1Recomp.pak.zip has pak.json at the zip root"
    else
        note "dist/Gen1Recomp.pak.zip not built"
    fi

    if [ -f "$pakz" ]; then
        unzip -Z1 "$pakz" | matches '^Tools/tg5040/Gen1Recomp\.pak/launch\.sh$'
        check $? ".pakz contains Tools/tg5040/Gen1Recomp.pak/launch.sh"
        unzip -Z1 "$pakz" | matches '^Tools/tg5050/Gen1Recomp\.pak/launch\.sh$'
        check $? ".pakz contains Tools/tg5050/Gen1Recomp.pak/launch.sh"

        # Regression guard for the v0.1.0 layout. Shipping Emus/ or a ROM folder
        # again would put a second, stale entry under Games on every card that
        # unpacks the .pakz.
        unzip -Z1 "$pakz" | matches '^(Emus|Roms)/' \
            && bad ".pakz still ships an Emus/ or Roms/ tree (this is a Tool pak now)" \
            || ok ".pakz ships only Tools/ -- no ROM folder, no launchable stub"
    else
        note "dist/Gen1Recomp.pakz not built"
    fi

    # FAT32/exFAT cards cannot hold symlinks; release.sh dereferences with cp -L.
    syms=$(find "$DIST" -type l 2>/dev/null | head -3)
    [ -z "$syms" ]
    check $? "no symlinks in dist/ (exFAT cannot store them)"
fi

# ----------------------------------------------------------------- lint
if [ "$SKIP_LINT" = 0 ]; then
    group "Lint"
    if command -v shellcheck >/dev/null; then
        shellcheck -s sh "$ROOT/launch.sh"
        check $? "shellcheck (sh) launch.sh"
        shellcheck -s bash "$ROOT"/scripts/*.sh "$ROOT"/test/*.sh
        check $? "shellcheck (bash) scripts and tests"
    else
        note "shellcheck not installed -- skipped"
    fi

    if command -v luacheck >/dev/null && [ -f "$PAK/game/.luacheckrc" ]; then
        ( cd "$PAK/game" && luacheck --quiet . >/dev/null 2>&1 )
        check $? "luacheck the payload using upstream's .luacheckrc"
    else
        note "luacheck unavailable or upstream ships no .luacheckrc -- skipped"
    fi
fi

# ---------------------------------------------------------------- summary
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf '\033[1;31mverify failed.\033[0m A contract failure usually means upstream changed\n'
    printf 'something launch.sh depends on. Investigate before releasing.\n'
    exit 1
fi
printf 'Static checks only -- this says nothing about whether the pak runs.\n'
printf 'Run scripts/verify-device.sh on hardware before publishing.\n'
