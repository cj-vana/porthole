import AppKit
import Foundation

/// porthole-input-test: headless gate for the US-006 input path.
///
/// Modes:
///   porthole-input-test local
///       Byte-exact translation tests: factory-built NSEvents go through
///       InputController and the emitted control frames are compared byte
///       for byte against the protocol layouts.
///   porthole-input-test live <host> move-abs <x> <y>
///   porthole-input-test live <host> click <x> <y>
///   porthole-input-test live <host> type <text>
///       Connect to a live agent with the app's own ControlChannel and send
///       input through InputController. The caller verifies the effect on
///       the box (hyprctl cursorpos, typed file contents, activewindow).
///
/// Exit code 0 = pass/sent, 1 = failure.

var failures = 0

extension Array where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}

func checkBytes(_ name: String, _ actual: [UInt8], _ expected: [UInt8]) {
    if actual == expected {
        print("PASS: \(name)")
    } else {
        failures += 1
        print("FAIL: \(name)\n  actual   \(actual.hexString)\n  expected \(expected.hexString)")
    }
}

func checkTrue(_ name: String, _ condition: Bool) {
    if condition {
        print("PASS: \(name)")
    } else {
        failures += 1
        print("FAIL: \(name)")
    }
}

// MARK: NSEvent factories

func keyEvent(_ type: NSEvent.EventType,
              keyCode: UInt16,
              modifiers: NSEvent.ModifierFlags = [],
              characters: String = "") -> NSEvent {
    guard let event = NSEvent.keyEvent(with: type,
                                       location: .zero,
                                       modifierFlags: modifiers,
                                       timestamp: 0,
                                       windowNumber: 0,
                                       context: nil,
                                       characters: characters,
                                       charactersIgnoringModifiers: characters,
                                       isARepeat: false,
                                       keyCode: keyCode) else {
        fatalError("NSEvent factory failed")
    }
    return event
}

func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) -> NSEvent {
    guard let event = NSEvent.mouseEvent(with: type,
                                         location: point,
                                         modifierFlags: [],
                                         timestamp: 0,
                                         windowNumber: 0,
                                         context: nil,
                                         eventNumber: 0,
                                         clickCount: 1,
                                         pressure: 1) else {
        fatalError("NSEvent factory failed")
    }
    return event
}

func pixelScrollEvent(deltaY: Int32) -> NSEvent {
    guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil,
                                units: .pixel,
                                wheelCount: 1,
                                wheel1: deltaY,
                                wheel2: 0,
                                wheel3: 0),
          let event = NSEvent(cgEvent: cgEvent) else {
        fatalError("scroll event factory failed")
    }
    return event
}

// MARK: Local byte-exact tests

// One test per protocol layout, each with its expected bytes inline; a
// table-driven split would hide the byte comparisons the gate exists for.
// swiftlint:disable:next function_body_length
func runLocalTests() {
    let controller = InputController()
    var wire = [UInt8]()
    controller.onSend = { wire.append(contentsOf: $0) }
    controller.setCaptured(true)
    precondition(wire.isEmpty, "capture emits nothing")

    // 1. Plain key: 'a' down and up (kVK_ANSI_A 0x00 -> KEY_A 30).
    controller.handleKeyDown(keyEvent(.keyDown, keyCode: 0x00, characters: "a"))
    controller.handleKeyUp(keyEvent(.keyUp, keyCode: 0x00, characters: "a"))
    checkBytes("plain key a down+up", wire, [
        0, 0, 0, 4, 0x14, 0, 30, 1, // key 30 down
        0, 0, 0, 4, 0x14, 0, 30, 0 // key 30 up
    ])
    wire.removeAll()

    // 2. Shift+a: flagsChanged emits the shift key event and key_modifiers
    //    before the dependent key.
    controller.handleFlagsChanged(keyEvent(.flagsChanged, keyCode: 0x38, modifiers: [.shift]))
    controller.handleKeyDown(keyEvent(.keyDown, keyCode: 0x00, modifiers: [.shift], characters: "A"))
    controller.handleKeyUp(keyEvent(.keyUp, keyCode: 0x00, modifiers: [.shift], characters: "A"))
    controller.handleFlagsChanged(keyEvent(.flagsChanged, keyCode: 0x38, modifiers: []))
    checkBytes("shift+a ordering", wire, [
        0, 0, 0, 4, 0x14, 0, 42, 1, // KEY_LEFTSHIFT down
        0, 0, 0, 17, 0x15, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // modifiers depressed=1
        0, 0, 0, 4, 0x14, 0, 30, 1, // KEY_A down (shifted)
        0, 0, 0, 4, 0x14, 0, 30, 0, // KEY_A up
        0, 0, 0, 4, 0x14, 0, 42, 0, // KEY_LEFTSHIFT up
        0, 0, 0, 17, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 // modifiers depressed=0
    ])
    wire.removeAll()

    // 3. Pixel-precise scroll: +12 px up becomes -3072 (1/256 px) vertical,
    //    source continuous (no touch phase info on a converted CGEvent).
    controller.handleScroll(pixelScrollEvent(deltaY: 12))
    checkBytes("precise scroll 12px", wire, [
        0, 0, 0, 7, 0x13, 0, 2, 0xFF, 0xFF, 0xF4, 0x00 // value -3072
    ])
    wire.removeAll()

    // 4. Button mapping: left down/up -> BTN_LEFT 0x110.
    let downEvent = mouseEvent(.leftMouseDown, at: NSPoint(x: 100, y: 100))
    let upEvent = mouseEvent(.leftMouseUp, at: NSPoint(x: 100, y: 100))
    for (event, pressed) in [(downEvent, true), (upEvent, false)] {
        if let button = InputController.MouseButton.from(eventType: event.type,
                                                         buttonNumber: event.buttonNumber) {
            controller.handleMouseButton(button, pressed: pressed)
        }
    }
    checkBytes("left button down+up", wire, [
        0, 0, 0, 4, 0x12, 0x01, 0x10, 1,
        0, 0, 0, 4, 0x12, 0x01, 0x10, 0
    ])
    wire.removeAll()

    // 5. Letterbox mapping: 1280x800 view, 2560x1440 video (scale 0.5,
    //    40 px bars top/bottom).
    controller.videoSize = CGSize(width: 2560, height: 1440)
    let viewSize = CGSize(width: 1280, height: 800)
    controller.handleMouseMotion(point: CGPoint(x: 128, y: 120), deltaX: 0, deltaY: 0, viewSize: viewSize)
    checkBytes("letterbox map (128,120) -> (256,160)", wire, [
        0, 0, 0, 9, 0x10, 0, 0, 1, 0, 0, 0, 0, 0xA0
    ])
    wire.removeAll()
    controller.handleMouseMotion(point: CGPoint(x: 640, y: 400), deltaX: 0, deltaY: 0, viewSize: viewSize)
    checkBytes("letterbox map center -> (1280,720)", wire, [
        0, 0, 0, 9, 0x10, 0, 0, 5, 0, 0, 0, 2, 0xD0
    ])
    wire.removeAll()
    controller.handleMouseMotion(point: CGPoint(x: 640, y: 10), deltaX: 0, deltaY: 0, viewSize: viewSize)
    checkTrue("letterbox bar point sends nothing", wire.isEmpty)

    // 6. Modifier mask bits: Shift + Cmd -> depressed 1 | 64 = 65.
    controller.handleFlagsChanged(keyEvent(.flagsChanged, keyCode: 0x38, modifiers: [.shift]))
    controller.handleFlagsChanged(keyEvent(.flagsChanged, keyCode: 0x37, modifiers: [.shift, .command]))
    checkTrue("shift+cmd depressed mask 65",
              wire.suffix(21).starts(with: [0, 0, 0, 17, 0x15, 0, 0, 0, 65]))
    controller.handleFlagsChanged(keyEvent(.flagsChanged, keyCode: 0x37, modifiers: [.shift]))
    controller.handleFlagsChanged(keyEvent(.flagsChanged, keyCode: 0x38, modifiers: []))
    wire.removeAll()

    // 7. Scripted typing of "Hello!\n": shift via key_modifiers only.
    controller.typeText("Hello!\n")
    var expected: [UInt8] = []
    func modifiersFrame(_ depressed: UInt32) {
        expected.append(contentsOf: [0, 0, 0, 17, 0x15,
                                     UInt8(truncatingIfNeeded: depressed >> 24),
                                     UInt8(truncatingIfNeeded: depressed >> 16),
                                     UInt8(truncatingIfNeeded: depressed >> 8),
                                     UInt8(truncatingIfNeeded: depressed),
                                     0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }
    func keyFrame(_ code: UInt16, _ pressed: UInt8) {
        expected.append(contentsOf: [0, 0, 0, 4, 0x14,
                                     UInt8(truncatingIfNeeded: code >> 8),
                                     UInt8(truncatingIfNeeded: code),
                                     pressed])
    }
    modifiersFrame(1) // shift for H
    keyFrame(35, 1); keyFrame(35, 0) // H
    modifiersFrame(0)
    keyFrame(18, 1); keyFrame(18, 0) // e
    keyFrame(38, 1); keyFrame(38, 0) // l
    keyFrame(38, 1); keyFrame(38, 0) // l
    keyFrame(24, 1); keyFrame(24, 0) // o
    modifiersFrame(1) // shift for !
    keyFrame(2, 1); keyFrame(2, 0) // ! = shift+1
    modifiersFrame(0)
    keyFrame(28, 1); keyFrame(28, 0) // return
    checkBytes("typeText Hello!\\n", wire, expected)
    wire.removeAll()

    // 8. The system event-tap path forwards Command+Space as Super+Space in
    //    exact modifier/key order. This is the chord macOS otherwise consumes
    //    for Spotlight before the focused view receives it.
    let localCommandSpace = keyEvent(.keyDown,
                                     keyCode: 0x31,
                                     modifiers: [.command],
                                     characters: " ")
    checkTrue("Command+Space stays local outside event tap",
              !controller.handleKeyDown(localCommandSpace) && wire.isEmpty)
    checkTrue("shortcut filter owns active captured input",
              SystemShortcutCapture.shouldFilter(event: localCommandSpace,
                                                 enabled: true,
                                                 captured: true,
                                                 applicationIsActive: true))
    checkTrue("shortcut filter releases input when app is inactive",
              !SystemShortcutCapture.shouldFilter(event: localCommandSpace,
                                                  enabled: true,
                                                  captured: true,
                                                  applicationIsActive: false))
    let plainEscape = keyEvent(.keyDown, keyCode: 0x35)
    checkTrue("shortcut filter reserves plain Escape locally",
              !SystemShortcutCapture.shouldFilter(event: plainEscape,
                                                  enabled: true,
                                                  captured: true,
                                                  applicationIsActive: true))
    let shortcutEvents = [
        keyEvent(.flagsChanged, keyCode: 0x37, modifiers: [.command]),
        keyEvent(.keyDown, keyCode: 0x31, modifiers: [.command], characters: " "),
        keyEvent(.keyUp, keyCode: 0x31, modifiers: [.command], characters: " "),
        keyEvent(.flagsChanged, keyCode: 0x37, modifiers: [])
    ]
    var shortcutConsumed = true
    for event in shortcutEvents {
        shortcutConsumed = controller.handleCapturedKeyboardEvent(event) && shortcutConsumed
    }
    checkTrue("captured Command+Space events consumed", shortcutConsumed)
    checkBytes("captured Command+Space -> Super+Space", wire, [
        0, 0, 0, 4, 0x14, 0, 125, 1, // KEY_LEFTMETA down
        0, 0, 0, 17, 0x15, 0, 0, 0, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // Super modifier
        0, 0, 0, 4, 0x14, 0, 57, 1, // KEY_SPACE down
        0, 0, 0, 4, 0x14, 0, 57, 0, // KEY_SPACE up
        0, 0, 0, 4, 0x14, 0, 125, 0, // KEY_LEFTMETA up
        0, 0, 0, 17, 0x15, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 // modifiers clear
    ])
    wire.removeAll()

    // 9. A settled 3456x2234 Retina viewport is an exact display_resize
    //    control frame: four-byte length includes the one-byte type.
    checkBytes("display resize 3456x2234",
               Array(WireProtocol.encodeDisplayResize(width: 3_456, height: 2_234)), [
                   0, 0, 0, 9, 0x09,
                   0, 0, 0x0D, 0x80,
                   0, 0, 0x08, 0xBA
               ])

    // 10. A thumbnail fetched over a Tailscale/CGNAT endpoint must not teach
    //    the session to bypass a simultaneously advertised physical LAN
    //    address. The preference still wins among equally ranked paths.
    let txt = ["v": Data("1".utf8)]
    guard var routedMachine = Machine(serviceName: "gaming-box",
                                      hostName: "gaming-box.local.",
                                      addresses: ["100.126.134.75", "10.0.0.222", "192.168.50.4"],
                                      txt: txt) else {
        fatalError("machine test fixture failed")
    }
    routedMachine.preferredHost = "100.126.134.75"
    checkTrue("physical LAN outranks learned overlay",
              routedMachine.dialOrder == ["10.0.0.222", "192.168.50.4",
                                          "100.126.134.75", "gaming-box"])
    routedMachine.preferredHost = "192.168.50.4"
    checkTrue("learned preference wins inside LAN tier",
              routedMachine.dialOrder == ["192.168.50.4", "10.0.0.222",
                                          "100.126.134.75", "gaming-box"])
}

// MARK: Live mode

func runLive(host: String, command: [String]) -> Never {
    let control = ControlChannel()
    let input = InputController()
    input.onSend = { frame in control.sendInput(frame) }
    input.setCaptured(true)

    let helloReceived = DispatchSemaphore(value: 0)
    control.onEvent = { event in
        switch event {
        case .ready:
            break
        case .hello(let hello):
            print("hello: \(hello.width)x\(hello.height), cap \(hello.fps) fps from \(host)")
            helloReceived.signal()
        case .pong, .agentStats:
            break // latency probes are the app's concern, not this gate's
        case .clipboard:
            break // clipboard sync is the app's concern, not this gate's
        case .disconnected(let reason):
            print("FAIL: \(reason)")
            exit(1)
        }
    }
    control.connect(host: host)
    guard helloReceived.wait(timeout: .now() + 5) == .success else {
        print("FAIL: no hello from \(host) within 5s")
        exit(1)
    }

    switch command.first {
    case "move-abs" where command.count == 3:
        input.sendMotionAbs(x: Int32(command[1]) ?? 0, y: Int32(command[2]) ?? 0)
    case "click" where command.count == 3:
        input.sendMotionAbs(x: Int32(command[1]) ?? 0, y: Int32(command[2]) ?? 0)
        input.sendButton(InputMessages.buttonLeft, pressed: true)
        usleep(50_000)
        input.sendButton(InputMessages.buttonLeft, pressed: false)
    case "type" where command.count == 2:
        input.typeText(command[1])
    default:
        print("FAIL: unknown live command \(command)")
        exit(1)
    }

    usleep(400_000) // let TCP flush before disconnect
    control.disconnect()
    print("sent: \(command.joined(separator: " "))")
    exit(0)
}

// MARK: main

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("usage: porthole-input-test local | live <host> <move-abs x y | click x y | type text>")
    exit(1)
}

switch args[1] {
case "local":
    runLocalTests()
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)")
    exit(failures == 0 ? 0 : 1)
case "live":
    guard args.count >= 4 else {
        print("usage: porthole-input-test live <host> <command>")
        exit(1)
    }
    runLive(host: args[2], command: Array(args.dropFirst(3)))
default:
    print("unknown mode \(args[1])")
    exit(1)
}
