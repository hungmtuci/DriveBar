import Foundation
import Carbon
import AppKit

struct HotKeyBinding: Codable, Equatable, Hashable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Default Search Launcher shortcut: ⌘Space (Command + Space)
    static let defaultSearch = HotKeyBinding(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(cmdKey)
    )

    static let commandSpace = defaultSearch

    static let optionSpace = HotKeyBinding(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(optionKey)
    )

    static let controlSpace = HotKeyBinding(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(controlKey)
    )

    static let commandShiftSpace = HotKeyBinding(
        keyCode: UInt32(kVK_Space),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    /// Default Universal Actions shortcut: ⌘⇧A (Command + Shift + A)
    static let defaultUniversalAction = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    static let optionCommandA = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(optionKey | cmdKey)
    )

    static let controlShiftA = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_A),
        carbonModifiers: UInt32(controlKey | shiftKey)
    )

    static let commandShiftM = HotKeyBinding(
        keyCode: UInt32(kVK_ANSI_M),
        carbonModifiers: UInt32(cmdKey | shiftKey)
    )

    var hasCommand: Bool { (carbonModifiers & UInt32(cmdKey)) != 0 }
    var hasOption: Bool { (carbonModifiers & UInt32(optionKey)) != 0 }
    var hasControl: Bool { (carbonModifiers & UInt32(controlKey)) != 0 }
    var hasShift: Bool { (carbonModifiers & UInt32(shiftKey)) != 0 }

    var readableDisplay: String {
        var parts: [String] = []
        if hasControl { parts.append("⌃") }
        if hasOption { parts.append("⌥") }
        if hasShift { parts.append("⇧") }
        if hasCommand { parts.append("⌘") }
        parts.append(Self.keyName(for: Int(keyCode)))
        return parts.joined()
    }

    static func modifiersDisplay(for carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if (carbonModifiers & UInt32(controlKey)) != 0 { parts.append("⌃") }
        if (carbonModifiers & UInt32(optionKey)) != 0 { parts.append("⌥") }
        if (carbonModifiers & UInt32(shiftKey)) != 0 { parts.append("⇧") }
        if (carbonModifiers & UInt32(cmdKey)) != 0 { parts.append("⌘") }
        return parts.joined()
    }

    static let selectableKeys: [(keyCode: UInt32, label: String)] = [
        (UInt32(kVK_Space), "Space (Phím cách)"),
        (UInt32(kVK_Return), "Return (↩)"),
        (UInt32(kVK_Tab), "Tab (⇥)"),
        (UInt32(kVK_Delete), "Delete (⌫)"),
        (UInt32(kVK_ANSI_Grave), "` (Grave)"),
        (UInt32(kVK_ANSI_Slash), "/ (Slash)"),
        (UInt32(kVK_ANSI_Backslash), "\\ (Backslash)"),
        (UInt32(kVK_ANSI_Period), ". (Chấm)"),
        (UInt32(kVK_ANSI_Comma), ", (Phẩy)"),
        (UInt32(kVK_ANSI_Semicolon), ";"),
        (UInt32(kVK_ANSI_Quote), "'"),
        (UInt32(kVK_ANSI_Minus), "-"),
        (UInt32(kVK_ANSI_Equal), "="),
        (UInt32(kVK_ANSI_LeftBracket), "["),
        (UInt32(kVK_ANSI_RightBracket), "]"),
        (UInt32(kVK_ANSI_A), "A"), (UInt32(kVK_ANSI_B), "B"), (UInt32(kVK_ANSI_C), "C"),
        (UInt32(kVK_ANSI_D), "D"), (UInt32(kVK_ANSI_E), "E"), (UInt32(kVK_ANSI_F), "F"),
        (UInt32(kVK_ANSI_G), "G"), (UInt32(kVK_ANSI_H), "H"), (UInt32(kVK_ANSI_I), "I"),
        (UInt32(kVK_ANSI_J), "J"), (UInt32(kVK_ANSI_K), "K"), (UInt32(kVK_ANSI_L), "L"),
        (UInt32(kVK_ANSI_M), "M"), (UInt32(kVK_ANSI_N), "N"), (UInt32(kVK_ANSI_O), "O"),
        (UInt32(kVK_ANSI_P), "P"), (UInt32(kVK_ANSI_Q), "Q"), (UInt32(kVK_ANSI_R), "R"),
        (UInt32(kVK_ANSI_S), "S"), (UInt32(kVK_ANSI_T), "T"), (UInt32(kVK_ANSI_U), "U"),
        (UInt32(kVK_ANSI_V), "V"), (UInt32(kVK_ANSI_W), "W"), (UInt32(kVK_ANSI_X), "X"),
        (UInt32(kVK_ANSI_Y), "Y"), (UInt32(kVK_ANSI_Z), "Z"),
        (UInt32(kVK_ANSI_0), "0"), (UInt32(kVK_ANSI_1), "1"), (UInt32(kVK_ANSI_2), "2"),
        (UInt32(kVK_ANSI_3), "3"), (UInt32(kVK_ANSI_4), "4"), (UInt32(kVK_ANSI_5), "5"),
        (UInt32(kVK_ANSI_6), "6"), (UInt32(kVK_ANSI_7), "7"), (UInt32(kVK_ANSI_8), "8"),
        (UInt32(kVK_ANSI_9), "9"),
        (UInt32(kVK_UpArrow), "↑ (Mũi tên lên)"),
        (UInt32(kVK_DownArrow), "↓ (Mũi tên xuống)"),
        (UInt32(kVK_LeftArrow), "← (Mũi tên trái)"),
        (UInt32(kVK_RightArrow), "→ (Mũi tên phải)"),
        (UInt32(kVK_F1), "F1"), (UInt32(kVK_F2), "F2"), (UInt32(kVK_F3), "F3"),
        (UInt32(kVK_F4), "F4"), (UInt32(kVK_F5), "F5"), (UInt32(kVK_F6), "F6"),
        (UInt32(kVK_F7), "F7"), (UInt32(kVK_F8), "F8"), (UInt32(kVK_F9), "F9"),
        (UInt32(kVK_F10), "F10"), (UInt32(kVK_F11), "F11"), (UInt32(kVK_F12), "F12")
    ]

    static func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_Space: return "Space"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_F13: return "F13"
        case kVK_F14: return "F14"
        case kVK_F15: return "F15"
        case kVK_F16: return "F16"
        case kVK_F17: return "F17"
        case kVK_F18: return "F18"
        case kVK_F19: return "F19"
        default: return "Key(\(keyCode))"
        }
    }
}
