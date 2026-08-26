import Foundation

/// The stream configurations the client asks for over the settings message
/// (US-013). Two presets: quality is the connect-time default, gaming
/// trades bitrate-per-frame for motion clarity and encoder latency.
struct StreamSettings: Equatable {
    var fps: UInt16
    var codec: Hello.Codec
    var bitrateMbps: UInt16
    var lowLatency: Bool

    static let quality = StreamSettings(fps: 60, codec: .h264, bitrateMbps: 40, lowLatency: false)

    static func gaming(fps: Int) -> StreamSettings {
        // 60 Mbps HEVC is ample for 1440p while keeping 144 Hz packet and IDR
        // bursts below the client receive/decode saturation point. The former
        // 80 Mbps CBR target spent bandwidth on filler and increased latency.
        StreamSettings(fps: UInt16(clamping: fps), codec: .hevc, bitrateMbps: 60, lowLatency: true)
    }

    /// What the persisted chrome toggles ask for. SessionView owns the same
    /// keys through @AppStorage; an unset rate means the 144 default.
    static func stored(defaults: UserDefaults = .standard) -> StreamSettings {
        guard defaults.bool(forKey: "gamingMode") else { return .quality }
        let fps = defaults.integer(forKey: "gamingFps")
        return .gaming(fps: fps == 0 ? 144 : fps)
    }

    /// Whether a hello already describes this configuration, so a matching
    /// stream is not restarted for nothing. low_latency is not echoed in
    /// hello and cannot be compared.
    func matches(_ hello: Hello) -> Bool {
        hello.fps == UInt32(fps) && hello.codec == codec && hello.bitrateMbps == UInt32(bitrateMbps)
    }
}
