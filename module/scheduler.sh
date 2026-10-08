#!/system/bin/sh
# Opt-in periodic task scheduler.
#
# Ported from dpejoh/specter (src/lib/scheduler.sh). The default boot path
# already keeps things fresh through service.sh's hourly loop, the aswatcher
# daemon and the yypm backend; this scheduler exists for users who want explicit
# per-task intervals with independent switches. It is OFF by default so it never
# duplicates the work those owners already do.
#
# Master toggle (yypm config): scheduler_enable on|off (default off)
# Per-task toggles / intervals (seconds, floor 60):
#   sched_keybox_info   (default on)   sched_keybox_info_interval   (default 21600)
#   sched_auto_target   (default on)   sched_auto_target_interval   (default 300)
#   sched_autopif       (default off)  sched_autopif_interval       (default 86400)
#
# Started from service.sh when scheduler_enable=on. It never fetches the keybox
# itself (the yypm backend owns that) — only the indicator, target list and
# fingerprint tasks below.

MODDIR="${MODDIR:-${0%/*}}"
# shellcheck source=/dev/null
[ -f "$MODDIR/common.sh" ] && . "$MODDIR/common.sh"

[ "$(cfg_get scheduler_enable off)" = "on" ] || exit 0

STATE_DIR="$DATA_DIR/scheduler"
mkdir -p "$STATE_DIR" 2>/dev/null

log "[sched] 调度器启动"

_interval_of() { # $1 key  $2 default
    _iv=$(cfg_get "$1" "$2")
    case "$_iv" in ''|*[!0-9]*) _iv="$2" ;; esac
    [ "$_iv" -lt 60 ] 2>/dev/null && _iv=60
    echo "$_iv"
}

while true; do
    [ -d "$MODDIR" ] || exit 0
    _now=$(date +%s 2>/dev/null)
    case "$_now" in ''|*[!0-9]*) _now=0 ;; esac

    # name|script|toggle|default_interval
    for _task in \
        "keybox_info|status_fetch.sh|sched_keybox_info|21600" \
        "auto_target|build_target_txt.sh|sched_auto_target|300" \
        "autopif|pif_native_fetch.sh|sched_autopif|86400"; do
        _name="${_task%%|*}"
        _rest="${_task#*|}"
        _script="${_rest%%|*}"
        _rest="${_rest#*|}"
        _toggle="${_rest%%|*}"
        _default="${_rest#*|}"

        [ "$(cfg_get "$_toggle" on)" = "on" ] || continue
        # autopif is meaningless on a PIF-less (Lite) build.
        [ "$_name" = "autopif" ] && [ "${ENGINE:-none}" = "none" ] && continue

        _last=$(cat "$STATE_DIR/${_name}_last" 2>/dev/null)
        case "$_last" in ''|*[!0-9]*) _last=0 ;; esac
        _int=$(_interval_of "sched_${_name}_interval" "$_default")

        if [ "$_now" -ge "$((_last + _int))" ] && [ -x "$MODDIR/$_script" ]; then
            log "[sched] 运行 $_name"
            MODPATH="$MODDIR" AS_FAST=1 sh "$MODDIR/$_script" >>"$DATA_DIR/scheduler_${_name}.log" 2>&1
            printf '%s' "$_now" > "$STATE_DIR/${_name}_last"
        fi
    done

    sleep 57
done
