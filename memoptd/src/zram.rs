pub fn check_online() -> bool {
    let content = match std::fs::read_to_string("/proc/swaps") {
        Ok(c) => c,
        Err(_) => return false,
    };
    for line in content.lines().skip(1) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() >= 3 && parts[0].contains("zram") && parts[1] != "partition" {
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
            if fields.len() >= 2 && fields[0] > 0 {
                return Some(fields[0] as f64 / fields[1] as f64);
            }
        }
    }
    None
}
