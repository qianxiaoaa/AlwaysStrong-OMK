#!/system/bin/sh
# AlwaysStrong — module self-update.
#
# Fetches the signed update manifest published by .github/workflows/manifest.yml
# (mirror-data branch, mirrored on jsDelivr), and — only when it advertises a
# higher versionCode — downloads the release zip, verifies it against the
# bundled Ed25519 public key (module/pubkey.b64 via verify_tool), re-checks the
# package's own versionCode, and hands it to the root manager to install.
#
# The device trusts a key, not a server: the manifest only carries a URL plus a
# detached signature over the exact zip bytes, so a zip fetched from any mirror
# or CDN is safe — a substituted or tampered file cannot produce a valid
# signature. If verify_tool is missing the update is refused unless
# UPDATE_ALLOW_UNSIGNED=1 (sha256-only, for debugging).
#
# Output (key=value, for the WebUI / Action):
#   LOCAL_VERSION, LOCAL_VC, REMOTE_VERSION, REMOTE_VC,
#   UPDATE_STATE = none|available|updated|failed, RESULT_TEXT
#
# Exit: 0 updated · 2 nothing to do / no update · 1 failure
# Env: UPDATE_REPO (default qianxiaoaa/AlwaysStrong-OMK), UPDATE_ACCEL, UPDATE_DISABLE=1

UPDATE_REPO="${UPDATE_REPO:-qianxiaoaa/AlwaysStrong-OMK}"
UPDATE_ACCEL="${UPDATE_ACCEL:-}"
UPDATE_ALLOW_UNSIGNED="${UPDATE_ALLOW_UNSIGNED:-}"

MODDIR="${MODDIR:-/data/adb/modules/tricky_store}"
CONFIG_DIR="${CONFIG_DIR:-/data/adb/tricky_store}"
PROP="$MODDIR/module.prop"
PUBKEY="$MODDIR/pubkey.b64"
PUBKEY_FP="$MODDIR/pubkey.fp"

log() { echo "self_update: $*"; }
say() { echo "$1"; }

have_prop() { [ -f "$PROP" ]; }

# ---- tool resolution (mirrors keybox_fetch.sh) ------------------------------
SELF_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="$MODDIR"
case "$(uname -m)" in
    aarch64)        ABI=arm64-v8a ;;
    armv7*|armv8l)  ABI=armeabi-v7a ;;
    x86_64)         ABI=x86_64 ;;
    i?86)           ABI=x86 ;;
    *)              ABI="" ;;
esac
ASFETCH="$SELF_DIR/bin/$ABI/asfetch"
VERIFY="$SELF_DIR/bin/$ABI/verify_tool"
BB=""
for bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox \
          /data/adb/modules/busybox-ndk/system/*/busybox "$(command -v busybox 2>/dev/null)"; do
    [ -n "$bb" ] && [ -x "$bb" ] && BB="$bb" && break
done

TO=""
if timeout -k 1 5 true >/dev/null 2>&1; then TO="timeout -k 3"
elif timeout 5 true >/dev/null 2>&1; then TO="timeout"
elif [ -n "$BB" ] && "$BB" timeout -k 1 5 true >/dev/null 2>&1; then TO="$BB timeout -k 3"
elif [ -n "$BB" ] && "$BB" timeout 5 true >/dev/null 2>&1; then TO="$BB timeout"
fi
bounded() { _bs="$1"; shift; if [ -n "$TO" ]; then $TO "$_bs" "$@"; else "$@"; fi; }

run_engine() {  # $1=engine $2=out $3=url
    rm -f "$2"
    case "$1" in
        asfetch) [ -n "$ABI" ] && [ -f "$ASFETCH" ] && { [ -x "$ASFETCH" ] || chmod 0755 "$ASFETCH" 2>/dev/null; } && bounded 120 "$ASFETCH" -T 15 -o "$2" "$3" 2>/dev/null ;;
        bb)      [ -n "$BB" ] && bounded 120 "$BB" wget -q -T 20 -O "$2" "$3" 2>/dev/null ;;
        curl)    command -v curl >/dev/null 2>&1 && bounded 120 curl -fsSL --connect-timeout 15 --speed-limit 1 --speed-time 20 --max-time 110 -o "$2" "$3" 2>/dev/null ;;
        wget)    command -v wget >/dev/null 2>&1 && bounded 120 wget -q -T 20 -O "$2" "$3" 2>/dev/null ;;
    esac
    [ -s "$2" ]
}
try_fetch() {  # $1=out $2=url
    _o="$1"; _u="$2"
    for _e in asfetch bb curl wget; do
        run_engine "$_e" "$_o" "$_u" && return 0
    done
    return 1
}

SHA256=""
if command -v sha256sum >/dev/null 2>&1; then
    SHA256="sha256sum"
elif [ -n "$BB" ]; then
    SHA256="$BB sha256sum"
fi

# ---- local version ----------------------------------------------------------
if ! have_prop; then
    say "UPDATE_STATE=failed"
    say "RESULT_TEXT=module.prop missing"
    exit 1
fi
LOCAL_VERSION=$(sed -n 's/^version=//p' "$PROP" | head -1 | tr -d '\r')
LOCAL_VC=$(sed -n 's/^versionCode=//p' "$PROP" | head -1 | tr -d '\r ')
case "$LOCAL_VC" in ''|*[!0-9]*) LOCAL_VC=0 ;; esac
say "LOCAL_VERSION=$LOCAL_VERSION"
say "LOCAL_VC=$LOCAL_VC"

if [ "$UPDATE_DISABLE" = "1" ]; then
    say "UPDATE_STATE=none"
    say "RESULT_TEXT=auto-update disabled"
    exit 2
fi

# ---- manifest sources -------------------------------------------------------
# Primary: raw on the mirror-data branch. Mirrors: jsDelivr edges (their branch
# cache can lag hours, so they only ever back up the raw fetch). All bases carry
# the same signed manifest at mirror/manifest.json.
MIRROR_DIR="mirror-data/mirror"
MANIFEST_BASES="
https://raw.githubusercontent.com/$UPDATE_REPO/$MIRROR_DIR
https://gcore.jsdelivr.net/gh/$UPDATE_REPO@$MIRROR_DIR
https://cdn.jsdelivr.net/gh/$UPDATE_REPO@$MIRROR_DIR
https://fastly.jsdelivr.net/gh/$UPDATE_REPO@$MIRROR_DIR
https://testingcf.jsdelivr.net/gh/$UPDATE_REPO@$MIRROR_DIR"
# Custom mirror (single base holding mirror/manifest.json); also used by tests.
[ -n "$UPDATE_MANIFEST_BASE" ] && MANIFEST_BASES="$UPDATE_MANIFEST_BASE"

mkdir -p "$CONFIG_DIR" 2>/dev/null
TMP="$CONFIG_DIR/.self_update.$$"
mkdir -p "$TMP" 2>/dev/null
trap 'rm -rf "$TMP"' EXIT INT TERM

jget() {  # $1=file $2=key  — first "key": <value> (string or number)
    sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" | head -1 | tr -d '\r'
}

MANIFEST="$TMP/manifest.json"
got_manifest=0
for base in $MANIFEST_BASES; do
    for _accel in "$UPDATE_ACCEL" ""; do
        [ -z "$_accel" ] && [ -n "$UPDATE_ACCEL" ] && continue
        url="$base/manifest.json"
        b="${_accel%/}"
        [ -n "$b" ] && url="$b/$url"
        if try_fetch "$MANIFEST" "$url" && grep -q '"version_code"' "$MANIFEST" 2>/dev/null; then
            got_manifest=1
            log "manifest <- $url"
            break
        fi
    done
    [ "$got_manifest" = 1 ] && break
done

if [ "$got_manifest" != 1 ]; then
    say "UPDATE_STATE=failed"
    say "RESULT_TEXT=manifest fetch failed"
    exit 1
fi

REMOTE_VC=$(jget "$MANIFEST" version_code)
case "$REMOTE_VC" in ''|*[!0-9]*) REMOTE_VC=0 ;; esac
REMOTE_VERSION=$(jget "$MANIFEST" version)
MODULE_URL=$(jget "$MANIFEST" url)
MODULE_SHA=$(jget "$MANIFEST" sha256)
MODULE_SIG=$(jget "$MANIFEST" signature)
say "REMOTE_VERSION=$REMOTE_VERSION"
say "REMOTE_VC=$REMOTE_VC"

if [ "$REMOTE_VC" -le "$LOCAL_VC" ] 2>/dev/null; then
    say "UPDATE_STATE=none"
    say "RESULT_TEXT=up to date ($LOCAL_VERSION)"
    exit 2
fi

say "UPDATE_STATE=available"
log "update available: $LOCAL_VERSION -> $REMOTE_VERSION (vc $LOCAL_VC -> $REMOTE_VC)"

# ---- download ---------------------------------------------------------------
ZIP="$TMP/update.zip"
dl_ok=0
for u in "$MODULE_URL" "https://github.com/$UPDATE_REPO/releases/download/$REMOTE_VERSION/AlwaysStrong-$REMOTE_VERSION.zip"; do
    [ -n "$u" ] || continue
    if try_fetch "$ZIP" "$u"; then dl_ok=1; break; fi
done
if [ "$dl_ok" != 1 ]; then
    say "UPDATE_STATE=failed"
    say "RESULT_TEXT=download failed"
    exit 1
fi

# ---- sha256 -----------------------------------------------------------------
if [ -n "$SHA256" ] && [ -n "$MODULE_SHA" ]; then
    _got=$($SHA256 < "$ZIP" | awk '{print tolower($1)}')
    if [ "$_got" != "$(printf '%s' "$MODULE_SHA" | tr 'A-Z' 'a-z')" ]; then
        say "UPDATE_STATE=failed"
        say "RESULT_TEXT=sha256 mismatch"
        exit 1
    fi
fi

# ---- Ed25519 signature ------------------------------------------------------
if [ -n "$MODULE_SIG" ] && [ -f "$VERIFY" ] && [ -f "$PUBKEY" ]; then
    [ -x "$VERIFY" ] || chmod 0755 "$VERIFY" 2>/dev/null
    printf '%s' "$MODULE_SIG" > "$TMP/sig.b64"
    if ! bounded 30 "$VERIFY" "$PUBKEY" "$TMP/sig.b64" "$ZIP" >/dev/null 2>&1; then
        say "UPDATE_STATE=failed"
        say "RESULT_TEXT=signature verification failed"
        log "signature verification FAILED — refusing $REMOTE_VERSION"
        exit 1
    fi
    log "signature ok"
elif [ "$UPDATE_ALLOW_UNSIGNED" = "1" ]; then
    log "verify_tool/signature unavailable — unsigned install allowed by UPDATE_ALLOW_UNSIGNED"
else
    say "UPDATE_STATE=failed"
    say "RESULT_TEXT=signature unavailable, refusing (set UPDATE_ALLOW_UNSIGNED=1 to override)"
    exit 1
fi

# ---- refuse a zip whose own versionCode is not newer ------------------------
zip_vc() {
    _o=""
    if [ -n "$BB" ]; then
        _o=$("$BB" unzip -p "$1" module.prop 2>/dev/null | sed -n 's/^versionCode=//p' | head -1 | tr -d '\r ')
    fi
    if [ -z "$_o" ] && command -v unzip >/dev/null 2>&1; then
        _o=$(unzip -p "$1" module.prop 2>/dev/null | sed -n 's/^versionCode=//p' | head -1 | tr -d '\r ')
    fi
    echo "$_o"
}
PKG_VC=$(zip_vc "$ZIP")
case "$PKG_VC" in ''|*[!0-9]*) PKG_VC="" ;; esac
if [ -n "$PKG_VC" ] && [ "$PKG_VC" -le "$LOCAL_VC" ] 2>/dev/null; then
    say "UPDATE_STATE=failed"
    say "RESULT_TEXT=package versionCode $PKG_VC not newer than $LOCAL_VC"
    exit 1
fi

# ---- install ----------------------------------------------------------------
STAGE="/data/local/tmp/AlwaysStrong-$REMOTE_VERSION.zip"
cp -f "$ZIP" "$STAGE" 2>/dev/null

KS=""
for k in /data/adb/ksu/bin/ksud /data/adb/ksud/bin/ksud; do
    [ -x "$k" ] && KS="$k" && break
done

if [ -n "$KS" ]; then
    if bounded 300 "$KS" module install "$STAGE" >/dev/null 2>&1; then
        say "UPDATE_STATE=updated"
        say "RESULT_TEXT=installed $REMOTE_VERSION (reboot to apply)"
        log "installed via ksud"
        exit 0
    fi
fi
if command -v magisk >/dev/null 2>&1; then
    if bounded 300 magisk --install-module "$STAGE" >/dev/null 2>&1; then
        say "UPDATE_STATE=updated"
        say "RESULT_TEXT=installed $REMOTE_VERSION (reboot to apply)"
        log "installed via magisk"
        exit 0
    fi
fi

say "UPDATE_STATE=available"
say "RESULT_TEXT=downloaded to $STAGE — install from your root manager"
log "no root-manager installer; staged at $STAGE"
exit 2
