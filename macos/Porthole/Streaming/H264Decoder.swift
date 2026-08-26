import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 decoder: Annex B access units in, CVPixelBuffers out.
///
/// Parameter set handling (the part US-005 calls fiddly):
/// - SPS/PPS NALs are lifted out of the stream whenever they appear (the
///   agent emits them at stream start and after every encoder restart, which
///   is what a keyframe_request triggers).
/// - A CMVideoFormatDescription is built from the raw parameter sets via
///   CMVideoFormatDescriptionCreateFromH264ParameterSets, and the
///   VTDecompressionSession is rebuilt whenever the parameter set bytes
///   change, which also covers resolution changes across encoder restarts.
/// - Sample buffers carry length-prefixed NAL units (AVCC form), matching the
///   4-byte NAL header length declared on the format description.
///
/// All entry points must be called from one serial queue (StreamSession's
/// decode queue). Decoding is synchronous per access unit: ordered output,
/// natural backpressure, and honest decode-time measurement.
final class H264Decoder {
    /// Color state for the renderer, derived from SPS VUI with PRD defaults
    /// (BT.709 for HD, BT.601 for SD) when the stream says nothing.
    struct ColorState: Equatable {
        var matrix: H264SPS.ColorMatrix
        var fullRange: Bool
    }

    /// Decoded image + capture timestamp in microseconds. Called on the
    /// caller's queue, presentation order handled by VideoToolbox.
    var onFrameDecoded: ((CVPixelBuffer, UInt64) -> Void)?
    /// Decode-fatal failure (malformed stream, dead session). The session
    /// layer should request a keyframe.
    var onFailure: ((String) -> Void)?
    /// Parameter sets changed and a fresh decode session is now active.
    var onSessionRebuilt: ((ColorState, _ width: Int, _ height: Int) -> Void)?

    private(set) var colorState = ColorState(matrix: .bt709, fullRange: false)
    private(set) var isReady = false
    /// Decode wall time of the last submitted access unit, in milliseconds.
    private(set) var lastDecodeMilliseconds = 0.0

    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentSPS: Data?
    private var currentPPS: Data?

    deinit {
        invalidate()
    }

    /// Drop the decode session. The next access unit carrying parameter sets
    /// builds a fresh one.
    func invalidate() {
        if let session {
            VTDecompressionSessionInvalidate(session)
        }
        session = nil
        formatDescription = nil
        currentSPS = nil
        currentPPS = nil
        isReady = false
    }

    /// Submit one complete Annex B access unit.
    ///
    /// Returns false when no decode session exists yet (no parameter sets
    /// seen), which means the caller should keep waiting for an IDR that
    /// carries SPS/PPS, or request another keyframe.
    @discardableResult
    func decode(accessUnit: Data, timestampMicros: UInt64) -> Bool {
        var sps: Data?
        var pps: Data?
        for nal in AnnexB.nalPayloads(in: accessUnit) {
            if nal.type == AnnexB.NALType.sps.rawValue, sps == nil {
                sps = nal.payload
            } else if nal.type == AnnexB.NALType.pps.rawValue, pps == nil {
                pps = nal.payload
            }
        }
        let nextSPS = sps ?? currentSPS
        let nextPPS = pps ?? currentPPS
        if let nextSPS, let nextPPS, nextSPS != currentSPS || nextPPS != currentPPS {
            rebuildSession(sps: nextSPS, pps: nextPPS)
        }

        guard let session, let formatDescription else {
            return false
        }

        let payload = AnnexB.avccPayload(fromAccessUnit: accessUnit)
        guard !payload.isEmpty,
              let sampleBuffer = makeSampleBuffer(payload: payload,
                                                  formatDescription: formatDescription,
                                                  timestampMicros: timestampMicros) else {
            onFailure?("failed to build sample buffer")
            return false
        }

        let started = ContinuousClock.now
        var flagsOut = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session,
                                                       sampleBuffer: sampleBuffer,
                                                       flags: [],
                                                       frameRefcon: nil,
                                                       infoFlagsOut: &flagsOut)
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let elapsed = ContinuousClock.now - started
        lastDecodeMilliseconds = Double(elapsed.components.seconds) * 1e3
            + Double(elapsed.components.attoseconds) / 1e15

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

    /// Build a new format description and decode session from fresh
    /// parameter sets. On failure the old session (if any) stays live.
    private func rebuildSession(sps: Data, pps: Data) {
        guard let parsed = H264SPS(nal: sps) else {
            onFailure?("unparseable SPS; keeping previous session")
            return
        }

        let (description, status) = Self.makeFormatDescription(sps: sps, pps: pps)
        guard status == noErr, let description else {
            onFailure?("CMVideoFormatDescriptionCreateFromH264ParameterSets failed (\(status))")
            return
        }

        // Color: VUI wins; otherwise BT.709 for HD, BT.601 for SD.
        let matrix = parsed.colorMatrix ?? (parsed.height >= 720 ? .bt709 : .bt601)
        colorState = ColorState(matrix: matrix, fullRange: parsed.fullRange)

        let pixelFormat = parsed.fullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferWidthKey as String: parsed.width,
            kCVPixelBufferHeightKey as String: parsed.height
        ]

        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: h264OutputCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        var newSession: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &newSession
        )
        guard createStatus == noErr, let newSession else {
            onFailure?("VTDecompressionSessionCreate failed (\(createStatus))")
            return
        }

        invalidate()
        session = newSession
        formatDescription = description
        currentSPS = sps
        currentPPS = pps
        isReady = true
        onSessionRebuilt?(colorState, parsed.width, parsed.height)
    }

    /// Format description from raw parameter sets, declaring the 4-byte NAL
    /// length prefix the AVCC sample buffers carry.
    private static func makeFormatDescription(sps: Data,
                                              pps: Data) -> (CMVideoFormatDescription?, OSStatus) {
        var description: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsBase = spsRaw.baseAddress, let ppsBase = ppsRaw.baseAddress else {
                    return errSecParam
                }
                var pointers: [UnsafePointer<UInt8>] = [
                    spsBase.assumingMemoryBound(to: UInt8.self),
                    ppsBase.assumingMemoryBound(to: UInt8.self)
                ]
                var sizes: [Int] = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: &pointers,
                    parameterSetSizes: &sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        return (description, status)
    }

    /// Assemble a CMSampleBuffer wrapping one access unit in AVCC form.
    private func makeSampleBuffer(payload: Data,
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
}

// VTDecompressionOutputCallback's parameter list is fixed by VideoToolbox.
// swiftlint:disable:next function_parameter_count
private func h264OutputCallback(refCon: UnsafeMutableRawPointer?,
                                frameRefCon _: UnsafeMutableRawPointer?,
                                status: OSStatus,
                                infoFlags _: VTDecodeInfoFlags,
                                imageBuffer: CVImageBuffer?,
                                presentationTimeStamp: CMTime,
                                presentationDuration _: CMTime) {
    guard let refCon else { return }
    let decoder = Unmanaged<H264Decoder>.fromOpaque(refCon).takeUnretainedValue()
    guard status == noErr, let imageBuffer else {
        decoder.onFailure?("output callback status \(status)")
        return
    }
    let micros = UInt64(max(0, CMTimeGetSeconds(presentationTimeStamp)) * 1_000_000)
    decoder.onFrameDecoded?(imageBuffer, micros)
}
