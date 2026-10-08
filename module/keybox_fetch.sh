#!/system/bin/sh
# AlwaysStrong — keybox auto-fetch.
#
# Collects a keybox from a pool of upstream sources (ported from yypm's PHP
# server: php-server/lib/sources.php). keybox_sources.sh walks the pool in
# priority order, decodes each candidate, and returns the first that passes both
# the structural check and Google's revocation list. This replaces the old
# single-mirror default (ZeyolZZZ), which had exactly the failure modes a pool
# fixes: it could go stale, serve a revoked key, or disappear.
#
# This script then detects whether the collected keybox differs from the one on
# disk, and atomically replaces it. The existing keybox is preserved on any
# failure — a stale-but-working key beats no key.
#
# Source override (a single user-pinned source bypasses the pool):
#   KEYBOX_URL        full URL to a raw keybox.xml or a base64 blob
#   KEYBOX_BASE_URL   legacy mirror root; the key is fetched from <root>/key
#
# Exit codes:
#   0  keybox updated (new content written)
#   2  no change (already up to date)
#   1  fetch / verify failed (existing keybox preserved)

KEYBOX_URL="${KEYBOX_URL:-}"
KEYBOX_BASE_URL="${KEYBOX_BASE_URL:-}"
if [ -n "$KEYBOX_URL" ]; then
    KEY_URL="$KEYBOX_URL"
elif [ -n "$KEYBOX_BASE_URL" ]; then
    KEY_URL="$KEYBOX_BASE_URL/key"
else
    # Empty on purpose: the multi-source pool (keybox_sources.sh) is the default.
    KEY_URL=""
fi

# Google's attestation revocation list. The mirror is a shared key, so it is
# exactly the kind of key that ends up on this list — and a revoked keybox is
# invisible locally: it parses, keymint loads it, and every Play Integrity
# verdict is still red because the verdict is decided against this list on
# Google's servers. Read the same list before trusting a downloaded key.
STATUS_URL="${KEYBOX_STATUS_URL:-https://android.googleapis.com/attestation/status}"

CONFIG_DIR="${CONFIG_DIR:-/data/adb/tricky_store}"
TARGET="$CONFIG_DIR/keybox.xml"

log() { echo "keybox_fetch: $*"; }

# Custom-keybox mode: the user manages keybox.xml themselves via the WebUI —
# never fetch or overwrite it. (Defensive; action.sh/service.sh also gate on this.)
if [ -f "$CONFIG_DIR/custom_keybox" ]; then
    log "custom keybox active — skipping fetch."
    exit 2
fi

# ---- Resolve tools ----
# No single downloader works on every device: busybox wget's built-in TLS
# stalls mid-stream on the keybox mirror CDN on some devices, while our bundled
# rustls fetcher (asfetch) fails to connect on others. So we try each available
# engine in turn (asfetch → busybox wget → curl → system wget) and keep the
# first that actually returns bytes — never trust one tool to always work.
SELF_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR=/data/adb/modules/tricky_store
case "$(uname -m)" in
    aarch64)        ABI=arm64-v8a ;;
    armv7*|armv8l)  ABI=armeabi-v7a ;;
    x86_64)         ABI=x86_64 ;;
    i?86)           ABI=x86 ;;
    *)              ABI="" ;;
esac
ASFETCH="$SELF_DIR/bin/$ABI/asfetch"
BB=""
for bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox \
          /data/adb/modules/busybox-ndk/system/*/busybox "$(command -v busybox 2>/dev/null)"; do
    [ -n "$bb" ] && [ -x "$bb" ] && BB="$bb" && break
done

# bounded SECS cmd... — run cmd under a hard wall-clock cap. A fetcher that
# never returns (asfetch / wget / curl stuck on a dead route, a hung DNS, a
# TLS stall) used to freeze the whole Action: status_fetch and the first-tap
# keybox fetch called it with no bound at all, so the screen sat after the last
# row with no "done" until the user gave up. Every network step now goes through
# this; the caller falls through to the next engine when the cap trips.
# toybox timeout (Android 10+) and busybox timeout both take -k; -k SIGKILLs a
# command that ignores the SIGTERM, which a `sh` waiting on a child would defer.
TO=""
if timeout -k 1 5 true >/dev/null 2>&1; then TO="timeout -k 3"
elif timeout 5 true >/dev/null 2>&1; then TO="timeout"
elif [ -n "$BB" ] && "$BB" timeout -k 1 5 true >/dev/null 2>&1; then TO="$BB timeout -k 3"
elif [ -n "$BB" ] && "$BB" timeout 5 true >/dev/null 2>&1; then TO="$BB timeout"
fi
bounded() { _bs="$1"; shift; if [ -n "$TO" ]; then $TO "$_bs" "$@"; else "$@"; fi; }

# Caps are set for "definitely dead", never for "slow": each downloader's own
# -T is an IDLE timeout (asfetch, busybox wget, wget) or is paired with a speed
# floor (curl), so a slow link that keeps delivering bytes is never cut off; the
# outer cap only backstops a process that is stuck entirely.
# run_engine NAME OUTFILE URL — one download attempt with the named engine.
# Each engine's own -T bounds one idle wait; the outer cap bounds the call.
run_engine() {
    rm -f "$2"
    case "$1" in
        asfetch) [ -n "$ABI" ] && [ -f "$ASFETCH" ] && { [ -x "$ASFETCH" ] || chmod 0755 "$ASFETCH" 2>/dev/null; } && bounded 90 "$ASFETCH" -T 15 -o "$2" "$3" 2>/dev/null ;;
        bb)      [ -n "$BB" ] && bounded 90 "$BB" wget -q -T 20 -O "$2" "$3" 2>/dev/null ;;
        curl)    command -v curl >/dev/null 2>&1 && bounded 90 curl -fsSL --connect-timeout 15 --speed-limit 1 --speed-time 20 --max-time 85 -o "$2" "$3" 2>/dev/null ;;
        wget)    command -v wget >/dev/null 2>&1 && bounded 90 wget -q -T 20 -O "$2" "$3" 2>/dev/null ;;
    esac
    [ -s "$2" ]
}

# try_fetch OUTFILE URL — try each engine until one returns a non-empty file.
# The engine that last worked is remembered ($CONFIG_DIR/.kb_engine) and tried
# first, so we don't burn a fetcher's full timeout on every call.
CACHE="$CONFIG_DIR/.kb_engine"
try_fetch() {
    _o="$1"; _u="$2"
    _first=$(cat "$CACHE" 2>/dev/null)
    for _e in "$_first" asfetch bb curl wget; do
        [ -z "$_e" ] && continue
        if run_engine "$_e" "$_o" "$_u"; then
            [ "$_e" != "$_first" ] && echo "$_e" > "$CACHE" 2>/dev/null
            return 0
        fi
    done
    return 1
}

B64DEC=""
if echo dGVzdA== | base64 -d >/dev/null 2>&1; then
    B64DEC="base64 -d"
else
    for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$bb" ] && echo dGVzdA== | "$bb" base64 -d >/dev/null 2>&1; then
            B64DEC="$bb base64 -d"; break
        fi
    done
fi
[ -z "$B64DEC" ] && { log "no base64 decoder available."; exit 1; }

SHA256=""
if command -v sha256sum >/dev/null 2>&1; then
    SHA256="sha256sum"
else
    for bb in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        if [ -x "$bb" ] && echo x | "$bb" sha256sum >/dev/null 2>&1; then
            SHA256="$bb sha256sum"; break
        fi
    done
fi
[ -z "$SHA256" ] && { log "no sha256sum available."; exit 1; }

# ---- Fetch + decode ----
mkdir -p "$CONFIG_DIR"
TMP="$CONFIG_DIR/.keybox_fetch.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT INT TERM

# fetch_single URL — the override path: one pinned source, decoded inline. The
# payload is compared byte-for-byte against the file on disk later, regardless
# of cache, so a manual swap underneath us is still caught. Anything that
# already looks like XML is used as-is; base64 never contains '<', so the first
# bytes decide whether it is the raw or the legacy base64 mirror.
fetch_single() {
    try_fetch "$TMP/key" "$1" || return 1
    [ -s "$TMP/key" ] || return 1
    if head -c 256 "$TMP/key" | grep -q '<'; then
        cp -f "$TMP/key" "$TMP/keybox.xml" 2>/dev/null
    else
        $B64DEC < "$TMP/key" > "$TMP/keybox.xml" 2>/dev/null || true
    fi
    [ -s "$TMP/keybox.xml" ]
}

KB_SRC="$SELF_DIR/keybox_sources.sh"
if [ -n "$KEY_URL" ]; then
    fetch_single "$KEY_URL" || { log "download failed on all engines ($KEY_URL)"; exit 1; }
elif [ -f "$KB_SRC" ]; then
    # Default: the multi-source pool. The helper does its own structural and
    # revocation filtering and prints the chosen source name on stdout.
    if sh "$KB_SRC" collect "$TMP/keybox.xml" >"$TMP/kbsrc.name" 2>"$TMP/kbsrc.log"; then
        log "source: $(cat "$TMP/kbsrc.name" 2>/dev/null)"
    else
        sed 's/^/keybox_fetch: /' "$TMP/kbsrc.log" 2>/dev/null
        log "multi-source collection found no usable keybox — keeping the one on disk."
        exit 1
    fi
else
    # Partial install (helper missing): legacy single mirror as a last resort.
    fetch_single "https://raw.githubusercontent.com/ZeyolZZZ/TEESimulator-RS-fix/main/module/keybox.xml" \
        || { log "download failed on all engines (legacy mirror)"; exit 1; }
fi

if [ ! -s "$TMP/keybox.xml" ]; then
    log "downloaded payload is empty."
    exit 1
fi

# ---- Validate ----
# keybox_sources.sh already ran this on the pool path, but keep it here: it
# guards the override path, and it is cheap insurance against a helper that let
# something keymint would reject through. Structure, not the "Keybox" substring:
# keymint rejects a document it cannot parse and then rewrites its own bundled
# template instead of keeping the file that was there, taking every verdict down
# with it.
KB_CHECK="$SELF_DIR/keybox_check.sh"
if [ -f "$KB_CHECK" ]; then
    _why=$(sh "$KB_CHECK" "$TMP/keybox.xml" 2>&1)
    if [ $? -ne 0 ]; then
        log "collected keybox is unusable — keeping the one on disk."
        [ -n "$_why" ] && log "reason: $(printf '%s' "$_why" | tr '\n' ';')"
        exit 1
    fi
elif ! head -c 4096 "$TMP/keybox.xml" | grep -q "Keybox"; then
    # checker missing (partial install) — keep the old substring test as a floor
    log "collected payload does not look like a keybox — discarding."
    exit 1
fi

NEW_XML_HASH=$($SHA256 < "$TMP/keybox.xml" | awk '{print tolower($1)}')
DISK_HASH=""
[ -s "$TARGET" ] && DISK_HASH=$($SHA256 < "$TARGET" | awk '{print tolower($1)}')

# ---- Change detection (compare actual on-disk XML, not a side-state) ---
if [ -n "$DISK_HASH" ] && [ "$DISK_HASH" = "$NEW_XML_HASH" ]; then
    log "already up to date."
    exit 2
fi

# ---- Revocation check ----
# Placed after the change check on purpose: this is the only step that needs the
# network beyond the keybox itself, so it runs only when a genuinely different
# keybox is about to be installed — not on every hourly pass.
# Refusing a revoked key is strictly better than installing it: whatever is on
# disk was already failing the same way, and if the mirror regresses after having
# served a good key, this is what keeps the good one. A list that cannot be
# fetched is not a verdict, so the check fails open — it must never be the reason
# a usable key is not applied.
KB_REVOKE="$SELF_DIR/keybox_revoke_check.sh"
if [ -f "$KB_REVOKE" ]; then
    # Reuse the mirror-refreshed cache keybox_sources.sh just wrote when present;
    # only fall back to a direct fetch when there is no cache at all. This keeps
    # the final gate on the same list the collection used (and avoids a second
    # pull). An empty list is not a verdict, so the check fails open.
    STATUS_LIST="$CONFIG_DIR/.kb_status_list"
    if [ ! -s "$STATUS_LIST" ]; then
        try_fetch "$TMP/status.json" "$STATUS_URL" && STATUS_LIST="$TMP/status.json"
    fi
    if [ -s "$STATUS_LIST" ]; then
        _rev=$(sh "$KB_REVOKE" "$TMP/keybox.xml" "$STATUS_LIST" 2>&1)
        _rrc=$?
        if [ "$_rrc" = 1 ]; then
            log "collected keybox is REVOKED by Google — keeping the one on disk."
            printf '%s\n' "$_rev" | sed 's/^/keybox_fetch: /' >&2
            exit 1
        fi
        [ "$_rrc" = 0 ] || log "revocation check inconclusive — proceeding."
    else
        log "no revocation list available — skipping the revocation check."
    fi
fi

# ---- Atomic replace ----
mv -f "$TMP/keybox.xml" "$TARGET" || { log "mv to $TARGET failed."; exit 1; }
chmod 600 "$TARGET"
# Vestigial state file from older versions — clean up so it doesn't
# confuse anyone debugging.
rm -f "$CONFIG_DIR/.keybox.sha256" 2>/dev/null
log "$TARGET updated ($(wc -c < "$TARGET") bytes)."
exit 0
