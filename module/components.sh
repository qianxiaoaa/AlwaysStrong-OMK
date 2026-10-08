#!/system/bin/sh
# AlwaysStrong — component (packages) distribution client.
#
# Fetches the signed component index published by .github/workflows/packages.yml
# (mirror-data branch, mirrored on jsDelivr), verifies it against the bundled
# Ed25519 public key (verify_tool), then lists / checks / installs components:
#   - ksu-module zips  -> ksud/magisk module install (reboot to apply)
#   - apk files        -> pm install -r (immediate)
# Every downloaded component is re-checked against its per-entry sha256 and
# Ed25519 signature before install, so a package fetched from any mirror/CDN is
# safe. The device trusts a key, not a server.
#
# Usage:
#   components.sh list             list index entries
#   components.sh check            compare index vs installed (writes cache)
#   components.sh install <name>   download+verify+install one entry
#   components.sh update           install every NEW/UPD entry
#   components.sh auto             install only x-auto=1 entries (opt-in)
#
# Config markers in $CONFIG_DIR:
#   no_components          disable the whole feature
#   components_auto        allow `auto` installs (default: manual only)
#   components_allow_apk   allow apk installs (default: modules only)
#
# Env: COMPONENTS_REPO (default qianxiaoaa/AlwaysStrong-OMK), COMPONENTS_BASE,
#      COMPONENTS_DISABLE=1
#
# Exit: 0 ok · 2 nothing to do / disabled · 1 failure

REPO="${COMPONENTS_REPO:-${UPDATE_REPO:-qianxiaoaa/AlwaysStrong-OMK}}"
CONFIG_DIR="${CONFIG_DIR:-/data/adb/tricky_store}"
MODDIR="${MODDIR:-/data/adb/modules/tricky_store}"

SELF_DIR=$(cd "${0%/*}" 2>/dev/null && pwd)
[ -z "$SELF_DIR" ] && SELF_DIR="$MODDIR"
PUBKEY="$SELF_DIR/pubkey.b64"

case "$(uname -m)" in
    aarch64)        ABI=arm64-v8a ;;
    armv7*|armv8l)  ABI=armeabi-v7a ;;
    x86_64)         ABI=x86_64 ;;
    i?86)           ABI=x86 ;;
    *)              ABI="" ;;
esac
VERIFY="$SELF_DIR/bin/$ABI/verify_tool"
ASFETCH="$SELF_DIR/bin/$ABI/asfetch"

log() { echo "components: $*" >&2; }

# ---- tool resolution (mirrors self_update.sh) -------------------------------
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
        asfetch) [ -n "$ABI" ] && [ -f "$ASFETCH" ] && { [ -x "$ASFETCH" ] || chmod 0755 "$ASFETCH" 2>/dev/null; } && bounded 180 "$ASFETCH" -T 20 -o "$2" "$3" 2>/dev/null ;;
        bb)      [ -n "$BB" ] && bounded 180 "$BB" wget -q -T 25 -O "$2" "$3" 2>/dev/null ;;
        curl)    command -v curl >/dev/null 2>&1 && bounded 180 curl -fsSL --connect-timeout 15 --speed-limit 1 --speed-time 30 --max-time 170 -o "$2" "$3" 2>/dev/null ;;
        wget)    command -v wget >/dev/null 2>&1 && bounded 180 wget -q -T 25 -O "$2" "$3" 2>/dev/null ;;
    esac
    [ -s "$2" ]
}
try_fetch() {  # $1=out $2=url
    for _e in asfetch bb curl wget; do
        run_engine "$_e" "$1" "$2" && return 0
    done
    return 1
}

SHA256=""
if command -v sha256sum >/dev/null 2>&1; then
    SHA256="sha256sum"
elif [ -n "$BB" ]; then
    SHA256="$BB sha256sum"
fi
sha_of() { [ -n "$SHA256" ] && $SHA256 < "$1" 2>/dev/null | awk '{print tolower($1)}'; }

# ---- index sources ----------------------------------------------------------
MIRROR_DIR="mirror-data/mirror"
BASES="
https://raw.githubusercontent.com/$REPO/$MIRROR_DIR
https://gcore.jsdelivr.net/gh/$REPO@$MIRROR_DIR
https://cdn.jsdelivr.net/gh/$REPO@$MIRROR_DIR
https://fastly.jsdelivr.net/gh/$REPO@$MIRROR_DIR
https://testingcf.jsdelivr.net/gh/$REPO@$MIRROR_DIR"
[ -n "$COMPONENTS_BASE" ] && BASES="$COMPONENTS_BASE"

TMP="$CONFIG_DIR/.components.$$"
mkdir -p "$TMP" 2>/dev/null
trap 'rm -rf "$TMP"' EXIT INT TERM

fetch_index() {  # -> rc 0, $TMP/packages.json + .sig present
    for base in $BASES; do
        b="${base%/}"
        [ -n "$COMPONENTS_ACCEL" ] && b="$COMPONENTS_ACCEL/$base"
        if try_fetch "$TMP/packages.json" "$b/packages.json" \
           && try_fetch "$TMP/packages.json.sig" "$b/packages.json.sig" \
           && grep -q '"modules"' "$TMP/packages.json" 2>/dev/null; then
            log "index <- $b"
            return 0
        fi
    done
    return 1
}

verify_index() {
    [ -f "$TMP/packages.json" ] && [ -f "$TMP/packages.json.sig" ] || return 1
    [ -f "$VERIFY" ] && [ -f "$PUBKEY" ] || return 2
    [ -x "$VERIFY" ] || chmod 0755 "$VERIFY" 2>/dev/null
    bounded 30 "$VERIFY" "$PUBKEY" "$TMP/packages.json.sig" "$TMP/packages.json" >/dev/null 2>&1
}

# ---- index parser -> $TMP/pmeta.txt (name|id|vc|version|type|auto|pkg|url|sha|sig)
parse_index() {
    awk -v FS='"' '
    function trim(v){ gsub(/^[ \t]+/,"",v); gsub(/[ \t]+$/,"",v); gsub(/[,}]/,"",v); return v }
    /^[ \t]*"[^"]+\.(zip|apk)"[ \t]*:[ \t]*\{/ {
      name=$2; delete f
      for(i=3;i<=NF;i++){
        if($i=="x-id"||$i=="x-versionCode"||$i=="x-version"||$i=="x-type"||$i=="x-auto"||$i=="x-package"||$i=="url"||$i=="sha256"||$i=="signature"){
          v=$(i+1); sub(/^[ \t]*:/,"",v); v=trim(v)
          if(v==""||v=="{"){ v=$(i+2); v=trim(v) }
          f[$i]=v
        }
      }
      printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n", name,f["x-id"],f["x-versionCode"],f["x-version"],f["x-type"],f["x-auto"],f["x-package"],f["url"],f["sha256"],f["signature"]
    }' "$TMP/packages.json" > "$TMP/pmeta.txt" 2>/dev/null
    [ -s "$TMP/pmeta.txt" ]
}

installed_vc() { # $1=module id -> versionCode or empty
    _d=""
    [ -f "/data/adb/modules/$1/module.prop" ] && _d="/data/adb/modules/$1"
    [ -z "$_d" ] && [ -f "/data/adb/modules_update/$1/module.prop" ] && _d="/data/adb/modules_update/$1"
    [ -n "$_d" ] || return 1
    _v=$(sed -n 's/^versionCode=//p' "$_d/module.prop" 2>/dev/null | head -1 | tr -d '\r ')
    [ -z "$_v" ] && _v=$(sed -n 's/^version=//p' "$_d/module.prop" 2>/dev/null | head -1 | tr -d '\r ')
    [ -n "$_v" ] && { echo "$_v"; return 0; }
    return 1
}

pm_bin() {
    command -v pm 2>/dev/null && return 0
    for p in /system/bin/pm /system/xbin/pm; do [ -x "$p" ] && { echo "$p"; return 0; }; done
    return 1
}
apk_installed() { # $1 = package name
    _pm=$(pm_bin) || return 1
    "$_pm" path "$1" </dev/null 2>/dev/null | grep -q '^package:'
}

ksud_bin() {
    command -v ksud 2>/dev/null && return 0
    [ -x /data/adb/ksud ] && { echo /data/adb/ksud; return 0; }
    [ -x /data/adb/ksu/bin/ksud ] && { echo /data/adb/ksu/bin/ksud; return 0; }
    return 1
}

STATE="$CONFIG_DIR/components_installed.sha"
state_get() { [ -f "$STATE" ] && sed -n "s|^$1=||p" "$STATE" 2>/dev/null | head -1; }
state_set() { # $1=name $2=sha
    mkdir -p "$CONFIG_DIR"
    if [ -f "$STATE" ]; then grep -v "^$1=" "$STATE" > "$STATE.tmp" 2>/dev/null; else : > "$STATE.tmp"; fi
    echo "$1=$2" >> "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}

# ---- install one downloaded, verified file ----------------------------------
install_file() { # $1=name $2=type $3=pkg $4=path
    _ty="$2"; _pk="$3"; _f="$4"
    if [ "$_ty" = "apk" ]; then
        _pm=$(pm_bin) || { log "pm not found"; return 1; }
        "$_pm" install -r "$_f" </dev/null >/dev/null 2>&1
        return $?
    fi
    _ks=$(ksud_bin) || true
    if [ -n "$_ks" ] && bounded 300 "$_ks" module install "$_f" >/dev/null 2>&1; then
        return 0
    fi
    if command -v magisk >/dev/null 2>&1 && bounded 300 magisk --install-module "$_f" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

# download+verify an entry, then install. $1=pmeta line
install_entry() {
    _line="$1"
    _name=$(printf '%s' "$_line" | cut -d'|' -f1)
    _id=$(printf '%s' "$_line"   | cut -d'|' -f2)
    _ver=$(printf '%s' "$_line"  | cut -d'|' -f4)
    _ty=$(printf '%s' "$_line"   | cut -d'|' -f5)
    _pk=$(printf '%s' "$_line"   | cut -d'|' -f7)
    _url=$(printf '%s' "$_line"  | cut -d'|' -f8)
    _sha=$(printf '%s' "$_line"  | cut -d'|' -f9)
    _sig=$(printf '%s' "$_line"  | cut -d'|' -f10)
    [ -n "$_url" ] || { log "$_name: no url"; return 1; }
    if [ "$_ty" = "apk" ] && [ ! -f "$CONFIG_DIR/components_allow_apk" ]; then
        log "$_name: apk installs disabled (touch $CONFIG_DIR/components_allow_apk)"
        return 1
    fi
    _dst="$TMP/$_name"
    try_fetch "$_dst" "$_url" || { log "$_name: download failed"; return 1; }
    _got=$(sha_of "$_dst")
    if [ -n "$_sha" ] && [ "$_got" != "$(printf '%s' "$_sha" | tr 'A-Z' 'a-z')" ]; then
        log "$_name: sha256 mismatch"; return 1
    fi
    if [ -n "$_sig" ] && [ -f "$VERIFY" ] && [ -f "$PUBKEY" ]; then
        printf '%s' "$_sig" > "$TMP/one.sig"
        if ! bounded 30 "$VERIFY" "$PUBKEY" "$TMP/one.sig" "$_dst" >/dev/null 2>&1; then
            log "$_name: signature verification failed"; return 1
        fi
    else
        log "$_name: signature unavailable, refusing"; return 1
    fi
    if install_file "$_name" "$_ty" "$_pk" "$_dst"; then
        [ "$_ty" = "apk" ] && state_set "$_name" "$_sha"
        log "$_name: installed"
        return 0
    fi
    log "$_name: install failed"
    return 1
}

need_index() {
    fetch_index || { echo "COMP_STATE=FAIL"; echo "COMP_SUMMARY=index fetch failed"; return 1; }
    if ! verify_index; then
        echo "COMP_STATE=FAIL"; echo "COMP_SUMMARY=index signature invalid"; return 1
    fi
    parse_index || { echo "COMP_STATE=FAIL"; echo "COMP_SUMMARY=index parse failed"; return 1; }
    return 0
}

cmd_check() {
    need_index || return 1
    : > "$TMP/check.txt"
    n_new=0; n_upd=0; n_ok=0
    while IFS='|' read -r name id vc ver ty au pk url sha sig; do
        [ -n "$name" ] || continue
        if [ "$ty" = "apk" ]; then
            label="${pk:-$name}"
            if [ -z "$pk" ]; then
                echo "CHECK|$name|$label|?|?|ERR|index missing package name" >> "$TMP/check.txt"; continue
            fi
            if apk_installed "$pk"; then
                inst=$(state_get "$name")
                if [ -n "$inst" ] && [ -n "$sha" ] && [ "$inst" != "$sha" ]; then
                    echo "CHECK|$name|$label|installed|new|UPD|update available" >> "$TMP/check.txt"; n_upd=$((n_upd+1))
                else
                    echo "CHECK|$name|$label|installed|-|OK|installed (app)" >> "$TMP/check.txt"; n_ok=$((n_ok+1))
                fi
            else
                echo "CHECK|$name|$label|not installed|-|NEW|not installed (app)" >> "$TMP/check.txt"; n_new=$((n_new+1))
            fi
            continue
        fi
        mid="${id:-$(echo "$name" | sed 's/\.zip$//')}"
        lvc=$(installed_vc "$mid") || lvc=""
        if [ -z "$lvc" ]; then
            echo "CHECK|$name|$mid|not installed|${vc:-?}|NEW|not installed" >> "$TMP/check.txt"; n_new=$((n_new+1))
        elif [ -n "$vc" ] && [ "$lvc" -eq "$vc" ] 2>/dev/null; then
            echo "CHECK|$name|$mid|$lvc|$vc|OK|up to date" >> "$TMP/check.txt"; n_ok=$((n_ok+1))
        elif [ -n "$vc" ] && [ "$lvc" -gt "$vc" ] 2>/dev/null; then
            echo "CHECK|$name|$mid|$lvc|$vc|OK|local newer than index" >> "$TMP/check.txt"; n_ok=$((n_ok+1))
        else
            echo "CHECK|$name|$mid|$lvc|${vc:-?}|UPD|update available${ver:+: $ver}" >> "$TMP/check.txt"; n_upd=$((n_upd+1))
        fi
    done < "$TMP/pmeta.txt"

    cp -f "$TMP/check.txt" "$CONFIG_DIR/components_check.txt" 2>/dev/null
    ntot=$((n_new + n_upd + n_ok))
    if [ "$n_new" -gt 0 ] || [ "$n_upd" -gt 0 ]; then st=UPD; else st=OK; fi
    {
        echo "state=$st"
        echo "checked_at=$(date '+%m-%d %H:%M')"
        echo "new=$n_new"
        echo "upd=$n_upd"
        echo "ok=$n_ok"
        echo "total=$ntot"
    } > "$CONFIG_DIR/components.prop" 2>/dev/null
    cat "$TMP/check.txt"
    echo "COMP_STATE=$st"
    echo "COMP_SUMMARY=total $ntot: new $n_new, update $n_upd, ok $n_ok"
    return 0
}

cmd_list() {
    need_index || return 1
    while IFS='|' read -r name id vc ver ty au pk url sha sig; do
        [ -n "$name" ] || continue
        echo "$name ${ver:+$ver }[$ty]${au:+ auto=$au}"
    done < "$TMP/pmeta.txt"
    return 0
}

cmd_install() {
    _want="$1"
    [ -n "$_want" ] || { echo "usage: components.sh install <name>"; return 1; }
    need_index || return 1
    _line=$(grep -F "$_want|" "$TMP/pmeta.txt" 2>/dev/null | head -1)
    [ -n "$_line" ] || _line=$(grep -F "$_want" "$TMP/pmeta.txt" 2>/dev/null | head -1)
    [ -n "$_line" ] || { echo "INSTALL=FAIL"; echo "no such component: $_want"; return 1; }
    if install_entry "$_line"; then
        echo "INSTALL=OK"
        return 0
    fi
    echo "INSTALL=FAIL"
    return 1
}

cmd_update() { # install NEW/UPD entries
    need_index || return 1
    cmd_check >/dev/null 2>&1
    [ -f "$CONFIG_DIR/components_check.txt" ] || { echo "UPDATE=NONE"; return 2; }
    ok=0; fail=0
    while IFS='|' read -r tag name mid lvc rvc st msg; do
        [ -n "$name" ] || continue
        case "$st" in UPD|NEW) ;; *) continue ;; esac
        _line=$(grep -F "$name|" "$TMP/pmeta.txt" 2>/dev/null | head -1)
        [ -n "$_line" ] || continue
        if install_entry "$_line"; then ok=$((ok+1)); else fail=$((fail+1)); fi
    done < "$CONFIG_DIR/components_check.txt"
    if [ "$ok" -gt 0 ]; then
        echo "UPDATE=OK"
        echo "UPDATE_OK=$ok"
        echo "UPDATE_FAIL=$fail"
        echo "UPDATE_RESTART=1"
        return 0
    fi
    echo "UPDATE=NONE"
    echo "UPDATE_FAIL=$fail"
    return 2
}

cmd_auto() {
    [ -f "$CONFIG_DIR/components_auto" ] || { echo "AUTO=DISABLED"; return 2; }
    need_index || return 1
    ok=0; fail=0
    while IFS='|' read -r name id vc ver ty au pk url sha sig; do
        [ -n "$name" ] || continue
        [ "$au" = "1" ] || continue
        _line=$(grep -F "$name|" "$TMP/pmeta.txt" 2>/dev/null | head -1)
        [ -n "$_line" ] || continue
        # skip when already satisfied
        if [ "$ty" = "apk" ]; then
            if apk_installed "$pk" && [ "$(state_get "$name")" = "$sha" ]; then continue; fi
        else
            mid="${id:-$(echo "$name" | sed 's/\.zip$//')}"
            lvc=$(installed_vc "$mid") || lvc=""
            [ -n "$lvc" ] && [ -n "$vc" ] && [ "$lvc" -ge "$vc" ] 2>/dev/null && continue
        fi
        if install_entry "$_line"; then ok=$((ok+1)); else fail=$((fail+1)); fi
    done < "$TMP/pmeta.txt"
    if [ "$ok" -gt 0 ]; then
        echo "AUTO=OK"; echo "AUTO_OK=$ok"; echo "AUTO_FAIL=$fail"; echo "AUTO_RESTART=1"; return 0
    fi
    echo "AUTO=NONE"; echo "AUTO_FAIL=$fail"; return 2
}

ACTION="${1:-check}"
if [ -f "$CONFIG_DIR/no_components" ] || [ "$COMPONENTS_DISABLE" = "1" ]; then
    echo "COMP_STATE=DISABLED"
    exit 2
fi

case "$ACTION" in
    list)    cmd_list ;;
    check)   cmd_check ;;
    install) shift; cmd_install "$@" ;;
    update)  cmd_update ;;
    auto)    cmd_auto ;;
    *)       echo "usage: components.sh {list|check|install <name>|update|auto}"; exit 2 ;;
esac
exit $?
