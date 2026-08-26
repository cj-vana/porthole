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
/// Threading and the synchronous-decode contract are the VideoDecoder
/// protocol's; the VideoToolbox mechanics live in VTDecode, shared with
/// HEVCDecoder (US-013).
final class H264Decoder: VideoDecoder {
    var onFrameDecoded: ((CVPixelBuffer, UInt64) -> Void)?
    var onFailure: ((String) -> Void)?
    var onSessionRebuilt: ((ColorState, _ width: Int, _ height: Int) -> Void)?

    private(set) var colorState = ColorState(matrix: .bt709, fullRange: false)
    private(set) var isReady = false
    private(set) var lastDecodeMilliseconds = 0.0
    private(set) var lastPrepareMilliseconds = 0.0

    private let sink = VTOutputSink()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentSPS: Data?
    private var currentPPS: Data?

    init() {
        sink.onFrame = { [weak self] pixelBuffer, micros in
            self?.onFrameDecoded?(pixelBuffer, micros)
        }
        sink.onStatusError = { [weak self] status in
            self?.onFailure?("output callback status \(status)")
        }
    }

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

    @discardableResult
    func decode(accessUnit: Data, timestampMicros: UInt64) -> Bool {
        let prepareStarted = ContinuousClock.now
        let nalUnits = AnnexB.locateNALUnits(in: accessUnit)
        var sps: Data?
        var pps: Data?
        for nal in nalUnits {
            if nal.type == AnnexB.NALType.sps.rawValue, sps == nil {
                sps = accessUnit.subdata(in: nal.range)
            } else if nal.type == AnnexB.NALType.pps.rawValue, pps == nil {
                pps = accessUnit.subdata(in: nal.range)
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

        guard let sampleBuffer = VTDecode.makeSampleBuffer(accessUnit: accessUnit,
                                                           codec: .h264,
                                                           nalUnits: nalUnits,
                                                           formatDescription: formatDescription,
                                                           timestampMicros: timestampMicros) else {
            onFailure?("failed to build sample buffer")
            return false
        }

        let prepareElapsed = ContinuousClock.now - prepareStarted
        lastPrepareMilliseconds = Double(prepareElapsed.components.seconds) * 1e3
            + Double(prepareElapsed.components.attoseconds) / 1e15

        let result = VTDecode.submit(sampleBuffer, to: session)
        lastDecodeMilliseconds = result.milliseconds
        return finishSubmit(result.status)
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

        let (newSession, createStatus) = VTDecode.makeSession(formatDescription: description,
                                                              width: parsed.width,
                                                              height: parsed.height,
                                                              fullRange: parsed.fullRange,
                                                              sink: sink)
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
}
