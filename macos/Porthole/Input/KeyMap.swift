import Foundation

/// macOS virtual key code (Carbon kVK_*, hardware-position based, US layout)
/// to evdev KEY_* translation, plus a US character to keystroke table for
/// scripted typing (used by porthole-input-test).
///
/// The keyCode table is positional: the key labeled Q on a US keyboard
/// produces kVK_ANSI_Q regardless of the user's layout. Non-US layouts get
/// US-position behavior, matching how the agent's evdev/pc105/us keymap
/// interprets the codes.
enum KeyMap {
    /// One keystroke: an evdev KEY_* code plus whether Shift must be active.
    struct Keystroke: Equatable {
        let code: UInt16
        let needsShift: Bool
    }

    // evdev codes used below, named once for readability.
    private static let keyEsc: UInt16 = 1
    private static let keyEnter: UInt16 = 28
    private static let keyTab: UInt16 = 15
    private static let keySpace: UInt16 = 57
    private static let keyBackspace: UInt16 = 14
    static let keyCapsLock: UInt16 = 58

    static let keyLeftShift: UInt16 = 42
    static let keyRightShift: UInt16 = 54
    static let keyLeftControl: UInt16 = 29
    static let keyRightControl: UInt16 = 97
    static let keyLeftAlt: UInt16 = 56
    static let keyRightAlt: UInt16 = 100
    static let keyLeftSuper: UInt16 = 125
    static let keyRightSuper: UInt16 = 126

    /// macOS keyCode -> evdev KEY_* code. Covers the US alphanumeric layout,
    /// punctuation, function keys F1-F12, navigation cluster, arrows,
    /// modifiers, and the keypad. Returns nil for unmapped codes (Fn and
    /// friends).
    static func evdevCode(forKeyCode keyCode: UInt16) -> UInt16? {
        Self.table[keyCode]
    }

    // Table indexed by macOS keyCode (kVK constants in comments).
    private static let table: [UInt16: UInt16] = [
        0x00: 30, // kVK_ANSI_A -> KEY_A
        0x01: 31, // S
        0x02: 32, // D
        0x03: 33, // F
        0x04: 35, // H
        0x05: 34, // G
        0x06: 44, // Z
        0x07: 45, // X
        0x08: 46, // C
        0x09: 47, // V
        0x0B: 48, // B
        0x0C: 16, // Q
        0x0D: 17, // W
        0x0E: 18, // E
        0x0F: 19, // R
        0x10: 21, // Y
        0x11: 20, // T
        0x12: 2,  // 1
        0x13: 3,  // 2
        0x14: 4,  // 3
        0x15: 5,  // 4
        0x16: 7,  // 6
        0x17: 6,  // 5
        0x18: 13, // = (KEY_EQUAL)
        0x19: 10, // 9
        0x1A: 8,  // 7
        0x1B: 12, // - (KEY_MINUS)
        0x1C: 9,  // 8
        0x1D: 11, // 0
        0x1E: 27, // ] (KEY_RIGHTBRACE)
        0x1F: 24, // O
        0x20: 22, // U
        0x21: 26, // [ (KEY_LEFTBRACE)
        0x22: 23, // I
        0x23: 25, // P
        0x24: keyEnter, // Return
        0x25: 38, // L
        0x26: 36, // J
        0x27: 40, // ' (KEY_APOSTROPHE)
        0x28: 37, // K
        0x29: 39, // ; (KEY_SEMICOLON)
        0x2A: 43, // \ (KEY_BACKSLASH)
        0x2B: 51, // , (KEY_COMMA)
        0x2C: 53, // / (KEY_SLASH)
        0x2D: 49, // N
        0x2E: 50, // M
        0x2F: 52, // . (KEY_DOT)
        0x30: keyTab,
        0x31: keySpace,
        0x32: 41, // ` (KEY_GRAVE)
        0x33: keyBackspace, // Delete (backspace)
        0x35: keyEsc,
        0x36: keyRightSuper, // Right Command -> KEY_RIGHTMETA
        0x37: keyLeftSuper,  // Command -> KEY_LEFTMETA (Super on Linux)
        0x38: keyLeftShift,
        0x39: keyCapsLock,
        0x3A: keyLeftAlt,    // Option -> Alt
        0x3B: keyLeftControl,
        0x3C: keyRightShift,
        0x3D: keyRightAlt,
        0x3E: keyRightControl,
        // Keypad.
        0x41: 83,  // keypad . (KEY_KPDOT)
        0x43: 55,  // keypad * (KEY_KPASTERISK)
        0x45: 78,  // keypad + (KEY_KPPLUS)
        0x47: 69,  // keypad Clear (KEY_NUMLOCK)
        0x4B: 98,  // keypad / (KEY_KPSLASH)
        0x4C: 96,  // keypad Enter (KEY_KPENTER)
        0x4E: 74,  // keypad - (KEY_KPMINUS)
        0x51: 117, // keypad = (KEY_KPEQUALS)
        0x52: 82,  // keypad 0
        0x53: 79, 0x54: 80, 0x55: 81, // keypad 1-3
        0x56: 75, 0x57: 76, 0x58: 77, // keypad 4-6
        0x59: 71, // keypad 7
        0x5B: 72, // keypad 8
        0x5C: 73, // keypad 9
        // Function keys.
        0x7A: 59, // F1
        0x78: 60, // F2
        0x63: 61, // F3
        0x76: 62, // F4
        0x60: 63, // F5
        0x61: 64, // F6
        0x62: 65, // F7
        0x64: 66, // F8
        0x65: 67, // F9
        0x6D: 68, // F10
        0x67: 87, // F11
        0x6F: 88, // F12
        // Navigation cluster.
        0x72: 110, // Help -> KEY_INSERT
        0x73: 102, // Home
        0x74: 104, // Page Up
        0x75: 111, // Forward Delete -> KEY_DELETE
        0x77: 107, // End
        0x79: 109, // Page Down
        0x7B: 105, // Left arrow
        0x7C: 106, // Right arrow
        0x7D: 108, // Down arrow
        0x7E: 103 // Up arrow
    ]

    /// Keystroke for one Character on a US layout, for scripted typing
    /// (porthole-input-test). Returns nil for characters off the table.
    static func keystroke(for character: Character) -> Keystroke? {
        switch character {
        case "a"..."z":
            let letters: [Character: UInt16] = [
                "a": 30, "b": 48, "c": 46, "d": 32, "e": 18, "f": 33,
                "g": 34, "h": 35, "i": 23, "j": 36, "k": 37, "l": 38,
                "m": 50, "n": 49, "o": 24, "p": 25, "q": 16, "r": 19,
                "s": 31, "t": 20, "u": 22, "v": 47, "w": 17, "x": 45,
                "y": 21, "z": 44
            ]
            return letters[character].map { Keystroke(code: $0, needsShift: false) }
        case "A"..."Z":
            return keystroke(for: Character(character.lowercased()))
                .map { Keystroke(code: $0.code, needsShift: true) }
        case "0"..."9":
            let digits: [Character: UInt16] = [
                "1": 2, "2": 3, "3": 4, "4": 5, "5": 6,
                "6": 7, "7": 8, "8": 9, "9": 10, "0": 11
            ]
            return digits[character].map { Keystroke(code: $0, needsShift: false) }
        case " ": return Keystroke(code: keySpace, needsShift: false)
        case "\n": return Keystroke(code: keyEnter, needsShift: false)
        case "\t": return Keystroke(code: keyTab, needsShift: false)
        default:
            return shiftedPunctuation[character] ?? plainPunctuation[character]
        }
    }

    // Punctuation on a US layout, split by whether Shift is needed.
    private static let plainPunctuation: [Character: Keystroke] = [
        "-": Keystroke(code: 12, needsShift: false),
        "=": Keystroke(code: 13, needsShift: false),
        "[": Keystroke(code: 26, needsShift: false),
        "]": Keystroke(code: 27, needsShift: false),
        ";": Keystroke(code: 39, needsShift: false),
        "'": Keystroke(code: 40, needsShift: false),
        "`": Keystroke(code: 41, needsShift: false),
        "\\": Keystroke(code: 43, needsShift: false),
        ",": Keystroke(code: 51, needsShift: false),
        ".": Keystroke(code: 52, needsShift: false),
        "/": Keystroke(code: 53, needsShift: false)
    ]

    private static let shiftedPunctuation: [Character: Keystroke] = [
        "!": Keystroke(code: 2, needsShift: true),
        "@": Keystroke(code: 3, needsShift: true),
        "#": Keystroke(code: 4, needsShift: true),
        "$": Keystroke(code: 5, needsShift: true),
        "%": Keystroke(code: 6, needsShift: true),
        "^": Keystroke(code: 7, needsShift: true),
        "&": Keystroke(code: 8, needsShift: true),
        "*": Keystroke(code: 9, needsShift: true),
        "(": Keystroke(code: 10, needsShift: true),
        ")": Keystroke(code: 11, needsShift: true),
        "_": Keystroke(code: 12, needsShift: true),
        "+": Keystroke(code: 13, needsShift: true),
        "{": Keystroke(code: 26, needsShift: true),
        "}": Keystroke(code: 27, needsShift: true),
        ":": Keystroke(code: 39, needsShift: true),
        "\"": Keystroke(code: 40, needsShift: true),
        "~": Keystroke(code: 41, needsShift: true),
        "|": Keystroke(code: 43, needsShift: true),
        "<": Keystroke(code: 51, needsShift: true),
        ">": Keystroke(code: 52, needsShift: true),
        "?": Keystroke(code: 53, needsShift: true)
    ]
}
