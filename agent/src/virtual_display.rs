//! Virtual display management for headless operation (US-015).
//!
//! Hyprland-specific: shells out to `hyprctl`. When `virtual_display` is
//! configured and no physical output is attached (all outputs are FALLBACK
//! or HEADLESS), ensures a headless output exists at the configured geometry
//! and returns its name so capture can prefer it. Idempotent: an existing
//! headless output is reconfigured or reused, never duplicated.

use crate::config::VirtualDisplay;

/// Ensure a headless output at the configured geometry exists; returns the
/// output name capture should prefer, or None when the option is unset,
/// skipped (physical monitor attached), or setup failed (logged; capture
/// falls back to the first output).
#[cfg(target_os = "linux")]
pub fn ensure(requested: Option<VirtualDisplay>) -> Option<String> {
    imp::ensure(requested)
}

/// Match a configured headless output to a live stream rate. Physical
/// monitors are left untouched by the same safety check as startup setup.
#[cfg(target_os = "linux")]
pub fn match_stream_refresh(requested: Option<VirtualDisplay>, refresh_hz: u16) {
    let Some(mut display) = requested else { return };
    display.refresh_hz = u32::from(refresh_hz);
    let _ = imp::ensure(Some(display));
}

/// Ensure XDG_RUNTIME_DIR and WAYLAND_DISPLAY are set so the Wayland client
/// can connect even from a bare SSH shell or a minimal systemd unit. Values
/// already in the env win; otherwise derived from /run/user/<uid>/.
/// Must be called before the first Wayland connection.
#[cfg(target_os = "linux")]
pub fn ensure_session_env() {
    if std::env::var_os("XDG_RUNTIME_DIR").is_none() {
        // Safety: getuid has no memory-safety requirements.
        let dir = format!("/run/user/{}", unsafe { libc::getuid() });
        std::env::set_var("XDG_RUNTIME_DIR", dir);
    }
    if std::env::var_os("WAYLAND_DISPLAY").is_none() {
        let display = std::env::var("XDG_RUNTIME_DIR")
            .ok()
            .and_then(|dir| {
                std::fs::read_dir(dir)
                    .ok()?
                    .filter_map(Result::ok)
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .find(|n| n.starts_with("wayland-"))
            })
            .unwrap_or_else(|| "wayland-0".to_string());
        std::env::set_var("WAYLAND_DISPLAY", display);
    }
}

#[cfg(not(target_os = "linux"))]
pub fn ensure_session_env() {}

#[cfg(not(target_os = "linux"))]
pub fn ensure(requested: Option<VirtualDisplay>) -> Option<String> {
    if requested.is_some() {
        tracing::warn!("virtual_display is only supported on Linux with Hyprland; ignoring");
    }
    None
}

#[cfg(not(target_os = "linux"))]
pub fn match_stream_refresh(_requested: Option<VirtualDisplay>, _refresh_hz: u16) {}

#[cfg(target_os = "linux")]
mod imp {
    use std::collections::HashSet;
    use std::process::Command;
    use std::time::Duration;

    use anyhow::{bail, Context};
    use serde::Deserialize;

    use crate::config::VirtualDisplay;

    #[derive(Debug, Deserialize)]
    struct HyprMonitor {
        name: String,
        width: u32,
        height: u32,
        #[serde(rename = "refreshRate")]
        refresh_rate: f64,
        disabled: bool,
    }

    impl HyprMonitor {
        /// FALLBACK is Hyprland's placeholder when nothing is attached;
        /// HEADLESS-* are virtual. Anything else counts as physical.
        fn is_physical(&self) -> bool {
            !self.disabled && self.name != "FALLBACK" && !self.name.starts_with("HEADLESS")
        }

        fn is_headless(&self) -> bool {
            !self.disabled && self.name.starts_with("HEADLESS")
        }

        fn matches(&self, vd: &VirtualDisplay) -> bool {
            self.width == vd.width
                && self.height == vd.height
                && self.refresh_rate.round() as u32 == vd.refresh_hz
        }
    }

    /// Discover the Hyprland session environment: XDG_RUNTIME_DIR and
    /// HYPRLAND_INSTANCE_SIGNATURE from the process env first (systemd user
    /// service case), then derived from /run/user/<uid>/hypr/ (SSH case).
    fn session_env() -> (String, Option<String>) {
        let runtime_dir = std::env::var("XDG_RUNTIME_DIR").unwrap_or_else(|_| {
            // Safety: getuid has no memory-safety requirements.
            format!("/run/user/{}", unsafe { libc::getuid() })
        });
        let signature = std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
            .ok()
            .or_else(|| {
                std::fs::read_dir(format!("{runtime_dir}/hypr"))
                    .ok()?
                    .filter_map(Result::ok)
                    .find(|e| e.file_type().ok().is_some_and(|t| t.is_dir()))
                    .map(|e| e.file_name().to_string_lossy().into_owned())
            });
        (runtime_dir, signature)
    }

    fn hyprctl(
        args: &[&str],
        runtime_dir: &str,
        signature: Option<&str>,
    ) -> anyhow::Result<String> {
        let mut cmd = Command::new("hyprctl");
        cmd.args(args).env("XDG_RUNTIME_DIR", runtime_dir);
        if let Some(sig) = signature {
            cmd.env("HYPRLAND_INSTANCE_SIGNATURE", sig);
        }
        let out = cmd
            .output()
            .context("failed to run hyprctl (is Hyprland running?)")?;
        let stdout = String::from_utf8_lossy(&out.stdout).into_owned();
        // hyprctl reports failures on stdout and can still exit 0.
        if !out.status.success() || stdout.starts_with("error") {
            bail!(
                "hyprctl {} failed: {}{}",
                args.join(" "),
                stdout.trim(),
                String::from_utf8_lossy(&out.stderr).trim()
            );
        }
        Ok(stdout)
    }

    fn list_monitors(
        runtime_dir: &str,
        signature: Option<&str>,
    ) -> anyhow::Result<Vec<HyprMonitor>> {
        let out = hyprctl(&["monitors", "-j"], runtime_dir, signature)?;
        serde_json::from_str(&out).context("failed to parse hyprctl monitors output")
    }

    pub fn ensure(requested: Option<VirtualDisplay>) -> Option<String> {
        let vd = requested?;
        match ensure_inner(&vd) {
            Ok(name) => name,
            Err(err) => {
                tracing::error!("{err:#}: virtual display setup failed, continuing without it");
                None
            }
        }
    }

    fn ensure_inner(vd: &VirtualDisplay) -> anyhow::Result<Option<String>> {
        let (runtime_dir, signature) = session_env();
        let sig = signature.as_deref();
        let monitors = list_monitors(&runtime_dir, sig)?;

        let physical: Vec<&str> = monitors
            .iter()
            .filter(|m| m.is_physical())
            .map(|m| m.name.as_str())
            .collect();
        if !physical.is_empty() {
            tracing::info!(
                monitors = ?physical,
                "physical monitor(s) attached, leaving outputs alone; virtual_display not applied"
            );
            return Ok(None);
        }

        // Reuse a headless output already at the configured geometry.
        let headless: Vec<&HyprMonitor> = monitors.iter().filter(|m| m.is_headless()).collect();
        if let Some(m) = headless.iter().find(|m| m.matches(vd)) {
            tracing::info!(output = %m.name, geometry = %vd, "reusing existing headless output");
            return Ok(Some(m.name.clone()));
        }

        // Otherwise reconfigure an existing headless output, or create one.
        let name = if let Some(m) = headless.first() {
            tracing::info!(
                output = %m.name,
                current = format!("{}x{}@{:.0}", m.width, m.height, m.refresh_rate),
                target = %vd,
                "reconfiguring existing headless output"
            );
            m.name.clone()
        } else {
            let before: HashSet<&str> = monitors.iter().map(|m| m.name.as_str()).collect();
            let out = hyprctl(&["output", "create", "headless"], &runtime_dir, sig)?;
            if !out.trim().eq_ignore_ascii_case("ok") {
                bail!(
                    "hyprctl output create headless: unexpected reply {}",
                    out.trim()
                );
            }
            // Hyprland takes a beat before the new output shows in `monitors`.
            let mut created = None;
            for _ in 0..20 {
                std::thread::sleep(Duration::from_millis(100));
                let now = list_monitors(&runtime_dir, sig)?;
                if let Some(m) = now
                    .iter()
                    .find(|m| m.is_headless() && !before.contains(m.name.as_str()))
                {
                    created = Some(m.name.clone());
                    break;
                }
            }
            let name = created.context("headless output never appeared in hyprctl monitors")?;
            tracing::info!(output = %name, "created headless output");
            name
        };

        // Set the mode via Hyprland's Lua config API (hyprctl keyword is gone
        // with the non-legacy parser in Hyprland 0.55+).
        let rule = format!(
            r#"hl.monitor({{output = "{name}", mode = "{w}x{h}@{r}", position = "0x0", scale = 1}})"#,
            w = vd.width,
            h = vd.height,
            r = vd.refresh_hz,
        );
        hyprctl(&["eval", &rule], &runtime_dir, sig)?;

        // Verify the geometry actually applied before capture prefers it.
        for _ in 0..20 {
            std::thread::sleep(Duration::from_millis(100));
            let now = list_monitors(&runtime_dir, sig)?;
            if let Some(m) = now.iter().find(|m| m.name == name && m.matches(vd)) {
                tracing::info!(output = %m.name, geometry = %vd, "headless output ready");
                return Ok(Some(m.name.clone()));
            }
        }
        bail!("headless output {name} did not reach configured geometry {vd}")
    }
}
