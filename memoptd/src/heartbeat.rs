use crate::psi::MemoryPsi;
use std::io::Write;

pub struct Emitter { count: u64, path: String }

impl Emitter {
    pub fn new() -> Self {
        Self { count: 0, path: "/data/local/tmp/memoryopt_heartbeat.json".to_string() }
    }

    pub fn tick(&mut self, psi: &MemoryPsi, effective_swappiness: i64) {
        self.count += 1;
        if self.count % 60 == 0 { self.emit(psi, effective_swappiness); }
    }

    fn emit(&self, psi: &MemoryPsi, effective_swappiness: i64) {
        let ts = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        let zram_ratio = super::zram::compression_ratio()
            .map(|r| format!("{:.2}", r)).unwrap_or_else(|| "N/A".to_string());
        // Write JSON directly without serde_json dependency
        let json = format!(
            r#"{{"ts":{},"heartbeat":{},"swappiness":{},"psi":{{"some_avg10":"{:.2}","some_avg60":"{:.2}","full_avg10":"{:.2}","full_avg60":"{:.2}","total_mb":{}}},"zram_compression_ratio":"{}"}}"#,
            ts, self.count, effective_swappiness,
            psi.some_avg10, psi.some_avg60, psi.full_avg10, psi.full_avg60,
            psi.total_kb / 1024, zram_ratio
        );
        if let Ok(mut f) = std::fs::File::create(&self.path) {
            let _ = f.write_all(json.as_bytes());
            let _ = f.write_all(b"\n");
        }
    }
}
