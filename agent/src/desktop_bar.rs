//! Reversible remote-desktop bar control.
//!
//! Omarchy keeps its Quickshell process alive and watches a `bar-off` state
//! flag. Using its supported toggle helper avoids a process restart, keeps
//! panel widgets intact, and makes hide/show effectively instantaneous.

use std::env;
use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use porthole_agent::protocol::{DesktopBarCommand, DesktopBarState};

const OMARCHY_TOGGLE: &str = "omarchy-toggle-bar";
const OMARCHY_FLAG: &str = ".local/state/omarchy/toggles/bar-off";

/// Apply a client's desired state and report the resulting state. Unsupported
/// desktops remain untouched and are reported explicitly to the client.
pub fn apply(command: DesktopBarCommand) -> DesktopBarState {
    let Some(executable) = find_executable(OMARCHY_TOGGLE) else {
        return DesktopBarState::Unavailable;
    };
    let Some(flag) = env::var_os("HOME")
        .map(PathBuf::from)
        .map(|home| home.join(OMARCHY_FLAG))
    else {
        return DesktopBarState::Unavailable;
    };

    let action = match command {
        DesktopBarCommand::Query => return state_from_flag(&flag),
        // `omarchy-toggle-bar` controls the `bar-off` flag: enabling that
        // flag hides the bar, while disabling it shows the bar.
        DesktopBarCommand::Show => "off",
        DesktopBarCommand::Hide => "on",
    };
    match Command::new(executable).arg(action).status() {
        Ok(status) if status.success() => state_from_flag(&flag),
        Ok(status) => {
            tracing::warn!(?status, action, "desktop bar command failed");
            DesktopBarState::Unavailable
        }
        Err(err) => {
            tracing::warn!(%err, action, "could not run desktop bar command");
            DesktopBarState::Unavailable
        }
    }
}

fn state_from_flag(flag: &Path) -> DesktopBarState {
    state_from_hidden(flag.is_file())
}

fn state_from_hidden(hidden: bool) -> DesktopBarState {
    if hidden {
        DesktopBarState::Hidden
    } else {
        DesktopBarState::Visible
    }
}

fn find_executable(name: &str) -> Option<PathBuf> {
    let system = [
        PathBuf::from("/usr/bin").join(name),
        PathBuf::from("/usr/local/bin").join(name),
    ];
    let path_candidates = env::var_os("PATH")
        .map(|value| {
            env::split_paths(&value)
                .map(|path| path.join(name))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    system.into_iter().chain(path_candidates).find(|path| {
        fs::metadata(path)
            .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hidden_flag_maps_to_reported_state() {
        assert_eq!(state_from_hidden(false), DesktopBarState::Visible);
        assert_eq!(state_from_hidden(true), DesktopBarState::Hidden);
    }
}
