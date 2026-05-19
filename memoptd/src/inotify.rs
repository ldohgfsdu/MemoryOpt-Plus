use std::os::unix::io::{AsRawFd, RawFd};
use std::path::Path;

pub struct Watcher { fd: RawFd, wd: i32 }

impl Watcher {
    pub fn new(path: &Path) -> Result<Self, Box<dyn std::error::Error>> {
        let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK) };
        if fd < 0 { return Err("inotify_init1 failed".into()); }
        let target: &Path = if path.is_dir() { path } else { path.parent().unwrap_or(Path::new("/")) };
        let wd = unsafe {
            libc::inotify_add_watch(fd, target.as_os_str().as_encoded_bytes().as_ptr() as *const i8,
                                    libc::IN_MODIFY | libc::IN_CLOSE_WRITE | libc::IN_MOVED_TO)
        };
        if wd < 0 { unsafe { libc::close(fd); } return Err("inotify_add_watch failed".into()); }
        Ok(Self { fd, wd })
    }

    pub fn drain(&self) {
        let mut buf = [0u8; 4096];
        loop {
            if unsafe { libc::read(self.fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) } <= 0 { break; }
        }
    }
}

impl AsRawFd for Watcher { fn as_raw_fd(&self) -> RawFd { self.fd } }

impl Drop for Watcher {
    fn drop(&mut self) { unsafe { libc::inotify_rm_watch(self.fd, self.wd); libc::close(self.fd); } }
}
