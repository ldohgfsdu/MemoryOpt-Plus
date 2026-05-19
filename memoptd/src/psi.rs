use std::io::{BufRead, BufReader};

#[derive(Debug, Default, Clone)]
pub struct MemoryPsi {
    pub some_avg10: f64,
    pub some_avg60: f64,
    pub full_avg10: f64,
    pub full_avg60: f64,
    pub total_kb: u64,
}

pub fn read_memory_pressure() -> MemoryPsi {
    let mut psi = MemoryPsi::default();
    if let Ok(f) = std::fs::File::open("/proc/pressure/memory") {
        for line in BufReader::new(f).lines().flatten() {
            if line.starts_with("some") {
                psi.some_avg10 = extract_avg(&line, "avg10=");
                psi.some_avg60 = extract_avg(&line, "avg60=");
            } else if line.starts_with("full") {
                psi.full_avg10 = extract_avg(&line, "avg10=");
                psi.full_avg60 = extract_avg(&line, "avg60=");
            }
        }
    }
    if let Ok(content) = std::fs::read_to_string("/proc/meminfo") {
        for line in content.lines() {
            if line.starts_with("MemTotal:") {
                psi.total_kb = line.split_whitespace().nth(1).and_then(|s| s.parse().ok()).unwrap_or(0);
                break;
            }
        }
    }
    psi
}

fn extract_avg(line: &str, key: &str) -> f64 {
    line.find(key)
        .and_then(|i| line[i + key.len()..].split_whitespace().next())
        .and_then(|s| s.parse().ok())
        .unwrap_or(0.0)
}
