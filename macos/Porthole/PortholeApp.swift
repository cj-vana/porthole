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
        // Home: the machine picker (US-007).
        WindowGroup("Porthole", id: "picker") {
            PickerView()
                .environmentObject(store)
                .frame(minWidth: 780, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 920, height: 640)
        .defaultPosition(.center)

        // The one session window; content follows store.activeSessionMachine.
        WindowGroup(id: "session") {
            SessionWindowContent()
                .environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .defaultPosition(.center)
    }
}

/// Session window body: shows the machine the picker last opened.
private struct SessionWindowContent: View {
    @EnvironmentObject private var store: MachineStore
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if let machine = store.activeSessionMachine {
            SessionView(machine: machine)
        } else {
            // Only window restoration reaches this branch (after a crash or
            // a kill, macOS reopens the session window before the picker
            // has chosen a machine); an empty session window would sit on
            // top of the picker and eat the first click.
            Color.black
                .onAppear { dismissWindow(id: "session") }
        }
    }
}
