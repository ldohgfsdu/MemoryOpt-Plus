#!/system/bin/sh
# MemoryOpt Plus 卸载脚本

MODDIR=${0%/*}
BACKUP="$MODDIR/vm_backup"
ZRAM_BACKUP="$MODDIR/zram_backup"
PERSIST_BACKUP="/data/local/tmp/memoryopt_backup"
REBUILD_LOCK="$MODDIR/.rebuild_lock"

if [ -z "$MODDIR" ] || [ ! -d "$MODDIR" ]; then
    echo "Error: module directory not found"
    exit 1
fi

. "$MODDIR/common.sh"

# 终止守护进程
if [ -f "$MODDIR/daemon.pid" ]; then
    oldpid=$(cat "$MODDIR/daemon.pid" 2>/dev/null)
    if [ "$oldpid" = "_pid" ]; then
        echo "检测到遗留 _pid 标记，使用 pgrep 清理"
        for pid in $(pgrep -f "sh.*${MODDIR}/service.sh" 2>/dev/null); do
            _stop_pid "$pid"
        done
    elif [ -n "$oldpid" ]; then
        _stop_pid "$oldpid"
    fi
fi

rm -f "$REBUILD_LOCK"
for pid in $(pgrep -f "sh.*${MODDIR}/service.sh" 2>/dev/null) \
           $(pgrep -f "sh.*${MODDIR}/memory.sh"  2>/dev/null); do
    [ "$pid" = "$$" ] && continue
    [ -n "$pid" ] && _stop_pid "$pid"
done
sleep 1
# Verify no lingering processes
pgrep -f "${MODDIR}" >/dev/null 2>&1 && sleep 2

# 恢复原生 zram0
if [ -d "$ZRAM_BACKUP" ]; then
    swapoff /dev/block/zram0 2>/dev/null
    echo 1 > /sys/block/zram0/reset 2>/dev/null
    sleep 0.15

    if [ -f "$ZRAM_BACKUP/algorithm" ] && [ -f /sys/block/zram0/comp_algorithm ]; then
        algo=$(head -n1 "$ZRAM_BACKUP/algorithm" 2>/dev/null)
        [ -n "$algo" ] && echo "$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null || \
            echo "Warning: 无法恢复原生压缩算法"
    fi
    if [ -s "$ZRAM_BACKUP/max_comp_streams" ] && [ -f /sys/block/zram0/max_comp_streams ]; then
        ms=$(cat "$ZRAM_BACKUP/max_comp_streams" 2>/dev/null)
        [ -n "$ms" ] && echo "$ms" > /sys/block/zram0/max_comp_streams 2>/dev/null
    fi
    if [ -s "$ZRAM_BACKUP/disksize" ] && [ -f /sys/block/zram0/disksize ]; then
        size=$(cat "$ZRAM_BACKUP/disksize" 2>/dev/null)
        if [ -n "$size" ] && [ "$size" -gt 0 ] 2>/dev/null; then
            echo "$size" > /sys/block/zram0/disksize 2>/dev/null
            if [ -e /dev/block/zram0 ] && ! grep -q zram0 /proc/swaps; then
                if ! mkswap /dev/block/zram0 2>/dev/null; then
                    echo "Warning: mkswap /dev/block/zram0 失败"
                elif ! swapon /dev/block/zram0 2>/dev/null; then
                    echo "Warning: swapon /dev/block/zram0 失败"
                fi
            fi
        else
            echo "原生 zram0 大小为 0，跳过恢复"
        fi
    fi
    rm -rf "$ZRAM_BACKUP"
fi

# 移除模块自建的 zram 设备
if [ -f "$MODDIR/zram_dev" ]; then
    mod_dev=$(cat "$MODDIR/zram_dev" 2>/dev/null)
    if [ -n "$mod_dev" ] && [ "$mod_dev" != "zram0" ]; then
        sw="/dev/block/$mod_dev"
        swapoff "$sw" 2>/dev/null
        echo 1 > "/sys/block/$mod_dev/reset" 2>/dev/null
        if [ -d /sys/class/zram-control ]; then
            id="${mod_dev#zram}"
            echo "$id" > /sys/class/zram-control/hot_remove 2>/dev/null
        fi
    fi
fi

# 恢复 VM 参数
if [ -d "$BACKUP" ]; then
    for n in swappiness dirty_background_ratio dirty_ratio vfs_cache_pressure \
             watermark_scale_factor overcommit_memory extra_free_kbytes \
             dirty_expire_centisecs dirty_writeback_centisecs stat_interval \
             watermark_boost_factor compaction_proactiveness page-cluster; do
        if [ -f "$BACKUP/$n" ]; then
            val=$(cat "$BACKUP/$n" 2>/dev/null)
            echo "$val" > "/proc/sys/vm/$n" 2>/dev/null || echo "Warning: 无法恢复 /proc/sys/vm/$n"
        fi
    done
    rm -rf "$BACKUP"
fi

# 恢复 post-fs-data 注入的系统属性
echo "恢复系统属性..."
_prop_del ro.config.low_ram
_prop_del ro.sys.fw.bg_apps_limit
_prop_del ro.vendor.qti.sys.fw.bg_apps_limit
_prop_del persist.vendor.qti.memory.enable
_prop_del ro.lmk.kill_heaviest_task
_prop_del ro.lmk.debug
_prop_del persist.sys.oplus.memory.kill_policy
_prop_del persist.sys.oplus.process_manager.bg_limit

# 清理所有残留
rm -rf "$PERSIST_BACKUP" 2>/dev/null
rm -f /data/local/tmp/memoryopt_heartbeat.json 2>/dev/null
rm -f "$MODDIR/disable" "$MODDIR/daemon.pid" "$MODDIR/daemon.pid.lock" "$MODDIR/zram_dev" \
      "$MODDIR/.current_alg" "$MODDIR/.rebuild_lock" 2>/dev/null

echo "MemoryOpt Plus 卸载完成"
