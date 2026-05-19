#!/system/bin/sh
# MemoryOpt Plus 核心优化脚本

: ${MODDIR:=${0%/*}}
: ${CONFIG:="$MODDIR/swap.ini"}
: ${LOG:="$MODDIR/log.txt"}

[ -n "$_MEMORY_SH_LOADED" ] && return 0
_MEMORY_SH_LOADED=1

. "$MODDIR/common.sh"

_SELF=$(basename "$0")
if [ "$_SELF" = "memory.sh" ]; then _log_init; _log_rotate; fi

_extract_algorithm() {
    sed -n 's/.*\[\([a-z0-9]*\)\].*/\1/p' 2>/dev/null | head -n1
}

_PERSIST_BACKUP="/data/local/tmp/memoryopt_backup"

_persist_backup_valid() {
    [ -f "$_PERSIST_BACKUP/.zram_done" ] || return 1
    [ -f "$_PERSIST_BACKUP/algorithm" ] || return 1
    [ -f "$_PERSIST_BACKUP/disksize" ] || return 1
    [ -f "$_PERSIST_BACKUP/max_comp_streams" ] || return 1
    return 0
}

backup_native_zram_once() {
    local backup_dir="$MODDIR/zram_backup"
    local stamp="$backup_dir/.done"
    if _persist_backup_valid; then
        mkdir -p "$backup_dir"
        cp -f "$_PERSIST_BACKUP"/* "$backup_dir/" 2>/dev/null
        touch "$stamp"
        log_info "已从持久存储恢复原生 ZRAM 备份"
        return 0
    fi
    [ -f "$stamp" ] && return 0
    mkdir -p "$backup_dir"
    [ -f /sys/block/zram0/comp_algorithm ] && \
        cat /sys/block/zram0/comp_algorithm 2>/dev/null | _extract_algorithm > "$backup_dir/algorithm"
    [ -f /sys/block/zram0/disksize ] && \
        cat /sys/block/zram0/disksize 2>/dev/null > "$backup_dir/disksize"
    [ -f /sys/block/zram0/max_comp_streams ] && \
        cat /sys/block/zram0/max_comp_streams 2>/dev/null > "$backup_dir/max_comp_streams"
    touch "$stamp"
    sync
    mkdir -p "$_PERSIST_BACKUP"
    cp -f "$backup_dir"/* "$_PERSIST_BACKUP/" 2>/dev/null
    touch "$_PERSIST_BACKUP/.zram_done"
    log_info "已备份原生 zram0 配置（含持久副本）"
}

init_zram() {
    if [ ! -e /dev/block/zram0 ] && [ ! -d /sys/class/zram-control ]; then
        log_warn "内核不支持 ZRAM"
        return 1
    fi
    log_info "检测到 ZRAM 支持"
    if [ -b "/dev/block/zram0" ]; then
        grep -q "/dev/block/zram0" /proc/swaps 2>/dev/null && \
            log_info "检测到 zram0 已启用，重新配置"
        echo "zram0"
        return 0
    fi
    if [ -d /sys/class/zram-control ]; then
        local id; id=$(cat /sys/class/zram-control/hot_add 2>/dev/null | tr -d '\n')
        case "$id" in
            ''|*[!0-9]*) log_warn "hot_add 无效 id: $id" ;;
            *)
                local dev="/dev/block/zram${id}" w=0
                while [ ! -b "$dev" ] && [ "$w" -lt 30 ]; do sleep 0.1; w=$((w+1)); done
                if [ -b "$dev" ]; then log_info "hot_add 创建 zram${id}"; echo "zram${id}"; return 0; fi
                log_warn "hot_add 设备未出现"
                ;;
        esac
    fi
    for i in 1 2 3 4 5; do
        [ -b "/dev/block/zram$i" ] && ! grep -q "/dev/block/zram$i" /proc/swaps 2>/dev/null && \
            { echo "zram$i"; return 0; }
    done
    return 1
}

get_algs() {
    [ -f "/sys/block/$1/comp_algorithm" ] || return
    cat "/sys/block/$1/comp_algorithm" 2>/dev/null | tr -d '[]' | tr -s ' '
}

select_alg() {
    local pref="$1" sup="$2"
    [ -z "$sup" ] && { echo "lz4"; return; }
    echo "$sup" | grep -qw "$pref" && { echo "$pref"; return; }
    for a in lz4 lz4hc zstd lzo-rle lzo deflate; do
        echo "$sup" | grep -qw "$a" && { log_info "算法降级: ${pref} → ${a}"; echo "$a"; return; }
    done
    local first; first=$(echo "$sup" | awk '{print $1}')
    if [ -n "$first" ]; then log_warn "所有优选算法均不匹配，使用: $first"; echo "$first"
    else log_warn "无法获取支持算法列表，回退 lz4"; echo "lz4"; fi
}

parse_zram_size() {
    local raw="$1" mem_mb="$2"
    local val; val=$(echo "$raw" | sed 's/ //g')
    if echo "$val" | grep -qiE '^[0-9]+(\.[0-9]+)?[gGmMkK]$'; then
        echo "$val" | tr '[:lower:]' '[:upper:]'
    elif echo "$val" | grep -qE '^[0-9]+(\.[0-9]+)?$'; then
        local target_mb
        target_mb=$(awk -v mb="$mem_mb" -v fac="$val" 'BEGIN{printf "%d", mb*fac+0.5}' 2>/dev/null)
        if [ -z "$target_mb" ]; then
            local int_part="${val%%.*}" dec_part="${val#*.}"
            [ "$int_part" = "$val" ] && dec_part=""
            [ -z "$int_part" ] && int_part=0
            case "$dec_part" in ''|*[!0-9]*) dec_part=0 ;; esac
            if [ -n "$dec_part" ] && [ "$dec_part" != "0" ]; then
                local dd=${#dec_part} div=1
                case "$dd" in 1) div=10 ;; 2) div=100 ;; 3) div=1000 ;; *) div=10000 ;; esac
                target_mb=$(( (mem_mb * int_part) + (mem_mb * dec_part / div) ))
            else
                target_mb=$((mem_mb * int_part))
            fi
        fi
        local min_mb=$((mem_mb / 8)); [ "$min_mb" -lt 128 ] && min_mb=128
        [ "$target_mb" -lt "$min_mb" ] && { log_warn "计算值 ${target_mb}MB 过低，提升至 ${min_mb}MB"; target_mb=$min_mb; }
        [ "$target_mb" -gt 16384 ] && target_mb=16384
        echo "${target_mb}M"
    else
        log_warn "zram_size 格式未知: $raw，回退 2.0"
        echo "$((mem_mb * 2))M"
    fi
}

_wait_zram_reset() {
    local zsys="$1" waited=0
    while [ "$waited" -lt 30 ]; do
        local sz; sz=$(cat "$zsys/disksize" 2>/dev/null | tr -cd '0-9')
        if [ -z "$sz" ] || [ "$sz" = "0" ]; then return 0; fi
        sleep 0.05; waited=$((waited + 1))
    done
    return 1
}

config_zram() {
    local algo="$1" size_raw="$2" dev="$3" streams="$4" priority="$5"
    local zdev="/dev/block/$dev" zsys="/sys/block/$dev"
    [ -z "$priority" ] && priority=100
    [ ! -b "$zdev" ] && { log_warn "$zdev 不存在或非块设备"; return 1; }

    local backing_dev=""
    [ -f "$zsys/backing_dev" ] && backing_dev=$(cat "$zsys/backing_dev" 2>/dev/null)
    log_info "回写块地址: ${backing_dev:-none}"

    log_info "重置 ZRAM ($dev)"
    [ -f "$MODDIR/zram_dev" ] && {
        local _od; _od=$(cat "$MODDIR/zram_dev" 2>/dev/null)
        [ -n "$_od" ] && [ "$_od" != "$dev" ] && {
            swapoff "/dev/block/$_od" 2>/dev/null
            echo 1 > "/sys/block/$_od/reset" 2>/dev/null
        }
    }
    [ "$dev" = "zram0" ] && grep -q zram0 /proc/swaps 2>/dev/null && swapoff /dev/block/zram0 2>/dev/null
    swapoff "$zdev" 2>/dev/null
    echo 1 > "$zsys/reset" 2>/dev/null
    if ! _wait_zram_reset "$zsys"; then
        log_warn "ZRAM reset 超时 ($dev)，继续尝试配置"
    fi

    if [ -n "$backing_dev" ] && [ "$backing_dev" != "none" ]; then
        log_info "恢复回写块地址"
        echo "$backing_dev" > "$zsys/backing_dev" 2>/dev/null || log_warn "恢复回写块地址失败"
    fi
    [ -f "$zsys/writeback_limit_enable" ] && echo 0 > "$zsys/writeback_limit_enable" 2>/dev/null

    [ -f "$zsys/max_comp_streams" ] && {
        [ "$streams" = "auto" ] && streams=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
        set_value "$streams" "$zsys/max_comp_streams" quiet
    }

    log_info "设置压缩算法: $algo"
    [ -f "$zsys/comp_algorithm" ] && set_value "$algo" "$zsys/comp_algorithm" quiet

    local mem_mb; mem_mb=$(get_mem_mb)
    local disk; disk=$(parse_zram_size "$size_raw" "$mem_mb")
    log_info "设置 ZRAM 大小"
    set_value "$disk" "$zsys/disksize" quiet || { echo 1 > "$zsys/reset" 2>/dev/null; return 1; }

    if [ -z "$SWAPON_HAS_P" ]; then
        SWAPON_HAS_P=false
        if swapon --help 2>&1 | grep -q '\-p'; then SWAPON_HAS_P=true
        elif command -v busybox >/dev/null 2>&1 && busybox swapon --help 2>&1 | grep -q '\-p'; then SWAPON_HAS_P=true
        fi
    fi

    log_info "格式化 ZRAM (mkswap)"
    if ! mkswap "$zdev" >/dev/null 2>&1; then
        log_warn "mkswap 失败"
        echo 1 > "$zsys/reset" 2>/dev/null
        return 1
    fi

    log_info "启用 ZRAM (swapon)"
    local swap_ok=0
    if [ "$SWAPON_HAS_P" = true ]; then
        swapon "$zdev" -p "$priority" >/dev/null 2>&1 && swap_ok=1
    else
        swapon "$zdev" >/dev/null 2>&1 && swap_ok=1
    fi

    if [ "$swap_ok" = "1" ]; then
        _LOG_COUNT_OK=$((_LOG_COUNT_OK + 1))
        echo "$dev" > "$MODDIR/zram_dev"
        local pri=""
        [ "$SWAPON_HAS_P" = true ] && pri="优先级 ${priority}" || pri="无优先级"
        log_info "ZRAM 已启用: ${algo} · ${disk} · ${dev} · ${pri}"
        return 0
    else
        log_warn "swapon 失败"
        echo 1 > "$zsys/reset" 2>/dev/null
        return 1
    fi
}

disable_vendor_reclaim() {
    [ "$(get_config_safe disable_vendor_reclaim)" != "true" ] && return 0
    log_section "厂商回收禁用"
    log_optional 0 "/sys/module/process_reclaim/parameters/enable_process_reclaim"
    log_optional 0 "/sys/kernel/mi_reclaim/enable"
    log_optional 0 "/sys/kernel/mi_reclaim/greclaim_enable"
    log_optional 0 "/sys/kernel/low_free/low_free_enable"
    log_optional 0 "/sys/module/memplus_core/parameters/memory_plus_enabled"
    log_optional 0 "/proc/sys/vm/memory_plus"
    log_optional 0 "/sys/kernel/mi_thermald/mi_thermald_enable"
    log_optional 0 "/sys/module/perfmgr/parameters/perfmgr_enable"
    log_optional 0 "/sys/module/opchain/parameters/opchain_enable"
}

bind_lmkd() {
    [ "$(get_config_safe bind_lmkd)" != "true" ] && return 0
    command -v taskset >/dev/null 2>&1 || { log_warn "taskset 不可用"; return 0; }
    local raw_mask mask=0x0f
    raw_mask=$(get_config bind_lmkd_mask)
    if [ -n "$raw_mask" ]; then
        case "$raw_mask" in
            0[xX][0-9a-fA-F]*) mask="$raw_mask" ;;
            [0-9]*) mask=$(printf "0x%x" "$raw_mask" 2>/dev/null || echo "0x0f") ;;
            *) log_warn "bind_lmkd_mask 无效，使用默认 0x0f" ;;
        esac
    fi
    local count=0
    for pid in $(pgrep lmkd 2>/dev/null); do
        taskset -p "$mask" "$pid" 2>/dev/null && count=$((count + 1))
    done
    [ "$count" -gt 0 ] && log_info "lmkd 绑核完成: ${count} 个进程, mask=${mask}"
}

_SWAPPINESS_MAX_CACHED=""
swappiness_max() {
    if [ -n "$_SWAPPINESS_MAX_CACHED" ]; then echo "$_SWAPPINESS_MAX_CACHED"; return; fi
    local cur max
    cur=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    echo 32767 > /proc/sys/vm/swappiness 2>/dev/null
    max=$(cat /proc/sys/vm/swappiness 2>/dev/null)
    [ -n "$cur" ] && echo "$cur" > /proc/sys/vm/swappiness 2>/dev/null || echo 60 > /proc/sys/vm/swappiness 2>/dev/null
    _SWAPPINESS_MAX_CACHED="${max:-200}"
    echo "$_SWAPPINESS_MAX_CACHED"
}

config_vm() {
    log_section "VM 参数优化"
    local sw; sw=$(get_config_safe swappiness); [ -z "$sw" ] && sw=130
    local smax; smax=$(swappiness_max)
    [ "$sw" -gt "$smax" ] && { log_warn "swappiness ${sw} 超限，截断至 ${smax}"; sw=$smax; }
    set_value "$sw" /proc/sys/vm/swappiness

    local dbr=$(get_config_safe dirty_background_ratio); [ -z "$dbr" ] && dbr=2
    local dr=$(get_config_safe dirty_ratio); [ -z "$dr" ] && dr=5
    [ "$dbr" -ge "$dr" ] 2>/dev/null && { dbr=$((dr/2)); [ "$dbr" -lt 1 ] && dbr=1; }
    set_value "$dbr" /proc/sys/vm/dirty_background_ratio quiet
    set_value "$dr"  /proc/sys/vm/dirty_ratio quiet
    set_value "$(get_config_num dirty_expire_centisecs 1000)" /proc/sys/vm/dirty_expire_centisecs quiet
    set_value "$(get_config_num dirty_writeback_centisecs 100)" /proc/sys/vm/dirty_writeback_centisecs quiet
    set_value "$(get_config_safe vfs_cache_pressure)" /proc/sys/vm/vfs_cache_pressure quiet
    set_value 0 /proc/sys/vm/oom_kill_allocating_task quiet
    set_value 0 /proc/sys/vm/oom_dump_tasks quiet
    set_value 1 /proc/sys/vm/compact_unevictable_allowed quiet
    set_value 0 /proc/sys/vm/block_dump quiet
    set_value "$(get_config_safe overcommit_memory)" /proc/sys/vm/overcommit_memory quiet
    set_value 0 /proc/sys/vm/panic_on_oom quiet
    set_value 3 /proc/sys/vm/stat_interval quiet
    set_value "$(get_config_safe compaction_proactiveness)" /proc/sys/vm/compaction_proactiveness quiet
    [ -f /sys/kernel/mm/transparent_hugepage/khugepaged/defrag ] && set_value 0 /sys/kernel/mm/transparent_hugepage/khugepaged/defrag quiet
    [ -f /proc/sys/kernel/sched_autogroup_enabled ] && set_value 0 /proc/sys/kernel/sched_autogroup_enabled quiet

    if [ -f /sys/kernel/mm/lru_gen/enabled ]; then
        set_value 0x0003 /sys/kernel/mm/lru_gen/enabled quiet
        log_info "已启用 MGLRU"
        [ -f /sys/kernel/mm/lru_gen/min_ttl_ms ] && set_value 10000 /sys/kernel/mm/lru_gen/min_ttl_ms quiet
    fi

    local pc; pc=$(get_config_safe page_cluster)
    if [ "$pc" = "auto" ]; then
        local alg; [ -f "$MODDIR/.current_alg" ] && alg=$(cat "$MODDIR/.current_alg")
        [ -z "$alg" ] && alg=$(get_config_safe algorithm)
        [ -z "$alg" ] && alg="lz4"
        case "$alg" in zstd*) pc=0 ;; *) pc=1 ;; esac
    fi
    set_value "$pc" /proc/sys/vm/page-cluster quiet
    local wsf; wsf=$(get_config_safe watermark_scale_factor)
    [ -n "$wsf" ] && set_value "$wsf" /proc/sys/vm/watermark_scale_factor quiet
    if [ -f /proc/sys/vm/extra_free_kbytes ]; then
        local efk; efk=$(get_config_safe extra_free_kbytes)
        [ "$efk" != "auto" ] && set_value "$efk" /proc/sys/vm/extra_free_kbytes quiet
    fi
}

config_lmk() {
    log_section "LMK 策略"
    local minfree_str; minfree_str=$(calc_lmk_minfree)
    local lmk_node="/sys/module/lowmemorykiller/parameters/minfree"
    if [ -n "$minfree_str" ] && [ -f "$lmk_node" ]; then
        set_value "$minfree_str" "$lmk_node" quiet
        return 0
    fi
    local mem_mb; mem_mb=$(get_mem_mb)
    local l=$(get_config_safe lmk_low_percent);      : ${l:=6}
    local m=$(get_config_safe lmk_medium_percent);   : ${m:=4}
    local c=$(get_config_safe lmk_critical_percent); : ${c:=2}
    if [ "$_HAS_RESETPROP" = "true" ]; then
        log_info "无内核 LMK 节点，注入属性"
        resetprop ro.lmk.use_minfree_levels true
        resetprop ro.lmk.low      "$((mem_mb * l * 256 / 100))"
        resetprop ro.lmk.medium   "$((mem_mb * m * 256 / 100))"
        resetprop ro.lmk.critical "$((mem_mb * c * 256 / 100))"
        resetprop ro.lmk.upgrade_pressure 100
    fi
}

_check_mem_pressure() {
    local avail; avail=$(grep MemAvailable /proc/meminfo 2>/dev/null | tr -cd '0-9')
    local total; total=$(get_mem_kb)
    [ -z "$avail" ] || [ "$avail" -eq 0 ] && return 0
    [ "$avail" -lt $(( total / 10 )) ] && return 1
    return 0
}

run_optimization() {
    if [ "$(get_config_safe enable)" = "false" ]; then
        log_info "enable=false，跳过优化"
        return 0
    fi
    RUN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | cut -c1-4 || echo "$RANDOM")
    _log_banner
    [ -w "$LOG" ] && echo "" >> "$LOG"
    log_info "开始优化 #${RUN_ID}"
    backup_native_zram_once
    [ ! -f "$CONFIG" ] && { log_warn "缺少 $CONFIG"; return 1; }
    [ ! -r "$CONFIG" ] && { log_warn "配置文件不可读: $CONFIG"; return 1; }
    log_info "配置文件读取成功"

    local alg=$(get_config_safe algorithm);   [ -z "$alg" ] && alg="lz4"
    local size=$(get_config_safe zram_size);  [ -z "$size" ] && size="2.0"
    local ms=$(get_config_safe max_streams);  [ -z "$ms" ] && ms="auto"
    local priority; priority=$(get_config_num zram_priority 100)

    if ! _check_mem_pressure; then
        log_warn "内存压力较高，ZRAM 重建可能导致 OOM，尝试继续..."
    fi

    log_section "ZRAM 配置"
    local start; start=$(timer_start)
    local dev; dev=$(init_zram)
    if [ -n "$dev" ]; then
        local sup; sup=$(get_algs "$dev")
        local final; final=$(select_alg "$alg" "$sup")
        echo "$final" > "$MODDIR/.current_alg"
        if ! config_zram "$final" "$size" "$dev" "$ms" "$priority"; then
            log_warn "配置失败，尝试安全回退"
            local mem_mb; mem_mb=$(get_mem_mb)
            local fallback="1G"; [ "$mem_mb" -gt 4096 ] && fallback="2G"
            config_zram "lz4" "$fallback" "$dev" "auto" "$priority" && echo "lz4" > "$MODDIR/.current_alg"
        fi
    else
        log_warn "ZRAM 初始化失败"
    fi
    log_time "ZRAM 部署" "$(timer_end $start)"

    start=$(timer_start)
    disable_vendor_reclaim
    config_vm
    config_lmk
    bind_lmkd
    log_time "参数调优" "$(timer_end $start)"

    if [ -f "$MODDIR/zram_dev" ]; then
        if _check_mem_pressure; then
            sync; echo 1 > /proc/sys/vm/drop_caches 2>/dev/null
            log_info "已清除页面缓存"
        else
            log_info "跳过页面缓存清除（内存不足）"
        fi
    fi

    [ -w "$LOG" ] && echo "" >> "$LOG"
    log_section "摘要"
    log_summary
    log_info "优化完成 #${RUN_ID}"
    [ -w "$LOG" ] && echo "" >> "$LOG"
}

lock_params() {
	log_info "进入参数锁定循环 (shell 回退模式)"
	local interval; interval=$(get_config_num watch_interval 5)
	[ "$interval" -lt 1 ] && interval=1

	while true; do
		[ -f "$DISABLE" ] && { log_info "disable 文件存在，退出锁定循环"; break; }
		[ ! -d "$MODDIR" ] && { log_info "模块目录不存在，退出"; break; }

		reload_config_cache

		if [ "$_lock_enable" = "false" ]; then
			sleep "$interval"
			continue
		fi

		[ -n "$_lock_swappiness" ] && _raw_write "$_lock_swappiness" /proc/sys/vm/swappiness
		[ -n "$_lock_watermark" ] && _raw_write "$_lock_watermark" /proc/sys/vm/watermark_scale_factor
		[ -n "$_lock_dbr" ] && _raw_write "$_lock_dbr" /proc/sys/vm/dirty_background_ratio
		[ -n "$_lock_dr" ] && _raw_write "$_lock_dr" /proc/sys/vm/dirty_ratio
		[ -n "$_lock_vfs_cache" ] && _raw_write "$_lock_vfs_cache" /proc/sys/vm/vfs_cache_pressure
		[ -n "$_lock_overcommit" ] && _raw_write "$_lock_overcommit" /proc/sys/vm/overcommit_memory
		[ -n "$_lock_dirty_expire" ] && _raw_write "$_lock_dirty_expire" /proc/sys/vm/dirty_expire_centisecs
		[ -n "$_lock_dirty_writeback" ] && _raw_write "$_lock_dirty_writeback" /proc/sys/vm/dirty_writeback_centisecs
		[ -n "$_lock_page_cluster" ] && _raw_write "$_lock_page_cluster" /proc/sys/vm/page-cluster
		[ -n "$_lock_compaction" ] && _raw_write "$_lock_compaction" /proc/sys/vm/compaction_proactiveness
		[ "$_lock_stat_interval" != "" ] && _raw_write "$_lock_stat_interval" /proc/sys/vm/stat_interval
		[ "$_lock_oom_kill_alloc" != "" ] && _raw_write "$_lock_oom_kill_alloc" /proc/sys/vm/oom_kill_allocating_task
		[ "$_lock_oom_dump" != "" ] && _raw_write "$_lock_oom_dump" /proc/sys/vm/oom_dump_tasks
		[ "$_lock_compact_unevict" != "" ] && _raw_write "$_lock_compact_unevict" /proc/sys/vm/compact_unevictable_allowed
		[ "$_lock_panic_on_oom" != "" ] && _raw_write "$_lock_panic_on_oom" /proc/sys/vm/panic_on_oom

		if [ -n "$_lock_extra_free" ] && [ "$_lock_extra_free" != "auto" ] && [ -f /proc/sys/vm/extra_free_kbytes ]; then
			_raw_write "$_lock_extra_free" /proc/sys/vm/extra_free_kbytes
		fi

		if [ -n "$_lock_lmk_minfree" ] && [ -f /sys/module/lowmemorykiller/parameters/minfree ]; then
			_raw_write "$_lock_lmk_minfree" /sys/module/lowmemorykiller/parameters/minfree
		fi

		if [ "$_NEED_ZRAM_REBUILD" = "1" ]; then
			_NEED_ZRAM_REBUILD=0
			log_info "重建 ZRAM (配置变更)"
			local dev; dev=$(cat "$MODDIR/zram_dev" 2>/dev/null)
			[ -z "$dev" ] && dev="zram0"
			local alg; alg=$(get_config_safe algorithm); [ -z "$alg" ] && alg="lz4"
			local size; size=$(get_config_safe zram_size); [ -z "$size" ] && size="2.0"
			local ms; ms=$(get_config_safe max_streams); [ -z "$ms" ] && ms="auto"
			local priority; priority=$(get_config_num zram_priority 100)
			local sup; sup=$(get_algs "$dev")
			local final; final=$(select_alg "$alg" "$sup")
			echo "$final" > "$MODDIR/.current_alg"
			config_zram "$final" "$size" "$dev" "$ms" "$priority" || \
				log_warn "ZRAM 重建失败"
		fi

		local swap_cnt=0
		[ -f /proc/swaps ] && swap_cnt=$(grep -c /dev/block/zram /proc/swaps 2>/dev/null || echo 0)
		local zram_info="none"
		[ -f "$MODDIR/zram_dev" ] && zram_info=$(cat "$MODDIR/zram_dev" 2>/dev/null)
		local vm_info=0
		[ -f /proc/sys/vm/swappiness ] && vm_info=$(cat /proc/sys/vm/swappiness 2>/dev/null | tr -d '\n')
		log_heartbeat "$swap_cnt" "$zram_info" "$vm_info"

		sleep "$interval"
	done

	log_info "锁定循环已退出"
	rm -f "$PIDFILE"
}

[ "$_SELF" = "memory.sh" ] && run_optimization
