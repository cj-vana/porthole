import CoreVideo
import Foundation

/// porthole-decode-test: headless gate for the US-005 decode path.
///
/// Reads an Annex B H.264 dump (default: /tmp/porthole-lan.h264, recorded
/// with the agent's reference receiver: `cargo run --example receiver --
/// <agent-ip> --dump /tmp/porthole-lan.h264`), feeds access units through
/// H264Decoder starting at the first IDR, and asserts that VideoToolbox
/// decodes more than 100 frames at 2560x1440.
///
/// Exit code 0 = pass, 1 = fail. Prints progress to stdout.
///
///   xcodebuild -scheme porthole-decode-test -configuration Debug build
///   .../Build/Products/Debug/porthole-decode-test [path-to-dump]

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/porthole-lan.h264"
guard let stream = FileManager.default.contents(atPath: path) else {
    print("FAIL: cannot read \(path)")
    exit(1)
}

let accessUnits = AnnexB.accessUnits(in: stream)
print("stream: \(stream.count) bytes, \(accessUnits.count) access units")
guard !accessUnits.isEmpty else {
    print("FAIL: no access units found (not an Annex B stream?)")
    exit(1)
}

let decoder = H264Decoder()
var decodedFrames = 0
var decodedWidth = 0
var decodedHeight = 0
decoder.onFrameDecoded = { pixelBuffer, _ in
    decodedFrames += 1
    decodedWidth = CVPixelBufferGetWidth(pixelBuffer)
    decodedHeight = CVPixelBufferGetHeight(pixelBuffer)
}
decoder.onSessionRebuilt = { colorState, width, height in
    print("decode session: \(width)x\(height), matrix \(colorState.matrix), fullRange \(colorState.fullRange)")
}
decoder.onFailure = { print("decoder failure: \($0)") }

var fed = 0
for accessUnit in accessUnits {
    // Mirror the receiver rule: start decoding from the first keyframe AU.
    if fed == 0, !AnnexB.containsIDR(accessUnit) {
        continue
    }
    decoder.decode(accessUnit: accessUnit, timestampMicros: UInt64(fed) * 16_666)
    fed += 1
}

print("fed \(fed) access units; decoded \(decodedFrames) frames at \(decodedWidth)x\(decodedHeight)")
guard decodedFrames > 100 else {
    print("FAIL: decoded \(decodedFrames) frames, want > 100")
    exit(1)
}
guard decodedWidth == 2560, decodedHeight == 1440 else {
    print("FAIL: decoded resolution \(decodedWidth)x\(decodedHeight), want 2560x1440")
    exit(1)
}
print("PASS: \(decodedFrames) frames at 2560x1440 decoded via VideoToolbox")
exit(0)
