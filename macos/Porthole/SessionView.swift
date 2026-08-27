import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Session screen: the Metal surface plus floating chrome (US-005, US-006,
/// US-010, US-013). Opened from the picker for a specific machine and
/// connects immediately; the host field stays editable while disconnected
/// as the manual escape hatch (mDNS is link-local, so a Tailscale-only
/// machine still needs an address typed).
struct SessionView: View {
    @EnvironmentObject private var store: MachineStore
    /// Target frame rate for the render surface, persisted across launches:
    /// 0 is Auto (the screen's maximum refresh rate), else 60/120/144.
    @AppStorage("targetFrameRate") private var targetFrameRate = 0
    /// When off, shortcuts stay with macOS. When on, an Accessibility-backed
    /// event tap captures the focused surface's keyboard before system hotkeys.
    @AppStorage("sendSystemShortcuts") private var sendSystemShortcuts = false
    /// Pointer lock: hides the local cursor and sends relative motion for
    /// games and 3D apps. Esc releases it.
    @AppStorage("pointerLock") private var pointerLock = false
    /// Gaming mode (US-013): high-rate low-latency HEVC stream.
    @AppStorage("gamingMode") private var gamingMode = false
    /// The gaming-mode capture ceiling. VFR can deliver fewer real source
    /// frames when the compositor has no changed buffer to send.
    @AppStorage("gamingFps") private var gamingFps = 288
    /// Latency HUD over the stream (US-013).
    @AppStorage("statsOverlay") private var statsOverlay = false
    /// Remote audio playback level, 0 to 1 (US-009).
    @AppStorage("audioVolume") private var audioVolume = 0.8
    /// Mutes remote audio while keeping the slider position.
    @AppStorage("audioMuted") private var audioMuted = false
    /// Two-way clipboard text sync (US-008); off pauses without disconnecting.
    @AppStorage("clipboardSync") private var clipboardSync = true

    let machine: Machine
    @State private var host: String
    /// US-010 display mode, persisted per machine.
    @State private var displayMode: DisplayMode
    /// The window notification is authoritative. A persisted fullscreen
    /// preference can exist briefly (or fail to apply) while the window is
    /// not actually fullscreen; hiding chrome from preference alone would
    /// leave no local escape hatch.
    @State private var isNativeFullscreen = false
    /// Manual chrome collapse is intentionally not persisted: every new
    /// session starts with an obvious local control surface.
    @State private var controlsHidden = false
    @State private var shortcutCapturePermissionRequired = false
    @StateObject private var session = StreamSession()
    /// Drag-and-drop file transfers to the connected machine (US-011).
    @StateObject private var transfers = FileTransferList()

    init(machine: Machine) {
        self.machine = machine
        _host = State(initialValue: machine.host)
        _displayMode = State(initialValue: DisplayMode.stored(forMachine: machine.id))
    }

    var body: some View {
        ZStack(alignment: .top) {
            MetalSurfaceView(frameRate: targetFrameRate,
                             lowLatency: gamingMode,
                             pointerLocked: session.pointerLockActive,
                             displayMode: displayMode,
                             renderer: session.renderer,
                             input: session.input,
                             onFullscreenChanged: syncFullscreen,
                             onViewportSizeChanged: session.setRemoteDisplaySize)
                .id(session.surfaceGeneration)

            if controlsHidden, !exclusiveGamingSurface {
                revealControlsButton
            } else if !exclusiveGamingSurface {
                VStack(spacing: 8) {
                    statusBar
                    controlBar
                }
                .padding(.top, 12)
            }
        }
        .overlay(alignment: .topTrailing) {
            if statsOverlay, case .live = session.state, !exclusiveGamingSurface {
                StatsHUD(stats: session.latency)
                    .padding(.top, controlsHidden ? 16 : 124)
                    .padding(.trailing, 16)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !exclusiveGamingSurface {
                FileTransferOverlay(transfers: transfers)
                    .padding(16)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .frame(minWidth: 1100, minHeight: 600)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .navigationTitle(machine.name)
        .onAppear {
            applySystemShortcutSetting(sendSystemShortcuts)
            session.input.wantsPointerLock = pointerLock
            session.audio.setVolume(Float(audioVolume))
            session.audio.setMuted(audioMuted)
            session.setClipboardSync(clipboardSync)
            if !session.isConnected, !host.isEmpty {
                connect()
            }
        }
        .onDisappear {
            session.disconnect()
        }
        .onChange(of: clipboardSync) { _, enabled in
            session.setClipboardSync(enabled)
        }
        .onChange(of: audioVolume) { _, volume in
            session.audio.setVolume(Float(volume))
        }
        .onChange(of: audioMuted) { _, muted in
            session.audio.setMuted(muted)
        }
        .onChange(of: sendSystemShortcuts) { _, newValue in
            applySystemShortcutSetting(newValue)
        }
        .onChange(of: pointerLock) { _, newValue in
            session.input.wantsPointerLock = newValue
        }
        .onChange(of: gamingMode) { _, enabled in
            session.setGamingMode(enabled, fps: gamingFps)
        }
        .onChange(of: gamingFps) { _, fps in
            if gamingMode {
                session.setGamingMode(true, fps: fps)
            }
        }
        .onChange(of: displayMode) { _, mode in
            mode.store(forMachine: machine.id)
        }
        // Esc released the lock; the controller clears the stored toggle.
        .onChange(of: session.pointerLockActive) { _, active in
            if !active, pointerLock {
                pointerLock = false
            }
        }
        // The single session window was pointed at a different machine:
        // drop the old session and connect to the new one.
        .onChange(of: machine) { _, newMachine in
            session.disconnect()
            host = newMachine.host
            displayMode = DisplayMode.stored(forMachine: newMachine.id)
            controlsHidden = false
            connect()
        }
        .alert("Allow Shortcut Capture",
               isPresented: $shortcutCapturePermissionRequired) {
            Button("Open System Settings") {
                openAccessibilitySettings()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("Enable Porthole in Privacy & Security > Accessibility, then turn Shortcuts on again.")
        }
    }

    /// A fullscreen gaming frame should be one opaque Metal surface. The
    /// translucent SwiftUI chrome and HUD force WindowServer composition on
    /// every frame; Escape exits native fullscreen and brings the controls
    /// back, so the fastest path can stay visually clean without trapping the
    /// user.
    private var exclusiveGamingSurface: Bool {
        gamingMode && isNativeFullscreen
    }

    /// Fullscreen moves started by the window itself (green button, exit
    /// gesture) keep the mode picker and the per-machine setting true.
    private func syncFullscreen(_ entered: Bool) {
        isNativeFullscreen = entered
        if entered != (displayMode == .fullscreen) {
            displayMode = entered ? .fullscreen : .fit
        }
    }

    private func applySystemShortcutSetting(_ enabled: Bool) {
        guard session.input.setSystemShortcutCaptureEnabled(enabled) else {
            sendSystemShortcuts = false
            shortcutCapturePermissionRequired = true
            return
        }
    }

    private func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text(machine.name)
                .font(.headline)
            Button("Machines") {
                store.activeSessionMachine = nil
            }
            .help("Return to the machine picker")
            Spacer()
            if session.pointerLockActive {
                Label("pointer locked", systemImage: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            } else if session.inputCaptured {
                Label("input captured", systemImage: "circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            Text(statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
            if case .live = session.state {
                Text(session.latency.summary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("Capture to pixels on screen, and control round trip; n/a until the agent answers a ping")
            }
            TextField("host", text: $host)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .disabled(session.isConnected)
            Button(session.isConnected ? "Disconnect" : "Connect") {
                if session.isConnected {
                    session.disconnect()
                } else {
                    connect()
                }
            }
            .disabled(host.isEmpty)
            Button {
                controlsHidden = true
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("Hide Porthole controls")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
    }

    private var controlBar: some View {
        HStack(spacing: 10) {
            Picker("Display mode", selection: $displayMode) {
                ForEach(DisplayMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Fit adapts the Linux display to this window; Full adapts it to native fullscreen")
            Picker("Local display", selection: $targetFrameRate) {
                Text("Auto").tag(0)
                Text("60 Hz").tag(60)
                Text("120 Hz").tag(120)
                Text("144 Hz").tag(144)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Auto follows the screen; Gaming phase-locks presentation to its native cadence")
            Toggle("Gaming", isOn: $gamingMode)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("High-rate HEVC with the encoder biased toward latency; off returns to a 60 fps H.264 ceiling")
            if gamingMode {
                Picker("Capture ceiling", selection: $gamingFps) {
                    Text("Max 120").tag(120)
                    Text("Max 144").tag(144)
                    Text("Max 180").tag(180)
                    Text("Max 288").tag(288)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("A ceiling, not a promise: VFR sends only real compositor frames; Stats shows delivered rates")
            }
            Toggle("Stats", isOn: $statsOverlay)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Latency HUD over the stream")
            Toggle("Shortcuts", isOn: $sendSystemShortcuts)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Capture keyboard shortcuts for the remote machine (requires Accessibility)")
            Toggle("Pointer lock", isOn: $pointerLock)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Relative mouse mode for games; Esc releases")
            Toggle("Clipboard", isOn: $clipboardSync)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Sync copied text with the remote machine")
            audioControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial, in: Capsule())
    }

    /// Remote audio (US-009): mute plus a compact volume slider.
    private var audioControls: some View {
        HStack(spacing: 6) {
            Button {
                audioMuted.toggle()
            } label: {
                Image(systemName: audioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(audioMuted ? "Unmute remote audio" : "Mute remote audio")
            Slider(value: $audioVolume, in: 0...1)
                .controlSize(.mini)
                .frame(width: 70)
                .disabled(audioMuted)
                .help("Remote audio volume")
        }
    }

    /// A visible, pointer-operable escape hatch even when Shortcuts captures
    /// every local key chord. Exclusive fullscreen gaming intentionally omits
    /// it; unmodified Escape exits that mode without compositor overlay cost.
    private var revealControlsButton: some View {
        Button {
            controlsHidden = false
        } label: {
            Image(systemName: "chevron.down")
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        .help("Show Porthole controls")
    }

    /// Files dropped on the session window transfer to the connected
    /// machine (US-011). Gated on the live state: only then is
    /// connectedHost the candidate that actually answered, rather than
    /// whichever one the dial walker is currently trying.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard case .live = session.state, let host = session.connectedHost else { return false }
        var accepted = false
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                // Providers hand the URL back as its bookmark-style data
                // representation; the direct URL cast is the fallback.
                let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    ?? item as? URL
                guard let url, url.isFileURL else { return }
                DispatchQueue.main.async { transfers.send(url: url, host: host) }
            }
        }
        return accepted
    }

    /// Unedited host field: use the machine's address candidates (LAN first,
    /// name fallback). An edited field dials exactly what was typed.
    private func connect() {
        if host == machine.host {
            session.connect(machine: machine)
        } else {
            session.connect(host: host, controlPort: machine.controlPort)
        }
    }

    private var statusText: String {
        switch session.state {
        case .disconnected:
            return session.lastError ?? "Not connected"
        case .connecting:
            return "Connecting..."
        case .waitingForKeyframe:
            return "Waiting for keyframe..."
        case .live(let width, let height, let fps):
            return "Live \(width)x\(height) · cap ≤\(fps) fps"
        }
    }
}

/// US-013 stats overlay: the per-second pipeline figures as a compact HUD
/// over the stream. Each value prints n/a until its source has reported
/// (the first decoded second, an agent_stats message, or a pong for the
/// network estimate).
private struct StatsHUD: View {
    let stats: LatencyStats

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
            row("source fps", stats.sourceFps.map(String.init))
            row("encoded fps", stats.encodedFps.map(String.init))
            row("decoded fps", stats.decodedFps.map(String.init))
            row("presented fps", stats.presentedFps.map(String.init))
            row("present", milliseconds(stats.capturePresentMs))
            row("encode", milliseconds(stats.encodeMs))
            row("network", milliseconds(stats.networkMs))
            row("decode", milliseconds(stats.decodeMs))
            row("loss", stats.lossPercent.map { String(format: "%.1f%%", $0) })
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .help("Per-second stage latencies; network is half the control round trip (one-way estimate)")
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value ?? "n/a")
                .gridColumnAlignment(.trailing)
        }
    }

    private func milliseconds(_ value: Double?) -> String? {
        value.map { String(format: "%.1f ms", $0) }
    }
}
