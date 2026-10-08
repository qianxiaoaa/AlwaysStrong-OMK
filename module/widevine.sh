#!/system/bin/sh
# Widevine L1 attestation-key injection via the vendor KmInstallKeybox binary.
#
# Ported from dpejoh/specter (src/features/widevine.sh). Downloads an
# attestation keybox (substitution-ciphered), decodes it, and feeds it to the
# vendor's KmInstallKeybox tool so Widevine reports L1. Only meaningful on
# devices whose vendor still ships KmInstallKeybox (mostly Qualcomm); elsewhere
# it reports "not found" and does nothing.
#
# OFF BY DEFAULT — it writes a keybox into the TEE provisioning path, which is a
# device-specific operation. Enable from the WebUI 环境对抗 page.
#
# Toggles (yypm config):
#   widevine_l1 on|off                     (default off)
#   widevine_attestation_url <url>         (override; defaults to specter's feed)
#
# Manual: `webui.sh widevine-install` (always runs, ignores the auto switch).

MODDIR="${MODDIR:-${0%/*}}"
# shellcheck source=/dev/null
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

STD_ALPHABET="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
SHUFFLED_ALPHABET="1dgWnocayqxU3r6vA5lCIPYfHmkV08b4tz+KMsp2NQ9LRXihODwSj7BEFJ/ZuGTe"
decode_substitution() { tr "$SHUFFLED_ALPHABET" "$STD_ALPHABET" < "$1" > "$2"; }

find_kmInstallKeybox() {
    _fk_dir=
    for _fk_dir in /vendor/bin/hw /vendor/bin /system/bin /system/vendor/bin \
                     /odm/bin /vendor/lib64/hw /vendor/lib/hw; do
        [ -x "$_fk_dir/KmInstallKeybox" ] && { echo "$_fk_dir/KmInstallKeybox"; return 0; }
    done
    return 1
}

MODE="${1:-auto}"
if [ "$MODE" != "manual" ] && [ "$(cfg_get widevine_l1 off)" != "on" ]; then
    echo "WIDEVINE=off"
    exit 0
fi

URL=$(cfg_get widevine_attestation_url "https://rawbin.dpejoh.com/clips/attestation")

WDIR=/data/local/tmp
_raw="$WDIR/widevine_attestation_raw.$$"
_dec="$WDIR/widevine_attestation.$$"
trap 'rm -f "$_raw" "$_dec" 2>/dev/null' EXIT

if ! download "$URL" "$_raw" || [ ! -s "$_raw" ]; then
    log "[widevine] 下载 attestation 失败（$URL）"
    echo "WIDEVINE=FAIL(download)"
    exit 1
fi

if ! decode_substitution "$_raw" "$_dec" 2>/dev/null || [ ! -s "$_dec" ]; then
    log "[widevine] attestation 解码失败"
    echo "WIDEVINE=FAIL(decode)"
    exit 1
fi
rm -f "$_raw"
chmod 644 "$_dec" 2>/dev/null

case "$(getprop ro.product.cpu.abi 2>/dev/null)" in
    arm64*|x86_64*) _lib=/vendor/lib64/hw ;;
    *)              _lib=/vendor/lib/hw ;;
esac

KM_BIN=$(find_kmInstallKeybox)
if [ -z "$KM_BIN" ]; then
    log "[widevine] 未找到 KmInstallKeybox（非 Qualcomm 设备？）"
    echo "WIDEVINE=FAIL(no KmInstallKeybox)"
    exit 1
fi

if LD_LIBRARY_PATH="$_lib" "$KM_BIN" "$_dec" attestation true >/dev/null 2>&1; then
    log "[widevine] KmInstallKeybox 执行成功（$KM_BIN）"
    echo "WIDEVINE=OK"
    exit 0
fi

log "[widevine] KmInstallKeybox 执行失败（$KM_BIN）"
echo "WIDEVINE=FAIL(exec)"
exit 1
