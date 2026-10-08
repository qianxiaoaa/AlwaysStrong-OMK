#!/usr/bin/env bash
# AlwaysStrong-OMK build script.
#
# Assembles the flashable module ZIP out of three pieces:
#
#   module/                 our sources (AlwaysStrong v1.0.4 + the OhMyKeymint swap)
#   attest/omk.sh           the attestation-engine adapter, overlaid as attest.sh
#   native/*/prebuilt/      AlwaysStrong's own native helpers (asfetch, aswatcher)
#
# plus two upstream release payloads, which are never committed here:
#
#   OhMyKeymint v1.3.5-196-10113e7      libs/arm64-v8a/{keymint,inject,soterta-svc},
#                                       injector.toml, keybox.xml, soterta.sh
#   PlayIntegrityFork v18               classes.dex, zygisk/*.so, the PIF scripts
#
# Usage:
#   ./build.sh                      download both payloads, then build
#   ./build.sh --omk-file PATH      use a local OhMyKeymint zip, skip the download
#   ./build.sh --pif-file PATH      use a local PlayIntegrityFork zip, skip the download
#   ./build.sh --clean              wipe build/ and out/ first
#
# Output: out/AlwaysStrong-<version>.zip

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
STAGE="$BUILD/module"
OUT="$ROOT/out"

OMK_TAG="v1.3.5-196-10113e7"
OMK_ASSET="OhMyKeymint-1.3.5-196-10113e7-release.zip"
OMK_URL="https://github.com/ITxiao6666/OhMyKeymint/releases/download/$OMK_TAG/$OMK_ASSET"

PIF_TAG="v18"
PIF_ASSET="PlayIntegrityFork-v18.zip"
PIF_URL="https://github.com/osm0sis/PlayIntegrityFork/releases/download/$PIF_TAG/$PIF_ASSET"

# Files lifted out of the PlayIntegrityFork zip into the module.
PIF_FILES="autopif4.sh killpi.sh migrate.sh common_setup.sh example.pif.prop app_replace_list.txt"

# ABIs that get AlwaysStrong's native helpers. OhMyKeymint itself is arm64-v8a
# only, which is why attest/omk.sh aborts the install on any other ABI.
ABIS="arm64-v8a armeabi-v7a x86 x86_64"
OMK_ABI="arm64-v8a"

OMK_FILE=""
PIF_FILE=""
CLEAN=0

die()  { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
ok()   { echo "    $*"; }

usage() {
    sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --omk-file) OMK_FILE="$2"; shift 2 ;;
        --pif-file) PIF_FILE="$2"; shift 2 ;;
        --clean)    CLEAN=1; shift ;;
        -h|--help)  usage ;;
        *)          die "unknown option: $1" ;;
    esac
done

command -v unzip >/dev/null 2>&1 || die "unzip not found"

# Info-ZIP's zip is preferred: it records the Unix modes the installer expects.
# A stock Windows box has no zip and no MSYS to borrow one from, so fall back to
# the Python packer in scripts/, which writes the same archive shape.
# `command -v python3` alone is not enough here: the Microsoft Store leaves a
# non-functional python3 alias on PATH, and picking it fails only after the whole
# module is staged. Probe each candidate instead of trusting the first hit.
if [ -z "${PYTHON:-}" ]; then
    for _cand in python3 python py; do
        _p="$(command -v "$_cand" 2>/dev/null)" || continue
        if "$_p" -V >/dev/null 2>&1; then PYTHON="$_p"; break; fi
    done
fi
if ! command -v zip >/dev/null 2>&1 && [ -z "$PYTHON" ]; then
    die "neither zip nor a working python is available to package the module"
fi

pack() {  # pack <out.zip> <dir>
    if command -v zip >/dev/null 2>&1; then
        ( cd "$2" && zip -qr9 "$1" . )
    else
        "$PYTHON" "$ROOT/scripts/zipdir.py" "$1" "$2"
    fi
}

fetch() {  # fetch <dest> <url>
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 -o "$1" "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$1" "$2"
    else
        die "neither curl nor wget is available"
    fi
}

[ "$CLEAN" = 1 ] && { info "Cleaning"; rm -rf "$BUILD" "$OUT"; }

VERSION="$(sed -n 's/^version=//p' "$ROOT/module/module.prop" | head -n 1)"
[ -n "$VERSION" ] || die "module/module.prop has no version="
VERSION="${VERSION%% (*}"

# ---------- 1) our own files ----------
info "Staging module/ (AlwaysStrong $VERSION, OhMyKeymint engine)"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -a "$ROOT/module/." "$STAGE/"

# The engine adapter is kept outside module/ so the swap stays visible.
cp "$ROOT/attest/omk.sh" "$STAGE/attest.sh"
ok "attestation engine: omk (attest/omk.sh -> attest.sh)"

if [ -f "$ROOT/banner.png" ]; then
    cp "$ROOT/banner.png" "$STAGE/banner.png"
    ok "bundled banner.png"
fi

# Native helper -> source path. The watcher's binary is called aswatcher but its
# crate directory is native/watcher, so the name is not enough to find it.
native_src() {  # native_src <bin> <abi>
    case "$1" in
        asfetch)   echo "$ROOT/native/asfetch/prebuilt/$2/asfetch" ;;
        aswatcher) echo "$ROOT/native/watcher/prebuilt/$2/aswatcher" ;;
        *)         echo "" ;;
    esac
}

for abi in $ABIS; do
    for bin in asfetch aswatcher; do
        src="$(native_src "$bin" "$abi")"
        if [ -n "$src" ] && [ -f "$src" ]; then
            mkdir -p "$STAGE/bin/$abi"
            cp "$src" "$STAGE/bin/$abi/$bin"
        fi
    done
done

# The module only installs on arm64-v8a (see attest/omk.sh), so a missing
# arm64-v8a helper means the native/ layout moved and the zip would silently
# ship without the fingerprint crawler or the watcher.
for bin in asfetch aswatcher; do
    [ -f "$STAGE/bin/$OMK_ABI/$bin" ] || die "native/$bin for $OMK_ABI was not staged — native/ layout changed"
done
ok "staged native helpers (asfetch, aswatcher)"

# ---------- 2) OhMyKeymint payload ----------
mkdir -p "$BUILD"
OMK_ZIP="$BUILD/$OMK_ASSET"
if [ -n "$OMK_FILE" ]; then
    [ -f "$OMK_FILE" ] || die "--omk-file not found: $OMK_FILE"
    OMK_ZIP="$OMK_FILE"
    ok "local OhMyKeymint zip: $OMK_ZIP"
elif [ ! -f "$OMK_ZIP" ]; then
    info "Downloading OhMyKeymint $OMK_TAG"
    fetch "$OMK_ZIP" "$OMK_URL"
fi

OMK_X="$BUILD/omk_extracted"
rm -rf "$OMK_X"; mkdir -p "$OMK_X"
unzip -qq -o "$OMK_ZIP" -d "$OMK_X"

# Only the keystore-engine half is lifted out. OMK 1.3.5 also ships its own
# Zygisk PIF payload (zygisk/*.so), an embedded WebUI (webroot/), and its own
# daemon/daemon-injector — AlwaysStrong already provides all of those (bundled
# PlayIntegrityFork, its own WebUI, and omk-daemon/omk-injector which add the
# undecryptable-store recovery), so staging them again would only create two
# competing Fingerprint vendors. soterta-svc + soterta.sh ARE staged: the
# Qualcomm Soter software-TA relay has no AlwaysStrong equivalent.
for f in keymint inject soterta-svc; do
    [ -f "$OMK_X/libs/$OMK_ABI/$f" ] || die "OhMyKeymint zip missing libs/$OMK_ABI/$f — upstream layout changed"
done
[ -f "$OMK_X/injector.toml" ] || die "OhMyKeymint zip missing injector.toml — upstream layout changed"
[ -f "$OMK_X/soterta.sh" ]    || die "OhMyKeymint zip missing soterta.sh — upstream layout changed"

mkdir -p "$STAGE/libs/$OMK_ABI"
for f in keymint inject soterta-svc; do
    cp "$OMK_X/libs/$OMK_ABI/$f" "$STAGE/libs/$OMK_ABI/$f"
done
cp "$OMK_X/injector.toml" "$STAGE/injector.toml"
cp "$OMK_X/soterta.sh"    "$STAGE/soterta.sh"

# Default keybox, used only when the user has none of their own.
[ -f "$OMK_X/keybox.xml" ] && cp "$OMK_X/keybox.xml" "$STAGE/keybox.xml"
ok "staged OhMyKeymint payload ($OMK_ABI)"

# ---------- 3) PlayIntegrityFork payload ----------
PIF_ZIP="$BUILD/$PIF_ASSET"
if [ -n "$PIF_FILE" ]; then
    [ -f "$PIF_FILE" ] || die "--pif-file not found: $PIF_FILE"
    PIF_ZIP="$PIF_FILE"
    ok "local PlayIntegrityFork zip: $PIF_ZIP"
elif [ ! -f "$PIF_ZIP" ]; then
    info "Downloading PlayIntegrityFork $PIF_TAG"
    fetch "$PIF_ZIP" "$PIF_URL"
fi

PIF_X="$BUILD/pif_extracted"
rm -rf "$PIF_X"; mkdir -p "$PIF_X"
unzip -qq -o "$PIF_ZIP" -d "$PIF_X"

[ -f "$PIF_X/classes.dex" ] || die "PlayIntegrityFork zip missing classes.dex — upstream layout changed"
cp "$PIF_X/classes.dex" "$STAGE/classes.dex"

if [ -d "$PIF_X/zygisk" ]; then
    mkdir -p "$STAGE/zygisk"
    cp "$PIF_X/zygisk"/*.so "$STAGE/zygisk/"
fi

for f in $PIF_FILES; do
    [ -f "$PIF_X/$f" ] || die "PlayIntegrityFork zip missing $f — upstream layout changed"
    cp "$PIF_X/$f" "$STAGE/$f"
done
ok "staged PlayIntegrityFork payload"

# ---------- 4) install coverage ----------
# r8 packaged keybox_check.sh but customize.sh's extraction list never named it,
# so the file did not exist on device and both keybox gates silently degraded to
# their fallbacks there. A script that ships without an installer is that same bug
# class, so fail the build here rather than reading it off a diagnostic log later.
#
# The installer asks for names in three places: the `for f in ...` loop (whose
# $ENGINE_FILES half is defined by engine.sh, the same sourcing customize.sh does),
# literal install_file calls in customize.sh, and the engine adapter's attest_install.
# tr's octal form of backslash (\134) is deliberate: the loop continues lines with
# it, and a written backslash in a regex is the fragile way to delete one.
installed_names() {
    sed -n '/^for f in/,/; *do/p' "$STAGE/customize.sh" \
        | tr -d '\134\n"' | tr -s ' \t' '\n' \
        | grep -vE '^$|^for$|^in$|^do$|^f$|^;$|[$;|&]'
    sed -n 's/^ENGINE_FILES="\([^"]*\)".*/\1/p' "$STAGE/engine.sh" | tr ' \t' '\n\n'
    grep -h '^[[:space:]]*install_file "' "$STAGE/customize.sh" "$STAGE/attest.sh" 2>/dev/null \
        | sed 's/^[[:space:]]*install_file "//; s/".*//' \
        | grep -v '[$]'
}

# Kept out of $STAGE so the check itself cannot end up inside the package.
# Blank and path-shaped entries are dropped: only root-level names are comparable,
# and the engine adapter installs its binaries by subdirectory.
NAMES_LIST="$BUILD/installed-names.txt"
installed_names | grep -vE '^$|.*/' | sort -u > "$NAMES_LIST"

_orphans=""
for f in "$STAGE"/*.sh; do
    [ -f "$f" ] || continue
    n="${f##*/}"
    # The installer script itself is read by the manager, never extracted.
    [ "$n" = "customize.sh" ] && continue
    grep -qx "$n" "$NAMES_LIST" || _orphans="$_orphans
  - $n"
done
[ -z "$_orphans" ] || die "staged scripts no installer extracts:$_orphans"

_missing=""
while IFS= read -r n; do
    # -e, not -f: an installer may name a tree (webroot/) rather than a file.
    [ -e "$STAGE/$n" ] || _missing="$_missing
  - $n"
done < "$NAMES_LIST"
[ -z "$_missing" ] || die "installer names files that are not staged:$_missing"
ok "every staged script has an installer ($(wc -l < "$NAMES_LIST" | tr -d ' ') names checked)"

# ---------- 5) permissions + package ----------
chmod 0755 "$STAGE"/*.sh 2>/dev/null || true
chmod 0755 "$STAGE/omk-daemon" "$STAGE/omk-injector" 2>/dev/null || true
chmod 0755 "$STAGE/libs/$OMK_ABI/keymint" "$STAGE/libs/$OMK_ABI/inject" \
           "$STAGE/libs/$OMK_ABI/soterta-svc" 2>/dev/null || true
for abi in $ABIS; do
    chmod 0755 "$STAGE/bin/$abi/asfetch"  2>/dev/null || true
    chmod 0755 "$STAGE/bin/$abi/aswatcher" 2>/dev/null || true
done

mkdir -p "$OUT"
ZIP="$OUT/AlwaysStrong-${VERSION}.zip"
rm -f "$ZIP"
info "Packaging $ZIP"
pack "$ZIP" "$STAGE"

ok "$(du -h "$ZIP" | cut -f1)  $ZIP"
