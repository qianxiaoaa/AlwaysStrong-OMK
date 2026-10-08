#!/system/bin/sh
# Zygisk Next module configuration.
#
# Ported from dpejoh/specter (src/features/zygisk_next.sh). Zygisk Next reads a
# numeric enforcement level from /data/adb/zygisksu/denylist_enforce; level 2 is
# the "enforce" mode Play Integrity setups rely on. This only writes the level,
# it never touches the user's DenyList contents.
#
# OFF BY DEFAULT (Zygisk Next manages this itself in most setups); enable from
# the WebUI 环境对抗 page if a detector still sees Zygisk.
#
# Toggle (yypm config): zygisk_next_cfg on|off (default off)

MODDIR="${MODDIR:-${0%/*}}"
# shellcheck source=/dev/null
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

[ "$(cfg_get zygisk_next_cfg off)" = "on" ] || { echo "ZYGISK_NEXT=off"; exit 0; }

ZN_DATA_DIR=/data/adb/zygisksu
ZN_MODULE_DIR=/data/adb/modules/zygisksu
[ ! -d "$ZN_MODULE_DIR" ] && ZN_MODULE_DIR=/data/adb/modules_update/zygisksu

if [ ! -f "$ZN_MODULE_DIR/module.prop" ]; then
    log "[zygisk-next] 未检测到 Zygisk Next 模块"
    echo "ZYGISK_NEXT=FAIL(no module)"
    exit 1
fi

ZN_NAME=$(grep "^name=" "$ZN_MODULE_DIR/module.prop" 2>/dev/null | cut -d= -f2-)
log "[zygisk-next] 检测到：${ZN_NAME:-Zygisk Next}"

# Guard against a different module squatting on the zygisksu id (specter
# validates the name before writing the enforcement level).
case "$ZN_NAME" in
    *Zygisk*Next*) ;;
    *) log "[zygisk-next] 模块名不匹配（$ZN_NAME），放弃配置"; echo "ZYGISK_NEXT=FAIL(name)"; exit 1 ;;
esac

mkdir -p "$ZN_DATA_DIR" 2>/dev/null
if printf '2' > "$ZN_DATA_DIR/denylist_enforce" 2>/dev/null; then
    log "[zygisk-next] denylist_enforce -> 2"
    echo "ZYGISK_NEXT=OK"
    exit 0
fi

log "[zygisk-next] 写入 denylist_enforce 失败"
echo "ZYGISK_NEXT=FAIL(write)"
exit 1
