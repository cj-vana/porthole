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
    /// Annex B parsing and sample-buffer construction before decode submit.
    var lastPrepareMilliseconds: Double { get }

    /// Submit one complete access unit. Returns false when no
    /// decode session exists yet (keep waiting for an IDR that carries
    /// parameter sets, or request another keyframe) or the submit failed.
    @discardableResult
    func decode(accessUnit: Data,
                sampleFormat: AnnexB.SampleFormat,
                timestampMicros: UInt64) -> Bool
    /// Drop the decode session. The next access unit carrying parameter
    /// sets builds a fresh one.
    func invalidate()
}

extension VideoDecoder {
    /// Decode-test and file-input compatibility: recorded elementary streams
    /// are Annex B, while live reassembly supplies the faster in-place layout.
    @discardableResult
    func decode(accessUnit: Data, timestampMicros: UInt64) -> Bool {
        decode(accessUnit: accessUnit,
               sampleFormat: .annexB,
               timestampMicros: timestampMicros)
    }

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

    /// Assemble a CMSampleBuffer from Annex B without first materializing an
    /// AVCC `Data`. The CoreMedia block is the only destination allocation:
    /// NAL lengths and bytes are written into it in one pass, avoiding the
    /// old Annex B -> Data -> CMBlockBuffer double copy on every frame.
    static func makeSampleBuffer(accessUnit: Data,
                                 codec: AnnexB.Codec,
                                 nalUnits: [AnnexB.NALUnit],
                                 formatDescription: CMVideoFormatDescription,
                                 timestampMicros: UInt64) -> CMSampleBuffer? {
        let sampleUnits = nalUnits.filter { $0.type != codec.audType }
        guard !sampleUnits.isEmpty else { return nil }

        var payloadLength = 0
        for unit in sampleUnits {
            guard unit.range.count <= Int(UInt32.max),
                  payloadLength <= Int.max - 4 - unit.range.count else {
                return nil
            }
            payloadLength += 4 + unit.range.count
        }

        var blockBuffer: CMBlockBuffer?
        // memoryBlock nil + default allocator: CoreMedia allocates and owns
        // one contiguous block that we populate directly below.
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: payloadLength,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: payloadLength,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer else {
            return nil
        }

        var contiguousLength = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer,
                                          atOffset: 0,
                                          lengthAtOffsetOut: &contiguousLength,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let dataPointer,
              contiguousLength >= payloadLength,
              totalLength == payloadLength else {
            return nil
        }

        let copied = accessUnit.withUnsafeBytes { source -> Bool in
            guard let sourceBase = source.baseAddress else { return false }
            let destination = UnsafeMutableRawPointer(dataPointer)
            var offset = 0
            for unit in sampleUnits {
                var length = UInt32(unit.range.count).bigEndian
                withUnsafeBytes(of: &length) { bytes in
                    destination.advanced(by: offset).copyMemory(from: bytes.baseAddress!, byteCount: 4)
                }
                offset += 4
                destination.advanced(by: offset).copyMemory(
                    from: sourceBase.advanced(by: unit.range.lowerBound),
                    byteCount: unit.range.count
                )
                offset += unit.range.count
            }
            return offset == payloadLength
        }
        guard copied else { return nil }

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

    /// Build a sample and use it synchronously. Length-prefixed live buffers
    /// can be borrowed by CoreMedia without allocating or copying; the body
    /// runs inside `Data.withUnsafeBytes`, which keeps that pointer valid for
    /// the entire synchronous VideoToolbox submit. Recorded Annex B streams
    /// retain the general allocation-and-conversion fallback above.
    static func withSampleBuffer<Result>(accessUnit: Data,
                                         sampleFormat: AnnexB.SampleFormat,
                                         codec: AnnexB.Codec,
                                         nalUnits: [AnnexB.NALUnit],
                                         formatDescription: CMVideoFormatDescription,
                                         timestampMicros: UInt64,
                                         body: (CMSampleBuffer) -> Result) -> Result? {
        switch sampleFormat {
        case .annexB:
            guard let sampleBuffer = makeSampleBuffer(accessUnit: accessUnit,
                                                      codec: codec,
                                                      nalUnits: nalUnits,
                                                      formatDescription: formatDescription,
                                                      timestampMicros: timestampMicros) else {
                return nil
            }
            return body(sampleBuffer)
        case .lengthPrefixed:
            guard let firstUnit = nalUnits.first(where: { $0.type != codec.audType }) else {
                return nil
            }
            let sampleOffset = firstUnit.range.lowerBound - 4
            guard sampleOffset >= 0, sampleOffset < accessUnit.count else { return nil }

            return accessUnit.withUnsafeBytes { raw -> Result? in
                guard let baseAddress = raw.baseAddress else { return nil }
                var blockBuffer: CMBlockBuffer?
                // The pointer is borrowed only through `body`. kCFAllocatorNull
                // tells CoreMedia not to free Data's storage.
                let blockStatus = CMBlockBufferCreateWithMemoryBlock(
                    allocator: kCFAllocatorDefault,
                    memoryBlock: UnsafeMutableRawPointer(mutating: baseAddress),
                    blockLength: raw.count,
                    blockAllocator: kCFAllocatorNull,
                    customBlockSource: nil,
                    offsetToData: sampleOffset,
                    dataLength: raw.count - sampleOffset,
                    flags: 0,
                    blockBufferOut: &blockBuffer
                )
                guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

                var timing = CMSampleTimingInfo(
                    duration: .invalid,
                    presentationTimeStamp: CMTime(value: CMTimeValue(timestampMicros),
                                                  timescale: 1_000_000),
                    decodeTimeStamp: .invalid
                )
                var sampleBuffer: CMSampleBuffer?
                let sampleStatus = CMSampleBufferCreateReady(
                    allocator: kCFAllocatorDefault,
                    dataBuffer: blockBuffer,
                    formatDescription: formatDescription,
                    sampleCount: 1,
                    sampleTimingEntryCount: 1,
                    sampleTimingArray: &timing,
                    sampleSizeEntryCount: 0,
                    sampleSizeArray: nil,
                    sampleBufferOut: &sampleBuffer
                )
                guard sampleStatus == noErr, let sampleBuffer else { return nil }
                return body(sampleBuffer)
            }
        }
    }

    /// Decode one sample buffer synchronously: with both asynchronous and
    /// temporal-processing flags clear, VideoToolbox guarantees the output
    /// callback fires before this call returns. That provides ordered output
    /// and natural backpressure without a redundant global wait.
    static func submit(_ sampleBuffer: CMSampleBuffer,
                       to session: VTDecompressionSession) -> (status: OSStatus, milliseconds: Double) {
        let started = ContinuousClock.now
        var flagsOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session,
                                                       sampleBuffer: sampleBuffer,
                                                       flags: [],
                                                       frameRefcon: nil,
                                                       infoFlagsOut: &flagsOut)
        let elapsed = ContinuousClock.now - started
        let milliseconds = Double(elapsed.components.seconds) * 1e3
            + Double(elapsed.components.attoseconds) / 1e15
        return (status, milliseconds)
    }
}
