use std::collections::HashMap;
use std::path::Path;

#[derive(Debug)]
pub struct Config { raw: HashMap<String, String> }

#[derive(Debug, Clone)]
pub struct Locks {
    pub swappiness: i64,
    pub dirty_bg: i64,
    pub dirty: i64,
    pub vfs_cache: i64,
    pub watermark: i64,
    pub compaction: i64,
    pub overcommit: i64,
    pub page_cluster: i64,
    pub extra_free: String,
    pub dirty_expire: i64,
    pub dirty_writeback: i64,
    pub watch_interval: u64,
    pub _enable: bool,
}

impl Config {
    pub fn from_file(path: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        let content = std::fs::read_to_string(path)?;
        let mut raw = HashMap::new();
        for line in content.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') { continue; }
            if let Some(eq) = line.find('=') {
                let key = line[..eq].trim().to_string();
                let val = line[eq + 1..].split('#').next().unwrap_or("").trim().to_string();
                if !key.is_empty() { raw.insert(key, val); }
            }
        }
        Ok(Self { raw })
    }
    pub fn get(&self, key: &str) -> Option<&str> { self.raw.get(key).map(|s| s.as_str()) }
    pub fn get_num(&self, key: &str, default: i64) -> i64 {
        self.get(key).and_then(|v| v.parse().ok()).unwrap_or(default)
    }
    pub fn get_true(&self, key: &str) -> bool { self.get(key).map(|v| v == "true").unwrap_or(false) }
}

impl Locks {
    pub fn from_config(cfg: &Config) -> Self {
        let sw = cfg.get_num("swappiness", 130);
        let dbr = cfg.get_num("dirty_background_ratio", 2);
        let dr = cfg.get_num("dirty_ratio", 5);
        let (dbr, dr) = if dbr >= dr { ((dr / 2).max(1), dr) } else { (dbr, dr) };
        let page_cluster = match cfg.get("page_cluster") {
            Some("auto") | None => {
                let alg = cfg.get("algorithm").unwrap_or("lz4");
                if alg.starts_with("zstd") { 0 } else { 1 }
            }
            Some(v) => v.parse().unwrap_or(1),
        };
        Self {
            swappiness: sw.min(200).max(0),
            dirty_bg: dbr, dirty: dr,
            vfs_cache: cfg.get_num("vfs_cache_pressure", 125),
            watermark: cfg.get_num("watermark_scale_factor", 100),
            compaction: cfg.get_num("compaction_proactiveness", 20),
            overcommit: cfg.get_num("overcommit_memory", 1),
            page_cluster,
            extra_free: cfg.get("extra_free_kbytes").unwrap_or("auto").to_string(),
            dirty_expire: cfg.get_num("dirty_expire_centisecs", 1000),
            dirty_writeback: cfg.get_num("dirty_writeback_centisecs", 100),
            watch_interval: cfg.get_num("watch_interval", 5).max(1) as u64,
            _enable: cfg.get_true("enable"),
        }
    }
}
