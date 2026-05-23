use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::sync::Mutex;

static mut LOG_FILE: Option<std::fs::File> = None;
static LOG_MUTEX: Mutex<()> = Mutex::new(());

pub fn init_log(log_path: &std::path::Path) {
    if let Ok(f) = std::fs::OpenOptions::new().create(true).append(true).open(log_path) {
        unsafe { LOG_FILE = Some(f); }
    }
}

pub fn log_to_file(level: &str, msg: &str) {
    let _guard = LOG_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(ref mut f) = unsafe { LOG_FILE.as_mut() } {
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
