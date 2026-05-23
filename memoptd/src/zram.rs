use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;

use crate::sysfs;

/// Parse algorithm from sysfs format: "lz4 [lzo] zstd" → "lzo"
fn parse_algorithm(raw: &str) -> Option<String> {
    for token in raw.split_whitespace() {
        let tok = token.trim_start_matches('[').trim_end_matches(']');
        if !tok.is_empty() && tok != "none" {
            return Some(tok.to_string());
        }
    }
    None
}

/// Get supported algorithms for a zram device
fn get_supported_algorithms(dev: &str) -> Vec<String> {
    let path = format!("/sys/block/{}/comp_algorithm", dev);
    let content = match std::fs::read_to_string(&path) {
        Ok(c) => c,
        Err(_) => return vec![],
    };
    content.split_whitespace()
        .filter_map(|t| {
            let tok = t.trim_start_matches('[').trim_end_matches(']');
            if !tok.is_empty() && tok != "none" { Some(tok.to_string()) } else { None }
        })
        .collect()
}

/// Select best algorithm: prefer configured, fallback to common ones
fn select_algorithm(preferred: &str, supported: &[String]) -> String {
    if supported.iter().any(|a| a == preferred) {
        return preferred.to_string();
    }
    for fallback in &["lz4", "lz4hc", "zstd", "lzo-rle", "lzo", "deflate"] {
        if supported.iter().any(|a| a == fallback) {
            sysfs::log_to_file("i", &format!("algorithm downgrade: {} → {}", preferred, fallback));
            return fallback.to_string();
        }
    }
    if let Some(first) = supported.first() {
        sysfs::log_to_file("!", &format!("no preferred algorithm match, using: {}", first));
        first.clone()
    } else {
        sysfs::log_to_file("!", "no algorithms found, using lz4");
        "lz4".to_string()
    }
}

/// Parse zram_size config value into absolute bytes
/// Supports: "2.0" (factor of memory), "2048M", "4G"
fn parse_zram_size(raw: &str, mem_bytes: u64) -> u64 {
    let trimmed = raw.trim();
    // Try suffix format: 2048M, 4G, etc.
    if let Some(stripped) = trimmed.strip_suffix(|c: char| c == 'M' || c == 'm') {
        if let Ok(mb) = stripped.trim().parse::<u64>() {
            return mb * 1024 * 1024;
        }
    }
    if let Some(stripped) = trimmed.strip_suffix(|c: char| c == 'G' || c == 'g') {
        if let Ok(gb) = stripped.trim().parse::<u64>() {
            return gb * 1024 * 1024 * 1024;
        }
    }
    // Try factor format: "2.0"
    if let Ok(factor) = trimmed.parse::<f64>() {
        let bytes = (mem_bytes as f64 * factor) as u64;
        let min = (mem_bytes / 8).max(128 * 1024 * 1024);
        let max = 16u64 * 1024 * 1024 * 1024;
        return bytes.max(min).min(max);
    }
    // Default: 2x memory
    mem_bytes * 2
}

/// Wait for zram block device to appear after reset
fn wait_for_device(path: &str, max_wait_ms: u64) -> bool {
    let mut waited = 0u64;
    while waited < max_wait_ms {
        if std::path::Path::new(path).exists() {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(50));
        waited += 50;
    }
    false
}

/// Initialize and configure a zram device
pub fn configure(
    algorithm: &str,
    size_raw: &str,
    dev: &str,
    streams: &str,
    priority: i64,
) -> bool {
    let zdev = format!("/dev/block/{}", dev);
    let zsys = format!("/sys/block/{}", dev);

    if !std::path::Path::new(&zdev).exists() {
        sysfs::log_to_file("!", &format!("{} is not a block device", zdev));
        return false;
    }

    // Backup current algorithm before reset
    let _ = std::fs::read_to_string(format!("{}/comp_algorithm", zsys))
        .ok()
        .and_then(|c| parse_algorithm(&c))
        .map(|alg| std::fs::write(format!("{}/.current_alg_backup", std::env::var("MODDIR").unwrap_or_default()), &alg).ok());

    // Get supported algorithms
    let supported = get_supported_algorithms(dev);
    let selected = select_algorithm(algorithm, &supported);

    sysfs::log_to_file("i", &format!("configuring zram: dev={} algo={}", dev, selected));

    // Take device offline
    let _ = std::process::Command::new("swapoff").arg(&zdev).output();

    // Reset device
    let _ = std::fs::write(format!("{}/reset", zsys), "1");
    std::thread::sleep(std::time::Duration::from_millis(100));

    // Set algorithm
    if supported.iter().any(|a| a == &selected) {
        sysfs::write_str(&format!("{}/comp_algorithm", zsys), &selected);
    }

    // Set max comp streams
    let num_streams = if streams == "auto" {
        num_cpus().to_string()
    } else {
        streams.to_string()
    };
    sysfs::write_str(&format!("{}/max_comp_streams", zsys), &num_streams);

    // Set disk size
    let mem_bytes = crate::sysfs::read_mem_total_bytes();
    let disk_bytes = parse_zram_size(size_raw, mem_bytes);
    let disk_str = disk_bytes.to_string();
    if !sysfs::write_str(&format!("{}/disksize", zsys), &disk_str) {
        sysfs::log_to_file("!", &format!("failed to set disksize={}", disk_str));
        return false;
    }

    // Wait for device to appear
    if !wait_for_device(&zdev, 2000) {
        sysfs::log_to_file("!", &format!("{} did not appear after disksize set", zdev));
        return false;
    }

    // Format with mkswap
    let output = std::process::Command::new("mkswap").arg(&zdev).output();
    match output {
        Ok(o) if !o.status.success() => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            sysfs::log_to_file("!", &format!("mkswap failed: {}", stderr));
            return false;
        }
        Err(e) => {
            sysfs::log_to_file("!", &format!("mkswap exec failed: {}", e));
            return false;
        }
        _ => {}
    }

    // swapon with priority
    let output = std::process::Command::new("swapon")
        .arg(&zdev)
        .arg("-p")
        .arg(priority.to_string())
        .output();
    match output {
        Ok(o) if o.status.success() => {
            let disk_mb = disk_bytes / (1024 * 1024);
            sysfs::log_to_file("i", &format!(
                "zram configured: dev={} algo={} size={}MB streams={} priority={}",
                dev, selected, disk_mb, num_streams, priority
            ));
            // Save device info
            let _ = std::fs::write("/data/adb/modules/memoryopt_plus/zram_dev", dev);
            let _ = std::fs::write("/data/adb/modules/memoryopt_plus/.current_alg", &selected);
            true
        }
        Ok(o) => {
            let stderr = String::from_utf8_lossy(&o.stderr);
            sysfs::log_to_file("!", &format!("swapon failed: {}", stderr));
            false
        }
        Err(e) => {
            sysfs::log_to_file("!", &format!("swapon exec failed: {}", e));
            false
        }
    }
}

/// Read number of CPUs
fn num_cpus() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
}

/// Read current zram device from saved file
pub fn get_current_device() -> String {
    std::fs::read_to_string("/data/adb/modules/memoryopt_plus/zram_dev")
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| "zram0".to_string())
}

pub fn check_online() -> bool {
    let content = match std::fs::read_to_string("/proc/swaps") {
        Ok(c) => c,
        Err(_) => return false,
    };
    for line in content.lines().skip(1) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 3 && parts[0].contains("zram") && parts[1] == "zram" {
            return true;
        }
    }
    false
}

pub fn compression_ratio() -> Option<f64> {
    for entry in std::fs::read_dir("/sys/block").ok()? {
        let entry = entry.ok()?;
        let name = entry.file_name();
        let name = name.to_str()?;
        if !name.starts_with("zram") { continue; }
        let stat_path = entry.path().join("mm_stat");
        if let Ok(content) = std::fs::read_to_string(&stat_path) {
            let fields: Vec<u64> = content.split_whitespace().filter_map(|s| s.parse().ok()).collect();
            // fields[0] = original_data_size, fields[1] = compressed_data_size
            if fields.len() >= 2 && fields[0] > 0 && fields[1] > 1024 {
                return Some(fields[0] as f64 / fields[1] as f64);
            }
        }
    }
    None
}
