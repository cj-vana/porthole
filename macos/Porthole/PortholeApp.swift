import SwiftUI

@main
struct PortholeApp: App {
    @StateObject private var store = MachineStore()

    init() {
        // Session lifecycle is managed explicitly (picker, auto-reconnect),
        // so macOS window restoration would only duplicate session windows.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    var body: some Scene {
        // One physical window owns both picker and session content. Separate
        // SwiftUI scenes instantiate independently during state restoration;
        // that previously left dozens of hidden picker windows in WindowServer
        // and raced the session's fullscreen transition.
        Window("Porthole", id: "main") {
            RootWindowContent()
                .environmentObject(store)
                .sessionFullscreenEnabled()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .defaultPosition(.center)
    }
}

private extension View {
    /// macOS 15 gives SwiftUI, rather than AppKit, the final say over whether
    /// a scene's window may enter fullscreen. Keep the macOS 14 AppKit bridge
    /// below while explicitly enabling the native behavior where available.
    @ViewBuilder
    func sessionFullscreenEnabled() -> some View {
        if #available(macOS 15.0, *) {
            windowFullScreenBehavior(.enabled)
        } else {
            self
        }
    }
}

/// The root switches content without replacing the AppKit window or its Metal
/// layer hierarchy, so auto-reconnect has exactly one fullscreen authority.
private struct RootWindowContent: View {
    @EnvironmentObject private var store: MachineStore

    var body: some View {
        if let machine = store.activeSessionMachine {
            SessionView(machine: machine)
        } else {
            PickerView()
                .frame(minWidth: 780, minHeight: 480)
        }
    }
}
