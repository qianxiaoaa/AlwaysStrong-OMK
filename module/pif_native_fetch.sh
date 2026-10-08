#!/system/bin/sh
# AlwaysStrong — native fingerprint fetch (primary PIF source).
#
# The fingerprint now comes from Elcapitanoe/PIF-Config-Generator, which crawls
# Google's Pixel build servers itself and publishes ready-made profiles as
# release assets: "<Device>_<build>.json" for the stable channel and
# "<Device>_beta_<build>.json" for the beta channel. That removes the whole
# in-module crawl (flash.android.com landing-page scrape, content-flashstation
# build queries, per-product canary parsing) — the biggest and most brittle part
# of this script — and the busybox-TLS stalls that crawl used to hit on some
# ROMs.
#
# We take the newest release that still carries a STABLE (non-"beta") profile,
# pick the device's own codename when the feed has one, else a known-good Pixel,
# download that one small JSON, and translate it into the engine's prop file.
# A user import (WebUI) and the shipped fallbacks in action.sh are unaffected and
# still win where they applied before.
#
# The release list is one GitHub API call, cached under CONFIG_DIR for 6h so the
# hourly pass does not spend the unauthenticated rate limit; the profile itself
# is ~0.5 KB and re-fetched each run so a cleared pif is regenerated.
#
# On success it writes $CONFIG_DIR/pif.prop (same file the shipped fallbacks use)
# and exits 0. Any failure exits non-zero and leaves the existing pif untouched.
#
# Exit codes:
#   0  fresh fingerprint written
#   1  feed/download/parse failed (nothing written)

CONFIG_DIR=/data/adb/tricky_store
TARGET="$CONFIG_DIR/pif.prop"
RELEASES_API="https://api.github.com/repos/Elcapitanoe/PIF-Config-Generator/releases?per_page=10"
FEED="$CONFIG_DIR/.pif_feed.json"
FEED_TAG="$CONFIG_DIR/.pif_feed_tag"
FEED_TTL=21600   # 6h
TIMEOUT=15       # idle timeout per fetch; outer per-fetch cap is TIMEOUT + CAP_EXTRA
CAP_EXTRA=60

# Known-good Pixel codenames, most preferred first, used when the device's own
# codename has no profile in the feed. Pixel 9 "tokay" is left out on purpose:
# Google stopped granting it STRONG even with a valid keybox.
PREFER="caiman komodo tegu comet frankel blazer felix husky"

log() { echo "pif_native_fetch: $*"; }

# ---- Resolve the module dir + engine adapter --------------------------------
SELF_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR=/data/adb/modules/tricky_store

# Where the profile lands, and under which spoof-flag names, belongs to
# engine.sh — writing the engine's prop file directly from here would give one
# build flags the other's zygisk cannot read.
MODPATH="$SELF_DIR"
if [ -f "$SELF_DIR/engine.sh" ]; then
    . "$SELF_DIR/engine.sh"
else
    log "engine.sh missing — cannot install a fingerprint."; exit 1
fi

case "$(uname -m)" in
    aarch64)        ABI=arm64-v8a ;;
    armv7*|armv8l)  ABI=armeabi-v7a ;;
    x86_64)         ABI=x86_64 ;;
    i?86)           ABI=x86 ;;
    *)              ABI="" ;;
esac
ASFETCH="$SELF_DIR/bin/$ABI/asfetch"

BB=""
for p in /data/adb/modules/busybox-ndk/system/*/busybox /data/adb/magisk/busybox \
         /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    [ -f "$p" ] && BB="$p" && break
done

if [ -z "$BB" ] && { [ -z "$ABI" ] || [ ! -x "$ASFETCH" ]; } \
   && ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    log "no fetcher available (asfetch/curl/wget)."; exit 1
fi

# bounded SECS cmd... — run cmd under a hard wall-clock cap. A fetcher that
# never returns (asfetch / wget / curl stuck on a dead route, a hung DNS, a TLS
# stall) used to freeze the whole Action; every network step goes through this.
# toybox/busybox timeout both take -k (SIGKILL a command that ignores SIGTERM).
TO=""
if timeout -k 1 5 true >/dev/null 2>&1; then TO="timeout -k 3"
elif timeout 5 true >/dev/null 2>&1; then TO="timeout"
elif [ -n "$BB" ] && "$BB" timeout -k 1 5 true >/dev/null 2>&1; then TO="$BB timeout -k 3"
elif [ -n "$BB" ] && "$BB" timeout 5 true >/dev/null 2>&1; then TO="$BB timeout"
fi
bounded() { _bs="$1"; shift; if [ -n "$TO" ]; then $TO "$_bs" "$@"; else "$@"; fi; }

# fetch OUTFILE URL [HEADER] — try asfetch, then busybox wget, curl, wget; keep
# the first non-empty body. GitHub API and release assets both redirect, so a
# downloader that does not follow redirects simply loses to one that does.
fetch() {
    _o="$1"; _u="$2"; _h="$3"
    if [ -n "$ABI" ] && [ -x "$ASFETCH" ]; then
        rm -f "$_o"
        if [ -n "$_h" ]; then bounded $((TIMEOUT + CAP_EXTRA)) "$ASFETCH" -T "$TIMEOUT" -H "$_h" -o "$_o" "$_u" 2>/dev/null
        else bounded $((TIMEOUT + CAP_EXTRA)) "$ASFETCH" -T "$TIMEOUT" -o "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    if [ -n "$BB" ]; then
        rm -f "$_o"
        if [ -n "$_h" ]; then bounded $((TIMEOUT + CAP_EXTRA)) "$BB" wget -q -T "$TIMEOUT" --header "$_h" --no-check-certificate -O "$_o" "$_u" 2>/dev/null
        else bounded $((TIMEOUT + CAP_EXTRA)) "$BB" wget -q -T "$TIMEOUT" --no-check-certificate -O "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        rm -f "$_o"
        if [ -n "$_h" ]; then bounded $((TIMEOUT + CAP_EXTRA)) curl -fsSL --connect-timeout 15 --speed-limit 1 --speed-time "$TIMEOUT" --max-time $((TIMEOUT + CAP_EXTRA - 5)) -H "$_h" -o "$_o" "$_u" 2>/dev/null
        else bounded $((TIMEOUT + CAP_EXTRA)) curl -fsSL --connect-timeout 15 --speed-limit 1 --speed-time "$TIMEOUT" --max-time $((TIMEOUT + CAP_EXTRA - 5)) -o "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        rm -f "$_o"
        if [ -n "$_h" ]; then bounded $((TIMEOUT + CAP_EXTRA)) wget -q -T "$TIMEOUT" --header "$_h" -O "$_o" "$_u" 2>/dev/null
        else bounded $((TIMEOUT + CAP_EXTRA)) wget -q -T "$TIMEOUT" -O "$_o" "$_u" 2>/dev/null; fi
        [ -s "$_o" ] && return 0
    fi
    return 1
}

# file_age PATH — seconds since PATH was modified, or empty when it cannot be
# determined (no stat / date). A present-but-unknown-age cache is treated as
# fresh by the caller, so a ROM without those tools still skips the refetch.
file_age() {
    _t=$(stat -c %Y "$1" 2>/dev/null)
    [ -z "$_t" ] && _t=$(date -r "$1" +%s 2>/dev/null)
    case "$_t" in ''|*[!0-9]*) echo ""; return ;; esac
    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) echo ""; return ;; esac
    echo $((_now - _t))
}

W="$CONFIG_DIR/.pif_native.$$"
mkdir -p "$W" || { log "cannot create work dir."; exit 1; }
# INT/TERM must exit explicitly: busybox ash RESUMES a script after a signal
# trap, which would otherwise keep running with $W deleted.
trap 'rm -rf "$W"' EXIT
trap 'rm -rf "$W"; exit 143' TERM
trap 'rm -rf "$W"; exit 130' INT

# ---- 1. Release feed (GitHub API, cached 6h) --------------------------------
need_feed=1
if [ -s "$FEED" ]; then
    _age=$(file_age "$FEED")
    [ -z "$_age" ] && need_feed=0
    [ -n "$_age" ] && [ "$_age" -lt "$FEED_TTL" ] && need_feed=0
fi
if [ "$need_feed" = 1 ]; then
    if fetch "$W/feed.json" "$RELEASES_API" "Accept: application/vnd.github+json"; then
        mv -f "$W/feed.json" "$FEED" 2>/dev/null
    elif [ ! -s "$FEED" ]; then
        log "could not fetch the release feed."; exit 1
    else
        log "release feed refresh failed — using the cached copy."
    fi
fi
[ -s "$FEED" ] || { log "no release feed available."; exit 1; }

# ---- 2. Pick a stable profile ----------------------------------------------
# One release is a JSON object with a "tag_name" and an "assets" array; the
# API returns releases newest-first. Flatten every asset to "<tag>\t<name>\t<url>"
# and keep the first STABLE one (no "_beta_" marker) for the device, matching the
# feed's capitalized codenames case-insensitively.
ASSETS="$W/assets.tsv"
awk '
    /"tag_name":/ { t=$0; sub(/.*"tag_name": *"/,"",t); sub(/".*/,"",t) }
    /"assets": \[/ { inA=1; next }
    inA && /^[[:space:]]*\][,]?[[:space:]]*$/ { inA=0; next }
    inA && /"name":/ { n=$0; sub(/.*"name": *"/,"",n); sub(/".*/,"",n) }
    inA && /"browser_download_url":/ {
        u=$0; sub(/.*"browser_download_url": *"/,"",u); sub(/".*/,"",u)
        if (n != "" && u != "") print t "\t" n "\t" u
        n=""
    }
' "$FEED" > "$ASSETS" 2>/dev/null
[ -s "$ASSETS" ] || { log "could not parse the release feed."; exit 1; }

# stable_only: name has no "_beta_" marker.
stable_line() { awk -F'\t' 'index($0,"_beta_")==0 && $1!="" && $2!="" && $3!="" { print; exit }' "$ASSETS"; }

PICK=""
THISDEV=$(getprop ro.product.device 2>/dev/null | tr 'A-Z' 'a-z')
if [ -n "$THISDEV" ]; then
    PICK=$(awk -F'\t' -v d="$THISDEV" 'index($0,"_beta_")==0 { n=tolower($2); if (index(n, d "_")==1) { print; exit } }' "$ASSETS")
fi
if [ -z "$PICK" ]; then
    for _c in $PREFER; do
        PICK=$(awk -F'\t' -v d="$_c" 'index($0,"_beta_")==0 { n=tolower($2); if (index(n, d "_")==1) { print; exit } }' "$ASSETS")
        [ -n "$PICK" ] && break
    done
fi
[ -z "$PICK" ] && PICK=$(stable_line)
[ -n "$PICK" ] || { log "the feed carries no stable profile."; exit 1; }

REL_TAG=$(printf '%s' "$PICK" | cut -f1)
REL_NAME=$(printf '%s' "$PICK" | cut -f2)
REL_URL=$(printf '%s' "$PICK" | cut -f3)
log "stable profile: $REL_NAME ($REL_TAG)"

# ---- 3. Download + translate ------------------------------------------------
fetch "$W/profile.json" "$REL_URL" "Accept: application/vnd.github+json" \
    || { log "could not download $REL_NAME."; exit 1; }

JGET() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$W/profile.json" | head -n1; }
FP=$(JGET FINGERPRINT)
DEVV=$(JGET DEVICE)
[ -n "$FP" ] && [ -n "$DEVV" ] || { log "profile JSON is missing FINGERPRINT/DEVICE."; exit 1; }

TMP="$W/pif.prop"
{
    echo "MANUFACTURER=$(JGET MANUFACTURER)"
    echo "MODEL=$(JGET MODEL)"
    echo "FINGERPRINT=$FP"
    echo "PRODUCT=$(JGET PRODUCT)"
    echo "DEVICE=$DEVV"
    echo "SECURITY_PATCH=$(JGET SECURITY_PATCH)"
    echo "DEVICE_INITIAL_SDK_INT=$(JGET DEVICE_INITIAL_SDK_INT)"
} > "$TMP"
engine_spoof_block >> "$TMP"

grep -q '^FINGERPRINT=google/' "$TMP" || { log "produced pif.prop looks wrong."; exit 1; }
grep -q '^MODEL=' "$TMP" || { log "produced pif.prop has no MODEL."; exit 1; }

# ---- 4. Install -------------------------------------------------------------
mkdir -p "$CONFIG_DIR"
engine_install_pif "$TMP" || { log "$ENGINE could not install the fingerprint."; exit 1; }
cp -f "$TMP" "$TARGET" 2>/dev/null
echo "$REL_TAG $REL_NAME" > "$FEED_TAG" 2>/dev/null

log "installed fingerprint ($ENGINE): $FP"
exit 0
