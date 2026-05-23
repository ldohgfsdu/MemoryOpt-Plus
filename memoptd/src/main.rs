#![deny(unused_imports)]

mod config;
mod sysfs;
mod psi;
mod inotify;
mod zram;
mod heartbeat;

use std::io::Write;
use std::os::unix::io::{AsFd, AsRawFd, BorrowedFd};
use std::path::PathBuf;
use std::process;
use std::time::Duration;

use nix::sys::signal::{Signal, SigSet};
use nix::sys::signalfd::SignalFd;
use nix::sys::timerfd::{ClockId, TimerFd, TimerFlags, TimerSetTimeFlags, Expiration};
use nix::poll::{poll, PollFd, PollFlags, PollTimeout};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let config_path = args.get(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/data/adb/modules/memoryopt_plus/swap.ini"));

    // Derive log path from config directory
    if let Some(parent) = config_path.parent() {
        let log_path = parent.join("log.txt");
        sysfs::init_log(&log_path);
    }

    match Daemon::new(&config_path) {
        Ok(mut d) => d.run(),
        Err(e) => {
            let msg = format!("Failed to init memoptd: {}", e);
            sysfs::log_to_file("!", &msg);
            let _ = std::io::stderr().write_all(format!("[!] memoptd: {}\n", msg).as_bytes());
            process::exit(1);
        }
    }
}

struct Daemon {
    config_path: PathBuf,
    inotify: inotify::Watcher,
    locks: config::Locks,
    heartbeat: heartbeat::Emitter,
    last_zram_ok: bool,
    boot_cycles: u64,
}

impl Daemon {
    fn new(config_path: &std::path::Path) -> Result<Self, Box<dyn std::error::Error>> {
        let config = config::Config::from_file(config_path)?;
        let locks = config::Locks::from_config(&config);
        let inotify = inotify::Watcher::new(config_path)?;
        let heartbeat = heartbeat::Emitter::new();
        Ok(Self {
            config_path: config_path.to_owned(),
            inotify,
            locks,
            heartbeat,
            last_zram_ok: false,
            boot_cycles: 0,
        })
    }

    fn run(&mut self) {
        let mut sigset = SigSet::empty();
        sigset.add(Signal::SIGHUP);
        sigset.add(Signal::SIGUSR1);
        if let Err(e) = sigset.thread_block() {
            error_msg("sigset", &format!("failed to block signals: {}", e));
            process::exit(1);
        }

        let sfd = match SignalFd::with_flags(&sigset, nix::sys::signalfd::SfdFlags::SFD_NONBLOCK) {
            Ok(fd) => fd,
            Err(e) => { error_msg("signalfd", &e.to_string()); process::exit(1); }
        };

        let interval = Duration::from_secs(self.locks.watch_interval);
        let tfd = match TimerFd::new(ClockId::CLOCK_MONOTONIC, TimerFlags::TFD_NONBLOCK) {
            Ok(fd) => fd,
            Err(e) => { error_msg("timerfd", &e.to_string()); process::exit(1); }
        };
        if let Err(e) = tfd.set(
            Expiration::IntervalDelayed(
                nix::sys::time::TimeSpec::from(interval),
                nix::sys::time::TimeSpec::from(interval),
            ),
            TimerSetTimeFlags::empty(),
        ) {
            error_msg("timerfd.set", &format!("failed to arm timer: {}", e));
            process::exit(1);
        }

        // Extract raw fds to avoid borrow conflicts with &mut self
        let ino_fd = self.inotify.as_raw_fd();
        let sfd_fd = sfd.as_raw_fd();
        let tfd_fd = tfd.as_fd().as_raw_fd();

        self.apply_all();
        self.configure_zram();
        sysfs::log_to_file("i", "memoptd started");

        loop {
            let mut pfds = [
                PollFd::new(unsafe { BorrowedFd::borrow_raw(ino_fd) }, PollFlags::POLLIN),
                PollFd::new(unsafe { BorrowedFd::borrow_raw(sfd_fd) }, PollFlags::POLLIN),
                PollFd::new(unsafe { BorrowedFd::borrow_raw(tfd_fd) }, PollFlags::POLLIN),
            ];

            match poll(&mut pfds, PollTimeout::NONE) {
                Ok(_) => {}
                Err(nix::errno::Errno::EINTR) => continue,
                Err(e) => {
                    warn_msg(&format!("poll error: {}", e));
                    continue;
                }
            }

            if pfds[0].revents().map_or(false, |r| r.contains(PollFlags::POLLIN)) {
                self.inotify.drain();
                self.reload();
            }

            if pfds[1].revents().map_or(false, |r| r.contains(PollFlags::POLLIN)) {
                while let Ok(Some(event)) = sfd.read_signal() {
                    match event.ssi_signo as i32 {
                        libc::SIGHUP => self.reload(),
                        libc::SIGUSR1 => self.trigger_zram_rebuild(),
                        _ => {}
                    }
                }
            }

            if pfds[2].revents().map_or(false, |r| r.contains(PollFlags::POLLIN)) {
                tfd.wait().ok();
                self.lock_cycle();
            }
        }
    }

    fn apply_all(&mut self) {
        lock_sysctl("swappiness", self.locks.swappiness);
        lock_sysctl("dirty_background_ratio", self.locks.dirty_bg);
        lock_sysctl("dirty_ratio", self.locks.dirty);
        lock_sysctl("vfs_cache_pressure", self.locks.vfs_cache);
        lock_sysctl("watermark_scale_factor", self.locks.watermark);
        lock_sysctl("compaction_proactiveness", self.locks.compaction);
        lock_sysctl("overcommit_memory", self.locks.overcommit);
        lock_sysctl("page-cluster", self.locks.page_cluster);
        lock_sysctl("stat_interval", 3);
        lock_sysctl("oom_kill_allocating_task", 0);
        lock_sysctl("oom_dump_tasks", 0);
        lock_sysctl("compact_unevictable_allowed", 1);
        lock_sysctl("panic_on_oom", 0);
        lock_sysctl("block_dump", 0);
        if self.locks.extra_free != "auto" {
            sysfs::write_str("/proc/sys/vm/extra_free_kbytes", &self.locks.extra_free);
        }
        if self.locks.dirty_expire > 0 { lock_sysctl("dirty_expire_centisecs", self.locks.dirty_expire); }
        if self.locks.dirty_writeback > 0 { lock_sysctl("dirty_writeback_centisecs", self.locks.dirty_writeback); }

        if self.locks.enable_mglru {
            if std::path::Path::new("/sys/kernel/mm/lru_gen/enabled").exists() {
                sysfs::write_str("/sys/kernel/mm/lru_gen/enabled", "0x0003");
                sysfs::write_str("/sys/kernel/mm/lru_gen/min_ttl_ms", "10000");
            }
        } else {
            if std::path::Path::new("/sys/kernel/mm/lru_gen/enabled").exists() {
                sysfs::write_str("/sys/kernel/mm/lru_gen/enabled", "0x0000");
            }
        }
        // Disable vendor-specific reclaim mechanisms (only at startup)
        let vendor_paths = [
            "/sys/module/process_reclaim/parameters/enable_process_reclaim",
            "/sys/kernel/mi_reclaim/enable",
            "/sys/kernel/mi_reclaim/greclaim_enable",
            "/sys/kernel/low_free/low_free_enable",
            "/sys/module/memplus_core/parameters/memory_plus_enabled",
            "/proc/sys/vm/memory_plus",
            "/sys/kernel/mi_thermald/mi_thermald_enable",
            "/sys/module/perfmgr/parameters/perfmgr_enable",
            "/sys/module/opchain/parameters/opchain_enable",
        ];
        for path in &vendor_paths {
            sysfs::write_str(path, "0");
        }
        // Disable transparent hugepage compaction and scheduler autogroup
        sysfs::write_str("/sys/kernel/mm/transparent_hugepage/khugepaged/defrag", "0");
        sysfs::write_str("/proc/sys/kernel/sched_autogroup_enabled", "0");
        self.last_zram_ok = zram::check_online();
    }

    fn lock_cycle(&mut self) {
        delta_lock("dirty_background_ratio", self.locks.dirty_bg);
        delta_lock("dirty_ratio", self.locks.dirty);
        delta_lock("vfs_cache_pressure", self.locks.vfs_cache);
        delta_lock("watermark_scale_factor", self.locks.watermark);
        delta_lock("compaction_proactiveness", self.locks.compaction);
        delta_lock("overcommit_memory", self.locks.overcommit);
        delta_lock("page-cluster", self.locks.page_cluster);
        delta_lock("stat_interval", 3);
        delta_lock("oom_kill_allocating_task", 0);
        delta_lock("oom_dump_tasks", 0);
        delta_lock("compact_unevictable_allowed", 1);
        delta_lock("panic_on_oom", 0);
        delta_lock("block_dump", 0);
        if self.locks.dirty_expire > 0 { delta_lock("dirty_expire_centisecs", self.locks.dirty_expire); }
        if self.locks.dirty_writeback > 0 { delta_lock("dirty_writeback_centisecs", self.locks.dirty_writeback); }

        if !zram::check_online() && self.last_zram_ok {
            warn_msg("ZRAM device lost, triggering rebuild");
            self.trigger_zram_rebuild();
        }
        self.last_zram_ok = zram::check_online();

        self.boot_cycles += 1;
        let psi_data = psi::read_memory_pressure();

        // Swappiness ramp: linearly interpolate from 50% of target to target over 24 cycles
        let effective_swappiness = if self.boot_cycles < 24 {
            let target = self.locks.swappiness;
            let min_start = target / 2;
            let ramp = min_start + (target - min_start) * self.boot_cycles as i64 / 24;
            if psi_data.some_avg10 > 15.0 { ramp / 2 } else { ramp }
        } else if psi_data.some_avg10 > 10.0 {
            (self.locks.swappiness / 2).min(80)
        } else {
            self.locks.swappiness
        };
        delta_lock("swappiness", effective_swappiness);
        self.heartbeat.tick(&psi_data, effective_swappiness);
    }

    fn reload(&mut self) {
        match config::Config::from_file(&self.config_path) {
            Ok(cfg) => {
                self.locks = config::Locks::from_config(&cfg);
                self.boot_cycles = 0;
                self.apply_all();
                self.configure_zram();
            }
            Err(e) => { warn_msg(&format!("config reload failed: {}", e)); }
        }
    }

    fn trigger_zram_rebuild(&mut self) {
        self.configure_zram();
    }

    fn configure_zram(&mut self) {
        let dev = zram::get_current_device();
        if !zram::configure(
            &self.locks.zram_algorithm,
            &self.locks.zram_size,
            &dev,
            &self.locks.zram_streams,
            self.locks.zram_priority,
        ) {
            let mem_bytes = sysfs::read_mem_total_bytes();
            let fallback_size = if mem_bytes > 4u64 * 1024 * 1024 * 1024 { "2.0" } else { "1.0" };
            warn_msg("zram config failed, trying lz4 fallback");
            zram::configure("lz4", fallback_size, &dev, "auto", self.locks.zram_priority);
        }
    }
}

fn lock_sysctl(key: &str, val: i64) {
    sysfs::write_str(&format!("/proc/sys/vm/{}", key), &val.to_string());
}

fn delta_lock(key: &str, expected: i64) {
    let path = format!("/proc/sys/vm/{}", key);
    if let Ok(cur) = sysfs::read_i64(&path) {
        if cur != expected { sysfs::write_str(&path, &expected.to_string()); }
    }
}

fn warn_msg(msg: &str)  { let _ = std::io::stderr().write_all(format!("[!] memoptd: {}\n", msg).as_bytes()); }
fn error_msg(c: &str, m: &str) { let _ = std::io::stderr().write_all(format!("[!] memoptd/{}: {}\n", c, m).as_bytes()); }
