#!/system/bin/sh
# MemoryOpt Plus - 公共函数库

[ -n "$_COMMON_SH_LOADED" ] && return 0
_COMMON_SH_LOADED=1

MAX_LOG_SIZE=$((1024 * 1024))
_HEARTBEAT_FILE="/data/local/tmp/memoryopt_heartbeat.json"

_CONFIG_CACHE_MTIME=0

get_config() {
    [ -z "$CONFIG" ] && { echo ""; return; }
    [ ! -f "$CONFIG" ] && { echo ""; return; }
    local mt
    mt=$(stat -c %Y "$CONFIG" 2>/dev/null)
    if [ -z "$mt" ] || [ "$mt" = "0" ]; then
        mt=$(ls -l "$CONFIG" 2>/dev/null | awk '{print $6$7$8$5}')
    fi
    if [ "$mt" != "$_CONFIG_CACHE_MTIME" ]; then
        _CONFIG_CACHE_MTIME=$mt
        eval "$(awk -F= '
            /^[[:space:]]*#/ { next }
            {
                eq = index($0, "=")
                if (eq == 0) next
                k = substr($0, 1, eq-1); gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                if (k == "") next
                v = substr($0, eq+1); sub(/#.*$/, "", v)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
                gsub(/\x27/, "\x27\\\x27\x27", v)
                printf "_cfg_%s='\''%s'\''\n", k, v
            }' "$CONFIG" 2>/dev/null
        )"
    fi
    eval "echo \${_cfg_${1}:-}"
}

get_config_safe() {
    local val
    val=$(get_config "$1")
    case "$1" in
        algorithm) case "$val" in lz4|lz4hc|lzo|lzo-rle|zstd|deflate) ;; *) val="lz4" ;; esac ;;
        zram_size) [ -z "$val" ] && val="2.0" ;;
        swappiness|dirty_background_ratio|dirty_ratio|vfs_cache_pressure|\
        watermark_scale_factor|compaction_proactiveness|overcommit_memory|\
        dirty_expire_centisecs|dirty_writeback_centisecs)
            case "$val" in ''|*[!0-9]*) case "$1" in
                swappiness) val=130 ;; dirty_background_ratio) val=2 ;; dirty_ratio) val=5 ;;
                vfs_cache_pressure) val=125 ;; watermark_scale_factor) val=100 ;;
                compaction_proactiveness) val=20 ;; overcommit_memory) val=1 ;;
                dirty_expire_centisecs) val=1000 ;; dirty_writeback_centisecs) val=100 ;;
            esac ;; esac ;;
        lmk_low_percent|lmk_medium_percent|lmk_critical_percent)
            case "$val" in ''|*[!0-9]*) val= ;; esac
            [ -n "$val" ] && { [ "$val" -lt 1 ] 2>/dev/null && val=1; [ "$val" -gt 15 ] 2>/dev/null && val=15; }
            case "$1" in lmk_low_percent) : ${val:=6} ;; lmk_medium_percent) : ${val:=4} ;; lmk_critical_percent) : ${val:=2} ;; esac ;;
        page_cluster|extra_free_kbytes|max_streams) case "$val" in auto|''|*[!0-9]*) val="auto" ;; esac ;;
        watch_interval) case "$val" in ''|*[!0-9]*) val=5 ;; esac ;;
        zram_priority) case "$val" in ''|*[!0-9]*) val=100 ;; *) [ "$val" -lt 0 ] 2>/dev/null && val=0; [ "$val" -gt 32767 ] 2>/dev/null && val=32767 ;; esac ;;
        early_start|enable|disable_vendor_reclaim|bind_lmkd|log_to_logcat) case "$val" in true|false) ;; *) val="false" ;; esac ;;
        log_level) case "$val" in quiet|normal|verbose) ;; *) val="normal" ;; esac ;;
    esac
    echo "$val"
}

get_config_num() {
    local val=$(get_config "$1")
    case "$val" in ''|*[!0-9]*) echo "$2" ;; *) echo "$val" ;; esac
}

get_mem_kb() { local _mk; _mk=$(grep MemTotal /proc/meminfo | tr -cd '0-9'); echo "${_mk:-0}"; }
get_mem_mb() { local kb; kb=$(get_mem_kb); echo $(( (kb + 512) / 1024 )); }
get_mem_gb() { local kb; kb=$(get_mem_kb); echo $(( (kb + 524288) / 1048576 )); }

detect_oem() {
    if [ -f "$MODDIR/.oem_type" ]; then cat "$MODDIR/.oem_type" 2>/dev/null; return; fi
    local oem="generic"
    getprop ro.product.manufacturer 2>/dev/null | grep -qiE "xiaomi" && oem="xiaomi"
    getprop ro.product.manufacturer 2>/dev/null | grep -qiE "oppo|oneplus" && oem="oppo"
    [ -n "$(getprop persist.sys.oplus.confirm 2>/dev/null)" ] && oem="oppo"
    echo "$oem"
}

_HAS_RESETPROP=false
command -v resetprop >/dev/null 2>&1 && _HAS_RESETPROP=true

_prop_set() {
    if [ "$_HAS_RESETPROP" = "true" ]; then
        resetprop "$1" "$2" 2>/dev/null
    else
        setprop "$1" "$2" 2>/dev/null
    fi
}

_prop_del() {
    if [ "$_HAS_RESETPROP" = "true" ]; then
        resetprop -d "$1" 2>/dev/null
    else
        setprop "$1" "" 2>/dev/null
    fi
}

_selinux_restore() {
    local file="$1"
    command -v restorecon >/dev/null 2>&1 && restorecon "$file" 2>/dev/null
    command -v chcon >/dev/null 2>&1 && chcon -h "u:object_r:sysfs:s0" "$file" 2>/dev/null
}

_raw_write() {
    local val="$1" file="$2"
    [ ! -f "$file" ] && return 1
    if echo "$val" > "$file" 2>/dev/null; then return 0; fi
    local orig_perm="" stat_bin=""
    command -v busybox >/dev/null 2>&1 && stat_bin="busybox"
    command -v stat >/dev/null 2>&1 && stat_bin="stat"
    [ -n "$stat_bin" ] && orig_perm=$($stat_bin -c %a "$file" 2>/dev/null)
    [ -z "$orig_perm" ] && orig_perm="644"
    chmod 666 "$file" 2>/dev/null
    if echo "$val" > "$file" 2>/dev/null; then
        chmod "$orig_perm" "$file" 2>/dev/null
        return 0
    fi
    _selinux_restore "$file"
    if echo "$val" > "$file" 2>/dev/null; then
        chmod "$orig_perm" "$file" 2>/dev/null
        return 0
    fi
    chmod "$orig_perm" "$file" 2>/dev/null
    return 1
}

set_value() {
    local val="$1" file="$2" quiet="$3"
    val=$(echo "$val" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ ! -f "$file" ]; then
        _LOG_COUNT_SKIP=$((_LOG_COUNT_SKIP + 1))
        [ "$quiet" != "quiet" ] && _log_msg "!" "$file not found"
        return 1
    fi
    if _raw_write "$val" "$file"; then
        log_write "$file" "$val" "$quiet"
        return 0
    else
        log_fail "写入失败: $file"
        return 1
    fi
}

_stop_pid() {
    local pid="$1"
    [ -z "$pid" ] && return
    kill -0 "$pid" 2>/dev/null || return
    kill "$pid" 2>/dev/null
    local i=0
    while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 10 ]; do
        sleep 0.3; i=$((i + 1))
    done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
}

_LOG_FILE=""; _LOG_LEVEL=""; _LOG_LOGCAT=""; _LOG_INIT_DONE=""
_LOG_COUNT_OK=0; _LOG_COUNT_FAIL=0; _LOG_COUNT_SKIP=0; _LOG_HEARTBEAT=0
_LOG_KEEP=3

_log_init() {
    [ -n "$_LOG_INIT_DONE" ] && return 0
    [ -z "$LOG" ] && _LOG_FILE="/dev/null" || _LOG_FILE="$LOG"
    _LOG_LEVEL=$(get_config_safe log_level)
    _LOG_LOGCAT=$(get_config_safe log_to_logcat)
    [ -z "$_LOG_LEVEL" ] && _LOG_LEVEL="normal"
    [ -z "$_LOG_LOGCAT" ] && _LOG_LOGCAT="false"
    _LOG_INIT_DONE=1
}

_log_rotate() {
    [ -z "$_LOG_FILE" ] || [ "$_LOG_FILE" = "/dev/null" ] && return
    [ ! -f "$_LOG_FILE" ] && return
    local sz=0
    if ! sz=$(wc -c < "$_LOG_FILE" 2>/dev/null | tr -d ' '); then
        sz=$(stat -c %s "$_LOG_FILE" 2>/dev/null)
    fi
    [ -z "$sz" ] && sz=0
    [ "$sz" -lt "$MAX_LOG_SIZE" ] && return
    rm -f "${_LOG_FILE}.${_LOG_KEEP}" 2>/dev/null
    local i=$_LOG_KEEP
    while [ "$i" -gt 1 ]; do
        [ -f "${_LOG_FILE}.$((i-1))" ] && mv "${_LOG_FILE}.$((i-1))" "${_LOG_FILE}.${i}" 2>/dev/null
        i=$((i-1))
    done
    mv "${_LOG_FILE}" "${_LOG_FILE}.1" 2>/dev/null
}

_log_msg() {
    local level="$1" msg="$2"
    [ -z "$_LOG_FILE" ] && _log_init
    case "$_LOG_LEVEL" in
        quiet)  [ "$level" = "!" ] || return 0 ;;
        normal) [ "$level" = "d" ] && return 0 ;;
    esac
    local prefix
    case "$level" in
        i) prefix="- [i]:" ;; !) prefix="- [!]:" ;; d) prefix="- [d]:" ;; *) prefix="- [i]:" ;;
    esac
    local ts; ts=$(date '+%m-%d %H:%M:%S')
    [ -n "$_LOG_FILE" ] && [ "$_LOG_FILE" != "/dev/null" ] && \
        echo "[$ts] $prefix $msg" >> "$_LOG_FILE"
    [ "$_LOG_LOGCAT" = "true" ] && command -v log >/dev/null 2>&1 && \
        log -t "MemOpt" -p "$([ "$level" = "!" ] && echo E || echo I)" "$msg" 2>/dev/null
}

log_info()  { _log_msg "i" "$1"; }
log_warn()  { _log_msg "!" "$1"; }
log_debug() { _log_msg "d" "$1"; }
log_section() { _log_msg "i" "────────── $1 ──────────"; }

log_write() {
    local file="$1" expected="$2" quiet="$3"
    local actual; actual=$(head -n1 "$file" 2>/dev/null | tr -d '\n\r')
    if [ "$actual" = "$expected" ]; then
        _LOG_COUNT_OK=$((_LOG_COUNT_OK + 1))
        [ "$quiet" != "quiet" ] && _log_msg "i" "写入: $file → $expected"
    else
        _LOG_COUNT_FAIL=$((_LOG_COUNT_FAIL + 1))
        _log_msg "!" "写入失败: $file 目标=${expected} 实际=${actual}"
    fi
}

log_optional() {
    local val="$1" file="$2"
    [ ! -f "$file" ] && { _LOG_COUNT_SKIP=$((_LOG_COUNT_SKIP + 1)); return 1; }
    if _raw_write "$val" "$file"; then
        _LOG_COUNT_OK=$((_LOG_COUNT_OK + 1))
        return 0
    fi
    _LOG_COUNT_FAIL=$((_LOG_COUNT_FAIL + 1))
    _log_msg "!" "写入失败: $file"
    return 1
}

log_fail() { _LOG_COUNT_FAIL=$((_LOG_COUNT_FAIL + 1)); _log_msg "!" "$1"; }

log_time() { _log_msg "i" "$1 耗时: ${2}ms"; }

log_change() {
    local key="$1" old="$2" new="$3" w="${4:-20}"
    local pad="" i=0 kl=${#key}
    while [ $i -lt $((w - kl)) ]; do pad="${pad} "; i=$((i+1)); done
    _log_msg "i" "  ${key}${pad}${old} → ${new}"
}

log_heartbeat() {
    _LOG_HEARTBEAT=$((_LOG_HEARTBEAT + 1))
    _log_msg "d" "心跳 #${_LOG_HEARTBEAT} · swap=$1 · zram=$2 · vm=$3"
    echo "$(date +%s)" > "$_HEARTBEAT_FILE" 2>/dev/null
}

log_summary() {
    local t="${1:-0}"
    local total=$((_LOG_COUNT_OK + _LOG_COUNT_FAIL + _LOG_COUNT_SKIP))
    [ "$total" -eq 0 ] && return
    local s="操作统计: 成功 ${_LOG_COUNT_OK} · 跳过 ${_LOG_COUNT_SKIP} · 失败 ${_LOG_COUNT_FAIL}"
    [ "$t" -gt 0 ] && s="${s} · 耗时 ${t}ms"
    _log_msg "i" "$s"
    _LOG_COUNT_OK=0; _LOG_COUNT_FAIL=0; _LOG_COUNT_SKIP=0
}

_log_banner() {
    [ -z "$_LOG_FILE" ] || [ "$_LOG_FILE" = "/dev/null" ] && return
    local _ver="" _brand="" _model="" _market="" _android="" _kernel="" _mem="" _sys="" _time=""
    [ -f "$MODDIR/module.prop" ] && _ver=$(grep "^version=" "$MODDIR/module.prop" 2>/dev/null | \
        head -n1 | cut -d'=' -f2- | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    _brand=$(getprop ro.product.brand 2>/dev/null)
    _market=$(getprop ro.product.marketname 2>/dev/null)
    _model=$(getprop ro.product.model 2>/dev/null)
    [ -z "$_model" ] && _model=$(getprop ro.product.vendor.model 2>/dev/null)
    [ -z "$_model" ] && _model="unknown"
    _android=$(getprop ro.build.version.release 2>/dev/null)
    _kernel=$(uname -r 2>/dev/null | cut -d'-' -f1)
    _mem=$(get_mem_gb)
    _time=$(date "+%Y-%m-%d %H:%M:%S")
    local _miui=$(getprop ro.miui.ui.version.name 2>/dev/null)
    local _hyper=$(getprop ro.mi.os.version.name 2>/dev/null)
    if [ -n "$_hyper" ]; then
        _sys="HyperOS ${_hyper} ($(getprop ro.build.version.incremental 2>/dev/null))"
    elif [ -n "$_miui" ]; then
        if [ "$_miui" = "V816" ]; then
            _sys="HyperOS $(getprop ro.product.build.version.incremental 2>/dev/null)"
        else
            _sys="MIUI ${_miui} - $(getprop ro.build.version.incremental 2>/dev/null)"
        fi
    else
        _sys=$(getprop ro.product.build.version.incremental 2>/dev/null)
    fi
    {
        echo ""
        echo "###############################################"
        printf "  MemoryOpt Plus %s\n" "${_ver:-unknown}"
        echo "-----------------------------------------------"
        printf "  手机品牌: %s\n" "$_brand"
        [ -n "$_market" ] && printf "  上市名称: %s\n" "$_market"
        printf "  手机型号: %s\n" "$_model"
        printf "  安卓版本: %s\n" "$_android"
        printf "  内存大小: %sGB\n" "$_mem"
        printf "  内核版本: %s\n" "$_kernel"
        [ -n "$_sys" ] && printf "  系统版本: %s\n" "$_sys"
        printf "  当前时间: %s\n" "$_time"
        echo "###############################################"
    } >> "$_LOG_FILE"
}

_timestamp_ms() {
    local t; t=$(awk '{printf "%d\n", $1 * 1000}' /proc/uptime 2>/dev/null)
    case "$t" in ''|*[!0-9]*) t=$(date +%s%3N 2>/dev/null); case "$t" in ''|*[!0-9]*) t=$(date +%s)000 ;; esac ;; esac
    echo "$t"
}
timer_start() { _timestamp_ms; }
timer_end() { local start=$1 end; end=$(_timestamp_ms); echo $((end - start)); }

calc_lmk_minfree() {
    local lmk_node="/sys/module/lowmemorykiller/parameters/minfree"
    [ ! -f "$lmk_node" ] && { echo ""; return; }
    local mem_mb; mem_mb=$(get_mem_mb)
    [ "$mem_mb" -eq 0 ] && { echo ""; return; }
    local l=$(get_config_safe lmk_low_percent);      : ${l:=6}
    local m=$(get_config_safe lmk_medium_percent);   : ${m:=4}
    local c=$(get_config_safe lmk_critical_percent); : ${c:=2}
    local low=$(( mem_mb * l * 256 / 100 ))
    local med=$(( mem_mb * m * 256 / 100 ))
    local cri=$(( mem_mb * c * 256 / 100 ))
    local low2=$(( low * 8 / 10 ))
    local med2=$(( med * 8 / 10 ))
    local cri2=$(( cri * 8 / 10 ))
    local cur_vals num_slots=6
    cur_vals=$(cat "$lmk_node" 2>/dev/null | tr -d '[:space:]')
    [ -n "$cur_vals" ] && num_slots=$(echo "$cur_vals" | awk -F, '{print NF}') && [ "$num_slots" -lt 1 ] && num_slots=6
    local template="cri2 cri med2 med low2 low" result="" i=0
    for token in $template; do
        [ $i -ge $num_slots ] && break
        local val
        case "$token" in
            low) val=$low ;; low2) val=$low2 ;; med) val=$med ;;
            med2) val=$med2 ;; cri) val=$cri ;; cri2) val=$cri2 ;;
        esac
        [ -n "$result" ] && result="${result},"
        result="${result}${val}"
        i=$((i+1))
    done
    while [ $i -lt $num_slots ]; do result="${result},${low}"; i=$((i+1)); done
    echo "$result"
}
