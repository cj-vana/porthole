import CoreGraphics
import Foundation

/// Wire encoders for the US-006 input messages (types 0x10 through 0x15).
/// Layouts per docs/protocol.md; all integers big-endian.
enum InputMessages {
    /// evdev button codes used by the Mac client.
    static let buttonLeft: UInt16 = 0x110
    static let buttonRight: UInt16 = 0x111
    static let buttonMiddle: UInt16 = 0x112
    static let buttonSide: UInt16 = 0x113
    static let buttonExtra: UInt16 = 0x114

    /// wl_pointer.axis_source values.
    enum AxisSource: UInt8 {
        /// Mouse wheel; one click is 10 px (value 2560).
        case wheel = 0
        /// Trackpad finger contact.
        case finger = 1
        /// Trackpad momentum / free-floating precise scroll.
        case continuous = 2
        case wheelTilt = 3
    }

    /// xkb modifier bit indices for the wire (0x15). The classic X11 order,
    /// which matches the modifier indices of the agent's evdev/pc105/us
    /// xkbcommon keymap: bit 0 Shift, bit 1 Lock (CapsLock, used in `locked`
    /// only), bit 2 Control, bit 3 Mod1 (Alt/Option), bit 6 Mod4 (Super/Cmd).
    enum ModifierBit {
        static let shift: UInt32 = 1 << 0
        static let lock: UInt32 = 1 << 1
        static let control: UInt32 = 1 << 2
        static let alt: UInt32 = 1 << 3
        static let sup: UInt32 = 1 << 6
    }

    /// pointer_motion_abs: x, y in output pixels.
    static func motionAbs(x: Int32, y: Int32) -> Data {
        var payload = Data(capacity: 8)
        payload.appendUInt32BE(UInt32(bitPattern: x))
        payload.appendUInt32BE(UInt32(bitPattern: y))
        return WireProtocol.encodeControlMessage(.pointerMotionAbs, payload: payload)
    }

    /// pointer_motion_rel: dx, dy in 1/256 pixel units.
    static func motionRel(dx256: Int32, dy256: Int32) -> Data {
        var payload = Data(capacity: 8)
        payload.appendUInt32BE(UInt32(bitPattern: dx256))
        payload.appendUInt32BE(UInt32(bitPattern: dy256))
        return WireProtocol.encodeControlMessage(.pointerMotionRel, payload: payload)
    }

    /// pointer_button: evdev BTN_* code + pressed state.
    static func button(_ button: UInt16, pressed: Bool) -> Data {
        var payload = Data(capacity: 3)
        payload.appendUInt16BE(button)
        payload.append(pressed ? 1 : 0)
        return WireProtocol.encodeControlMessage(.pointerButton, payload: payload)
    }

    /// pointer_axis: vertical/horizontal, source, value in 1/256 px units.
    /// Positive vertical values scroll down.
    static func axis(vertical: Bool, source: AxisSource, value256: Int32) -> Data {
        var payload = Data(capacity: 6)
        payload.append(vertical ? 0 : 1)
        payload.append(source.rawValue)
        payload.appendUInt32BE(UInt32(bitPattern: value256))
        return WireProtocol.encodeControlMessage(.pointerAxis, payload: payload)
    }

    /// key: evdev KEY_* code + pressed state.
    static func key(_ code: UInt16, pressed: Bool) -> Data {
        var payload = Data(capacity: 3)
        payload.appendUInt16BE(code)
        payload.append(pressed ? 1 : 0)
        return WireProtocol.encodeControlMessage(.key, payload: payload)
    }

    /// key_modifiers: xkb masks, matching the virtual-keyboard modifiers()
    /// request. Sent before dependent keys so shifted characters work.
    static func keyModifiers(depressed: UInt32,
                             latched: UInt32 = 0,
                             locked: UInt32 = 0,
                             group: UInt32 = 0) -> Data {
        var payload = Data(capacity: 16)
        payload.appendUInt32BE(depressed)
        payload.appendUInt32BE(latched)
        payload.appendUInt32BE(locked)
        payload.appendUInt32BE(group)
        return WireProtocol.encodeControlMessage(.keyModifiers, payload: payload)
    }
}

/// Maps a point in the Metal surface's view coordinates (top-left origin,
/// points) to remote output pixels, reversing the aspect-fit letterbox the
/// renderer applies. Returns nil inside the letterbox/pillarbox bars, where
/// there is no remote pixel to point at.
enum Letterbox {
    static func outputPoint(forViewPoint point: CGPoint,
                            viewSize: CGSize,
                            videoSize: CGSize) -> CGPoint? {
        guard viewSize.width > 0, viewSize.height > 0,
              videoSize.width > 0, videoSize.height > 0 else { return nil }
        let scale = min(viewSize.width / videoSize.width,
                        viewSize.height / videoSize.height)
        let displaySize = CGSize(width: videoSize.width * scale,
                                 height: videoSize.height * scale)
        let origin = CGPoint(x: (viewSize.width - displaySize.width) / 2,
                             y: (viewSize.height - displaySize.height) / 2)
        let x = (point.x - origin.x) / scale
        let y = (point.y - origin.y) / scale
        guard x >= 0, y >= 0, x < videoSize.width, y < videoSize.height else { return nil }
        return CGPoint(x: x, y: y)
    }
}
