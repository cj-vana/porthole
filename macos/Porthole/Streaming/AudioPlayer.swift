import AVFAudio
import Foundation
import os

/// Opus playback for the audio channel (US-009): packets in from the
/// receiver, sound out of the default output device. Decode and buffering
/// run on a dedicated serial queue so audio work never rides the video
/// decode queue.
///
/// The engine pulls through an AVAudioSourceNode rather than scheduling
/// buffers on an AVAudioPlayerNode: the pull model keeps the whole jitter
/// policy inside the render callback (take what is buffered, silence
/// covers the rest), where scheduled buffers would need completion
/// bookkeeping and give no control over what plays on an underrun.
final class AudioPlayer {
    /// One second of audio figures for the session stats line.
    struct Stats {
        let bufferedMs: Int
        let packets: Int
        let lost: Int
        let droppedMs: Int
        let underruns: Int
    }

    /// A sequence jump past this many packets (200 ms, the jitter buffer
    /// cap) is a discontinuity to resync over, not loss worth concealing:
    /// concealing more than the cap would only wipe the buffer to silence.
    private static let resetGapPackets: Int32 = 10

    private let engine = AVAudioEngine()
    private let buffer = AudioJitterBuffer()
    private let queue = DispatchQueue(label: "porthole.audio.decode")
    private let logger = Logger(subsystem: "com.porthole.mac", category: "audio")
    private var sourceNode: AVAudioSourceNode?

    // Queue-only state.
    private var decoder: OpusDecoder?
    private var running = false
    private var nextSequence: UInt32?

    // Window counters and the output level, shared across queues.
    private let stateLock = NSLock()
    private var windowPackets = 0
    private var windowLost = 0
    private var volume: Float = 0.8
    private var muted = false

    func start() {
        queue.async { [weak self] in self?.startOnQueue() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    /// Called on the receiver's thread; hops to the audio queue.
    func enqueue(_ packet: WireProtocol.AudioDatagram) {
        queue.async { [weak self] in self?.decodeAndBuffer(packet) }
    }

    /// Route a receiver's packets into the decode queue. Failures are
    /// logged rather than escalated: audio is optional, so a lost bind or
    /// read error costs sound only and the session stays up on video.
    func attach(to receiver: AudioReceiver) {
        receiver.onEvent = { [weak self] event in
            switch event {
            case .packet(let packet):
                self?.enqueue(packet)
            case .failed(let message):
                self?.logger.warning("\(message, privacy: .public)")
            }
        }
    }

    /// Mixer level, 0...1. SessionView persists the value and pushes
    /// changes here; mute keeps the slider position and drives the mixer
    /// to zero instead.
    func setVolume(_ value: Float) {
        stateLock.lock()
        volume = min(max(value, 0), 1)
        stateLock.unlock()
        applyOutputVolume()
    }

    func setMuted(_ value: Bool) {
        stateLock.lock()
        muted = value
        stateLock.unlock()
        applyOutputVolume()
    }

    /// The last second's figures, resetting the window. Safe from any
    /// queue; the counters live behind locks.
    func perSecond() -> Stats {
        stateLock.lock()
        let packets = windowPackets
        let lost = windowLost
        windowPackets = 0
        windowLost = 0
        stateLock.unlock()
        let window = buffer.takeWindow()
        return Stats(bufferedMs: buffer.bufferedMs,
                     packets: packets,
                     lost: lost,
                     droppedMs: window.droppedFrames / AudioJitterBuffer.framesPerMs,
                     underruns: window.underruns)
    }

    // MARK: Audio queue

    private func startOnQueue() {
        guard !running else { return }
        guard let decoder = OpusDecoder() else {
            logger.warning("Opus AudioConverter unavailable; audio disabled")
            return
        }
        self.decoder = decoder
        if sourceNode == nil {
            attachSourceNode()
        }
        buffer.reset()
        nextSequence = nil
        do {
            try engine.start()
            running = true
            applyOutputVolume()
        } catch {
            // Audio is optional; the session stays up on video alone.
            logger.warning("audio engine start failed: \(error.localizedDescription, privacy: .public)")
            self.decoder = nil
        }
    }

    private func stopOnQueue() {
        guard running else { return }
        running = false
        engine.stop()
        decoder = nil
        nextSequence = nil
        buffer.reset()
        stateLock.lock()
        windowPackets = 0
        windowLost = 0
        stateLock.unlock()
    }

    private func decodeAndBuffer(_ packet: WireProtocol.AudioDatagram) {
        guard running, let decoder else { return }
        stateLock.lock()
        windowPackets += 1
        stateLock.unlock()

        if let expected = nextSequence {
            let distance = Int32(bitPattern: packet.sequence &- expected)
            if distance < 0 {
                // Late arrival; its gap was already concealed as silence.
                return
            }
            if distance > Self.resetGapPackets {
                logger.info("audio resync after sequence jump of \(distance) packets")
                buffer.reset()
            } else if distance > 0 {
                // Concealed as silence so the buffered timeline keeps its
                // length; AudioConverter exposes no way to ask the Opus
                // decoder for proper packet-loss concealment.
                stateLock.lock()
                windowLost += Int(distance)
                stateLock.unlock()
                for _ in 0..<distance {
                    buffer.pushSilence(frames: OpusDecoder.framesPerPacket)
                }
            }
        }
        nextSequence = packet.sequence &+ 1

        guard let pcm = decoder.decode(packet.opus) else {
            // A packet the decoder rejects still occupies 20 ms of timeline.
            buffer.pushSilence(frames: OpusDecoder.framesPerPacket)
            return
        }
        buffer.push(pcm)
    }

    private func attachSourceNode() {
        // Deinterleaved float is AVAudioEngine's native bus format; the
        // render block fills one buffer per channel. The connection uses
        // this exact format so the engine does not negotiate a different one
        // underneath the render block, which is what silently broke playback
        // when the node claimed interleaved and the bus was deinterleaved.
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Double(OpusDecoder.sampleRate),
                                         channels: AVAudioChannelCount(OpusDecoder.channels),
                                         interleaved: false) else {
            return
        }
        let buffer = self.buffer
        let node = AVAudioSourceNode(format: format) { isSilence, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let left = buffers[0].mData?.assumingMemoryBound(to: Float.self)
            let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : left
            guard let left, let right else { return noErr }
            if buffer.render(left: left, right: right, frames: Int(frameCount)) == 0 {
                isSilence.pointee = true
            }
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        sourceNode = node
    }

    private func applyOutputVolume() {
        stateLock.lock()
        let level = muted ? 0 : volume
        stateLock.unlock()
        engine.mainMixerNode.outputVolume = level
    }
}

/// Decoded interleaved stereo samples between the decode queue (push) and
/// the audio render thread (pop). Playback starts once `targetFrames`
/// (about 40 ms) is buffered and the gate re-arms on underrun, so a late
/// burst refills before playing instead of stuttering packet by packet.
/// Growth past `capacityFrames` (about 200 ms) drops the oldest audio so
/// latency cannot accumulate. An NSLock like the rest of the project; the
/// critical sections are copy loops over at most a few thousand floats and
/// the push side runs at the 20 ms packet cadence, so the render thread's
/// wait stays far under its deadline.
final class AudioJitterBuffer {
    static let framesPerMs = OpusDecoder.sampleRate / 1000
    static let targetFrames = 40 * framesPerMs
    static let capacityFrames = 200 * framesPerMs

    private static let channels = OpusDecoder.channels

    private let lock = NSLock()
    private let storage: UnsafeMutablePointer<Float>
    private var readFrame = 0
    private var framesBuffered = 0
    private var prebuffering = true
    private var droppedFrames = 0
    private var underruns = 0

    init() {
        let capacity = Self.capacityFrames * Self.channels
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    var bufferedMs: Int {
        lock.lock()
        defer { lock.unlock() }
        return framesBuffered / Self.framesPerMs
    }

    func push(_ samples: UnsafeBufferPointer<Float>) {
        guard let base = samples.baseAddress else { return }
        let frames = samples.count / Self.channels
        lock.lock()
        let start = makeRoom(for: frames)
        for offset in 0..<(frames * Self.channels) {
            storage[(start * Self.channels + offset) % (Self.capacityFrames * Self.channels)] = base[offset]
        }
        framesBuffered += frames
        lock.unlock()
    }

    func pushSilence(frames: Int) {
        lock.lock()
        let start = makeRoom(for: frames)
        for offset in 0..<(frames * Self.channels) {
            storage[(start * Self.channels + offset) % (Self.capacityFrames * Self.channels)] = 0
        }
        framesBuffered += frames
        lock.unlock()
    }

    /// Fill `frames` frames into the deinterleaved left and right channel
    /// buffers, deinterleaving from interleaved storage. Returns the frames
    /// that came from the buffer; the remainder is silence.
    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if prebuffering {
            if framesBuffered >= Self.targetFrames {
                prebuffering = false
            } else {
                left.update(repeating: 0, count: frames)
                right.update(repeating: 0, count: frames)
                return 0
            }
        }
        let delivered = min(frames, framesBuffered)
        let span = Self.capacityFrames * Self.channels
        for frame in 0..<delivered {
            let base = ((readFrame + frame) * Self.channels) % span
            left[frame] = storage[base]
            right[frame] = storage[base + 1]
        }
        readFrame = (readFrame + delivered) % Self.capacityFrames
        framesBuffered -= delivered
        if delivered < frames {
            left.advanced(by: delivered).update(repeating: 0, count: frames - delivered)
            right.advanced(by: delivered).update(repeating: 0, count: frames - delivered)
            underruns += 1
            prebuffering = true
        }
        return delivered
    }

    func reset() {
        lock.lock()
        readFrame = 0
        framesBuffered = 0
        prebuffering = true
        // The window counters too, so a reconnect's first stats line does
        // not report the previous session's tail.
        droppedFrames = 0
        underruns = 0
        lock.unlock()
    }

    /// Drop and underrun counts since the last call, for the stats line.
    func takeWindow() -> (droppedFrames: Int, underruns: Int) {
        lock.lock()
        defer { lock.unlock() }
        let window = (droppedFrames, underruns)
        droppedFrames = 0
        underruns = 0
        return window
    }

    /// Caller holds the lock. Frees space for `frames` by dropping the
    /// oldest audio when the cap would be exceeded, and returns the frame
    /// index to write at.
    private func makeRoom(for frames: Int) -> Int {
        let overflow = framesBuffered + frames - Self.capacityFrames
        if overflow > 0 {
            readFrame = (readFrame + overflow) % Self.capacityFrames
            framesBuffered -= overflow
            droppedFrames += overflow
        }
        return (readFrame + framesBuffered) % Self.capacityFrames
    }
}
