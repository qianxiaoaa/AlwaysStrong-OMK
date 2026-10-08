#!/system/bin/sh
# ADB / developer-options disabler.
#
# Ported from dpejoh/specter (src/features/adb_disabler.sh). Turns off developer
# options, USB debugging and OEM-unlock support so a detector (or a banking app)
# that treats a debuggable build as a tamper signal sees a clean, release-like
# device. This is a query-level property/global spoof: it does not remove the
# user's ADB binaries, it only flips the visible toggles.
#
# OFF BY DEFAULT: while enabled the user's own ADB workflow stops working
# (that is the point), so it is opt-in from the WebUI 环境对抗 page.
#
# Toggles live in the yypm config (WebUI 环境对抗页「ADB 调试关闭」):
#   adb_disabler             on|off   (default off)  master switch
#   adb_disabler_dev_options on|off   (default on)   development_settings_enabled
#   adb_disabler_usb_debug   on|off   (default on)   ro.debuggable / adb_enabled / ...
#   adb_disabler_oem_unlock  on|off   (default on)   ro.oem_unlock_supported
#
# Called from service.sh at boot when enabled, and from
# `webui.sh adb-disabler on|off` (which also runs it immediately).

MODDIR="${MODDIR:-${0%/*}}"
# shellcheck source=/dev/null
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

# Hard stop if the master switch is off — the boot caller already checks, but a
# manual `sh adb_disabler.sh` from a shell must honour it too.
[ "$(cfg_get adb_disabler off)" = "on" ] || { echo "ADB_DISABLER=off"; exit 0; }

RP=$(get_resetprop 2>/dev/null) || RP=resetprop
rprop() { "$RP" -n "$1" "$2" 2>/dev/null; }

_did=0

# 1. Developer options visible in Settings.
if [ "$(cfg_get adb_disabler_dev_options on)" = "on" ]; then
    settings put global development_settings_enabled 0 2>/dev/null
    rprop persist.sys.development_settings_enabled 0
    _did=$((_did + 1))
fi

# 2. USB debugging + adbd. The prop set mirrors specter exactly so a detector
# reading any of these (ro.debuggable, adb_enabled, init.svc.adbd) sees it off.
if [ "$(cfg_get adb_disabler_usb_debug on)" = "on" ]; then
    rprop ro.debuggable 0
    rprop ro.force.debuggable 0
    rprop ro.adb.secure 1
    rprop persist.sys.usb.config mtp
    rprop sys.usb.config mtp
    rprop sys.oem_unlock_allowed 0
    rprop service.adb.root 0
    rprop init.svc.adbd stopped
    rprop init.svc_debug_pid.adbd ""
    settings put global adb_enabled 0 2>/dev/null
    _did=$((_did + 1))
fi

# 3. OEM unlock support flag.
if [ "$(cfg_get adb_disabler_oem_unlock on)" = "on" ]; then
    rprop ro.oem_unlock_supported 0
    _did=$((_did + 1))
fi

log "[adb] ADB disabler applied (${_did} group(s))"
echo "ADB_DISABLED=${_did}"
exit 0
