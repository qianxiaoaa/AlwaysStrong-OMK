#!/system/bin/sh
# GMS / DroidGuard kill + Play Store maintenance.
#
# Ported from dpejoh/specter (src/features/gms.sh + kill_play_store.sh).
# Force-stopping DroidGuard and GMS makes Play Integrity request a fresh
# attestation on the next app launch, which is how a newly installed keybox or
# fingerprint takes effect without waiting for GMS's own cache to expire.
# Optionally clearing Play Store data forces it to re-read the device state too
# (default OFF: clearing data also wipes the local Play session view).
#
# The auto path is OFF by default because force-stopping GMS every boot churns
# background services; the WebUI exposes a manual button and the toggles below.
#
# Toggles (yypm config):
#   gms_force_stop on|off  (default off)  kill DroidGuard + GMS + Play services
#   gms_clear_data on|off  (default off)  pm clear com.android.vending
#
# Manual: `webui.sh gms-kill force|clear|all` (always runs, ignores auto switches).

MODDIR="${MODDIR:-${0%/*}}"
# shellcheck source=/dev/null
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

# Force-stop targets: specter's GMS_KILL_LIST (the GMS/attestation family plus
# Chrome and the Google app, whose cached attestation results influence the
# next Play Integrity call). Play Store is included so its view is refreshed too.
GMS_LIST="com.android.vending com.google.android.gsf com.google.android.gms \
com.google.android.contactkeys com.google.android.ims com.google.android.safetycore \
com.google.android.apps.walletnfcrel com.google.android.apps.nbu.paisa.user \
com.google.android.gms.persistent com.google.android.gms.unstable com.google.android.rkpdapp \
com.android.chrome com.google.android.googlequicksearchbox"
GMS_KILL_PROCS="droidguard|com.google.android.gms"

MODE="${1:-auto}"
_fs=off
_cd=off
case "$MODE" in
    manual-force) _fs=on ;;
    manual-clear) _cd=on ;;
    manual-all)   _fs=on; _cd=on ;;
    *)            _fs=$(cfg_get gms_force_stop off); _cd=$(cfg_get gms_clear_data off) ;;
esac

[ "$_fs$_cd" = "offoff" ] && { echo "GMS_KILLED=0"; exit 0; }

PM=$(pm_bin 2>/dev/null) || PM=""
_pkgs=$([ -n "$PM" ] && "$PM" list packages 2>/dev/null)
_count=0

if [ "$_fs" = "on" ]; then
    # DroidGuard runs as its own process; kill it first so the next GMS call
    # re-spawns it with a fresh attestation context.
    for _pid in $(pgrep -f "$GMS_KILL_PROCS" 2>/dev/null); do
        kill -9 "$_pid" 2>/dev/null && _count=$((_count + 1))
    done
    for _pkg in $GMS_LIST; do
        echo "$_pkgs" | grep -Fq "package:$_pkg" || continue
        am force-stop "$_pkg" >/dev/null 2>&1 && _count=$((_count + 1))
    done
    log "[gms] force-stopped ${_count} GMS/DroidGuard target(s)"
fi

if [ "$_cd" = "on" ] && echo "$_pkgs" | grep -q "package:com.android.vending"; then
    if [ -n "$PM" ] && "$PM" clear com.android.vending >/dev/null 2>&1; then
        log "[gms] Play Store data cleared"
    else
        log "[gms] Play Store clear failed"
    fi
fi

echo "GMS_KILLED=$_count"
echo "GMS_CLEARED=$_cd"
exit 0
