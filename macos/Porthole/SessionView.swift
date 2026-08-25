import SwiftUI

/// Session screen: the Metal surface plus minimal floating chrome with a
/// host field, connect button, and input controls (US-006). The test pattern
/// idles behind the chrome until a stream goes live.
///
/// Seam (PRD US-013): the header will become the real auto-hiding session
/// toolbar, with machine name from Bonjour discovery, display-mode and
/// gaming-mode toggles. The host field goes away when the machine picker
/// lands (US-007/US-012).
struct SessionView: View {
    /// Target frame rate for the render surface (60/120/144), persisted across
    /// launches. Previews the per-machine streaming-rate setting the session
    /// toolbar will own (PRD US-013 gaming mode offers 60/120/144 fps).
    @AppStorage("targetFrameRate") private var targetFrameRate = 60
    /// Last connected host, persisted across launches (US-012 will own a
    /// proper machine list; this is the minimal US-005 affordance).
    @AppStorage("lastHost") private var lastHost = "100.105.41.71"
    /// When off, Cmd chords stay with macOS; when on, they forward to the
    /// remote machine best effort (Cmd+Tab and Spotlight's Cmd+Space are
    /// intercepted by macOS before the app sees them regardless).
    @AppStorage("sendSystemShortcuts") private var sendSystemShortcuts = false
    /// Pointer lock: hides the local cursor and sends relative motion for
    /// games and 3D apps. Esc releases it.
    @AppStorage("pointerLock") private var pointerLock = false

    @StateObject private var session = StreamSession()

    var body: some View {
        ZStack(alignment: .top) {
            MetalSurfaceView(frameRate: targetFrameRate,
                             renderer: session.renderer,
                             input: session.input)

            header
                .padding(.top, 12)
        }
        .frame(minWidth: 1100, minHeight: 600)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            session.input.sendSystemShortcuts = sendSystemShortcuts
            session.input.wantsPointerLock = pointerLock
            // Minimal auto-reconnect so a relaunch rejoins the last machine;
            // US-012 will make this a real setting.
            if !session.isConnected, !lastHost.isEmpty {
                session.connect(host: lastHost)
            }
        }
        .onChange(of: sendSystemShortcuts) { _, newValue in
            session.input.sendSystemShortcuts = newValue
        }
        .onChange(of: pointerLock) { _, newValue in
            session.input.wantsPointerLock = newValue
        }
        // Esc released the lock; the controller clears the stored toggle.
        .onChange(of: session.pointerLockActive) { _, active in
            if !active, pointerLock {
                pointerLock = false
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("Porthole")
                .font(.headline)
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
            Picker("Frame rate", selection: $targetFrameRate) {
                Text("60").tag(60)
                Text("120").tag(120)
                Text("144").tag(144)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Target frame rate (above 60 fps requires a ProMotion / high-refresh display)")
            Toggle("Shortcuts", isOn: $sendSystemShortcuts)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Forward Cmd chords to the remote machine (best effort; macOS keeps Cmd+Tab)")
            Toggle("Pointer lock", isOn: $pointerLock)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("Relative mouse mode for games; Esc releases")
            TextField("host", text: $lastHost)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .disabled(session.isConnected)
            Button(session.isConnected ? "Disconnect" : "Connect") {
                if session.isConnected {
                    session.disconnect()
                } else {
                    session.connect(host: lastHost)
                }
            }
            .disabled(lastHost.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
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
            return "Live \(width)x\(height)@\(fps)"
        }
    }
}
