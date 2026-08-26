import CoreVideo
import Foundation

/// The session's one decoder handle across codec changes (US-013): wraps
/// the active H264Decoder or HEVCDecoder and swaps it when a settings
/// request or a reconfigured hello moves the stream to the other codec.
/// Callbacks set here survive the swap. Threading contract matches the
/// wrapped decoders: one serial queue for everything.
final class CodecSwitchingDecoder: VideoDecoder {
    var onFrameDecoded: ((CVPixelBuffer, UInt64) -> Void)? {
        didSet { active.onFrameDecoded = onFrameDecoded }
    }
    var onFailure: ((String) -> Void)? {
        didSet { active.onFailure = onFailure }
    }
    var onSessionRebuilt: ((ColorState, _ width: Int, _ height: Int) -> Void)? {
        didSet { active.onSessionRebuilt = onSessionRebuilt }
    }

    private(set) var codec: Hello.Codec = .h264
    private var active: VideoDecoder = H264Decoder()

    var colorState: ColorState { active.colorState }
    var isReady: Bool { active.isReady }
    var lastDecodeMilliseconds: Double { active.lastDecodeMilliseconds }
    var lastPrepareMilliseconds: Double { active.lastPrepareMilliseconds }

    /// Swap decoders when `codec` differs from the active one. Returns true
    /// on a swap; the caller then owes the stream a fresh IDR, because
    /// nothing decoded so far helps the new decoder.
    @discardableResult
    func select(_ codec: Hello.Codec) -> Bool {
        guard codec != self.codec else { return false }
        active.invalidate()
        active = codec == .hevc ? HEVCDecoder() : H264Decoder()
        self.codec = codec
        active.onFrameDecoded = onFrameDecoded
        active.onFailure = onFailure
        active.onSessionRebuilt = onSessionRebuilt
        return true
    }

    @discardableResult
    func decode(accessUnit: Data, timestampMicros: UInt64) -> Bool {
        active.decode(accessUnit: accessUnit, timestampMicros: timestampMicros)
    }

    func invalidate() {
        active.invalidate()
    }
}
