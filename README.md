# MemoryOpt Plus

> Android 高性能内存优化 Magisk 模块

<p align="center">
  <img src="https://img.shields.io/badge/version-V26.05.20-blue" alt="version">
  <img src="https://img.shields.io/badge/platform-Android-green" alt="Android">
  <img src="https://img.shields.io/badge/min%20kernel-4.x-blue" alt="Kernel 4.x+">
  <img src="https://img.shields.io/badge/license-MIT-orange" alt="MIT">
</p>

---

## 简介

MemoryOpt Plus 是一款面向 Android 设备的 Magisk 内存优化模块，支持 **Magisk / KernelSU / APatch**。

通过 **ZRAM 智能管理** + **20+ VM 参数锁定** + **PSI 压力自适应** + **厂商回收禁用**，显著提升多任务后台保活能力与系统流畅度。

---

## 特性

| 类别 | 说明 |
|------|------|
| **双引擎** | Rust (`memoptd`) 零 fork 高性能 + Shell 零依赖回退 |
| **ZRAM 管理** | 自动备份/恢复原生配置，支持热插拔创建新设备 |
| **多算法** | lz4 / zstd / lz4hc / lzo / lzo-rle / deflate，不支持自动降级 |
| **VM 锁定** | swappiness / vfs_cache_pressure / dirty_ratio 等 20+ 参数持续守护 |
| **热重载** | 编辑 `swap.ini` 保存即生效（Rust 引擎 inotify < 100ms）|
| **PSI 自适应** | 内存紧张时自动降低 swappiness，避免 OOM |
| **厂商回收禁用** | 支持 Xiaomi / OPPO / OnePlus / VIVO |
| **LMK 调优** | 根据内存大小动态计算 minfree 阈值 |
| **干净卸载** | 完整还原原生 ZRAM + VM 参数 + 系统属性 |

---

## 安装

```bash
# 1. 在 Magisk / KernelSU / APatch 中刷入 zip 包
# 2. 重启设备
# 3. 编辑配置文件（重启后生效）
```

配置文件路径：
```
/data/adb/modules/memoryopt_plus/swap.ini
```

> 升级安装会自动保留旧配置，无需重新调整。

---

## 配置

### 核心参数

| 参数 | 默认值 | 取值范围 | 说明 |
|------|--------|----------|------|
| `algorithm` | `lz4` | lz4 / zstd / lz4hc / lzo / lzo-rle / deflate | ZRAM 压缩算法 |
| `zram_size` | `2.0` | 因子或 `4G` / `2048M` | ZRAM 大小（内存倍数或绝对值） |
| `swappiness` | `130` | 0 ~ 32767 | 交换倾向，越高越积极使用 ZRAM |
| `dirty_background_ratio` | `2` | 0 ~ 100 | 后台脏页刷新阈值 (% 总内存) |
| `dirty_ratio` | `5` | 0 ~ 100 | 强制脏页刷新阈值 (% 总内存) |
| `vfs_cache_pressure` | `125` | 0 ~ 200 | >100 优先回收 page cache |
| `watermark_scale_factor` | `100` | 1 ~ 1000 | 水位线缩放因子 |
| `compaction_proactiveness` | `20` | 0 ~ 100 | 主动内存规整，0 = 关闭 |
| `overcommit_memory` | `1` | 0 / 1 / 2 | 内存过量分配策略 |
| `watch_interval` | `5` | 1 ~ 3600 | VM 参数锁定检查间隔（秒） |

### 行为控制

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `enable` | `true` | 设为 `false` 则只监控不优化 |
| `early_start` | `false` | 在 `boot_completed` 之前启动 |
| `disable_vendor_reclaim` | `false` | 禁用厂商激进内存回收 |
| `bind_lmkd` | `false` | 将 lmkd 绑定到小核 |
| `log_level` | `normal` | quiet / normal / verbose |
| `log_to_logcat` | `false` | 同步输出到 logcat |

### LMK 参数

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `lmk_low_percent` | `6` | 低压力时的内存阈值 (% 总内存) |
| `lmk_medium_percent` | `4` | 中等压力阈值 |
| `lmk_critical_percent` | `2` | 临界阈值 |

---

## 编译 (memoptd)

```bash
cd memoptd/
./build.sh
cp out/memoptd ../bin/
```

> 不编译也可正常使用，模块会自动回退到 Shell 引擎。

---

## 打包

```bash
./pack.sh
```

---

## 日志

查看运行日志：
```bash
cat /data/adb/modules/memoryopt_plus/log.txt
```

---

## 卸载

在 Magisk Manager 中移除模块并重启即可。卸载脚本会自动：

- 还原原生 ZRAM 配置（算法、大小、压缩流数）
- 还原所有 VM 参数
- 清除注入的系统属性
- 清理持久化备份和心跳文件

---

## 兼容性

| 项目 | 要求 |
|------|------|
| Root 方案 | Magisk v20+ / KernelSU / APatch |
| 内核版本 | Linux 4.x+ |
| Android | 10+ (API 29+) |
| 架构 | arm64 / armv7 |

---

## 许可证

[MIT License](LICENSE)

---

## 注意事项

- ZRAM 大小不建议超过物理内存的 **3 倍**
- 部分厂商内核可能限制了 `swappiness` 上限（< 100）或未暴露 `minfree` 节点，属正常现象
- 与其它 ZRAM / swap 模块互斥，安装时会自动标记冲突模块卸载
- 遇到问题请先查看日志 `log.txt`
