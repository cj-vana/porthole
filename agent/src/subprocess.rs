//! Linux subprocess lifecycle helpers.
//!
//! The agent is commonly restarted by a service manager with SIGTERM. Rust
//! does not unwind on that signal, so `Child::drop` and module-specific Drop
//! implementations cannot be the only cleanup mechanism. Long-running media
//! and clipboard helpers inherit a kernel parent-death signal here instead.

#[cfg(target_os = "linux")]
use std::os::unix::process::CommandExt;
#[cfg(target_os = "linux")]
use std::process::Command;

/// Make `command` receive SIGKILL if the current agent process disappears.
///
/// `PR_SET_PDEATHSIG` is set in the child after `fork`; checking the captured
/// parent PID immediately afterward closes the fork-to-prctl race where the
/// parent could die before the child installs the signal.
#[cfg(target_os = "linux")]
pub fn die_with_parent(command: &mut Command) {
    let parent_pid = unsafe { libc::getpid() };
    unsafe {
        command.pre_exec(move || {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGKILL) == -1 {
                return Err(std::io::Error::last_os_error());
            }
            if libc::getppid() != parent_pid {
                return Err(std::io::Error::from_raw_os_error(libc::ESRCH));
            }
            Ok(())
        });
    }
}
