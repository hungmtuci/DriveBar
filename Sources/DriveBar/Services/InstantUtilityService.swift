import Foundation
import AppKit
import Darwin

struct MathEvaluationResult: Equatable, Sendable {
    let expression: String
    let rawCopyString: String
    let formattedDisplay: String
}

struct SystemUtilityDefinition: Sendable {
    let id: String
    let title: String
    let subtitle: String
    let keywords: [String]
    let inlineTriggers: [String]
    let badge: String
    let sfSymbol: String
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
            // Strip underscores or spaces between digits cleanly while tokenizing
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

        // Add / Sub (with smart percentage support: `1000 + 10%` -> `1000 * 1.10`)
        private mutating func parseAddSub() -> Double? {
            guard var left = parseMulDiv() else { return nil }
            while true {
                skipWhitespace()
                guard pos < chars.count else { break }
                let op = chars[pos]
                guard op == "+" || op == "-" else { break }
                pos += 1
                let savedOps = didPerformOperation
                var rightWasPercent = false
                guard let right = parseMulDiv(didEndWithPercent: &rightWasPercent) else { return nil }
                didPerformOperation = true
                if rightWasPercent {
                    // `right` is already divided by 100, so `left + left * right` gives natural calculator `%`
                    left = (op == "+") ? (left + left * right) : (left - left * right)
                } else {
                    left = (op == "+") ? (left + right) : (left - right)
                }
                _ = savedOps
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

            // Parentheses
            if chars[pos] == "(" {
                pos += 1
                guard let inner = parseAddSub() else { return nil }
                skipWhitespace()
                guard pos < chars.count && chars[pos] == ")" else { return nil }
                pos += 1
                return inner
            }

            // Identifier: Function or Constant (`sqrt`, `sin`, `cos`, `pi`, `e`, etc.)
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

            // Numeric literal (supports commas as thousand separators like `1,250.50` or underscores `2_400_000`)
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
                    // Check if comma is followed by 3 digits (thousand separator)
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

    // MARK: - 2. Native System Commands (`s` / `s + từ khóa` & Inline High-Confidence Matching)

    static let allSystemCommands: [SystemUtilityDefinition] = [
        SystemUtilityDefinition(
            id: "sys.dark_mode",
            title: "Chuyển chế độ Tối / Sáng (Toggle Dark Mode)",
            subtitle: "Đảo nhanh giao diện hệ thống macOS giữa Dark Mode và Light Mode",
            keywords: ["dark", "light", "mode", "appearance", "che", "do", "toi", "sang", "giao", "dien"],
            inlineTriggers: ["dark mode", "light mode", "che do toi", "che do sang"],
            badge: "Hệ thống",
            sfSymbol: "circle.lefthalf.filled"
        ),
        SystemUtilityDefinition(
            id: "sys.lock_screen",
            title: "Khóa màn hình ngay (Lock Screen)",
            subtitle: "Khóa máy Mac lập tức để bảo mật khi rời bàn làm việc",
            keywords: ["lock", "screen", "khoa", "man", "hinh", "security"],
            inlineTriggers: ["lock screen", "khoa man hinh", "khoa may"],
            badge: "Hệ thống",
            sfSymbol: "lock.display"
        ),
        SystemUtilityDefinition(
            id: "sys.finder_hidden",
            title: "Hiện / Ẩn tệp ẩn hệ thống trong Finder",
            subtitle: "Đảo cờ AppleShowAllFiles của Finder và làm mới cửa sổ Finder",
            keywords: ["hidden", "files", "finder", "dotfiles", "tep", "an", "hien"],
            inlineTriggers: ["hidden files", "hien tep an", "an tep an"],
            badge: "Finder",
            sfSymbol: "eye.slash"
        ),
        SystemUtilityDefinition(
            id: "sys.empty_trash",
            title: "Dọn sạch Thùng rác (Empty Trash)",
            subtitle: "Xóa vĩnh viễn toàn bộ các mục đang nằm trong Thùng rác Finder",
            keywords: ["empty", "trash", "don", "sach", "thung", "rac", "xoa"],
            inlineTriggers: ["empty trash", "don thung rac", "xoa thung rac"],
            badge: "Finder",
            sfSymbol: "trash"
        ),
        SystemUtilityDefinition(
            id: "sys.eject_all",
            title: "Ngắt kết nối mọi ổ đĩa ngoài & bộ cài DMG (Eject All)",
            subtitle: "Tháo an toàn tất cả USB, ổ cứng di động và đĩa ảo .dmg đang gắn",
            keywords: ["eject", "all", "disk", "usb", "dmg", "unmount", "ngat", "thao", "o", "dia"],
            inlineTriggers: ["eject all", "thao o dia", "ngat usb"],
            badge: "Ổ đĩa",
            sfSymbol: "eject"
        ),
        SystemUtilityDefinition(
            id: "sys.sleep_display",
            title: "Tắt màn hình tạm nghỉ (Sleep Display)",
            subtitle: "Tắt sáng màn hình ngay mà không tắt các tác vụ đang chạy nền",
            keywords: ["sleep", "display", "monitor", "tat", "man", "hinh", "nghi"],
            inlineTriggers: ["sleep display", "tat man hinh"],
            badge: "Nguồn",
            sfSymbol: "moon.zzz"
        ),
        SystemUtilityDefinition(
            id: "sys.ocr_clipboard",
            title: "OCR Ảnh trong Clipboard sang Markdown / Văn bản",
            subtitle: "Nhận diện chữ Tiếng Việt & Tiếng Anh từ ảnh chụp màn hình vừa lưu trong Clipboard",
            keywords: ["ocr", "clipboard", "screenshot", "image", "vision", "anh", "chup", "trich", "xuat"],
            inlineTriggers: ["ocr clipboard", "ocr anh"],
            badge: "AI • OCR",
            sfSymbol: "text.viewfinder"
        ),
        SystemUtilityDefinition(
            id: "sys.clear_clipboard",
            title: "Xóa lịch sử Clipboard của DriveBar",
            subtitle: "Làm sạch danh sách các mục đã lưu trong bộ nhớ lịch sử Clipboard ('c ')",
            keywords: ["clear", "clipboard", "history", "xoa", "lich", "su"],
            inlineTriggers: ["clear clipboard", "xoa clipboard"],
            badge: "Clipboard",
            sfSymbol: "xmark.bin"
        ),
        SystemUtilityDefinition(
            id: "sys.rebuild_index",
            title: "Quét lại toàn bộ chỉ mục Google Drive & Tệp tin",
            subtitle: "Cập nhật nền danh sách thư mục, tệp tin và ứng dụng mới nhất",
            keywords: ["rebuild", "reindex", "refresh", "cache", "quet", "lai", "dong", "bo"],
            inlineTriggers: ["rebuild cache", "quet lai google drive"],
            badge: "Index",
            sfSymbol: "arrow.clockwise.circle"
        )
    ]

    nonisolated static func searchSystemCommands(query: String, isExplicitSystemMode: Bool) -> [SearchResultItem] {
        let qNorm = GoogleDriveIndexService.removeAccents(query)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if isExplicitSystemMode && qNorm.isEmpty {
            return allSystemCommands.map(makeResultItem)
        }

        guard !qNorm.isEmpty else { return [] }
        let tokens = qNorm.split(separator: " ").map(String.init).filter { !$0.isEmpty }

        if isExplicitSystemMode {
            let matched = allSystemCommands.filter { def in
                let hay = GoogleDriveIndexService.removeAccents("\(def.title) \(def.subtitle)").lowercased()
                    + " " + def.keywords.joined(separator: " ")
                return tokens.allSatisfy { hay.contains($0) }
            }
            if matched.isEmpty {
                return [
                    SearchResultItem(
                        id: "sys:empty",
                        title: "Không có lệnh hệ thống nào khớp '\(query)'",
                        subtitle: "Thử gõ: dark mode, lock, trash, eject, hidden, sleep, ocr, rebuild...",
                        path: nil,
                        isDirectory: false,
                        kind: .infoBanner,
                        badge: "Hệ thống",
                        sfSymbolFallback: "gearshape"
                    )
                ]
            }
            return matched.map(makeResultItem)
        } else {
            // Inline mode: only match explicit multi-word or exact trigger phrases so normal Drive search stays clean
            guard qNorm.count >= 4 else { return [] }
            let matched = allSystemCommands.filter { def in
                def.inlineTriggers.contains { trigger in
                    trigger.hasPrefix(qNorm) || qNorm == trigger
                }
            }
            return matched.map(makeResultItem)
        }
    }

    private nonisolated static func makeResultItem(_ def: SystemUtilityDefinition) -> SearchResultItem {
        SearchResultItem(
            id: "syscmd:\(def.id)",
            title: def.title,
            subtitle: def.subtitle,
            path: nil,
            isDirectory: false,
            kind: .systemCommand(id: def.id),
            badge: def.badge,
            sfSymbolFallback: def.sfSymbol
        )
    }

    @MainActor
    static func executeSystemUtility(id: String, viewModel: LauncherViewModel, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch id {
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

        case "sys.lock_screen":
            LauncherPanelController.shared.hide()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                lockMacScreenImmediately()
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
                        symbol: nowShowing ? "eye" : "eye.slash"
                    )
                }
            }
            return true

        case "sys.empty_trash":
            LauncherPanelController.shared.hide()
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
                            symbol: "trash"
                        )
                    } else {
                        FloatingToastController.shared.showError(
                            title: "Thùng rác đang trống hoặc cần xác nhận từ Finder",
                            subtitle: "Finder"
                        )
                    }
                }
            }
            return true

        case "sys.eject_all":
            LauncherPanelController.shared.hide()
            Task.detached(priority: .userInitiated) {
                let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey, .volumeLocalizedNameKey]
                let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
                var ejectedNames: [String] = []
                for vol in vols {
                    guard vol.path != "/" else { continue }
                    if let vals = try? vol.resourceValues(forKeys: Set(keys)),
                       (vals.volumeIsRemovable == true || vals.volumeIsEjectable == true) && vals.volumeIsInternal != true {
                        let name = vals.volumeLocalizedName ?? vol.lastPathComponent
                        if (try? NSWorkspace.shared.unmountAndEjectDevice(at: vol)) != nil {
                            ejectedNames.append(name)
                        }
                    }
                }
                let finalNames = ejectedNames
                await MainActor.run {
                    if finalNames.isEmpty {
                        FloatingToastController.shared.showSuccess(
                            title: "Không có ổ đĩa ngoài hoặc DMG nào đang gắn",
                            subtitle: "Tất cả thiết bị đã an toàn",
                            symbol: "eject"
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

        case "sys.sleep_display":
            LauncherPanelController.shared.hide()
            Task.detached(priority: .userInitiated) {
                _ = runSimpleProcess("/usr/bin/pmset", ["displaysleepnow"])
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
                symbol: "doc.on.clipboard"
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
