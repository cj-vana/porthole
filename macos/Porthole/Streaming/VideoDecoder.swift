import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Color conversion state for the renderer. The H.264 decoder derives it
/// from the SPS VUI; the HEVC decoder skips VUI parsing and uses the PRD
/// defaults (BT.709 limited range for HD, BT.601 below).
struct ColorState: Equatable {
    var matrix: H264SPS.ColorMatrix
    var fullRange: Bool
}

/// One hardware video decoder: complete Annex B access units in, decoded
/// CVPixelBuffers out through `onFrameDecoded`. All entry points must be
/// called from one serial queue (StreamSession's decode queue); decoding is
/// synchronous per access unit.
protocol VideoDecoder: AnyObject {
    /// Decoded image + capture timestamp in microseconds. Called on the
    /// caller's queue, presentation order handled by VideoToolbox.
    var onFrameDecoded: ((CVPixelBuffer, UInt64) -> Void)? { get set }
    /// Decode-fatal failure (malformed stream, dead session). The session
    /// layer should request a keyframe.
    var onFailure: ((String) -> Void)? { get set }
    /// Parameter sets changed and a fresh decode session is now active.
    var onSessionRebuilt: ((ColorState, _ width: Int, _ height: Int) -> Void)? { get set }

    var colorState: ColorState { get }
    /// False until parameter sets have produced a decode session.
    var isReady: Bool { get }
    /// Decode wall time of the last submitted access unit, in milliseconds.
    var lastDecodeMilliseconds: Double { get }

    /// Submit one complete Annex B access unit. Returns false when no
    /// decode session exists yet (keep waiting for an IDR that carries
    /// parameter sets, or request another keyframe) or the submit failed.
    @discardableResult
    func decode(accessUnit: Data, timestampMicros: UInt64) -> Bool
    /// Drop the decode session. The next access unit carrying parameter
    /// sets builds a fresh one.
    func invalidate()
}

extension VideoDecoder {
    /// Shared tail of a decode submit: map the VideoToolbox status onto the
    /// decode() convention, invalidating a session that cannot recover so
    /// fresh parameter sets rebuild it.
    func finishSubmit(_ status: OSStatus) -> Bool {
        switch status {
        case noErr:
            return true
        case kVTInvalidSessionErr, kVTVideoDecoderMalfunctionErr:
            invalidate()
            onFailure?("decode session died (status \(status)); will rebuild")
        case kVTVideoDecoderReferenceMissingErr:
            onFailure?("reference frame missing (status \(status))")
        default:
            onFailure?("decode error (status \(status))")
        }
        return false
    }
}

/// Receives VTDecompressionSession output on behalf of a decoder. A
/// separate object so both decoders can share one C callback: the refCon
/// has to be cast back to a concrete class, and this is that class.
final class VTOutputSink {
    var onFrame: ((CVPixelBuffer, UInt64) -> Void)?
    var onStatusError: ((OSStatus) -> Void)?
}

// VTDecompressionOutputCallback's parameter list is fixed by VideoToolbox.
// swiftlint:disable:next function_parameter_count
private func vtOutputCallback(refCon: UnsafeMutableRawPointer?,
                              frameRefCon _: UnsafeMutableRawPointer?,
                              status: OSStatus,
                              infoFlags _: VTDecodeInfoFlags,
                              imageBuffer: CVImageBuffer?,
                              presentationTimeStamp: CMTime,
                              presentationDuration _: CMTime) {
    guard let refCon else { return }
    let sink = Unmanaged<VTOutputSink>.fromOpaque(refCon).takeUnretainedValue()
    guard status == noErr, let imageBuffer else {
        sink.onStatusError?(status)
        return
    }
    let micros = UInt64(max(0, CMTimeGetSeconds(presentationTimeStamp)) * 1_000_000)
    sink.onFrame?(imageBuffer, micros)
}

/// VideoToolbox mechanics shared by H264Decoder and HEVCDecoder: session
/// creation, AVCC sample buffers, and the synchronous submit that keeps
/// the decode-time figure honest.
enum VTDecode {
    /// Create a decompression session that outputs NV12 pixel buffers into
    /// `sink`. The sink must outlive the session; both decoders own theirs
    /// and invalidate the session first.
    static func makeSession(formatDescription: CMVideoFormatDescription,
                            width: Int,
                            height: Int,
                            fullRange: Bool,
                            sink: VTOutputSink) -> (VTDecompressionSession?, OSStatus) {
        let pixelFormat = fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: vtOutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(sink).toOpaque()
        )
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )
        return (session, status)
    }

    /// Assemble a CMSampleBuffer wrapping one access unit in AVCC form.
    static func makeSampleBuffer(payload: Data,
                                 formatDescription: CMVideoFormatDescription,
                                 timestampMicros: UInt64) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        // memoryBlock nil + default allocator: CoreMedia allocates and owns
        // the storage; the payload bytes are then copied in.
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: payload.count,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: payload.count,
                                                 flags: 0,
                                                 blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer else {
            return nil
        }
        let copyStatus = payload.withUnsafeBytes { raw in
            raw.baseAddress.map {
                CMBlockBufferReplaceDataBytes(with: $0,
                                              blockBuffer: blockBuffer,
                                              offsetIntoDestination: 0,
                                              dataLength: raw.count)
            }
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(timestampMicros), timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                               dataBuffer: blockBuffer,
                                               formatDescription: formatDescription,
                                               sampleCount: 1,
                                               sampleTimingEntryCount: 1,
                                               sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 0,
                                               sampleSizeArray: nil,
                                               sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    /// Decode one sample buffer synchronously, timing the wait: ordered
    /// output, natural backpressure, and an honest decode_ms.
    static func submit(_ sampleBuffer: CMSampleBuffer,
                       to session: VTDecompressionSession) -> (status: OSStatus, milliseconds: Double) {
        let started = ContinuousClock.now
        var flagsOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session,
                                                       sampleBuffer: sampleBuffer,
                                                       flags: [],
                                                       frameRefcon: nil,
                                                       infoFlagsOut: &flagsOut)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let elapsed = ContinuousClock.now - started
        let milliseconds = Double(elapsed.components.seconds) * 1e3
            + Double(elapsed.components.attoseconds) / 1e15
        return (status, milliseconds)
    }
}
