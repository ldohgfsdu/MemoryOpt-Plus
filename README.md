# MemoryOpt Plus

Android 高性能内存优化 Magisk 模块。支持 ZRAM 智能管理 + VM 参数锁定 + PSI 压力自适应。

## 特性

- **双引擎**：Rust (memoptd) 零 fork + Shell 零依赖回退
- **ZRAM** 自动备份/恢复原生配置，支持 zstd/lz4/lz4hc
- **VM 锁定**：swappiness, vfs_cache_pressure, dirty_ratio 等 20+ 参数
- **PSI 自适应**：内存紧张时自动降低 swappiness
- **inotify 热重载**：编辑 swap.ini 保存即生效（Rust 引擎）
- **厂商回收禁用**：支持 Xiaomi/OPPO/VIVO

## 安装

1. Magisk/KernelSU/APatch 刷入 zip
2. 重启
3. 编辑 `/data/adb/modules/memoryopt_plus/swap.ini`
4. 保存即生效

## 配置

参见 `swap.ini` 内注释。核心参数：

| 参数 | 默认 | 说明 |
|------|------|------|
| algorithm | lz4 | 压缩算法 (lz4/zstd/lz4hc) |
| zram_size | 2.0 | ZRAM = 内存 × 因子 |
| swappiness | 130 | 交换倾向 |
| watch_interval | 5 | 锁定检查间隔(s) |

## 编译 memoptd

```bash
cd memoptd/
./build.sh
cp out/memoptd ../bin/
```

## 打包

```bash
./pack.sh
```

## 许可证

MIT
