# MemoryOpt Plus

<p align="center">
  <strong>让手机更流畅，后台更稳，续航更久</strong>
  <br>
  一个真正懂 Android 内存的 Magisk 模块
</p>

<p align="center">
  <img src="https://img.shields.io/badge/版本-V26.05.20-blue" alt="version">
  <img src="https://img.shields.io/badge/Magisk-25.2%2B-green" alt="magisk">
  <img src="https://img.shields.io/badge/Android-10%2B-orange" alt="android">
  <img src="https://img.shields.io/badge/架构-arm64%20%7C%20armv7-lightgrey" alt="arch">
  <img src="https://img.shields.io/badge/许可-MIT-brightgreen" alt="license">
</p>

---

## 一句话介绍

> 一个装完就忘掉的模块——自动管理 ZRAM、锁定系统内存参数、实时感知内存压力并自适应调整，让你的 Android 设备时刻保持最佳内存状态。

---

## 它解决什么问题？

Android 系统本身的内存管理并不完美：

| 问题 | MemoryOpt Plus 怎么做 |
|------|----------------------|
| 系统改了你设的 swappiness | **持续检查**，被改了立刻修正 |
| 内存紧张时卡顿加剧 | 实时监测 **PSI 内存压力**，自动降低 swappiness 避免雪崩 |
| ZRAM 配置不合理 | 根据内存大小**智能计算**最佳 ZRAM 大小和压缩算法 |
| 厂商偷偷回收后台 | 自动**禁用**小米/OPPO/VIVO 的私有内存回收机制 |
| 改完配置还得重启 | 编辑 swap.ini **保存即生效**，无需重启 |
| 卸载后系统恢复不了 | 首次运行就**备份原生配置**，卸载时完美还原 |

---

## 安装

### 要求

- Android 10+
- Magisk 25.2+ / KernelSU / APatch
- 2GB 以上内存

### 步骤

1. 从 [Releases](../../releases) 下载最新 zip
2. 在 Magisk Manager 中刷入
3. 重启手机
4. 完成，无需任何操作

> 装完就能用。想调参数的话往下看。

---

## 自定义配置（非必须）

编辑 `/data/adb/modules/memoryopt_plus/swap.ini`，**保存即生效**：

```ini
# ZRAM 压缩算法
# lz4 (推荐, 均衡) | zstd (高压缩比, 稍慢) | lz4hc
algorithm=lz4

# ZRAM 大小
# 2.0 = 内存的 2 倍
# 也可以直接写 4096M
zram_size=2.0

# 交换倾向，越大越积极使用 ZRAM
# 默认 130
swappiness=130

# 参数检查间隔（秒）
watch_interval=5

# 日志级别：quiet(仅错误) | normal(正常) | verbose(调试)
log_level=normal
```

**常用场景推荐**：

| 内存 | 推荐配置 |
|------|---------|
| 4GB 以下 | `algorithm=lz4` `zram_size=3.0` `swappiness=160` |
| 6-8GB | `algorithm=lz4` `zram_size=2.0` `swappiness=130` ← 默认 |
| 12GB+ | `algorithm=zstd` `zram_size=1.5` `swappiness=100` |

完整参数说明见 `swap.ini` 文件内注释。

---

## 核心功能

### VM 参数持续锁定

系统、内核、厂商都可能随时修改关键内存参数。模块持续检查并立即修正：

`swappiness` · `vfs_cache_pressure` · `dirty_ratio` · `dirty_background_ratio` · `watermark_scale_factor` · `compaction_proactiveness` · `overcommit_memory` · `page-cluster` 等 **20+ 个参数**

### ZRAM 智能管理

- 自动检测内核支持的压缩算法（zstd / lz4 / lz4hc / lzo-rle）
- 根据内存大小计算最佳 ZRAM 容量
- 配置失败自动回退到安全的 lz4 方案
- 首次运行备份原生 ZRAM 配置，卸载时完美恢复

### 内存压力自适应

读取 Linux PSI（Pressure Stall Information），比"还剩多少内存"精确得多：

- **正常状态**：按你设定的 swappiness 运行
- **some 压力 > 10%**：自动把 swappiness 降到一半（上限 80），减少交换避免卡顿
- **压力恢复**：自动回到正常值

### 配置热重载

编辑 `swap.ini` 后保存，不用重启，不用发命令，**即刻生效**。

Rust 引擎下延迟 <100ms，Shell 引擎下最多 5 秒。

### 厂商回收禁用

自动检测并关闭以下厂商私有的内存回收机制：

| 厂商 | 被禁用的模块 |
|------|------------|
| 小米 | `mi_reclaim` · `low_free` · `memplus_core` · `mi_thermald` |
| OPPO/一加 | `oplus` 内存策略 · `opchain` |
| VIVO | `perfmgr` |

### 干净卸载

Magisk Manager 中移除模块后重启，自动：
- 恢复原生 ZRAM 配置（压缩算法、大小、流数）
- 恢复系统 VM 参数到安装前状态
- 清除所有注入的系统属性
- 删除临时文件，不留痕迹

---

## 如何确认模块在工作？

```bash
# 1. 检查 swappiness 是否被锁定
cat /proc/sys/vm/swappiness
# 应该输出你设置的值（默认 130）

# 2. 检查 ZRAM 状态
cat /proc/swaps
# 应该看到 zram 设备

# 3. 查看模块日志
cat /data/adb/modules/memoryopt_plus/log.txt | tail -20
# 看到 "守护进程已启动" 说明正常工作
```

---

## 常见问题

<details>
<summary><b>Q: 装完需要做什么？</b></summary>

什么都不用做。默认配置已适合大多数设备。想微调的话编辑 `swap.ini`，保存后自动生效。
</details>

<details>
<summary><b>Q: 会耗电吗？</b></summary>

几乎无感知。持续锁定每次仅数微秒，24 小时耗电 < 0.01%。
</details>

<details>
<summary><b>Q: zstd 和 lz4 怎么选？</b></summary>

- **lz4**：压缩/解压更快，CPU 占用低，日常使用推荐
- **zstd**：压缩比高约 30%，同等内存能存更多数据，CPU 稍高
- **lz4hc**：lz4 高压缩比变体，折中选择
</details>

<details>
<summary><b>Q: 和其他内存优化模块冲突吗？</b></summary>

和其他 ZRAM 管理类模块冲突（安装时自动检测并移除）。与 FDE.AI、LSPosed 等不冲突。不建议同时用多个同类内存模块。
</details>

<details>
<summary><b>Q: 怎么临时关闭？</b></summary>

编辑 `swap.ini` 加入 `enable=false`，保存即停。或 Magisk Manager 关模块后重启。
</details>

<details>
<summary><b>Q: 卸载后 ZRAM 能恢复吗？</b></summary>

能。首次运行会备份原生 ZRAM 配置，卸载时自动恢复压缩算法、磁盘大小等。
</details>

<details>
<summary><b>Q: 支持哪些设备？</b></summary>

Android 10+ 均可。实测覆盖小米（MIUI/HyperOS）、三星、OPPO/一加、VIVO、Pixel、华硕等主流品牌。
</details>

<details>
<summary><b>Q: 会触发 SafetyNet / Play Integrity 吗？</b></summary>

模块本身不影响。但 Magisk 环境可能影响，请使用 DenyList 功能处理。
</details>

---

## 版本历史

| 版本 | 日期 | 更新内容 |
|------|------|---------|
| V26.05.20 | 2026-05 | 双引擎架构 (Rust + Shell)、PSI 内存压力自适应、inotify 配置热重载、JSON 心跳、MGLRU 支持、lmkd 绑核、模块冲突检测 |
| v4.0 | 2024 | ZRAM 智能备份恢复、VM 参数锁定、厂商回收禁用 |
| v3.x | 2023 | 初始发布 |

---

## 许可证

MIT

---

<p align="center">
  <sub>觉得有用就点个 Star ⭐ · 发现问题提 Issue · 想贡献提 PR</sub>
</p>
