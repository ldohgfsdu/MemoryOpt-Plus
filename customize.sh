#!/system/bin/sh
# MemoryOpt Plus 安装脚本

SKIPUNZIP=0

[ -z "$MODPATH" ] && MODPATH="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"

MID=$(grep "^id=" "$MODPATH/module.prop" 2>/dev/null | head -n1 | \
    cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

LEGACY_IDS="aegismem_engine MemoryOpt"

ui_print() { echo "$1"; sleep 0.05; }

# 兼容 KernelSU/APatch
if ! command -v set_perm_recursive >/dev/null 2>&1; then
    set_perm_recursive() {
        local dir="$1" uid="$2" gid="$3" dperm="$4" fperm="$5"
        chown -R "$uid:$gid" "$dir" 2>/dev/null
        find "$dir" -type d -exec chmod "$dperm" {} + 2>/dev/null
        find "$dir" -type f -exec chmod "$fperm" {} + 2>/dev/null
    }
fi
if ! command -v set_perm >/dev/null 2>&1; then
    set_perm() {
        local file="$1" uid="$2" gid="$3" perm="$4"
        chown "$uid:$gid" "$file" 2>/dev/null
        chmod "$perm" "$file" 2>/dev/null || chmod 755 "$file"
    }
fi

find_mod() {
    local id="$1" d mid
    for base in /data/adb/modules /data/adb/ksu/modules; do
        [ ! -d "$base" ] && continue
        for d in "$base"/*; do
            [ ! -d "$d" ] || [ ! -f "$d/module.prop" ] && continue
            mid=$(grep "^id=" "$d/module.prop" 2>/dev/null | head -n1 | \
                cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ "$mid" = "$id" ] && { echo "${d%/}"; return 0; }
        done
    done
    echo ""
}

CONFLICT_IDS="zram_huanchen HChen_Zram MiniHChen swap_controller scene_swap_controller MemoryOpt_Lite"

remove_conflicts() {
    ui_print "- 检查冲突模块..."
    for id in $CONFLICT_IDS; do
        p=$(find_mod "$id")
        [ -n "$p" ] && { touch "$p/remove"; ui_print "  已标记卸载 $id"; }
    done
}

preserve_config() {
    local old_mod_dir=""
    for try_id in "$MID" $LEGACY_IDS; do
        old_mod_dir=$(find_mod "$try_id")
        [ -n "$old_mod_dir" ] && break
    done
    if [ -n "$old_mod_dir" ] && [ -f "$old_mod_dir/swap.ini" ]; then
        generate_optimal_config
        local line key val
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/[[:space:]]*#.*//')
            [ -z "$line" ] && continue
            key=${line%%=*}
            val=${line#*=}
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            val=$(echo "$val" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$key" ] && continue
            local escaped_key escaped_val
            escaped_key=$(echo "$key" | sed 's/[\/&\\]/\\&/g')
            escaped_val=$(echo "$val" | sed 's/[\/&\\]/\\&/g')
            if grep -qE "^[[:space:]]*${escaped_key}[[:space:]]*=" "$MODPATH/swap.ini" 2>/dev/null; then
                sed -i "s|^[[:space:]]*${escaped_key}[[:space:]]*=.*|${key}=${escaped_val}|" "$MODPATH/swap.ini" 2>/dev/null
            else
                echo "${key}=${val}" >> "$MODPATH/swap.ini"
                ui_print "  追加新配置项: ${key}=${val}"
            fi
        done < "$old_mod_dir/swap.ini"
        # 迁移持久备份
        local old_backup="/data/local/tmp/memoryopt_backup"
        if [ -d "$old_mod_dir/zram_backup" ] && [ -f "$old_mod_dir/zram_backup/.done" ]; then
            mkdir -p "$old_backup"
            cp -f "$old_mod_dir/zram_backup"/* "$old_backup/" 2>/dev/null
            touch "$old_backup/.zram_done"
            ui_print "- 已迁移原生 ZRAM 备份到持久存储"
        fi
        ui_print "- 已保留旧配置（来自 $old_mod_dir）"
        return 0
    fi
    return 1
}

get_mem_mb()      { local mk; mk=$(grep MemTotal /proc/meminfo | tr -cd '0-9'); echo $(((mk + 512) / 1024)); }
get_kernel_major(){ uname -r | cut -d. -f1; }
supports_zstd()   {
    [ -f /sys/block/zram0/comp_algorithm ] && grep -qw zstd /sys/block/zram0/comp_algorithm 2>/dev/null && return 0
    grep -qw zstd /proc/crypto 2>/dev/null && return 0
    return 1
}
is_xiaomi() { getprop ro.product.manufacturer 2>/dev/null | grep -qi xiaomi && return 0; return 1; }
is_oppo()   {
    getprop ro.product.manufacturer 2>/dev/null | grep -qiE "oppo|oneplus" && return 0
    [ -n "$(getprop persist.sys.oplus.confirm 2>/dev/null)" ] && return 0
    return 1
}

generate_optimal_config() {
    local mem_mb kernel_ver size_factor sw
    mem_mb=$(get_mem_mb)
    kernel_ver=$(get_kernel_major)
    local detected_alg="lz4"
    supports_zstd && detected_alg="zstd"
    if   [ "$mem_mb" -ge 12288 ]; then size_factor="1.5"
    elif [ "$mem_mb" -ge 8192  ]; then size_factor="2.0"
    elif [ "$mem_mb" -ge 4096  ]; then size_factor="2.5"
    else                               size_factor="3.0"
    fi
    sw=130; [ "$kernel_ver" -lt 5 ] && sw=100
    cat > "$MODPATH/swap.ini" <<EOFCONF
# MemoryOpt Plus 配置（智能生成）
algorithm=${detected_alg}
zram_size=${size_factor}
max_streams=auto
swappiness=${sw}
dirty_background_ratio=2
dirty_ratio=5
dirty_expire_centisecs=1000
dirty_writeback_centisecs=100
vfs_cache_pressure=125
page_cluster=auto
watermark_scale_factor=100
extra_free_kbytes=auto
compaction_proactiveness=20
overcommit_memory=1
lmk_low_percent=6
lmk_medium_percent=4
lmk_critical_percent=2
early_start=false
watch_interval=5
enable=true
disable_vendor_reclaim=false
zram_priority=100
log_level=normal
log_to_logcat=false
bind_lmkd=false
# bind_lmkd_mask=0x0f
EOFCONF
    ui_print "- 智能配置：算法=${detected_alg}，ZRAM 因子=${size_factor}，swappiness=${sw}"
}

detect_oem_and_save() {
    local oem="generic"
    is_xiaomi && oem="xiaomi"
    is_oppo   && oem="oppo"
    echo "$oem" > "$MODPATH/.oem_type"
    ui_print "- 识别设备厂商：${oem}"
}

backup_native_zram() {
    local zram0_sys="/sys/block/zram0"
    if [ -d "$zram0_sys" ]; then
        mkdir -p "$MODPATH/zram_backup"
        [ -f "$zram0_sys/comp_algorithm" ] && \
            cat "$zram0_sys/comp_algorithm" 2>/dev/null | \
            sed -n 's/.*\[\([a-z0-9]*\)\].*/\1/p' | head -n1 > "$MODPATH/zram_backup/algorithm"
        [ -f "$zram0_sys/disksize" ] && cat "$zram0_sys/disksize" 2>/dev/null > "$MODPATH/zram_backup/disksize"
        [ -f "$zram0_sys/max_comp_streams" ] && cat "$zram0_sys/max_comp_streams" 2>/dev/null > "$MODPATH/zram_backup/max_comp_streams"
        touch "$MODPATH/zram_backup/.done"
        local persist_dir="/data/local/tmp/memoryopt_backup"
        mkdir -p "$persist_dir"
        local copied=0
        for f in "$MODPATH/zram_backup"/*; do
            [ -f "$f" ] && cp -f "$f" "$persist_dir/" 2>/dev/null && copied=1
        done
        [ "$copied" = "1" ] && touch "$persist_dir/.zram_done"
        ui_print "- 已备份原生 ZRAM 配置（含持久副本）"
    fi
}

backup_vm() {
    local bdir="$MODPATH/vm_backup"
    mkdir -p "$bdir"
    for n in swappiness dirty_background_ratio dirty_ratio vfs_cache_pressure \
             watermark_scale_factor overcommit_memory extra_free_kbytes \
             dirty_expire_centisecs dirty_writeback_centisecs stat_interval \
             watermark_boost_factor compaction_proactiveness page-cluster; do
        [ -f "/proc/sys/vm/$n" ] && cat "/proc/sys/vm/$n" > "$bdir/$n" 2>/dev/null
    done
    ui_print "- 已备份系统 VM 参数"
}

sanitize_text() {
    ui_print "- 正在净化文本文件..."
    local f
    for f in "$MODPATH"/*.sh "$MODPATH"/*.ini "$MODPATH"/*.txt; do
        [ -f "$f" ] && [ -s "$f" ] && {
            sed 's/\r$//' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f" 2>/dev/null
        }
    done
    return 0
}

set_perms() {
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    for s in memory.sh service.sh post-fs-data.sh uninstall.sh common.sh; do
        [ -f "$MODPATH/$s" ] && set_perm "$MODPATH/$s" 0 0 0755
    done
}

deploy_memoptd() {
    local arch
    arch=$(uname -m)
    local src=""
    case "$arch" in
        aarch64|arm64) src="$MODPATH/bin/memoptd" ;;
        armv7l|armv8l|armeabi-v7a) src="$MODPATH/bin/memoptd.arm" ;;
        *) ui_print "- 不支持的架构: $arch，跳过 memoptd 部署"; return 0 ;;
    esac
    if [ -f "$src" ]; then
        chmod 0755 "$src"
        ui_print "- memoptd 已部署 ($arch)"
    else
        ui_print "- memoptd 二进制未找到 ($arch)，将使用 shell 回退"
    fi
    # 清理不需要的架构
    if [ -f "$MODPATH/bin/memoptd" ] && [ "$arch" != "aarch64" ] && [ "$arch" != "arm64" ]; then
        rm -f "$MODPATH/bin/memoptd" 2>/dev/null
    fi
    if [ -f "$MODPATH/bin/memoptd.arm" ] && [ "$arch" = "aarch64" ]; then
        rm -f "$MODPATH/bin/memoptd.arm" 2>/dev/null
    fi
}

main() {
    ui_print "MemoryOpt Plus 安装中..."
    remove_conflicts
    if preserve_config; then
        ui_print "- 更新安装：已保留旧配置，跳过智能生成"
    else
        generate_optimal_config
        ui_print "- 如需调整算法，安装后编辑 swap.ini 的 algorithm= 行即可"
    fi
    detect_oem_and_save
    backup_native_zram
    backup_vm
    sanitize_text
    set_perms
    deploy_memoptd
    ui_print "- 安装完成（重启后生效）"
}

main
