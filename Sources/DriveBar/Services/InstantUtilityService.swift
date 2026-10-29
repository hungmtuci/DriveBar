import Foundation
import AppKit
import Darwin

struct MathEvaluationResult: Equatable, Sendable {
    let expression: String
    let rawCopyString: String
    let formattedDisplay: String
}

enum SystemUtilityCategory: String, CaseIterable, Sendable {
    case displayAndSecurity = "Màn hình & Bảo mật"
    case audio = "Âm thanh"
    case apps = "Quản lý Ứng dụng"
    case finderAndDisks = "Thùng rác, Finder & Ổ đĩa"
    case sessionAndPower = "Phiên làm việc & Nguồn máy"
    case driveBarTools = "Tiện ích DriveBar & AI"
}

struct SystemUtilityDefinition: Identifiable, Sendable {
    let id: String
    let category: SystemUtilityCategory
    let primaryKeyword: String
    let title: String
    let subtitle: String
    let keywords: [String]
    let inlineExactKeywords: [String]
    let inlinePhrasePrefixes: [String]
    let supportsConfirmation: Bool
    let badge: String
    let sfSymbol: String
}

private struct MountedEjectableVolume {
    let url: URL
    let name: String
    let capacityDescription: String
}

enum InstantUtilityService {

    // MARK: - 1. Safe Recursive-Descent Math Calculator

    nonisolated static func evaluateMathExpression(_ rawQuery: String) -> MathEvaluationResult? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2, trimmed.count <= 160 else { return nil }
        guard !trimmed.hasPrefix("/") && !trimmed.hasPrefix("~") && !trimmed.lowercased().hasPrefix("http") else {
            return nil
        }

        // Normalize common math symbols (`×`, `÷`, `−`, `**`)
        let normalized = trimmed
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "**", with: "^")
            .replacingOccurrences(of: "π", with: "pi")

        // Require at least one operator or math function call so plain numbers ("2026") don't trigger calculator
        let lower = normalized.lowercased()
        let hasOperator = normalized.contains { "+-*/^%".contains($0) }
        let hasFunction = ["sqrt(", "sin(", "cos(", "tan(", "log(", "ln(", "abs(", "round(", "ceil(", "floor(", "exp("]
            .contains { lower.contains($0) }
        guard hasOperator || hasFunction else { return nil }

        var parser = MathParser(normalized)
        guard let value = parser.parseComplete(),
              value.isFinite else {
            return nil
        }

        // Reject trivial bare single-literal results like "-5" or "+10" where no actual calculation happened
        if !parser.didPerformOperation {
            return nil
        }

        let cleanRaw = formatRawNumber(value)
        let prettyDisplay = formatPrettyNumber(value)
        return MathEvaluationResult(
            expression: trimmed,
            rawCopyString: cleanRaw,
            formattedDisplay: prettyDisplay
        )
    }

    private nonisolated static func formatRawNumber(_ value: Double) -> String {
        if abs(value) < 1e-12 { return "0" }
        if abs(value.rounded() - value) < 1e-9 && abs(value) < 1e15 {
            return String(format: "%.0f", value.rounded())
        }
        let s = String(format: "%.10g", value)
        return s
    }

    private nonisolated static func formatPrettyNumber(_ value: Double) -> String {
        if abs(value) < 1e-12 { return "0" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        if abs(value.rounded() - value) < 1e-9 && abs(value) < 1e15 {
            formatter.maximumFractionDigits = 0
            return formatter.string(from: NSNumber(value: value.rounded())) ?? formatRawNumber(value)
        } else {
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 8
            return formatter.string(from: NSNumber(value: value)) ?? formatRawNumber(value)
        }
    }

    private struct MathParser {
        private let chars: [Character]
        private var pos: Int = 0
        private(set) var didPerformOperation: Bool = false

        init(_ input: String) {
            self.chars = Array(input)
        }

        mutating func parseComplete() -> Double? {
            skipWhitespace()
            guard let result = parseAddSub() else { return nil }
            skipWhitespace()
            if pos < chars.count && chars[pos] == "=" {
                pos += 1
                skipWhitespace()
            }
            guard pos == chars.count else { return nil }
            return result
        }

        private mutating func skipWhitespace() {
            while pos < chars.count && chars[pos].isWhitespace {
                pos += 1
            }
        }

        private mutating func parseAddSub() -> Double? {
            guard var left = parseMulDiv() else { return nil }
            while true {
                skipWhitespace()
                guard pos < chars.count else { break }
                let op = chars[pos]
                guard op == "+" || op == "-" else { break }
                pos += 1
                var rightWasPercent = false
                guard let right = parseMulDiv(didEndWithPercent: &rightWasPercent) else { return nil }
                didPerformOperation = true
                if rightWasPercent {
                    left = (op == "+") ? (left + left * right) : (left - left * right)
                } else {
                    left = (op == "+") ? (left + right) : (left - right)
                }
            }
            return left
        }

        private mutating func parseMulDiv(didEndWithPercent: inout Bool) -> Double? {
            didEndWithPercent = false
            guard var left = parsePower(didEndWithPercent: &didEndWithPercent) else { return nil }
            while true {
                skipWhitespace()
                guard pos < chars.count else { break }
                let op = chars[pos]
                guard op == "*" || op == "/" else { break }
                pos += 1
                var subPct = false
                guard let right = parsePower(didEndWithPercent: &subPct) else { return nil }
                didPerformOperation = true
                didEndWithPercent = false
                if op == "*" {
                    left *= right
                } else {
                    guard abs(right) > 1e-15 else { return nil }
                    left /= right
                }
            }
            return left
        }

        private mutating func parseMulDiv() -> Double? {
            var dummy = false
            return parseMulDiv(didEndWithPercent: &dummy)
        }

        private mutating func parsePower(didEndWithPercent: inout Bool) -> Double? {
            guard let base = parseUnary(didEndWithPercent: &didEndWithPercent) else { return nil }
            skipWhitespace()
            if pos < chars.count && chars[pos] == "^" {
                pos += 1
                var expPct = false
                guard let exponent = parsePower(didEndWithPercent: &expPct) else { return nil }
                didPerformOperation = true
                didEndWithPercent = false
                return pow(base, exponent)
            }
            return base
        }

        private mutating func parseUnary(didEndWithPercent: inout Bool) -> Double? {
            skipWhitespace()
            guard pos < chars.count else { return nil }
            if chars[pos] == "+" {
                pos += 1
                return parseUnary(didEndWithPercent: &didEndWithPercent)
            }
            if chars[pos] == "-" {
                pos += 1
                guard let val = parseUnary(didEndWithPercent: &didEndWithPercent) else { return nil }
                return -val
            }
            return parsePostfix(didEndWithPercent: &didEndWithPercent)
        }

        private mutating func parsePostfix(didEndWithPercent: inout Bool) -> Double? {
            guard var val = parsePrimary() else { return nil }
            skipWhitespace()
            while pos < chars.count && chars[pos] == "%" {
                pos += 1
                val /= 100.0
                didPerformOperation = true
                didEndWithPercent = true
                skipWhitespace()
            }
            return val
        }

        private mutating func parsePrimary() -> Double? {
            skipWhitespace()
            guard pos < chars.count else { return nil }

            if chars[pos] == "(" {
                pos += 1
                guard let inner = parseAddSub() else { return nil }
                skipWhitespace()
                guard pos < chars.count && chars[pos] == ")" else { return nil }
                pos += 1
                return inner
            }

            if chars[pos].isLetter {
                let start = pos
                while pos < chars.count && (chars[pos].isLetter || chars[pos].isNumber) {
                    pos += 1
                }
                let ident = String(chars[start..<pos]).lowercased()
                skipWhitespace()

                if ident == "pi" {
                    didPerformOperation = true
                    return Double.pi
                }
                if ident == "e" {
                    didPerformOperation = true
                    return M_E
                }

                guard pos < chars.count && chars[pos] == "(" else {
                    return nil
                }
                pos += 1
                guard let arg1 = parseAddSub() else { return nil }
                skipWhitespace()

                if ident == "mod" || ident == "pow" {
                    guard pos < chars.count && chars[pos] == "," else { return nil }
                    pos += 1
                    guard let arg2 = parseAddSub() else { return nil }
                    skipWhitespace()
                    guard pos < chars.count && chars[pos] == ")" else { return nil }
                    pos += 1
                    didPerformOperation = true
                    if ident == "mod" {
                        guard abs(arg2) > 1e-15 else { return nil }
                        return arg1.truncatingRemainder(dividingBy: arg2)
                    } else {
                        return pow(arg1, arg2)
                    }
                }

                guard pos < chars.count && chars[pos] == ")" else { return nil }
                pos += 1
                didPerformOperation = true

                switch ident {
                case "sqrt": return arg1 >= 0 ? sqrt(arg1) : nil
                case "sin": return sin(arg1)
                case "cos": return cos(arg1)
                case "tan": return tan(arg1)
                case "abs": return abs(arg1)
                case "log", "log10": return arg1 > 0 ? log10(arg1) : nil
                case "ln": return arg1 > 0 ? log(arg1) : nil
                case "exp": return exp(arg1)
                case "round": return arg1.rounded()
                case "ceil": return ceil(arg1)
                case "floor": return floor(arg1)
                default: return nil
                }
            }

            let start = pos
            var numStr = ""
            var sawDot = false
            while pos < chars.count {
                let c = chars[pos]
                if c.isNumber {
                    numStr.append(c)
                    pos += 1
                } else if c == "." && !sawDot {
                    sawDot = true
                    numStr.append(c)
                    pos += 1
                } else if c == "_" {
                    pos += 1
                } else if c == "," && !sawDot {
                    let rem = chars.count - (pos + 1)
                    if rem >= 3 && chars[pos + 1].isNumber && chars[pos + 2].isNumber && chars[pos + 3].isNumber {
                        let after3 = pos + 4
                        if after3 == chars.count || !chars[after3].isNumber {
                            pos += 1
                            continue
                        }
                    }
                    break
                } else {
                    break
                }
            }

            guard pos > start, let parsed = Double(numStr) else {
                return nil
            }
            return parsed
        }
    }

    // MARK: - 2. Full Alfred-Parity System Commands (`s` / `s <từ khóa>` & Direct Alfred Keywords)

    static let allSystemCommands: [SystemUtilityDefinition] = [
        // A. Display & Security
        SystemUtilityDefinition(
            id: "sys.screensaver",
            category: .displayAndSecurity,
            primaryKeyword: "screensaver",
            title: "Bật Trình bảo vệ màn hình (Screen Saver)",
            subtitle: "Kích hoạt ngay trình bảo vệ màn hình của macOS",
            keywords: ["screensaver", "screen", "saver", "man", "hinh", "cho", "bao", "ve"],
            inlineExactKeywords: ["screensaver"],
            inlinePhrasePrefixes: ["screen saver", "man hinh cho"],
            supportsConfirmation: false,
            badge: "screensaver",
            sfSymbol: "sparkles.tv"
        ),
        SystemUtilityDefinition(
            id: "sys.lock_screen",
            category: .displayAndSecurity,
            primaryKeyword: "lock",
            title: "Khóa màn hình ngay (Lock Screen)",
            subtitle: "Khóa máy Mac lập tức để bảo mật khi rời bàn làm việc",
            keywords: ["lock", "screen", "khoa", "man", "hinh", "may", "security"],
            inlineExactKeywords: ["lock"],
            inlinePhrasePrefixes: ["lock screen", "khoa man hinh", "khoa may"],
            supportsConfirmation: false,
            badge: "lock",
            sfSymbol: "lock.display"
        ),
        SystemUtilityDefinition(
            id: "sys.sleep_display",
            category: .displayAndSecurity,
            primaryKeyword: "sleepdisplays",
            title: "Tắt sáng màn hình tạm nghỉ (Sleep Displays)",
            subtitle: "Tắt sáng màn hình ngay mà không dừng các tiến trình đang chạy nền",
            keywords: ["sleepdisplays", "sleep", "display", "displays", "monitor", "tat", "man", "hinh"],
            inlineExactKeywords: ["sleepdisplays"],
            inlinePhrasePrefixes: ["sleep display", "sleep displays", "tat man hinh"],
            supportsConfirmation: false,
            badge: "sleepdisplays",
            sfSymbol: "display"
        ),
        SystemUtilityDefinition(
            id: "sys.dark_mode",
            category: .displayAndSecurity,
            primaryKeyword: "darkmode",
            title: "Chuyển chế độ Tối / Sáng (Toggle Dark Mode)",
            subtitle: "Đảo nhanh giao diện hệ thống macOS giữa Dark Mode và Light Mode",
            keywords: ["darkmode", "dark", "light", "mode", "appearance", "che", "do", "toi", "sang", "giao", "dien"],
            inlineExactKeywords: ["darkmode"],
            inlinePhrasePrefixes: ["dark mode", "light mode", "che do toi", "che do sang"],
            supportsConfirmation: false,
            badge: "darkmode",
            sfSymbol: "circle.lefthalf.filled"
        ),

        // B. Audio & Volume
        SystemUtilityDefinition(
            id: "sys.vol_up",
            category: .audio,
            primaryKeyword: "volup",
            title: "Tăng âm lượng hệ thống +10% (Volume Up)",
            subtitle: "Tăng âm lượng loa macOS thêm 10% (hoặc gõ 'vol 0..100' để đặt mức chính xác)",
            keywords: ["volup", "vol", "volume", "up", "tang", "am", "luong", "loa", "sound"],
            inlineExactKeywords: ["volup"],
            inlinePhrasePrefixes: ["volume up", "tang am luong"],
            supportsConfirmation: false,
            badge: "volup",
            sfSymbol: "speaker.wave.3.fill"
        ),
        SystemUtilityDefinition(
            id: "sys.vol_down",
            category: .audio,
            primaryKeyword: "voldown",
            title: "Giảm âm lượng hệ thống -10% (Volume Down)",
            subtitle: "Giảm âm lượng loa macOS đi 10% (hoặc gõ 'vol 0..100' để đặt mức chính xác)",
            keywords: ["voldown", "vol", "volume", "down", "giam", "nho", "am", "luong", "loa"],
            inlineExactKeywords: ["voldown"],
            inlinePhrasePrefixes: ["volume down", "giam am luong"],
            supportsConfirmation: false,
            badge: "voldown",
            sfSymbol: "speaker.wave.1.fill"
        ),
        SystemUtilityDefinition(
            id: "sys.vol_mute",
            category: .audio,
            primaryKeyword: "mute",
            title: "Tắt / Bật tiếng hệ thống (Toggle Mute)",
            subtitle: "Đảo trạng thái tắt tiếng (Mute / Unmute) âm thanh đầu ra của máy Mac",
            keywords: ["mute", "unmute", "tat", "bat", "tieng", "cam", "am", "thanh"],
            inlineExactKeywords: ["mute", "unmute"],
            inlinePhrasePrefixes: ["mute audio", "tat tieng", "bat tieng"],
            supportsConfirmation: false,
            badge: "mute",
            sfSymbol: "speaker.slash.fill"
        ),

        // C. Running Applications Management
        SystemUtilityDefinition(
            id: "sys.hide",
            category: .apps,
            primaryKeyword: "hide",
            title: "Ẩn ứng dụng đang chạy (Hide Application)",
            subtitle: "Gõ 'hide' hoặc 'hide <tên app>' để ẩn nhanh ứng dụng đang hiển thị trên màn hình",
            keywords: ["hide", "app", "application", "an", "ung", "dung"],
            inlineExactKeywords: ["hide"],
            inlinePhrasePrefixes: ["hide app", "an ung dung"],
            supportsConfirmation: false,
            badge: "hide",
            sfSymbol: "eye.slash.circle"
        ),
        SystemUtilityDefinition(
            id: "sys.quit",
            category: .apps,
            primaryKeyword: "quit",
            title: "Thoát ứng dụng đang chạy (Quit Application)",
            subtitle: "Gõ 'quit' hoặc 'quit <tên app>' để chọn và đóng an toàn ứng dụng đang mở",
            keywords: ["quit", "close", "exit", "app", "thoat", "dong", "ung", "dung"],
            inlineExactKeywords: ["quit"],
            inlinePhrasePrefixes: ["quit app", "thoat ung dung"],
            supportsConfirmation: false,
            badge: "quit",
            sfSymbol: "xmark.app"
        ),
        SystemUtilityDefinition(
            id: "sys.quit_all",
            category: .apps,
            primaryKeyword: "quitall",
            title: "Thoát tất cả ứng dụng đang mở (Quit All Apps)",
            subtitle: "Đóng lần lượt toàn bộ các ứng dụng trên thanh Dock (trừ Finder & DriveBar)",
            keywords: ["quitall", "quit", "all", "apps", "thoat", "tat", "ca", "dong", "het"],
            inlineExactKeywords: ["quitall"],
            inlinePhrasePrefixes: ["quit all", "thoat tat ca"],
            supportsConfirmation: true,
            badge: "quitall",
            sfSymbol: "xmark.rectangle"
        ),
        SystemUtilityDefinition(
            id: "sys.force_quit",
            category: .apps,
            primaryKeyword: "forcequit",
            title: "Buộc thoát ứng dụng bị treo (Force Quit)",
            subtitle: "Gõ 'forcequit <tên app>' để buộc dừng ngay ứng dụng không phản hồi",
            keywords: ["forcequit", "force", "quit", "kill", "hang", "buoc", "thoat", "treo"],
            inlineExactKeywords: ["forcequit"],
            inlinePhrasePrefixes: ["force quit", "buoc thoat"],
            supportsConfirmation: true,
            badge: "forcequit",
            sfSymbol: "bolt.slash.fill"
        ),

        // D. Trash, Finder & External Volumes
        SystemUtilityDefinition(
            id: "sys.show_trash",
            category: .finderAndDisks,
            primaryKeyword: "trash",
            title: "Mở Thùng rác trong Finder (Show Trash)",
            subtitle: "Mở và kiểm tra các tệp đang nằm trong Thùng rác của máy Mac",
            keywords: ["trash", "show", "bin", "open", "mo", "thung", "rac"],
            inlineExactKeywords: ["trash"],
            inlinePhrasePrefixes: ["show trash", "open trash", "mo thung rac"],
            supportsConfirmation: false,
            badge: "trash",
            sfSymbol: "trash.circle"
        ),
        SystemUtilityDefinition(
            id: "sys.empty_trash",
            category: .finderAndDisks,
            primaryKeyword: "emptytrash",
            title: "Dọn sạch Thùng rác (Empty Trash)",
            subtitle: "Xóa vĩnh viễn toàn bộ các mục đang nằm trong Thùng rác Finder",
            keywords: ["emptytrash", "empty", "trash", "don", "sach", "thung", "rac", "xoa"],
            inlineExactKeywords: ["emptytrash"],
            inlinePhrasePrefixes: ["empty trash", "don thung rac", "xoa thung rac"],
            supportsConfirmation: true,
            badge: "emptytrash",
            sfSymbol: "trash.slash"
        ),
        SystemUtilityDefinition(
            id: "sys.eject",
            category: .finderAndDisks,
            primaryKeyword: "eject",
            title: "Tháo an toàn từng ổ đĩa ngoài / USB / DMG (Eject)",
            subtitle: "Gõ 'eject' hoặc 'eject <tên ổ>' để liệt kê và ngắt kết nối từng ổ đĩa ngoài",
            keywords: ["eject", "disk", "volume", "usb", "sd", "dmg", "unmount", "thao", "ngat", "o", "dia"],
            inlineExactKeywords: ["eject"],
            inlinePhrasePrefixes: ["eject disk", "thao o dia", "ngat usb"],
            supportsConfirmation: false,
            badge: "eject",
            sfSymbol: "eject.circle"
        ),
        SystemUtilityDefinition(
            id: "sys.eject_all",
            category: .finderAndDisks,
            primaryKeyword: "ejectall",
            title: "Ngắt kết nối tất cả ổ đĩa ngoài & DMG (Eject All)",
            subtitle: "Tháo an toàn đồng thời toàn bộ USB, thẻ nhớ, ổ cứng di động và đĩa ảo .dmg",
            keywords: ["ejectall", "eject", "all", "disks", "usb", "dmg", "thao", "tat", "ca", "o", "dia"],
            inlineExactKeywords: ["ejectall"],
            inlinePhrasePrefixes: ["eject all", "thao tat ca o dia"],
            supportsConfirmation: false,
            badge: "ejectall",
            sfSymbol: "eject.fill"
        ),
        SystemUtilityDefinition(
            id: "sys.finder_hidden",
            category: .finderAndDisks,
            primaryKeyword: "hiddenfiles",
            title: "Hiện / Ẩn tệp ẩn hệ thống trong Finder",
            subtitle: "Đảo cờ AppleShowAllFiles của Finder và làm mới cửa sổ Finder",
            keywords: ["hiddenfiles", "hidden", "files", "finder", "dotfiles", "tep", "an", "hien"],
            inlineExactKeywords: ["hiddenfiles"],
            inlinePhrasePrefixes: ["hidden files", "hien tep an", "an tep an"],
            supportsConfirmation: false,
            badge: "hiddenfiles",
            sfSymbol: "doc.badge.gearshape"
        ),

        // E. Session & Power
        SystemUtilityDefinition(
            id: "sys.sleep",
            category: .sessionAndPower,
            primaryKeyword: "sleep",
            title: "Đưa máy Mac vào chế độ Ngủ (Sleep)",
            subtitle: "Tạm ngủ toàn bộ hệ thống máy Mac để tiết kiệm năng lượng",
            keywords: ["sleep", "mac", "ngu", "may", "che", "do", "ngu"],
            inlineExactKeywords: ["sleep"],
            inlinePhrasePrefixes: ["sleep mac", "che do ngu"],
            supportsConfirmation: false,
            badge: "sleep",
            sfSymbol: "moon.fill"
        ),
        SystemUtilityDefinition(
            id: "sys.logout",
            category: .sessionAndPower,
            primaryKeyword: "logout",
            title: "Đăng xuất tài khoản macOS (Log Out)",
            subtitle: "Đóng phiên làm việc của tài khoản người dùng hiện tại trên macOS",
            keywords: ["logout", "log", "out", "signout", "dang", "xuat", "phien"],
            inlineExactKeywords: ["logout"],
            inlinePhrasePrefixes: ["log out", "sign out", "dang xuat"],
            supportsConfirmation: true,
            badge: "logout",
            sfSymbol: "rectangle.portrait.and.arrow.right"
        ),
        SystemUtilityDefinition(
            id: "sys.restart",
            category: .sessionAndPower,
            primaryKeyword: "restart",
            title: "Khởi động lại máy Mac (Restart)",
            subtitle: "Đóng các ứng dụng và khởi động lại hệ điều hành macOS",
            keywords: ["restart", "reboot", "khoi", "dong", "lai", "may"],
            inlineExactKeywords: ["restart", "reboot"],
            inlinePhrasePrefixes: ["restart mac", "khoi dong lai"],
            supportsConfirmation: true,
            badge: "restart",
            sfSymbol: "restart.circle"
        ),
        SystemUtilityDefinition(
            id: "sys.shutdown",
            category: .sessionAndPower,
            primaryKeyword: "shutdown",
            title: "Tắt nguồn máy Mac (Shut Down)",
            subtitle: "Đóng toàn bộ ứng dụng và tắt hẳn nguồn máy tính Mac",
            keywords: ["shutdown", "shut", "down", "poweroff", "tat", "may", "nguon"],
            inlineExactKeywords: ["shutdown", "poweroff"],
            inlinePhrasePrefixes: ["shut down", "tat may", "tat nguon"],
            supportsConfirmation: true,
            badge: "shutdown",
            sfSymbol: "power"
        ),

        // F. DriveBar & AI Utilities
        SystemUtilityDefinition(
            id: "sys.ocr_clipboard",
            category: .driveBarTools,
            primaryKeyword: "ocr",
            title: "OCR Ảnh trong Clipboard sang Markdown / Văn bản",
            subtitle: "Nhận diện chữ Tiếng Việt & Tiếng Anh từ ảnh chụp màn hình vừa lưu trong Clipboard",
            keywords: ["ocr", "clipboard", "screenshot", "image", "vision", "anh", "chup", "trich", "xuat"],
            inlineExactKeywords: [],
            inlinePhrasePrefixes: ["ocr clipboard", "ocr anh"],
            supportsConfirmation: false,
            badge: "ocr",
            sfSymbol: "text.viewfinder"
        ),
        SystemUtilityDefinition(
            id: "sys.clear_clipboard",
            category: .driveBarTools,
            primaryKeyword: "clearclipboard",
            title: "Xóa lịch sử Clipboard của DriveBar",
            subtitle: "Làm sạch danh sách các mục đã lưu trong bộ nhớ lịch sử Clipboard ('cb ')",
            keywords: ["clearclipboard", "clear", "clipboard", "history", "xoa", "lich", "su"],
            inlineExactKeywords: ["clearclipboard"],
            inlinePhrasePrefixes: ["clear clipboard", "xoa clipboard"],
            supportsConfirmation: false,
            badge: "clearclipboard",
            sfSymbol: "xmark.bin"
        ),
        SystemUtilityDefinition(
            id: "sys.rebuild_index",
            category: .driveBarTools,
            primaryKeyword: "rebuild",
            title: "Quét lại toàn bộ chỉ mục Google Drive & Tệp tin",
            subtitle: "Cập nhật nền danh sách thư mục, tệp tin và ứng dụng mới nhất",
            keywords: ["rebuild", "reindex", "refresh", "cache", "quet", "lai", "dong", "bo"],
            inlineExactKeywords: [],
            inlinePhrasePrefixes: ["rebuild cache", "quet lai google drive"],
            supportsConfirmation: false,
            badge: "rebuild",
            sfSymbol: "arrow.clockwise.circle"
        )
    ]

    // MARK: - Search & Dynamic Expansion

    @MainActor
    static func searchSystemCommands(query: String, isExplicitSystemMode: Bool) -> [SearchResultItem] {
        let settings = AppSettings.shared
        let enabledDefs = allSystemCommands.filter { settings.isSystemCommandEnabled($0.id) }

        let qNorm = GoogleDriveIndexService.removeAccents(query)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if isExplicitSystemMode && qNorm.isEmpty {
            return enabledDefs.map { makeResultItem($0, settings: settings) }
        }

        guard !qNorm.isEmpty else { return [] }

        var results: [SearchResultItem] = []

        // 1. Dynamic Parameterized Commands (`quit`, `forcequit`, `hide`, `eject`, `vol 0..100`)
        results.append(contentsOf: buildDynamicTargetItems(qNorm: qNorm, settings: settings))

        // 2. Static Commands Matching
        if isExplicitSystemMode {
            let tokens = qNorm.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            let matched = enabledDefs.filter { def in
                // Avoid duplicating the generic template row when dynamic target list is already expanded
                if !results.isEmpty && ["sys.quit", "sys.force_quit", "sys.hide", "sys.eject"].contains(def.id),
                   (qNorm == def.primaryKeyword || qNorm.hasPrefix(def.primaryKeyword + " ")) {
                    return false
                }
                let hay = GoogleDriveIndexService.removeAccents("\(def.primaryKeyword) \(def.title) \(def.subtitle)").lowercased()
                    + " " + def.keywords.joined(separator: " ")
                return tokens.allSatisfy { hay.contains($0) }
            }
            results.append(contentsOf: matched.map { makeResultItem($0, settings: settings) })

            if results.isEmpty {
                return [
                    SearchResultItem(
                        id: "sys:empty",
                        title: "Không có lệnh hệ thống nào khớp '\(query)'",
                        subtitle: "Thử gõ: lock, sleep, screensaver, trash, emptytrash, volup, mute, quit, forcequit, eject, restart, shutdown...",
                        path: nil,
                        isDirectory: false,
                        kind: .infoBanner,
                        badge: "Hệ thống",
                        sfSymbolFallback: "gearshape"
                    )
                ]
            }
            return results
        } else {
            let matchedStatic = enabledDefs.filter { def in
                if !results.isEmpty && ["sys.quit", "sys.force_quit", "sys.hide", "sys.eject"].contains(def.id) {
                    return false
                }
                if def.inlineExactKeywords.contains(qNorm) {
                    return true
                }
                if qNorm.count >= 5 {
                    return def.inlinePhrasePrefixes.contains { phrase in
                        phrase.hasPrefix(qNorm) || qNorm == phrase
                    }
                }
                return false
            }
            results.append(contentsOf: matchedStatic.map { makeResultItem($0, settings: settings) })
            return results
        }
    }

    @MainActor
    private static func buildDynamicTargetItems(qNorm: String, settings: AppSettings) -> [SearchResultItem] {
        var items: [SearchResultItem] = []

        // A. Exact Volume Level (`vol 50`, `volume 75`, `am luong 40`)
        let volPrefixes = ["vol ", "volume ", "am luong "]
        if (settings.isSystemCommandEnabled("sys.vol_up") || settings.isSystemCommandEnabled("sys.vol_down")),
           let matchedPrefix = volPrefixes.first(where: { qNorm.hasPrefix($0) }) {
            let arg = String(qNorm.dropFirst(matchedPrefix.count)).trimmingCharacters(in: .whitespaces)
            if let pct = Int(arg), (0...100).contains(pct) {
                items.append(SearchResultItem(
                    id: "syscmd:vol_set:\(pct)",
                    title: "Đặt âm lượng hệ thống thành \(pct)%",
                    subtitle: pct == 0
                        ? "Nhấn Enter (↩) để đưa âm lượng về 0% (Tắt tiếng)"
                        : "Nhấn Enter (↩) để điều chỉnh ngay âm lượng đầu ra macOS thành \(pct)%",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "sys.vol_set:\(pct)"),
                    badge: "\(pct)%",
                    sfSymbolFallback: pct == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
                ))
            }
        }

        // B. Quit Running Application (`quit` or `quit <app>`)
        if settings.isSystemCommandEnabled("sys.quit"),
           (qNorm == "quit" || qNorm.hasPrefix("quit ")) {
            let appFilter = qNorm == "quit" ? "" : String(qNorm.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            let apps = matchingRunningApps(filter: appFilter, onlyVisible: false, includeFinder: false)
            for app in apps.prefix(15) {
                let name = app.localizedName ?? "Ứng dụng"
                items.append(SearchResultItem(
                    id: "syscmd:quit:\(app.processIdentifier)",
                    title: "Thoát \(name) (Quit)",
                    subtitle: "Đóng an toàn ứng dụng \(name) • PID \(app.processIdentifier)",
                    path: app.bundleURL?.path,
                    isDirectory: false,
                    kind: .systemCommand(id: "sys.quit_pid:\(app.processIdentifier)"),
                    badge: "Quit",
                    sfSymbolFallback: "xmark.app"
                ))
            }
        }

        // C. Force Quit Application (`forcequit`, `force quit`, `forcequit <app>`)
        if settings.isSystemCommandEnabled("sys.force_quit"),
           (qNorm == "forcequit" || qNorm.hasPrefix("forcequit ") || qNorm == "force quit" || qNorm.hasPrefix("force quit ")) {
            let appFilter: String
            if qNorm.hasPrefix("forcequit ") {
                appFilter = String(qNorm.dropFirst("forcequit ".count)).trimmingCharacters(in: .whitespaces)
            } else if qNorm.hasPrefix("force quit ") {
                appFilter = String(qNorm.dropFirst("force quit ".count)).trimmingCharacters(in: .whitespaces)
            } else {
                appFilter = ""
            }
            let needsConfirm = settings.requiresSystemCommandConfirmation("sys.force_quit")
            let apps = matchingRunningApps(filter: appFilter, onlyVisible: false, includeFinder: true)
            for app in apps.prefix(15) {
                let name = app.localizedName ?? "Ứng dụng"
                let sub = needsConfirm
                    ? "Buộc dừng ngay \(name) (Có hộp thoại xác nhận • ⌥↩ bỏ qua hỏi)"
                    : "Buộc dừng ngay lập tức tiến trình \(name) (PID \(app.processIdentifier))"
                items.append(SearchResultItem(
                    id: "syscmd:forcequit:\(app.processIdentifier)",
                    title: "Buộc thoát \(name) (Force Quit)",
                    subtitle: sub,
                    path: app.bundleURL?.path,
                    isDirectory: false,
                    kind: .systemCommand(id: "sys.force_quit_pid:\(app.processIdentifier)"),
                    badge: needsConfirm ? "Xác nhận" : "Force Quit",
                    sfSymbolFallback: "bolt.slash.fill"
                ))
            }
            if appFilter.isEmpty {
                items.append(SearchResultItem(
                    id: "syscmd:forcequit:dialog",
                    title: "Mở cửa sổ Buộc thoát Ứng dụng của macOS (⌘⌥Esc)",
                    subtitle: "Hiển thị hộp thoại Force Quit Applications mặc định của hệ thống",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "sys.force_quit_dialog"),
                    badge: "macOS",
                    sfSymbolFallback: "bolt.slash.fill"
                ))
            }
        }

        // D. Hide Application (`hide` or `hide <app>`)
        if settings.isSystemCommandEnabled("sys.hide"),
           (qNorm == "hide" || qNorm.hasPrefix("hide ")) {
            let appFilter = qNorm == "hide" ? "" : String(qNorm.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            let apps = matchingRunningApps(filter: appFilter, onlyVisible: true, includeFinder: false)
            for app in apps.prefix(12) {
                let name = app.localizedName ?? "Ứng dụng"
                items.append(SearchResultItem(
                    id: "syscmd:hide:\(app.processIdentifier)",
                    title: "Ẩn \(name) (Hide)",
                    subtitle: "Ẩn các cửa sổ đang mở của \(name) khỏi màn hình (⌘H)",
                    path: app.bundleURL?.path,
                    isDirectory: false,
                    kind: .systemCommand(id: "sys.hide_pid:\(app.processIdentifier)"),
                    badge: "Hide",
                    sfSymbolFallback: "eye.slash.circle"
                ))
            }
        }

        // E. Eject Individual Mounted Volume (`eject` or `eject <volume>`, excluding `ejectall` / `eject all`)
        if settings.isSystemCommandEnabled("sys.eject"),
           (qNorm == "eject" || (qNorm.hasPrefix("eject ") && !qNorm.hasPrefix("eject all"))) {
            let volFilter = qNorm == "eject" ? "" : String(qNorm.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            let volumes = mountedEjectableVolumes(filter: volFilter)
            if volumes.isEmpty && volFilter.isEmpty {
                items.append(SearchResultItem(
                    id: "syscmd:eject:none",
                    title: "Không có ổ đĩa ngoài, USB hoặc đĩa ảo .DMG nào đang gắn",
                    subtitle: "Gắn USB, thẻ nhớ hoặc mở file .dmg để tháo an toàn tại đây",
                    path: nil,
                    isDirectory: false,
                    kind: .infoBanner,
                    badge: "Ổ đĩa",
                    sfSymbolFallback: "eject.circle"
                ))
            } else {
                for vol in volumes {
                    items.append(SearchResultItem(
                        id: "syscmd:eject_vol:\(vol.url.path)",
                        title: "Tháo ổ đĩa '\(vol.name)' (Eject)",
                        subtitle: "\(vol.capacityDescription) • Nhấn Enter (↩) để ngắt kết nối an toàn",
                        path: vol.url.path,
                        isDirectory: true,
                        kind: .systemCommand(id: "sys.eject_vol:\(vol.url.path)"),
                        badge: "Eject",
                        sfSymbolFallback: "eject.circle"
                    ))
                }
                if volumes.count >= 2 && volFilter.isEmpty && settings.isSystemCommandEnabled("sys.eject_all") {
                    let names = volumes.map(\.name).joined(separator: ", ")
                    items.append(SearchResultItem(
                        id: "syscmd:eject_all_inline",
                        title: "Ngắt kết nối tất cả \(volumes.count) ổ đĩa cùng lúc (Eject All)",
                        subtitle: names,
                        path: nil,
                        isDirectory: false,
                        kind: .systemCommand(id: "sys.eject_all"),
                        badge: "ejectall",
                        sfSymbolFallback: "eject.fill"
                    ))
                }
            }
        }

        return items
    }

    @MainActor
    private static func makeResultItem(_ def: SystemUtilityDefinition, settings: AppSettings) -> SearchResultItem {
        let needsConfirm = def.supportsConfirmation && settings.requiresSystemCommandConfirmation(def.id)
        var sub = def.subtitle
        if def.id == "sys.show_trash" || def.id == "sys.empty_trash" {
            let count = trashItemCountFast()
            let trashNote = count == 0 ? "Thùng rác hiện đang trống" : "Đang có \(count) mục trong Thùng rác"
            sub = "\(trashNote) • \(def.subtitle)"
        }
        if needsConfirm {
            sub += " • Hỏi xác nhận (⌥↩ bỏ qua)"
        }

        return SearchResultItem(
            id: "syscmd:\(def.id)",
            title: def.title,
            subtitle: sub,
            path: nil,
            isDirectory: false,
            kind: .systemCommand(id: def.id),
            badge: needsConfirm ? "\(def.badge) • Xác nhận" : def.badge,
            sfSymbolFallback: def.sfSymbol
        )
    }

    // MARK: - 3. Execution Engine (with Optional Native Confirmation Alert)

    @MainActor
    static func executeSystemUtility(id: String, viewModel: LauncherViewModel, modifiers: NSEvent.ModifierFlags) -> Bool {
        // Contacts permission / app helper commands
        if id == "contact.request_access" {
            ContactsSearchService.shared.requestAccessIfNeeded()
            return true
        }
        if id == "contact.open_settings" {
            ContactsSearchService.shared.openContactsPrivacySettings()
            return true
        }
        if id == "contact.open_app" {
            LauncherPanelController.shared.hide()
            _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Contacts.app"))
            return true
        }

        // Dynamic PID / Volume / Volume-% commands
        if id.hasPrefix("sys.vol_set:"), let pct = Int(id.dropFirst("sys.vol_set:".count)) {
            LauncherPanelController.shared.hide()
            let clamped = max(0, min(100, pct))
            Task.detached(priority: .userInitiated) {
                let script = clamped == 0
                    ? "set volume output volume 0 with output muted"
                    : "set volume output volume \(clamped) without output muted"
                _ = runOSAScript(script)
                await MainActor.run {
                    FloatingToastController.shared.showSuccess(
                        title: clamped == 0 ? "Đã tắt tiếng (0%)" : "Đã đặt âm lượng: \(clamped)%",
                        subtitle: "Âm thanh hệ thống macOS",
                        symbol: clamped == 0 ? "speaker.slash.fill" : "speaker.wave.3.fill"
                    )
                }
            }
            return true
        }

        if id.hasPrefix("sys.quit_pid:"), let pid = Int32(id.dropFirst("sys.quit_pid:".count)) {
            LauncherPanelController.shared.hide()
            if let app = NSRunningApplication(processIdentifier: pid) {
                let name = app.localizedName ?? "Ứng dụng"
                _ = app.terminate()
                FloatingToastController.shared.showSuccess(
                    title: "Đã gửi lệnh thoát \(name)",
                    subtitle: "Quit Application",
                    symbol: "xmark.app"
                )
            }
            return true
        }

        if id.hasPrefix("sys.force_quit_pid:"), let pid = Int32(id.dropFirst("sys.force_quit_pid:".count)) {
            guard let app = NSRunningApplication(processIdentifier: pid) else {
                LauncherPanelController.shared.hide()
                return true
            }
            let name = app.localizedName ?? "Ứng dụng"
            LauncherPanelController.shared.hide()
            guard confirmIfRequired(
                commandID: "sys.force_quit",
                modifiers: modifiers,
                title: "Buộc thoát '\(name)' ngay lập tức?",
                message: "Mọi thay đổi chưa lưu trong '\(name)' sẽ bị mất nếu buộc dừng tiến trình này.",
                confirmButtonTitle: "Buộc thoát"
            ) else {
                return true
            }
            let terminated = app.forceTerminate()
            if !terminated {
                _ = Darwin.kill(pid, SIGKILL)
            }
            FloatingToastController.shared.showSuccess(
                title: "Đã buộc thoát \(name)",
                subtitle: "Force Quit hoàn tất",
                symbol: "bolt.slash.fill"
            )
            return true
        }

        if id == "sys.force_quit_dialog" {
            LauncherPanelController.shared.hide()
            Task.detached(priority: .userInitiated) {
                _ = runOSAScript("tell application \"System Events\" to key code 53 using {command down, option down}")
            }
            return true
        }

        if id.hasPrefix("sys.hide_pid:"), let pid = Int32(id.dropFirst("sys.hide_pid:".count)) {
            LauncherPanelController.shared.hide()
            if let app = NSRunningApplication(processIdentifier: pid) {
                let name = app.localizedName ?? "Ứng dụng"
                _ = app.hide()
                FloatingToastController.shared.showSuccess(
                    title: "Đã ẩn \(name)",
                    subtitle: "Hide Application",
                    symbol: "eye.slash.circle"
                )
            }
            return true
        }

        if id.hasPrefix("sys.eject_vol:") {
            let volPath = String(id.dropFirst("sys.eject_vol:".count))
            let volURL = URL(fileURLWithPath: volPath)
            let volName = (try? volURL.resourceValues(forKeys: [.volumeLocalizedNameKey]).volumeLocalizedName) ?? volURL.lastPathComponent
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: "Đang tháo an toàn '\(volName)'...",
                subtitle: volPath
            )
            Task.detached(priority: .userInitiated) {
                do {
                    try NSWorkspace.shared.unmountAndEjectDevice(at: volURL)
                    await MainActor.run {
                        FloatingToastController.shared.showSuccess(
                            title: "Đã ngắt kết nối '\(volName)' an toàn",
                            subtitle: "Bạn có thể rút thiết bị khỏi máy Mac",
                            symbol: "eject.fill"
                        )
                    }
                } catch {
                    await MainActor.run {
                        FloatingToastController.shared.showError(
                            title: "Không thể tháo '\(volName)'",
                            subtitle: error.localizedDescription
                        )
                    }
                }
            }
            return true
        }

        // Static System Commands
        switch id {
        case "sys.screensaver":
            LauncherPanelController.shared.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                _ = NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app"))
            }
            return true

        case "sys.lock_screen":
            LauncherPanelController.shared.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                lockMacScreenImmediately()
            }
            return true

        case "sys.sleep_display":
            LauncherPanelController.shared.hide()
            Task.detached(priority: .userInitiated) {
                _ = runSimpleProcess("/usr/bin/pmset", ["displaysleepnow"])
            }
            return true

        case "sys.dark_mode":
            LauncherPanelController.shared.hide()
            Task.detached(priority: .userInitiated) {
                let script = """
                tell application "System Events"
                    tell appearance preferences
                        set dark mode to not dark mode
                        return dark mode
                    end tell
                end tell
                """
                let out = runOSAScript(script)
                let isDarkNow = out?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
                await MainActor.run {
                    FloatingToastController.shared.showSuccess(
                        title: isDarkNow ? "Đã chuyển sang Chế độ Tối (Dark Mode)" : "Đã chuyển sang Chế độ Sáng (Light Mode)",
                        subtitle: "Giao diện hệ thống macOS",
                        symbol: "circle.lefthalf.filled"
                    )
                }
            }
            return true

        case "sys.vol_up":
            LauncherPanelController.shared.hide()
            Task.detached(priority: .userInitiated) {
                let script = """
                set curVol to output volume of (get volume settings)
                set nextVol to curVol + 10
                if nextVol > 100 then set nextVol to 100
                set volume output volume nextVol without output muted
                return nextVol
                """
                let out = runOSAScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run {
                    FloatingToastController.shared.showSuccess(
                        title: out.isEmpty ? "Đã tăng âm lượng (+10%)" : "Âm lượng: \(out)%",
                        subtitle: "Volume Up",
                        symbol: "speaker.wave.3.fill"
                    )
                }
            }
            return true

        case "sys.vol_down":
            LauncherPanelController.shared.hide()
            Task.detached(priority: .userInitiated) {
                let script = """
                set curVol to output volume of (get volume settings)
                set nextVol to curVol - 10
                if nextVol < 0 then set nextVol to 0
                set volume output volume nextVol
                return nextVol
                """
                let out = runOSAScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run {
                    FloatingToastController.shared.showSuccess(
                        title: out.isEmpty ? "Đã giảm âm lượng (-10%)" : "Âm lượng: \(out)%",
                        subtitle: "Volume Down",
                        symbol: "speaker.wave.1.fill"
                    )
                }
            }
            return true

        case "sys.vol_mute":
            LauncherPanelController.shared.hide()
            Task.detached(priority: .userInitiated) {
                let script = """
                set curMuted to output muted of (get volume settings)
                set nextMuted to not curMuted
                set volume output muted nextMuted
                return nextMuted
                """
                let out = runOSAScript(script)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let isMuted = (out == "true")
                await MainActor.run {
                    FloatingToastController.shared.showSuccess(
                        title: isMuted ? "Đã tắt tiếng hệ thống (Muted)" : "Đã bật tiếng hệ thống (Unmuted)",
                        subtitle: "Audio Output",
                        symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
                    )
                }
            }
            return true

        case "sys.hide":
            // When triggered from `s` browse list, expand running visible apps or hide previousFrontApp directly
            if let prev = LauncherPanelController.shared.previousFrontApp,
               !prev.isTerminated,
               prev.bundleIdentifier != "com.apple.finder" {
                LauncherPanelController.shared.hide()
                let name = prev.localizedName ?? "Ứng dụng"
                _ = prev.hide()
                FloatingToastController.shared.showSuccess(
                    title: "Đã ẩn \(name)",
                    subtitle: "Hide Application",
                    symbol: "eye.slash.circle"
                )
            } else {
                viewModel.searchText = "hide "
                viewModel.triggerInputFocus(selectAll: false)
            }
            return true

        case "sys.quit":
            viewModel.searchText = "quit "
            viewModel.triggerInputFocus(selectAll: false)
            return true

        case "sys.force_quit":
            viewModel.searchText = "forcequit "
            viewModel.triggerInputFocus(selectAll: false)
            return true

        case "sys.eject":
            let vols = mountedEjectableVolumes(filter: "")
            if vols.count == 1 {
                return executeSystemUtility(id: "sys.eject_vol:\(vols[0].url.path)", viewModel: viewModel, modifiers: modifiers)
            }
            viewModel.searchText = "eject "
            viewModel.triggerInputFocus(selectAll: false)
            return true

        case "sys.quit_all":
            let appsToQuit = matchingRunningApps(filter: "", onlyVisible: false, includeFinder: false)
            LauncherPanelController.shared.hide()
            guard !appsToQuit.isEmpty else {
                FloatingToastController.shared.showSuccess(
                    title: "Không có ứng dụng nào đang mở để đóng",
                    subtitle: "Quit All Apps",
                    symbol: "xmark.rectangle"
                )
                return true
            }
            let previewNames = appsToQuit.prefix(6).compactMap(\.localizedName).joined(separator: ", ")
            guard confirmIfRequired(
                commandID: "sys.quit_all",
                modifiers: modifiers,
                title: "Thoát tất cả \(appsToQuit.count) ứng dụng đang mở?",
                message: "DriveBar sẽ gửi lệnh đóng an toàn tới: \(previewNames)\(appsToQuit.count > 6 ? "..." : ""). Các ứng dụng có tài liệu chưa lưu sẽ hỏi bạn trước khi đóng.",
                confirmButtonTitle: "Thoát tất cả"
            ) else {
                return true
            }
            for app in appsToQuit {
                _ = app.terminate()
            }
            FloatingToastController.shared.showSuccess(
                title: "Đã gửi lệnh đóng \(appsToQuit.count) ứng dụng",
                subtitle: previewNames,
                symbol: "xmark.rectangle"
            )
            return true

        case "sys.show_trash":
            LauncherPanelController.shared.hide()
            let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")
            _ = NSWorkspace.shared.open(trashURL)
            return true

        case "sys.empty_trash":
            let count = trashItemCountFast()
            LauncherPanelController.shared.hide()
            if count == 0 {
                FloatingToastController.shared.showSuccess(
                    title: "Thùng rác hiện đang trống",
                    subtitle: "Finder",
                    symbol: "trash.slash"
                )
                return true
            }
            guard confirmIfRequired(
                commandID: "sys.empty_trash",
                modifiers: modifiers,
                title: "Dọn sạch Thùng rác (\(count) mục)?",
                message: "Bạn có chắc chắn muốn xóa vĩnh viễn toàn bộ các mục trong Thùng rác không? Không thể hoàn tác thao tác này.",
                confirmButtonTitle: "Dọn sạch Thùng rác"
            ) else {
                return true
            }
            FloatingToastController.shared.showProgress(
                title: "Đang dọn sạch Thùng rác...",
                subtitle: "Finder"
            )
            Task.detached(priority: .userInitiated) {
                let res = runOSAScript("tell application \"Finder\" to empty trash")
                let ok = (res != nil)
                await MainActor.run {
                    if ok {
                        FloatingToastController.shared.showSuccess(
                            title: "Đã dọn sạch Thùng rác",
                            subtitle: "Finder",
                            symbol: "trash.slash"
                        )
                    } else {
                        FloatingToastController.shared.showError(
                            title: "Không thể dọn Thùng rác hoặc cần xác nhận từ Finder",
                            subtitle: "Finder"
                        )
                    }
                }
            }
            return true

        case "sys.eject_all":
            LauncherPanelController.shared.hide()
            Task.detached(priority: .userInitiated) {
                let vols = mountedEjectableVolumes(filter: "")
                var ejectedNames: [String] = []
                for vol in vols {
                    if (try? NSWorkspace.shared.unmountAndEjectDevice(at: vol.url)) != nil {
                        ejectedNames.append(vol.name)
                    }
                }
                let finalNames = ejectedNames
                await MainActor.run {
                    if finalNames.isEmpty {
                        FloatingToastController.shared.showSuccess(
                            title: "Không có ổ đĩa ngoài hoặc DMG nào đang gắn",
                            subtitle: "Tất cả thiết bị đã an toàn",
                            symbol: "eject.fill"
                        )
                    } else {
                        FloatingToastController.shared.showSuccess(
                            title: "Đã ngắt kết nối \(finalNames.count) ổ đĩa an toàn",
                            subtitle: finalNames.joined(separator: ", "),
                            symbol: "eject.fill"
                        )
                    }
                }
            }
            return true

        case "sys.finder_hidden":
            LauncherPanelController.shared.hide()
            Task.detached(priority: .userInitiated) {
                let curOut = runSimpleProcess("/usr/bin/defaults", ["read", "com.apple.finder", "AppleShowAllFiles"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let currentlyShowing = (curOut == "1" || curOut == "true" || curOut == "yes")
                let nextBool = currentlyShowing ? "false" : "true"
                _ = runSimpleProcess("/usr/bin/defaults", ["write", "com.apple.finder", "AppleShowAllFiles", "-bool", nextBool])
                _ = runSimpleProcess("/usr/bin/killall", ["Finder"])
                let nowShowing = !currentlyShowing
                await MainActor.run {
                    FloatingToastController.shared.showSuccess(
                        title: nowShowing ? "Đã HIỆN các tệp ẩn trong Finder" : "Đã ẨN các tệp ẩn hệ thống trong Finder",
                        subtitle: "Cửa sổ Finder đã được cập nhật",
                        symbol: "doc.badge.gearshape"
                    )
                }
            }
            return true

        case "sys.sleep":
            LauncherPanelController.shared.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                Task.detached(priority: .userInitiated) {
                    if runOSAScript("tell application \"System Events\" to sleep") == nil {
                        _ = runSimpleProcess("/usr/bin/pmset", ["sleepnow"])
                    }
                }
            }
            return true

        case "sys.logout":
            LauncherPanelController.shared.hide()
            guard confirmIfRequired(
                commandID: "sys.logout",
                modifiers: modifiers,
                title: "Đăng xuất khỏi tài khoản macOS hiện tại?",
                message: "Tất cả các ứng dụng đang chạy sẽ được đóng lại để kết thúc phiên làm việc.",
                confirmButtonTitle: "Đăng xuất"
            ) else {
                return true
            }
            Task.detached(priority: .userInitiated) {
                if runOSAScript("tell application \"loginwindow\" to «event aevtrlgo»") == nil {
                    _ = runOSAScript("tell application \"System Events\" to log out")
                }
            }
            return true

        case "sys.restart":
            LauncherPanelController.shared.hide()
            guard confirmIfRequired(
                commandID: "sys.restart",
                modifiers: modifiers,
                title: "Khởi động lại máy Mac?",
                message: "Bạn có chắc chắn muốn đóng các ứng dụng đang mở và khởi động lại máy Mac ngay bây giờ không?",
                confirmButtonTitle: "Khởi động lại"
            ) else {
                return true
            }
            Task.detached(priority: .userInitiated) {
                _ = runOSAScript("tell application \"System Events\" to restart")
            }
            return true

        case "sys.shutdown":
            LauncherPanelController.shared.hide()
            guard confirmIfRequired(
                commandID: "sys.shutdown",
                modifiers: modifiers,
                title: "Tắt nguồn máy Mac?",
                message: "Bạn có chắc chắn muốn đóng toàn bộ ứng dụng và tắt nguồn máy tính ngay bây giờ không?",
                confirmButtonTitle: "Tắt máy"
            ) else {
                return true
            }
            Task.detached(priority: .userInitiated) {
                _ = runOSAScript("tell application \"System Events\" to shut down")
            }
            return true

        case "sys.ocr_clipboard":
            viewModel.runClipboardImageOCR(openPreview: modifiers.contains(.option))
            return true

        case "sys.clear_clipboard":
            ClipboardHistoryService.shared.clearHistory()
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showSuccess(
                title: "Đã xóa lịch sử Clipboard",
                subtitle: "DriveBar Clipboard History",
                symbol: "xmark.bin"
            )
            return true

        case "sys.rebuild_index":
            GoogleDriveIndexService.shared.rebuildAllCaches()
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: "Đang quét lại chỉ mục Google Drive & Tệp tin...",
                subtitle: "Hoạt động mượt ở nền"
            )
            return true

        default:
            return false
        }
    }

    // MARK: - Helpers (Confirmation, Running Apps, Volumes, Trash & Process Runners)

    @MainActor
    private static func confirmIfRequired(
        commandID: String,
        modifiers: NSEvent.ModifierFlags,
        title: String,
        message: String,
        confirmButtonTitle: String
    ) -> Bool {
        if modifiers.contains(.option) {
            return true
        }
        guard AppSettings.shared.requiresSystemCommandConfirmation(commandID) else {
            return true
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirmButtonTitle)
        alert.addButton(withTitle: "Hủy")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @MainActor
    private static func matchingRunningApps(
        filter: String,
        onlyVisible: Bool,
        includeFinder: Bool
    ) -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let prevPID = LauncherPanelController.shared.previousFrontApp?.processIdentifier
        let filterTokens = GoogleDriveIndexService.removeAccents(filter)
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        let candidates = NSWorkspace.shared.runningApplications.filter { app in
            guard app.activationPolicy == .regular else { return false }
            guard app.processIdentifier != ownPID, !app.isTerminated else { return false }
            if !includeFinder && app.bundleIdentifier == "com.apple.finder" && filterTokens.isEmpty {
                return false
            }
            if onlyVisible && app.isHidden {
                return false
            }
            guard !filterTokens.isEmpty else { return true }

            let name = app.localizedName ?? ""
            let bundleName = app.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
            let bundleID = app.bundleIdentifier ?? ""
            let hay = GoogleDriveIndexService.removeAccents("\(name) \(bundleName) \(bundleID)").lowercased()
            let words = hay.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let acronym = String(words.compactMap(\.first))

            return filterTokens.allSatisfy { tok in
                hay.contains(tok) || acronym.hasPrefix(tok)
            }
        }

        return candidates.sorted { a, b in
            if a.processIdentifier == prevPID { return true }
            if b.processIdentifier == prevPID { return false }
            if a.isActive != b.isActive { return a.isActive && !b.isActive }
            return (a.localizedName ?? "").localizedStandardCompare(b.localizedName ?? "") == .orderedAscending
        }
    }

    private nonisolated static func mountedEjectableVolumes(filter: String) -> [MountedEjectableVolume] {
        let keys: [URLResourceKey] = [
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsInternalKey,
            .volumeLocalizedNameKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let filterNorm = GoogleDriveIndexService.removeAccents(filter).lowercased().trimmingCharacters(in: .whitespaces)
        var list: [MountedEjectableVolume] = []

        for vol in urls {
            let p = vol.path
            guard p != "/" && !p.hasPrefix("/System/Volumes") else { continue }
            guard let vals = try? vol.resourceValues(forKeys: Set(keys)) else { continue }
            let isEjectableOrExternal = (vals.volumeIsRemovable == true)
                || (vals.volumeIsEjectable == true)
                || (p.hasPrefix("/Volumes/") && vals.volumeIsInternal == false)
            guard isEjectableOrExternal else { continue }

            let name = vals.volumeLocalizedName ?? vol.lastPathComponent
            if !filterNorm.isEmpty {
                let nameNorm = GoogleDriveIndexService.removeAccents(name).lowercased()
                guard nameNorm.contains(filterNorm) else { continue }
            }

            let capDesc: String = {
                if let total = vals.volumeTotalCapacity, total > 0 {
                    let totalStr = ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
                    if let avail = vals.volumeAvailableCapacity, avail >= 0 {
                        let availStr = ByteCountFormatter.string(fromByteCount: Int64(avail), countStyle: .file)
                        return "Trống \(availStr) / \(totalStr)"
                    }
                    return "Dung lượng \(totalStr)"
                }
                return p
            }()

            list.append(MountedEjectableVolume(url: vol, name: name, capacityDescription: capDesc))
        }

        return list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private nonisolated static func trashItemCountFast() -> Int {
        let trashPath = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first?.path
            ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/.Trash")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: trashPath) else {
            return 0
        }
        return items.filter { $0 != ".DS_Store" }.count
    }

    private nonisolated static func lockMacScreenImmediately() {
        typealias LockFunc = @convention(c) () -> Void
        let loginPath = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(loginPath, RTLD_LAZY),
           let sym = dlsym(handle, "SACLockScreenImmediate") {
            let fn = unsafeBitCast(sym, to: LockFunc.self)
            fn()
            dlclose(handle)
            return
        }
        _ = runSimpleProcess("/usr/bin/pmset", ["displaysleepnow"])
    }

    private nonisolated static func runOSAScript(_ script: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func runSimpleProcess(_ executable: String, _ args: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        guard (try? proc.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
