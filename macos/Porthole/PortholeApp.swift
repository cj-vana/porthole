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
        // A singleton Window, not a WindowGroup: auto-reconnect and window
        // restoration can both ask to open it during launch. WindowGroup
        // created two StreamSessions, which fought over the same UDP port and
        // made the agent replace one live client with the other.
        //
        // Keep this scene first. SwiftUI assigns a secondary singleton Window
        // the auxiliary window-manager role, which disables native fullscreen;
        // a first Window is principal. When no machine is active its content
        // immediately opens the picker before closing this empty window.
        Window("Porthole Session", id: "session") {
            SessionWindowContent()
                .environmentObject(store)
                .sessionFullscreenEnabled()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .defaultPosition(.center)

        // Home: the machine picker (US-007).
        WindowGroup("Porthole", id: "picker") {
            PickerView()
                .environmentObject(store)
                .frame(minWidth: 780, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 640)
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

/// Session window body: shows the machine the picker last opened.
private struct SessionWindowContent: View {
    @EnvironmentObject private var store: MachineStore
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let machine = store.activeSessionMachine {
            SessionView(machine: machine)
        } else {
            // The principal scene opens here on a cold launch. Hand off to the
            // picker; its auto-reconnect path will reopen this singleton after
            // selecting the remembered machine.
            Color.black
                .onAppear {
                    openWindow(id: "picker")
                    dismissWindow(id: "session")
                }
        }
    }
}
