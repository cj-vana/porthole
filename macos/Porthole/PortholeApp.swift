import SwiftUI

@main
struct PortholeApp: App {
    var body: some Scene {
        WindowGroup {
            SessionView()
                .navigationTitle("Porthole")
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .defaultPosition(.center)
    }
}
