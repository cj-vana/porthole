import SwiftUI

/// Placeholder session screen: the Metal surface plus minimal floating chrome.
///
/// Seam (PRD US-006/US-013): the header will become the real auto-hiding
/// session toolbar, with machine name from Bonjour discovery, connection
/// state, display-mode and gaming-mode toggles. Nothing here knows about
/// networking.
struct SessionView: View {
    /// Target frame rate for the render surface (60/120/144), persisted across
    /// launches. Previews the per-machine streaming-rate setting the session
    /// toolbar will own (PRD US-013 gaming mode offers 60/120/144 fps).
    @AppStorage("targetFrameRate") private var targetFrameRate = 60

    var body: some View {
        ZStack(alignment: .top) {
            MetalSurfaceView(frameRate: targetFrameRate)

            header
                .padding(.top, 12)
        }
        .frame(minWidth: 960, minHeight: 600)
        .background(Color.black)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "dot.radiowaves.left.and.right")
            Text("Porthole")
                .font(.headline)
            Spacer()
            Picker("Frame rate", selection: $targetFrameRate) {
                Text("60").tag(60)
                Text("120").tag(120)
                Text("144").tag(144)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .help("Target frame rate (above 60 fps requires a ProMotion / high-refresh display)")
            Text("Test pattern · not connected")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(.horizontal, 16)
    }
}
