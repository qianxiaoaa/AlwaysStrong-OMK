#!/system/bin/sh
# First-boot original-file backup.
#
# Ported from dpejoh/specter (src/features/first_boot_setup.sh, backup half).
# Before AlwaysStrong starts rewriting the keystore-manager config, snapshot the
# current files into /data/adb/tricky_store/backups so the user can restore the
# pre-module state by hand. Runs once on the first boot after install (marker
# file); pass `manual` to force a fresh snapshot from the WebUI.
#
# Backed up (when present):
#   keybox.xml, target.txt, security_patch.txt, config.ini, config.toml,
#   and the ROM's own patch level recorded by post-fs-data (.rom_security_patch).
#
# Toggle (yypm config): first_boot_backup on|off (default on)

MODDIR="${MODDIR:-${0%/*}}"
# shellcheck source=/dev/null
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

CONFIG_DIR=/data/adb/tricky_store
BACKUP_DIR="$CONFIG_DIR/backups"
MARKER="$CONFIG_DIR/.first_boot_backup_done"

[ "$(cfg_get first_boot_backup on)" = "on" ] || { echo "FIRST_BOOT_BACKUP=off"; exit 0; }

MODE="${1:-auto}"
if [ "$MODE" != "manual" ] && [ -f "$MARKER" ]; then
    echo "FIRST_BOOT_BACKUP=already"
    exit 0
fi

mkdir -p "$BACKUP_DIR" 2>/dev/null || { echo "FIRST_BOOT_BACKUP=FAIL(mkdir)"; exit 1; }

_ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null)
[ -n "$_ts" ] || _ts=first
_n=0

_bak() { # $1 = source file
    [ -f "$1" ] || return 0
    _bn=$(basename "$1")
    # Keep the oldest snapshot: a re-run must not overwrite the pristine backup.
    if [ ! -f "$BACKUP_DIR/$_bn.bak" ]; then
        cp "$1" "$BACKUP_DIR/$_bn.bak" 2>/dev/null && _n=$((_n + 1)) && \
            log "[first-boot] 备份 $_bn -> backups/$_bn.bak"
    fi
    # Also keep a timestamped copy so successive states are auditable.
    cp "$1" "$BACKUP_DIR/$_bn.$_ts.bak" 2>/dev/null || true
}

_bak "$CONFIG_DIR/keybox.xml"
_bak "$CONFIG_DIR/target.txt"
_bak "$CONFIG_DIR/security_patch.txt"
_bak "$CONFIG_DIR/config.ini"
_bak "$CONFIG_DIR/config.toml"
_bak "$CONFIG_DIR/.rom_security_patch"

touch "$MARKER" 2>/dev/null
log "[first-boot] 备份完成：$_n 个文件 -> $BACKUP_DIR"
echo "FIRST_BOOT_BACKUP=OK"
echo "FIRST_BOOT_BACKUP_DIR=$BACKUP_DIR"
echo "FIRST_BOOT_BACKUP_COUNT=$_n"
exit 0
