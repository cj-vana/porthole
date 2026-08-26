import CoreVideo
import Foundation
import VideoToolbox

/// Hardware HEVC decoder for gaming mode (US-013): Annex B access units in,
/// NV12 CVPixelBuffers out, mirroring H264Decoder's synchronous contract.
///
/// Parameter sets are the H.264 story plus a VPS: VPS(32)/SPS(33)/PPS(34)
/// NALs are lifted out of the stream whenever they appear, the format
/// description comes from CMVideoFormatDescriptionCreateFromHEVCParameterSets,
/// and the VTDecompressionSession is rebuilt when any of the three change.
/// Color: HEVC VUI parsing is out of scope, so the PRD defaults apply
/// unconditionally (BT.709 limited range for HD, BT.601 below).
final class HEVCDecoder: VideoDecoder {
    var onFrameDecoded: ((CVPixelBuffer, UInt64) -> Void)?
    var onFailure: ((String) -> Void)?
    var onSessionRebuilt: ((ColorState, _ width: Int, _ height: Int) -> Void)?

    private(set) var colorState = ColorState(matrix: .bt709, fullRange: false)
    private(set) var isReady = false
    private(set) var lastDecodeMilliseconds = 0.0

    private let sink = VTOutputSink()
    private var session: VTDecompressionSession?
    private var formatDescription: CMVideoFormatDescription?
    private var currentVPS: Data?
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
        currentVPS = nil
        currentSPS = nil
        currentPPS = nil
        isReady = false
    }

    @discardableResult
    func decode(accessUnit: Data, timestampMicros: UInt64) -> Bool {
        var vps: Data?
        var sps: Data?
        var pps: Data?
        for nal in AnnexB.nalPayloads(in: accessUnit, codec: .hevc) {
            switch nal.type {
            case AnnexB.HEVCNALType.vps.rawValue where vps == nil:
                vps = nal.payload
            case AnnexB.HEVCNALType.sps.rawValue where sps == nil:
                sps = nal.payload
            case AnnexB.HEVCNALType.pps.rawValue where pps == nil:
                pps = nal.payload
            default:
                break
            }
        }
        let nextVPS = vps ?? currentVPS
        let nextSPS = sps ?? currentSPS
        let nextPPS = pps ?? currentPPS
        if let nextVPS, let nextSPS, let nextPPS,
           nextVPS != currentVPS || nextSPS != currentSPS || nextPPS != currentPPS {
            rebuildSession(vps: nextVPS, sps: nextSPS, pps: nextPPS)
        }

        guard let session, let formatDescription else {
            return false
        }

        let payload = AnnexB.avccPayload(fromAccessUnit: accessUnit, codec: .hevc)
        guard !payload.isEmpty,
              let sampleBuffer = VTDecode.makeSampleBuffer(payload: payload,
                                                           formatDescription: formatDescription,
                                                           timestampMicros: timestampMicros) else {
            onFailure?("failed to build sample buffer")
            return false
        }

        let result = VTDecode.submit(sampleBuffer, to: session)
        lastDecodeMilliseconds = result.milliseconds
        return finishSubmit(result.status)
    }

    /// Build a new format description and decode session from fresh
    /// parameter sets. On failure the old session (if any) stays live.
    private func rebuildSession(vps: Data, sps: Data, pps: Data) {
        let (description, status) = Self.makeFormatDescription(vps: vps, sps: sps, pps: pps)
        guard status == noErr, let description else {
            onFailure?("CMVideoFormatDescriptionCreateFromHEVCParameterSets failed (\(status))")
            return
        }

        // VideoToolbox already parsed the parameter sets; read the coded
        // size back rather than duplicating an HEVC SPS parser.
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        colorState = ColorState(matrix: height >= 720 ? .bt709 : .bt601, fullRange: false)

        let (newSession, createStatus) = VTDecode.makeSession(formatDescription: description,
                                                              width: width,
                                                              height: height,
                                                              fullRange: colorState.fullRange,
                                                              sink: sink)
        guard createStatus == noErr, let newSession else {
            onFailure?("VTDecompressionSessionCreate failed (\(createStatus))")
            return
        }

        invalidate()
        session = newSession
        formatDescription = description
        currentVPS = vps
        currentSPS = sps
        currentPPS = pps
        isReady = true
        onSessionRebuilt?(colorState, width, height)
    }

    /// Format description from raw VPS/SPS/PPS, declaring the 4-byte NAL
    /// length prefix the AVCC sample buffers carry.
    private static func makeFormatDescription(vps: Data, sps: Data,
                                              pps: Data) -> (CMVideoFormatDescription?, OSStatus) {
        var description: CMVideoFormatDescription?
        let status: OSStatus = vps.withUnsafeBytes { vpsRaw in
            sps.withUnsafeBytes { spsRaw in
                pps.withUnsafeBytes { ppsRaw in
                    guard let vpsBase = vpsRaw.baseAddress,
                          let spsBase = spsRaw.baseAddress,
                          let ppsBase = ppsRaw.baseAddress else {
                        return errSecParam
                    }
                    var pointers: [UnsafePointer<UInt8>] = [
                        vpsBase.assumingMemoryBound(to: UInt8.self),
                        spsBase.assumingMemoryBound(to: UInt8.self),
                        ppsBase.assumingMemoryBound(to: UInt8.self)
                    ]
                    var sizes: [Int] = [vps.count, sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator: kCFAllocatorDefault,
                        parameterSetCount: 3,
                        parameterSetPointers: &pointers,
                        parameterSetSizes: &sizes,
                        nalUnitHeaderLength: 4,
                        extensions: nil,
                        formatDescriptionOut: &description
                    )
                }
            }
        }
        return (description, status)
    }
}
