# Changelog

All notable changes to MemoryOpt Plus will be documented in this file.

## [V26.05.20] - 2026-05-20

### Added
- 双引擎架构：Rust 守护进程 (memoptd) + Shell 零依赖回退
- ZRAM 智能管理：自动检测/配置压缩算法 (lz4/zstd/lz4hc/lzo/lzo-rle/deflate)
- ZRAM 原生配置自动备份与持久化恢复
- 20+ VM 参数锁定 (swappiness, vfs_cache_pressure, dirty_ratio 等)
- inotify 配置热重载 (Rust 引擎 <100ms)
- PSI 内存压力自适应调优
- JSON 结构化心跳输出
- MGLRU (Multi-Gen LRU) 检测与启用
- 厂商内存回收禁用 (Xiaomi/OPPO/VIVO)
- lmkd 绑核功能
- LMK minfree 自适应计算
- ZRAM 优先级支持
- page_cluster 根据压缩算法自适应 (zstd→0, 其他→1)
- 模块冲突自动检测与标记卸载
- 安装时智能配置生成 (根据内存大小/内核版本)
- 旧版本配置迁移
- 日志轮转 + logcat 同步

### Supported
- Magisk v25.2+ / KernelSU / APatch
- Android 10+ (API 29+)
- aarch64 / armv7
- Linux kernel 4.x / 5.x / 6.x

## [Upstream]
- MemoryOpt Ecosystem (M1racle Team)
