#!/system/bin/sh
# MemoryOpt Plus 守护进程

MODDIR=${0%/*}
CONFIG="$MODDIR/swap.ini"
DISABLE="$MODDIR/disable"
PIDFILE="$MODDIR/daemon.pid"
LOG="$MODDIR/log.txt"
REBUILD_LOCK="$MODDIR/.rebuild_lock"
PIDLOCK="$PIDFILE.lock"

. "$MODDIR/common.sh"
. "$MODDIR/memory.sh"

trap 'rm -f "$PIDFILE" "$PIDLOCK" "$REBUILD_LOCK"' EXIT
_FORCE_RELOAD=0
trap '_FORCE_RELOAD=1' HUP

# ── 单实例（flock 优先，PID 文件回退）─────
_HAS_FLOCK=false
command -v flock >/dev/null 2>&1 && _HAS_FLOCK=true

if [ "$_HAS_FLOCK" = "true" ]; then
    exec 9>"$PIDLOCK"
    if ! flock -n 9 2>/dev/null; then
        log_info "检测到另一个实例正在运行，退出"
        exit 0
    fi
    echo "$$" >&9
else
    if [ -f "$PIDFILE" ]; then
        oldpid=$(cat "$PIDFILE" 2>/dev/null)
        if [ -n "$oldpid" ] && [ "$oldpid" != "_pid" ]; then
            kill -0 "$oldpid" 2>/dev/null && {
                log_info "检测到另一个实例正在运行 (PID $oldpid)，退出"
                exit 0
            }
        fi
    fi
    echo "$$" > "$PIDFILE"
fi

_log_init; _log_rotate
log_info "守护进程已启动 (PID $$)"

# ── 工具 ──────────────────────────────────
get_mtime() {
    local mt; mt=$(stat -c %Y "$1" 2>/dev/null)
    [ -z "$mt" ] && mt=$(date -r "$1" +%s 2>/dev/null)
    [ -z "$mt" ] && mt=$(ls -l "$1" 2>/dev/null | awk '{print $6$7$8$5}')
    echo "$mt"
}

wait_boot() {
    local waited=0
    log_info "等待系统启动..."
    until [ "$(getprop sys.boot_completed)" = "1" ]; do
        sleep 5; waited=$((waited + 5))
        [ "$waited" -ge 600 ] && { log_warn "等待超时 (${waited}s)"; break; }
    done
    waited=0
    while [ ! -d "/sdcard/Android" ] && [ ! -d "/data/media/0/Android" ]; do
        sleep 1; waited=$((waited + 1))
        [ "$waited" -ge 120 ] && { log_warn "/sdcard/Android 未就绪"; break; }
    done
    sleep 5
    log_info "系统已就绪"
}

wait_vm_ready() {
    log_info "等待 VM 子系统..."
    until [ -f /proc/sys/vm/swappiness ]; do sleep 2; done
    sleep 5
    log_info "VM 子系统已就绪"
}

# ── 配置缓存 ──────────────────────────────
_lock_swappiness=""; _lock_watermark=""; _lock_dbr=""; _lock_dr=""; _lock_vfs_cache=""
_lock_extra_free=""; _lock_compaction=""; _lock_overcommit=""; _lock_dirty_expire=""
_lock_dirty_writeback=""; _lock_page_cluster=""; _lock_page_cluster_mode=""
_lock_enable=""; _lock_mtime=0; _lock_zram_priority=""
_lock_stat_interval=""; _lock_oom_kill_alloc=""; _lock_oom_dump=""
_lock_compact_unevict=""; _lock_panic_on_oom=""
_lock_lmk_minfree=""
_cached_swap_total=0; _cached_efk=""
_reloads=0; _changes=0
_lock_mglru=""

_NEED_ZRAM_REBUILD=0

_resolve_page_cluster() {
    if [ "$1" = "auto" ]; then
        local alg="" dev=""
        [ -f "$MODDIR/zram_dev" ] && dev=$(cat "$MODDIR/zram_dev" 2>/dev/null)
        [ -f "$MODDIR/.current_alg" ] && alg=$(cat "$MODDIR/.current_alg" 2>/dev/null)
        [ -z "$alg" ] && { [ -z "$dev" ] && dev="zram0"
            [ -f "/sys/block/$dev/comp_algorithm" ] && \
                alg=$(cat "/sys/block/$dev/comp_algorithm" 2>/dev/null | \
                    sed -n 's/.*\[\([a-z0-9]*\)\].*/\1/p' | head -n1); }
        case "$alg" in zstd*) echo 0 ;; *) echo 1 ;; esac
    else echo "$1"; fi
}

reload_config_cache() {
    local mt; mt=$(get_mtime "$CONFIG")
    if [ "$mt" != "$_lock_mtime" ] || [ "${_FORCE_RELOAD:-0}" = "1" ]; then
        _FORCE_RELOAD=0; _reloads=$((_reloads + 1))
        # 预读配置以填充缓存
        get_config swappiness >/dev/null

        local _o_en="$_lock_enable" _o_sw="$_lock_swappiness" _o_wm="$_lock_watermark"
        local _o_dbr="$_lock_dbr" _o_dr="$_lock_dr" _o_vfs="$_lock_vfs_cache"
        local _o_efk="$_lock_extra_free" _o_comp="$_lock_compaction" _o_oc="$_lock_overcommit"
        local _o_de="$_lock_dirty_expire" _o_dw="$_lock_dirty_writeback"
        local _o_pc="$_lock_page_cluster_mode" _o_lmk="$_lock_lmk_minfree"
        local _o_zp="$_lock_zram_priority"

        _lock_swappiness=$(_cfg_num swappiness 100)
        _lock_watermark=$(_cfg_num watermark_scale_factor 50)
        _lock_dbr=$(_cfg_num dirty_background_ratio 5)
        _lock_dr=$(_cfg_num dirty_ratio 10)
        _lock_vfs_cache=$(_cfg_num vfs_cache_pressure 125)
        _lock_extra_free=$(_cfg_str extra_free_kbytes "auto")
        _lock_compaction=$(_cfg_num compaction_proactiveness 20)
        _lock_overcommit=$(_cfg_num overcommit_memory 1)
        _lock_dirty_expire=$(_cfg_num dirty_expire_centisecs 1000)
        _lock_dirty_writeback=$(_cfg_num dirty_writeback_centisecs 100)
        _lock_page_cluster_mode=$(_cfg_str page_cluster "auto")
        _lock_page_cluster=$(_resolve_page_cluster "$_lock_page_cluster_mode")
        _lock_lmk_minfree=$(calc_lmk_minfree)
        _lock_enable=$(_cfg_bool enable)
        _lock_zram_priority=$(_cfg_num zram_priority 100)
        _lock_stat_interval=$(_cfg_num stat_interval 3)
        _lock_oom_kill_alloc=$(_cfg_num oom_kill_allocating_task 0)
        _lock_oom_dump=$(_cfg_num oom_dump_tasks 0)
        _lock_compact_unevict=$(_cfg_num compact_unevictable_allowed 1)
        _lock_panic_on_oom=$(_cfg_num panic_on_oom 0)
        _lock_mglru=$(_cfg_str enable_mglru "true")
        _lock_mtime=$mt

        [ -n "$_o_zp" ] && [ "$_o_zp" != "$_lock_zram_priority" ] && \
            { _NEED_ZRAM_REBUILD=1; log_info "zram_priority 变更 (${_o_zp} → ${_lock_zram_priority})"; }

        if [ "$_o_sw" != "" ]; then
            local _c=0
            [ "$_o_en" != "$_lock_enable" ] && { log_change "enable" "$_o_en" "$_lock_enable"; _c=1; }
            [ "$_o_sw" != "$_lock_swappiness" ] && { log_change "swappiness" "$_o_sw" "$_lock_swappiness"; _c=1; }
            [ "$_o_wm" != "$_lock_watermark" ] && { log_change "watermark" "$_o_wm" "$_lock_watermark"; _c=1; }
            [ "$_o_dbr" != "$_lock_dbr" ] && { log_change "dirty_bg_ratio" "$_o_dbr" "$_lock_dbr"; _c=1; }
            [ "$_o_dr" != "$_lock_dr" ] && { log_change "dirty_ratio" "$_o_dr" "$_lock_dr"; _c=1; }
            [ "$_o_vfs" != "$_lock_vfs_cache" ] && { log_change "vfs_cache" "$_o_vfs" "$_lock_vfs_cache"; _c=1; }
            [ "$_o_efk" != "$_lock_extra_free" ] && { log_change "extra_free" "$_o_efk" "$_lock_extra_free"; _c=1; }
            [ "$_o_comp" != "$_lock_compaction" ] && { log_change "compaction" "$_o_comp" "$_lock_compaction"; _c=1; }
            [ "$_o_oc" != "$_lock_overcommit" ] && { log_change "overcommit" "$_o_oc" "$_lock_overcommit"; _c=1; }
            [ "$_o_de" != "$_lock_dirty_expire" ] && { log_change "dirty_expire" "$_o_de" "$_lock_dirty_expire"; _c=1; }
            [ "$_o_dw" != "$_lock_dirty_writeback" ] && { log_change "dirty_writeback" "$_o_dw" "$_lock_dirty_writeback"; _c=1; }
            [ "$_o_pc" != "$_lock_page_cluster_mode" ] && { log_change "page_cluster" "$_o_pc" "$_lock_page_cluster_mode"; _c=1; }
            [ "$_o_lmk" != "$_lock_lmk_minfree" ] && { _c=1; log_info "  lmk_minfree          已变更"; }
            if [ "$_c" = "1" ]; then
                _changes=$((_changes + 1))
                log_info "配置已更新 #${_reloads} (第 ${_changes} 次变更)"
            else log_debug "配置文件已更新（无实际变更）"; fi
        else log_info "配置缓存已初始化"; fi
    fi
}

# ── 主入口 ────────────────────────────────
main() {
    if [ "$(get_config_safe early_start)" = "true" ]; then
        wait_vm_ready
    else
        wait_boot
    fi
    [ -f "$DISABLE" ] && { log_info "disable 文件存在，退出"; exit 0; }
    [ ! -d "$MODDIR" ] && exit 0

    log_info "使用 shell 引擎"
    run_optimization
    lock_params
}

main
