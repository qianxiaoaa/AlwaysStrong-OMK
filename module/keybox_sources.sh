#!/system/bin/sh
# AlwaysStrong — multi-source keybox collection.
#
# Ported from yypm's PHP server (php-server/lib/sources.php + config.php main
# loop). That project runs a self-hosted server that pulls a *pool* of upstream
# keybox sources, decodes each one, validates it, and picks the best. This is
# the same idea brought on-device, so the module no longer depends on a single
# mirror that can go stale, get revoked, or disappear.
#
# Sources (yypm's pool, priorities preserved):
#   priority 1 — hand-picked, long-verified
#     yurikey       plain base64
#     integritybox  10 rounds of base64, then hex, then rot13
#     megatron      same encoding as integritybox
#   priority 2 — collection repos (hundreds of files, date-rotated sampling)
#     keyboxhub     shall0e/KeyboxHub/KeyboxHub
#     keyboxstatus  SSM-FX/KeyboxStatus (repo root)
#
# Selection: walk priority 1 before priority 2; within a source take the first
# file that passes both the structural check (keybox_check.sh) and the
# revocation check (keybox_revoke_check.sh). A structure-valid but revoked
# candidate is skipped so the next source gets a turn — a revoked key changes
# nothing (verdicts already red) while a keymint-rejected key is strictly worse.
# If nothing passes, the caller keeps whatever is already on disk.
#
# Usage:
#   sh keybox_sources.sh collect <outfile>   # pick a usable keybox -> outfile
#   sh keybox_sources.sh decode <type>       # read stdin, write decoded stdout
#
# collect prints the chosen source name on stdout or nothing on failure, and
# diagnostics on stderr. Exit: 0 wrote outfile · 1 no usable candidate.
#
# Env:
#   CONFIG_DIR     default /data/adb/tricky_store
#   KEYBOX_ACCEL   optional GitHub acceleration prefix (e.g. https://fast.fumor.top/)
#   KEYBOX_STATUS_URL  override the revocation-list source order with one URL
#
# Exit codes from collect: 0 ok · 1 no usable candidate.

CONFIG_DIR="${CONFIG_DIR:-/data/adb/tricky_store}"
SELF_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR=/data/adb/modules/tricky_store
LIST_TTL=86400

log() { echo "keybox_sources: $*" >&2; }

# ---- tool resolution --------------------------------------------------------
# Same fallback shape keybox_fetch.sh uses: the shell builtins/toybox tools are
# usually present, busybox covers the ROMs where they are not.
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

TO=""
if timeout -k 1 5 true >/dev/null 2>&1; then TO="timeout -k 3"
elif timeout 5 true >/dev/null 2>&1; then TO="timeout"
elif [ -n "$BB" ] && "$BB" timeout -k 1 5 true >/dev/null 2>&1; then TO="$BB timeout -k 3"
elif [ -n "$BB" ] && "$BB" timeout 5 true >/dev/null 2>&1; then TO="$BB timeout"
fi
bounded() { _bs="$1"; shift; if [ -n "$TO" ]; then $TO "$_bs" "$@"; else "$@"; fi; }

# run_engine NAME OUTFILE URL — one download attempt with the named engine.
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

TR=""
if tr A-Z N-Z </dev/null >/dev/null 2>&1; then
    TR="tr"
elif [ -n "$BB" ] && "$BB" tr A-Z N-Z </dev/null >/dev/null 2>&1; then
    TR="$BB tr"
fi

# hex -> raw bytes. xxd -r -p is the fast path; the awk fallback keeps this
# working on ROMs whose busybox was built without xxd. Every decoder's input is
# ASCII (base64/hex text), so awk's %c never has to emit a byte >= 128 here.
HEX2BIN=""
if command -v xxd >/dev/null 2>&1 && printf '41' | xxd -r -p >/dev/null 2>&1; then
    HEX2BIN="xxd -r -p"
elif [ -n "$BB" ] && printf '41' | "$BB" xxd -r -p >/dev/null 2>&1; then
    HEX2BIN="$BB xxd -r -p"
fi
hex2bin_awk() {
    awk '
    {
        gsub(/[^0-9A-Fa-f]/, "")
        n = length($0)
        for (i = 1; i + 1 <= n; i += 2) {
            hi = index("0123456789abcdef", tolower(substr($0, i, 1))) - 1
            lo = index("0123456789abcdef", tolower(substr($0, i + 1, 1))) - 1
            if (hi < 0 || lo < 0) continue
            printf "%c", hi * 16 + lo
        }
    }'
}
hex2bin() {
    if [ -n "$HEX2BIN" ]; then $HEX2BIN; else hex2bin_awk; fi
}

# GitHub acceleration prefix for raw/github URLs (optional; yypm's server uses
# fast.fumor.top). Applied only when KEYBOX_ACCEL is set.
accel_url() {
    _u=$1
    if [ -n "$KEYBOX_ACCEL" ]; then
        case "$_u" in
            https://raw.githubusercontent.com/*|https://github.com/*)
                printf '%s/%s' "${KEYBOX_ACCEL%/}" "$_u" ;;
            *) printf '%s' "$_u" ;;
        esac
    else
        printf '%s' "$_u"
    fi
}

# ---- decoders ---------------------------------------------------------------

decode_multi_base64_hex_rot13() {
    _d=$(tr -d '[:space:]')
    [ -n "$_d" ] || return 1
    _i=0
    while [ "$_i" -lt 10 ]; do
        _d=$(printf '%s' "$_d" | $B64DEC 2>/dev/null)
        [ -n "$_d" ] || return 1
        _d=$(printf '%s' "$_d" | tr -d '[:space:]')
        [ -n "$_d" ] || return 1
        _i=$((_i + 1))
    done
    # Odd length means a lost/added byte at some layer: hex2bin cannot frame it.
    [ $(( ${#_d} % 2 )) -eq 0 ] || return 1
    printf '%s' "$_d" | hex2bin | $TR 'A-Za-z' 'N-ZA-Mn-za-m'
}

decode_hex_base64() {
    _hex=$(tr -d '[:space:]')
    [ -n "$_hex" ] || return 1
    [ $(( ${#_hex} % 2 )) -eq 0 ] || return 1
    _h=$(printf '%s' "$_hex" | hex2bin)
    [ -n "$_h" ] || return 1
    if printf '%s' "$_h" | grep -q -F '<?xml'; then printf '%s' "$_h"; return 0; fi
    if printf '%s' "$_h" | grep -q -F '<AndroidAttestation>'; then printf '%s' "$_h"; return 0; fi
    _d=$(printf '%s' "$_h" | tr -d '[:space:]' | $B64DEC 2>/dev/null)
    if [ -n "$_d" ] && (printf '%s' "$_d" | grep -q -F '<?xml' || printf '%s' "$_d" | grep -q -F '<AndroidAttestation>'); then
        printf '%s' "$_d"; return 0
    fi
    printf '%s' "$_h"
}

decode_stream() {
    case "$1" in
        base64)                 tr -d '[:space:]' | $B64DEC ;;
        hex_base64)             decode_hex_base64 ;;
        multi_base64_hex_rot13) decode_multi_base64_hex_rot13 ;;
        *)                      return 1 ;;
    esac
}

# ---- validators -------------------------------------------------------------

# struct_ok FILE — will keymint accept this document? (keybox_check.sh)
struct_ok() {
    [ -s "$1" ] || return 1
    if [ -f "$SELF_DIR/keybox_check.sh" ]; then
        sh "$SELF_DIR/keybox_check.sh" --quiet "$1" >/dev/null 2>&1
    else
        grep -q "Keybox" "$1" 2>/dev/null
    fi
}

# rev_rejected FILE — is it on Google's list? Fails open (no list -> not
# rejected): a missing list is not a verdict, and must never block a usable key.
rev_rejected() {
    [ -s "$LIST" ] || return 1
    [ -f "$SELF_DIR/keybox_revoke_check.sh" ] || return 1
    sh "$SELF_DIR/keybox_revoke_check.sh" "$1" "$LIST" >/dev/null 2>&1
    [ $? -eq 1 ]
}

# ---- revocation list (multi-mirror) -----------------------------------------
# yypm pulls mirrors of Google's attestation/status because the official host is
# unreachable from some networks. Order matters: mirrors first, official last.
status_list_sources() {
    if [ -n "$KEYBOX_STATUS_URL" ]; then
        printf 'override|%s\n' "$KEYBOX_STATUS_URL"
        return 0
    fi
    cat <<'EOF'
purainity|https://raw.githubusercontent.com/purainity/keybox-tools/main/res/status.json
kimmyxyc|https://raw.githubusercontent.com/KimmyXYC/KeyboxChecker/main/res/json/status.json
google|https://android.googleapis.com/attestation/status
EOF
}

list_age() {
    _t=
    if command -v stat >/dev/null 2>&1; then _t=$(stat -c %Y "$LIST" 2>/dev/null); fi
    if [ -z "$_t" ] && command -v date >/dev/null 2>&1; then _t=$(date -r "$LIST" +%s 2>/dev/null); fi
    case "$_t" in ''|*[!0-9]*) echo ""; return ;; esac
    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) echo ""; return ;; esac
    echo $((_now - _t))
}

ensure_status_list() {
    if [ -s "$LIST" ]; then
        _age=$(list_age)
        [ -z "$_age" ] && return 0
        [ "$_age" -lt "$LIST_TTL" ] && return 0
    fi
    status_list_sources > "$TMP/status.sources"
    while IFS='|' read -r _nm _u; do
        [ -n "$_u" ] || continue
        rm -f "$LIST.tmp"
        if try_fetch "$LIST.tmp" "$(accel_url "$_u")" && grep -q '"entries"' "$LIST.tmp" 2>/dev/null; then
            mv -f "$LIST.tmp" "$LIST"
            log "status list refreshed from $_nm"
            return 0
        fi
    done < "$TMP/status.sources"
    rm -f "$LIST.tmp"
    log "status list refresh failed — using existing list if any"
    return 1
}

# ---- directory (collection-repo) source -------------------------------------
# Normalise text so UTF-16 (KeyboxHub stores UTF-16LE + BOM) or a UTF-8 BOM does
# not hide the ASCII markers. Dropping NUL bytes de-interleaves UTF-16 ASCII
# without needing iconv.
normalize_text() {
    _in=$1; _o=$2
    tr -d '\000' < "$_in" > "$_o.tmpn" 2>/dev/null || { cp -f "$_in" "$_o"; return 0; }
    _b=$(head -c 3 "$_o.tmpn" | od -An -tx1 | tr -d ' \n')
    case "$_b" in
        fffe*)   tail -c +3 "$_o.tmpn" > "$_o" ;;
        feff*)   tail -c +3 "$_o.tmpn" > "$_o" ;;
        efbbbf*) tail -c +4 "$_o.tmpn" > "$_o" ;;
        *)       mv -f "$_o.tmpn" "$_o" ;;
    esac
    rm -f "$_o.tmpn"
    return 0
}

# dir_source_pick REPO DIR OUTFILE — list a repo dir, date-rotate the start
# point, and return the first XML that passes structure + revocation.
dir_source_pick() {
    _repo=$1; _dir=$2; _out=$3
    _api="https://api.github.com/repos/$_repo/contents/$_dir"
    _json="$TMP/dir.$$"
    rm -f "$_json"
    # Direct first (the accelerator truncates large directory listings).
    try_fetch "$_json" "$_api" || return 1
    _pairs=$(tr ',' '\n' < "$_json" | awk '
        /"name"[ \t]*:/ { v=$0; sub(/.*"name"[ \t]*:[ \t]*"/, "", v); sub(/".*/, "", v); name=v; have=1; next }
        /"download_url"[ \t]*:/ {
            if ($0 ~ /"download_url"[ \t]*:[ \t]*"/) {
                v=$0; sub(/.*"download_url"[ \t]*:[ \t]*"/, "", v); sub(/".*/, "", v)
                if (have && v != "") print name "\t" v
            }
            have=0
        }')
    _xml=$(printf '%s\n' "$_pairs" | awk -F'\t' 'NF==2 && tolower($1) ~ /\.xml$/ { print }')
    [ -n "$_xml" ] || return 1
    _count=$(printf '%s\n' "$_xml" | grep -c .)
    [ "$_count" -gt 0 ] || return 1
    _off=$(( $(date +%j 2>/dev/null || echo 0) % _count ))
    _i=0; _n=0
    while [ "$_n" -lt 15 ] && [ "$_i" -lt "$_count" ]; do
        _idx=$(( (_off + _i) % _count ))
        _i=$((_i + 1)); _n=$((_n + 1))
        _url=$(printf '%s\n' "$_xml" | awk -F'\t' -v n="$((_idx + 1))" 'NR==n{print $2}')
        [ -n "$_url" ] || continue
        _raw="$TMP/dirraw.$$"
        try_fetch "$_raw" "$(accel_url "$_url")" || continue
        normalize_text "$_raw" "$_out" || continue
        struct_ok "$_out" || continue
        rev_rejected "$_out" && continue
        return 0
    done
    return 1
}

# ---- source registry (yypm pool) --------------------------------------------
# name|priority|type|arg1|arg2   (priority 1 first, then 2)
sources_list() {
    cat <<'EOF'
yurikey|1|base64|https://raw.githubusercontent.com/Yurii0307/yurikey/main/key|
integritybox|1|multi_base64_hex_rot13|https://raw.githubusercontent.com/MeowDump/MeowDump/refs/heads/main/NullVoid/OptimusPrime|
megatron|1|multi_base64_hex_rot13|https://raw.githubusercontent.com/MeowDump/MeowDump/main/Megatron|
keyboxhub|2|github_dir|shall0e/KeyboxHub|KeyboxHub
keyboxstatus|2|github_dir|SSM-FX/KeyboxStatus|
EOF
}

# ---- collect ----------------------------------------------------------------
collect() {
    out=$1
    mkdir -p "$CONFIG_DIR"
    TMP=$(mktemp -d "${TMPDIR:-/data/local/tmp}/kbsrc.XXXXXX" 2>/dev/null)
    [ -n "$TMP" ] && [ -d "$TMP" ] || TMP="$CONFIG_DIR/.kbsrc.$$"
    mkdir -p "$TMP"
    trap 'rm -rf "$TMP"' EXIT INT TERM

    LIST="$CONFIG_DIR/.kb_status_list"
    ensure_status_list

    # Human-pinned keybox wins (A/B / rollback), exactly like yypm's keybox_pin.
    PIN="$CONFIG_DIR/keybox.pinned.xml"
    if [ -s "$PIN" ] && struct_ok "$PIN"; then
        if rev_rejected "$PIN"; then
            log "pinned keybox is revoked — ignoring pin"
        else
            cp -f "$PIN" "$out"
            echo "pinned"
            return 0
        fi
    fi

    sources_list > "$TMP/sources"
    while IFS='|' read -r name prio type arg1 arg2; do
        [ -n "$name" ] || continue
        log "trying source: $name ($type, priority $prio)"
        cand="$TMP/$name.xml"
        case "$type" in
            base64)
                raw="$TMP/$name.raw"
                try_fetch "$raw" "$(accel_url "$arg1")" || { log "  download failed"; continue; }
                tr -d '[:space:]' < "$raw" | $B64DEC > "$cand" 2>/dev/null
                ;;
            hex_base64)
                raw="$TMP/$name.raw"
                try_fetch "$raw" "$(accel_url "$arg1")" || { log "  download failed"; continue; }
                decode_hex_base64 < "$raw" > "$cand" || { log "  decode failed"; continue; }
                ;;
            multi_base64_hex_rot13)
                raw="$TMP/$name.raw"
                try_fetch "$raw" "$(accel_url "$arg1")" || { log "  download failed"; continue; }
                decode_multi_base64_hex_rot13 < "$raw" > "$cand" || { log "  decode failed"; continue; }
                ;;
            github_dir)
                dir_source_pick "$arg1" "$arg2" "$cand" || { log "  no usable file in directory"; continue; }
                ;;
            *)
                continue
                ;;
        esac
        if [ ! -s "$cand" ]; then log "  empty candidate"; continue; fi
        if ! struct_ok "$cand"; then log "  failed structural check"; continue; fi
        if rev_rejected "$cand"; then log "  revoked by Google — trying next source"; continue; fi
        cp -f "$cand" "$out"
        echo "$name"
        return 0
    done < "$TMP/sources"
    log "no usable keybox from any source"
    return 1
}

case "$1" in
    collect) shift; collect "$@"; exit $? ;;
    decode)  shift; decode_stream "$@" ;;
    *) echo "usage: keybox_sources.sh {collect <outfile>|decode <type>}" >&2; exit 2 ;;
esac
