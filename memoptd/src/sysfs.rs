use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::sync::OnceLock;

static LOG_FILE: OnceLock<std::sync::Mutex<Option<std::fs::File>>> = OnceLock::new();

fn get_log() -> &'static std::sync::Mutex<Option<std::fs::File>> {
    LOG_FILE.get_or_init(|| std::sync::Mutex::new(None))
}

pub fn init_log(log_path: &std::path::Path) {
    if let Ok(f) = std::fs::OpenOptions::new().create(true).append(true).open(log_path) {
        *get_log().lock().unwrap() = Some(f);
    }
}

pub fn log_to_file(level: &str, msg: &str) {
    let guard = get_log().lock().unwrap();
    if let Some(ref f) = *guard {
        let ts = chrono_timestamp();
        let _ = writeln!(f, "[{}] - [{}]: {}", ts, level, msg);
        let _ = f.flush();
    }
}

fn chrono_timestamp() -> String {
    let secs = unsafe { libc::time(std::ptr::null_mut()) };
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&secs, &mut tm); }
    format!("{:02}-{:02} {:02}:{:02}:{:02}",
        tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec)
}

pub fn write_str(path: &str, value: &str) -> bool {
    match open_write(path) {
        Ok(mut f) => { let _ = f.write_all(value.as_bytes()); true }
        Err(_) => {
            let orig = std::fs::metadata(path).map(|m| m.permissions()).ok();
            let _ = std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o644));
            let ok = open_write(path).map(|mut f| f.write_all(value.as_bytes()).is_ok()).unwrap_or(false);
            if let Some(orig) = orig { let _ = std::fs::set_permissions(path, orig); }
            ok
        }
    }
}

pub fn read_i64(path: &str) -> Result<i64, ()> {
    let mut buf = [0u8; 32];
    let mut f = std::fs::File::open(path).map_err(|_| ())?;
    let n = f.read(&mut buf).map_err(|_| ())?;
    std::str::from_utf8(&buf[..n]).map_err(|_| ())?.trim().parse().map_err(|_| ())
}

fn open_write(path: &str) -> std::io::Result<std::fs::File> {
    OpenOptions::new().write(true).custom_flags(libc::O_WRONLY).open(path)
}

pub fn read_mem_total_bytes() -> u64 {
    std::fs::read_to_string("/proc/meminfo")
        .ok()
        .and_then(|c| {
            c.lines().find(|l| l.starts_with("MemTotal:"))
                .and_then(|l| l.split_whitespace().nth(1))
                .and_then(|s| s.parse::<u64>().ok())
                .map(|kb| kb * 1024)
        })
        .unwrap_or(4u64 * 1024 * 1024 * 1024)
}
