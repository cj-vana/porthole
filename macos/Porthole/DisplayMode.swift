import Foundation

/// US-010 display modes for the session surface.
///
/// Persisted per machine in UserDefaults (keyed by machine id) rather than
/// as a field on Machine: the picker hands SessionView a Machine value, and
/// rewriting machines.json plus activeSessionMachine for a view preference
/// would ripple a disconnect/reconnect through onChange(of: machine).
enum DisplayMode: String, CaseIterable, Identifiable {
    /// Adapt the remote virtual display to the window and aspect-fit it.
    case fit
    /// Native macOS fullscreen in its own Space, also source-size adaptive.
    case fullscreen

    var id: String { rawValue }

    /// Segmented-control label.
    var label: String {
        switch self {
        case .fit: return "Fit"
        case .fullscreen: return "Full"
        }
    }

    static func stored(forMachine id: String) -> DisplayMode {
        UserDefaults.standard.string(forKey: key(id)).flatMap(DisplayMode.init) ?? .fit
    }

    func store(forMachine id: String) {
        UserDefaults.standard.set(rawValue, forKey: Self.key(id))
    }

    private static func key(_ id: String) -> String {
        "displayMode.\(id)"
    }
}
