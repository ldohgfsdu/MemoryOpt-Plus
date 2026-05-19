# MemoryOpt Plus — 项目移交文档

## 项目概述

Android Magisk/KernelSU/APatch 内存优化模块。
通过 ZRAM 管理 + VM 参数锁定 + PSI 压力自适应来优化 Android 内存。

**双引擎架构**：
- **Rust 引擎 (memoptd)**：零 fork、inotify 热重载、PSI 压力感知、JSON 心跳
- **Shell 引擎**：零依赖回退，兼容所有设备

**当前版本**：v4.1.0 | **许可证**：MIT

---

## 技术栈

- Shell (POSIX sh, mksh 兼容) — 核心逻辑 + 回退守护进程
- Rust (musl 静态链接, no_std 友好) — 高性能守护进程
- Android sysfs (`/proc/sys/vm/*`, `/sys/block/zram*`)
- Magisk 模块系统
- Linux: inotify / signalfd / timerfd / PSI

---

## 文件职责

| 文件 | 职责 | 类型 |
|------|------|------|
| `module.prop` | Magisk 元数据 | 配置 |
| `swap.ini` | 用户配置，运行时热重载 | 配置 |
| `customize.sh` | 安装：冲突检测、备份、配置生成、memoptd 部署 | Shell |
| `post-fs-data.sh` | 开机前置：属性注入、旧实例清理 | Shell |
| `service.sh` | 启动入口：ZRAM 初始化 + 引擎选择 (Rust/Shell) | Shell |
| `common.sh` | 公共库：配置缓存、日志、LMK、属性写入、`_stop_pid` | Shell |
| `memory.sh` | 核心：ZRAM 配置、VM 参数、厂商回收、LMK | Shell |
| `uninstall.sh` | 卸载：恢复原生 ZRAM/VM/属性，清理残留 | Shell |
| `memoptd/src/main.rs` | Rust 入口：poll 主循环 (inotify + signalfd + timerfd) | Rust |
| `memoptd/src/config.rs` | swap.ini 解析 + Locks 结构体 | Rust |
| `memoptd/src/sysfs.rs` | 零 fork 读写 `/proc/sys/vm/*` | Rust |
| `memoptd/src/psi.rs` | `/proc/pressure/memory` PSI 解析 | Rust |
| `memoptd/src/inotify.rs` | inotify 配置热重载 | Rust |
| `memoptd/src/zram.rs` | ZRAM 在线检测 + 压缩比 | Rust |
| `memoptd/src/heartbeat.rs` | JSON 结构化心跳输出 | Rust |
| `META-INF/` | Magisk 安装器模板 | 模板 |
| `pack.sh` | 打包脚本 | 工具 |

---

## 关键设计决策

| 决策 | 原因 |
|------|------|
| `get_config` 单次 `awk` → `eval` 缓存 | 高频循环零 fork |
| `_raw_write` 先直接写，失败才 `chmod 666` | 99% 情况一次成功 |
| `_NEED_ZRAM_REBUILD` 全局变量 | 跨函数传递重建标记 |
| 备份持久化到 `/data/local/tmp/memoryopt_backup` | 模块更新时 `$MODPATH` 被删除 |
| Shell 只做 ZRAM 初始化（一次性） | `mkswap`/`swapon` 必须 fork |
| Rust 接管锁定循环 | 零 fork、inotify、纳秒定时 |
| `exec memoptd` | 替换 shell 进程，省内存 |
| memoptd 丢失 → 自动回退 shell | 兼容所有设备 |

---

## 执行流程

```
开机
 ├─> post-fs-data.sh    属性注入 + 旧实例清理
 ├─> service.sh 启动
 │     ├─> wait_boot() / wait_vm_ready()
 │     ├─> run_optimization()    ZRAM 部署 (一次性)
 │     ├─> memoptd 存在?
 │     │     ├─ YES → exec memoptd $CONFIG   (Rust, 零 fork)
 │     │     └─ NO  → lock_params()           (Shell, 回退)
 │     └─ SIGHUP → 强制重载 | SIGUSR1 → ZRAM 重建
 └─> uninstall.sh
       ├─ 恢复原生 ZRAM (从备份)
       ├─ 恢复 VM 参数
       ├─ 重置系统属性
       └─ 清理持久备份 + 心跳文件
```

---

## 已知约束

- `local` 不能在脚本顶层使用 (ash/mksh 报错)
- `stat -c %Y` 在 toybox/GNU stat 都可用，busybox 稍不同（已做 fallback）
- `resetprop` 是 Magisk 特有，KernelSU 上不存在（已做检测）
- ZRAM reset 后需 `sleep 0.15`，否则写 `disksize` 可能 EBUSY
- `pgrep` 部分设备不存在（已 `2>/dev/null` 兜底）
- 心跳文件 `/data/local/tmp/memoryopt_heartbeat.json` 需卸载时清理

---

## 待办清单

[ ] armv7 memoptd 编译支持
[ ] cgroup v2 集成（per-process memory.high）
[ ] swap.ini per-app 自定义 swappiness
[ ] memoptd ZRAM 压缩率趋势图数据
[ ] CTS/Play Integrity 兼容测试
[ ] Magisk Delta/KernelSU 安装兼容测试
[ ] 心跳 JSON 增加 dirty page / compact 状态
[ ] dry-run 模式
[ ] 日志回传 (logcat / 文件)

---

## 快速验证命令

```bash
# 编译
cd memoptd && ./build.sh

# 打包
./pack.sh

# 检查运行状态
adb shell "pgrep memoptd || pgrep -f 'sh.*service.sh'"
adb shell "cat /data/local/tmp/memoryopt_heartbeat.json"
adb shell "cat /data/adb/modules/memoryopt_plus/log.txt | tail -20"

# 热重载测试
adb shell "echo 'swappiness=180' >> /data/adb/modules/memoryopt_plus/swap.ini"
adb shell "sleep 1 && cat /proc/sys/vm/swappiness"
```

---

## 代码风格

```
Shell:
  local var                    # 函数内声明，顶层不用
  _MODULE_GLOBAL              # 跨文件全局变量
  func_name() { ... }         # 函数定义
  [ "$a" = "$b" ]             # 字符串比较（不用 [[）

Rust:
  cargo fmt                   # 标准格式化
  #![deny(unused_imports)]    # 零容忍
  nix::*                      # 系统调用封装
  sysfs::write_str()          # 统一写入入口
```

---

## 启动 Agent 任务描述

> 你的任务是维护和改进 MemoryOpt Plus——
> 一个 Android Magisk 内存优化模块。
>
> 核心文件：service.sh(入口), memory.sh(ZRAM/VM), common.sh(库),
>           memoptd/(Rust 守护进程)
>
> 请先通读全部源文件和本文档，理解架构后开始工作。
> 优先处理 [待办清单] 中的项目。
> 修改代码前先说明方案，修改后验证逻辑一致性。
