#!/system/bin/sh
# MemoryOpt Plus - 开机前置部署

MODDIR=${0%/*}

chmod 0755 "$MODDIR"/*.sh 2>/dev/null

if [ -f "$MODDIR/daemon.pid" ]; then
    oldpid=$(cat "$MODDIR/daemon.pid" 2>/dev/null)
    if [ -n "$oldpid" ] && [ "$oldpid" != "_pid" ]; then
        kill "$oldpid" 2>/dev/null
        sleep 0.5
        kill -0 "$oldpid" 2>/dev/null && kill -9 "$oldpid" 2>/dev/null
    fi
    rm -f "$MODDIR/daemon.pid"
fi
rm -f "$MODDIR/log.txt.old" "$MODDIR/zram_dev" "$MODDIR/.rebuild_lock" \
      "/data/local/tmp/memoryopt_heartbeat.json" 2>/dev/null

. "$MODDIR/common.sh"

oem_type=$(detect_oem)
mem_gb=$(get_mem_gb)

bg_limit=48
if   [ "$mem_gb" -ge 16 ]; then bg_limit=128
elif [ "$mem_gb" -ge 12 ]; then bg_limit=96
elif [ "$mem_gb" -ge 8  ]; then bg_limit=80
elif [ "$mem_gb" -ge 6  ]; then bg_limit=64
fi

_prop_set ro.config.low_ram false
_prop_set ro.sys.fw.bg_apps_limit "$bg_limit"
_prop_set ro.vendor.qti.sys.fw.bg_apps_limit "$bg_limit"
_prop_set persist.vendor.qti.memory.enable false
_prop_set ro.lmk.kill_heaviest_task false
_prop_set ro.lmk.debug false

case "$oem_type" in
    xiaomi) ;;
    oppo)
        _prop_set persist.sys.oplus.memory.kill_policy 1
        _prop_set persist.sys.oplus.process_manager.bg_limit "$bg_limit"
        ;;
esac

exit 0
