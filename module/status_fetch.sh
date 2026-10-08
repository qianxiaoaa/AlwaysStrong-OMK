#!/system/bin/sh
# AlwaysStrong — module.prop keybox-health prefix, derived on-device.
#
# This used to ask the keybox mirror for a status line ("🟢🟢🟢"). The keybox no
# longer comes from that mirror (it comes from ZeyolZZZ's TEESimulator-RS-fix
# repo), so the mirror's verdict described a key the device is not using. The
# prefix is now computed from local state instead, three symbols left to right:
#   1. keybox   — /data/adb/tricky_store/keybox.xml is present and structurally
#                 usable (keybox_check.sh)
#   2. engine   — the attestation engine is running (attest_alive)
#   3. revoked  — the configured keybox is not on Google's revocation list,
#                 judged against a locally cached copy of that list
# Each symbol is 🟢 healthy, 🔴 broken, 🟡/⚪ unknown. A valid-but-revoked keybox
# reads 🟢🟢🔴 — like the mirror's "two green one red" (BASIC + DEVICE pass,
# only STRONG fails) — while a keymint-rejected keybox reads 🔴🔴🟡.
#
# Format: "description=<three symbols> <base>"  ← prefix, a space, then base.
# Base text is the canonical line from description.txt (single source of truth).
#
# Called from action.sh (manual) and service.sh (hourly + first boot).
# Idempotent: only rewrites module.prop if the description actually changed.
#
# Modes:
#   manual  action button — always recompute and write
#   auto    service.sh hourly — skip the write if no_auto_indicator is present
#   strip   WebUI indicator OFF — restore description to the bare base, no compute
#
# Exit: 0 ok · 1 setup problem (missing module.prop / description.txt)
#       2 nothing to derive from (no keybox) · 4 empty base text

MODE="${1:-auto}"
MODPATH="${MODPATH:-/data/adb/modules/tricky_store}"
PROP="$MODPATH/module.prop"
BASE_FILE="$MODPATH/description.txt"
CONFIG_DIR=/data/adb/tricky_store
NO_AUTO_FLAG="$CONFIG_DIR/no_auto_indicator"
KB="$CONFIG_DIR/keybox.xml"

# Google's attestation status list — the same public endpoint keybox_fetch.sh
# checks against when it installs a key. Cached here so the hourly status pass
# does not pull ~180 KB every time; KEYBOX_STATUS_URL overrides it (mirrors the
# env var the fetch script already honours).
STATUS_URL="${KEYBOX_STATUS_URL:-https://android.googleapis.com/attestation/status}"
LIST="$CONFIG_DIR/.kb_status_list"
LIST_TTL=86400   # 24h

log() { echo "status_fetch: $*"; }

[ -f "$PROP" ] || exit 1
[ -f "$BASE_FILE" ] || exit 1

# ---- strip mode: bare base text, no compute ---------------------------------
if [ "$MODE" = "strip" ]; then
    base=$(head -1 "$BASE_FILE" | tr -d '\r\n')
    [ -z "$base" ] && exit 4
    want="description=${base}"
    have=$(grep -m1 '^description=' "$PROP")
    [ "$have" = "$want" ] && exit 0
    tmp="${PROP}.tmp"
    awk -v new="$want" '
        !done && /^description=/ { print new; done=1; next }
        { print }
    ' "$PROP" > "$tmp" && mv -f "$tmp" "$PROP"
    exit 0
fi

# Auto path + user opted out of the indicator → leave module.prop alone.
if [ "$MODE" != "manual" ] && [ -f "$NO_AUTO_FLAG" ]; then
    exit 0
fi

# ---- tool resolution --------------------------------------------------------
BB=""
for p in /data/adb/modules/busybox-ndk/system/*/busybox /data/adb/magisk/busybox \
         /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
    [ -f "$p" ] && BB="$p" && break
done

SELF_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="$MODPATH"
case "$(uname -m)" in
    aarch64)       SF_ABI=arm64-v8a ;;
    armv7*|armv8l) SF_ABI=armeabi-v7a ;;
    x86_64)        SF_ABI=x86_64 ;;
    i?86)          SF_ABI=x86 ;;
    *)             SF_ABI="" ;;
esac
ASFETCH="$SELF_DIR/bin/$SF_ABI/asfetch"

# bounded SECS cmd... — asfetch / wget / curl can stall on a dead route or a
# hung DNS; every network step here is bounded so a manual press never freezes.
TO=""
if timeout -k 1 5 true >/dev/null 2>&1; then TO="timeout -k 3"
elif timeout 5 true >/dev/null 2>&1; then TO="timeout"
elif [ -n "$BB" ] && "$BB" timeout -k 1 5 true >/dev/null 2>&1; then TO="$BB timeout -k 3"
elif [ -n "$BB" ] && "$BB" timeout 5 true >/dev/null 2>&1; then TO="$BB timeout"
fi
bounded() { _bs="$1"; shift; if [ -n "$TO" ]; then $TO "$_bs" "$@"; else "$@"; fi; }

# ---- 1. keybox structure ----------------------------------------------------
KB_STATE=1   # 0 ok, 1 bad/missing
if [ -x "$SELF_DIR/keybox_check.sh" ] || [ -f "$SELF_DIR/keybox_check.sh" ]; then
    sh "$SELF_DIR/keybox_check.sh" --quiet "$KB" >/dev/null 2>&1 && KB_STATE=0
elif [ -s "$KB" ]; then
    # checker missing (partial install) — keep the old substring test as a floor
    head -c 4096 "$KB" | grep -q "Keybox" && KB_STATE=0
fi
[ -s "$KB" ] || KB_STATE=1

# ---- 2. engine liveness -----------------------------------------------------
ENGINE_STATE=1
if [ -f "$SELF_DIR/attest.sh" ]; then
    MODDIR="$MODPATH"
    . "$SELF_DIR/attest.sh"
    if command -v attest_alive >/dev/null 2>&1; then
        attest_alive >/dev/null 2>&1 && ENGINE_STATE=0
    elif pidof keymint >/dev/null 2>&1; then
        ENGINE_STATE=0
    fi
elif pidof keymint >/dev/null 2>&1; then
    ENGINE_STATE=0
fi

# ---- 3. revocation (against a cached Google status list) --------------------
# Refresh the cached list only when it is missing or older than LIST_TTL, so the
# hourly and per-press passes stay cheap. A stale-but-present list is still used
# if the refresh fails: a slightly old verdict beats no verdict.
fetch_to() {
    _o="$1"; _u="$2"
    rm -f "$_o"
    if [ -n "$SF_ABI" ] && [ -x "$ASFETCH" ]; then
        bounded 30 "$ASFETCH" -T 12 -o "$_o" "$_u" 2>/dev/null
        [ -s "$_o" ] && return 0
    fi
    if [ -n "$BB" ]; then
        bounded 30 "$BB" wget -q -T 12 -O "$_o" "$_u" 2>/dev/null
        [ -s "$_o" ] && return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        bounded 30 curl -fsSL --connect-timeout 8 --speed-limit 1 --speed-time 12 --max-time 28 -o "$_o" "$_u" 2>/dev/null
        [ -s "$_o" ] && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        bounded 30 wget -q -T 12 -O "$_o" "$_u" 2>/dev/null
        [ -s "$_o" ] && return 0
    fi
    return 1
}
list_age() { # seconds since LIST was modified; empty if unknown
    _t=
    if command -v stat >/dev/null 2>&1; then
        _t=$(stat -c %Y "$LIST" 2>/dev/null)
    fi
    if [ -z "$_t" ] && command -v date >/dev/null 2>&1; then
        _t=$(date -r "$LIST" +%s 2>/dev/null)
    fi
    case "$_t" in ''|*[!0-9]*) echo ""; return ;; esac
    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) echo ""; return ;; esac
    echo $((_now - _t))
}
need_list=1
if [ -s "$LIST" ]; then
    _age=$(list_age)
    # Unknown age (no stat) → treat as fresh rather than refetch every pass.
    [ -z "$_age" ] && need_list=0
    [ -n "$_age" ] && [ "$_age" -lt "$LIST_TTL" ] && need_list=0
fi
if [ "$need_list" = 1 ]; then
    fetch_to "$LIST.tmp" "$STATUS_URL" && mv -f "$LIST.tmp" "$LIST" || rm -f "$LIST.tmp"
fi

REV_STATE=2   # 0 ok, 1 revoked, 2 unknown
if [ -s "$LIST" ] && [ -f "$SELF_DIR/keybox_revoke_check.sh" ]; then
    sh "$SELF_DIR/keybox_revoke_check.sh" "$KB" "$LIST" >/dev/null 2>&1
    case $? in
        0) REV_STATE=0 ;;
        1) REV_STATE=1 ;;
        *) REV_STATE=2 ;;
    esac
fi

# ---- assemble the prefix ----------------------------------------------------
# 🟢 ok · 🔴 broken · 🟡 unknown. Position order matches the paragraphs above.
if [ "$KB_STATE" = 0 ]; then o1=🟢; else o1=🔴; fi
if [ "$ENGINE_STATE" = 0 ]; then o2=🟢; else o2=🔴; fi
case "$REV_STATE" in
    0) o3=🟢 ;;
    1) o3=🔴 ;;
    *) o3=🟡 ;;
esac
new="${o1}${o2}${o3}"

base=$(head -1 "$BASE_FILE" | tr -d '\r\n')
[ -z "$base" ] && exit 4

want="description=${new} ${base}"
have=$(grep -m1 '^description=' "$PROP")
[ "$have" = "$want" ] && exit 0

# Atomic rewrite: build the whole file, then swap it in.
tmp="${PROP}.tmp"
awk -v new="$want" '
    !done && /^description=/ { print new; done=1; next }
    { print }
' "$PROP" > "$tmp" && mv -f "$tmp" "$PROP"
log "health ${new} (keybox=$KB_STATE engine=$ENGINE_STATE revoked-state=$REV_STATE)"
exit 0
