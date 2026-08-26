import AudioToolbox
import Foundation

/// Opus packets to 48 kHz stereo interleaved float PCM, one 20 ms packet
/// per call, through an AudioToolbox AudioConverter with input format
/// kAudioFormatOpus. The C API over AVAudioConverter because the Opus
/// input side needs a per-packet AudioStreamPacketDescription, which
/// AudioConverterFillComplexBuffer takes directly where AVAudioConverter
/// would wrap every 20 ms packet in a fresh AVAudioCompressedBuffer; this
/// exact configuration is also the one a scratch probe verified against a
/// live agent stream.
final class OpusDecoder {
    static let sampleRate = 48_000
    static let channels = 2
    /// 20 ms at 48 kHz (the agent's Opus frame duration), so one packet
    /// decodes to this many frames.
    static let framesPerPacket = 960
    /// Generous ceiling for one packet; 128 kbit/s at 20 ms is ~320 bytes.
    static let maxPacketBytes = 4096

    /// Returned by the input proc once its single packet is consumed, so
    /// FillComplexBuffer stops asking. Returning noErr with zero packets
    /// instead would latch end-of-stream on the converter. Any value the
    /// converter does not use works; paired with decoded frames it means
    /// success, not failure.
    fileprivate static let packetConsumed: OSStatus = 0x504F4443 // "PODC"

    /// Input-proc state: one packet in stable storage plus its description.
    /// A class so the proc can reach it through the inUserData pointer.
    fileprivate final class PendingPacket {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: maxPacketBytes, alignment: 16)
        let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        var consumed = true

        deinit {
            bytes.deallocate()
            description.deallocate()
        }
    }

    private let converter: AudioConverterRef
    private let pending = PendingPacket()
    private let pcm: UnsafeMutablePointer<Float>

    init?() {
        var input = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(Self.framesPerPacket),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var output = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(Self.channels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(Self.channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(Self.channels),
            mBitsPerChannel: UInt32(8 * MemoryLayout<Float>.size),
            mReserved: 0
        )
        var reference: AudioConverterRef?
        guard AudioConverterNew(&input, &output, &reference) == noErr, let reference else {
            return nil
        }
        converter = reference
        pcm = UnsafeMutablePointer<Float>.allocate(capacity: Self.framesPerPacket * Self.channels)
    }

    deinit {
        AudioConverterDispose(converter)
        pcm.deallocate()
    }

    /// Decode one Opus packet. The returned samples (interleaved stereo)
    /// live in a scratch buffer that the next call overwrites, so copy
    /// them out before decoding again. Nil means a decode failure; an
    /// empty buffer is legitimate (Opus pre-skip can eat the first
    /// packet's output) and is not a loss.
    func decode(_ opus: Data) -> UnsafeBufferPointer<Float>? {
        guard !opus.isEmpty, opus.count <= Self.maxPacketBytes else { return nil }
        opus.copyBytes(to: pending.bytes.assumingMemoryBound(to: UInt8.self), count: opus.count)
        pending.description.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(opus.count)
        )
        pending.consumed = false

        var frames = UInt32(Self.framesPerPacket)
        let byteSize = UInt32(Self.framesPerPacket * Self.channels * MemoryLayout<Float>.size)
        var output = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: UInt32(Self.channels),
                                  mDataByteSize: byteSize,
                                  mData: UnsafeMutableRawPointer(pcm))
        )
        let status = AudioConverterFillComplexBuffer(
            converter, supplyOpusPacket, Unmanaged.passUnretained(pending).toOpaque(),
            &frames, &output, nil
        )
        guard status == noErr || status == Self.packetConsumed else { return nil }
        return UnsafeBufferPointer(start: pcm, count: Int(frames) * Self.channels)
    }
}

/// OpusDecoder's AudioConverterComplexInputDataProc: hand over the pending
/// packet on the first call, report it consumed on any further one. A free
/// function because a C function pointer cannot be formed from a method
/// reference.
private func supplyOpusPacket(
    _ converter: AudioConverterRef,
    _ packetCount: UnsafeMutablePointer<UInt32>,
    _ bufferList: UnsafeMutablePointer<AudioBufferList>,
    _ packetDescription: UnsafeMutablePointer<UnsafeMutablePointer<AudioStreamPacketDescription>?>?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else {
        packetCount.pointee = 0
        return OpusDecoder.packetConsumed
    }
    let pending = Unmanaged<OpusDecoder.PendingPacket>.fromOpaque(userData).takeUnretainedValue()
    guard !pending.consumed else {
        packetCount.pointee = 0
        return OpusDecoder.packetConsumed
    }
    pending.consumed = true
    packetCount.pointee = 1
    bufferList.pointee.mNumberBuffers = 1
    bufferList.pointee.mBuffers.mNumberChannels = UInt32(OpusDecoder.channels)
    bufferList.pointee.mBuffers.mData = pending.bytes
    bufferList.pointee.mBuffers.mDataByteSize = pending.description.pointee.mDataByteSize
    packetDescription?.pointee = pending.description
    return noErr
}
