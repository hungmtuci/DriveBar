import Foundation
import AppKit
import ApplicationServices
import Carbon

@MainActor
final class SelectionCaptureService {
    static let shared = SelectionCaptureService()

    private nonisolated static let appleScriptQueue = DispatchQueue(label: "com.hunglx.DriveBar.finderAppleScript", qos: .userInteractive)

    private init() {}

    /// Captures currently selected file(s)/folder(s) in Finder, or selected text/URL in the frontmost application.
    /// Falls back cleanly to Clipboard contents if no active selection is detected.
    func captureCurrentSelection() async -> ActionTarget? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier ?? ""

        var finderScriptSucceeded = false

        // 1. If Finder is frontmost, grab Finder's selected items directly (with open Finder folder fallback!)
        if bundleID == "com.apple.finder" {
            let res = await Self.fetchFinderSelectionAsync(includeOpenWindowFallback: true)
            finderScriptSucceeded = res.scriptSucceeded
            if !res.urls.isEmpty {
                return .files(res.urls, sourceNote: res.note)
            }
        }

        // 2. Try Accessibility API for selected text without touching Clipboard
        if AXIsProcessTrusted(), let selectedText = readAXSelectedText(), !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return classifyString(selectedText, note: "Văn bản bôi đen (\(frontApp?.localizedName ?? "App"))")
        }

        // 3. Try non-destructive simulated ⌘C if Accessibility is granted (only fall back on Finder if AppleEvents was blocked)
        if (bundleID != "com.apple.finder" || !finderScriptSucceeded) && AXIsProcessTrusted() {
            if let captured = await simulateCopyAndCapture(sourceAppName: frontApp?.localizedName) {
                return captured
            }
        }

        // 4. Even if Finder wasn't frontmost, check if Finder has an active selection
        if bundleID != "com.apple.finder" {
            let res = await Self.fetchFinderSelectionAsync(includeOpenWindowFallback: false)
            if !res.urls.isEmpty {
                return .files(res.urls, sourceNote: "Đang chọn trong Finder")
            }
        }

        // 5. Fallback to current Clipboard content
        return readFromCurrentClipboard()
    }

    private nonisolated static func fetchFinderSelectionAsync(includeOpenWindowFallback: Bool) async -> (urls: [URL], note: String, scriptSucceeded: Bool) {
        await withCheckedContinuation { continuation in
            appleScriptQueue.async {
                let res = fetchFinderSelectionInternal(includeOpenWindowFallback: includeOpenWindowFallback)
                continuation.resume(returning: res)
            }
        }
    }

    nonisolated static func fetchFinderSelectionURLs() -> [URL] {
        fetchFinderSelectionInternal(includeOpenWindowFallback: false).urls
    }

    private nonisolated static func fetchFinderSelectionInternal(includeOpenWindowFallback: Bool) -> (urls: [URL], note: String, scriptSucceeded: Bool) {
        let fallbackClause = includeOpenWindowFallback ? """
            if outList is "" then
                try
                    if (count of Finder windows) > 0 then
                        set winTarget to target of front Finder window
                        try
                            set outList to "WINDOW_TARGET::" & (URL of winTarget)
                        on error
                            set outList to "WINDOW_TARGET::" & POSIX path of (winTarget as text)
                        end try
                    end if
                end try
            end if
        """ : ""

        let scriptSource = """
        tell application "Finder"
            set outList to ""
            try
                set theSelection to selection
                repeat with itemRef in theSelection
                    try
                        set outList to outList & (URL of itemRef) & linefeed
                    on error
                        try
                            set outList to outList & POSIX path of (itemRef as text) & linefeed
                        on error
                            try
                                set outList to outList & POSIX path of (itemRef as alias) & linefeed
                            end try
                        end try
                    end try
                end repeat
            end try
            \(fallbackClause)
            return outList
        end tell
        """

        var rawOutput: String?
        if let appleScript = NSAppleScript(source: scriptSource) {
            var errDict: NSDictionary?
            let descriptor = appleScript.executeAndReturnError(&errDict)
            if errDict == nil {
                rawOutput = descriptor.stringValue
            }
        }

        if rawOutput == nil {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", scriptSource]
            let out = Pipe()
            proc.standardOutput = out
            proc.standardError = Pipe()
            if (try? proc.run()) != nil {
                let data = out.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if proc.terminationStatus == 0 {
                    rawOutput = String(data: data, encoding: .utf8)
                }
            }
        }

        let scriptSucceeded = (rawOutput != nil)
        guard let text = rawOutput, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ([], "Đang chọn trong Finder", scriptSucceeded)
        }

        var note = "Đang chọn trong Finder"
        var urls: [URL] = []

        for line in text.components(separatedBy: .newlines) {
            var rawPath = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else { continue }
            var isDirHint = false
            if rawPath.hasPrefix("WINDOW_TARGET::") {
                rawPath = String(rawPath.dropFirst("WINDOW_TARGET::".count))
                note = "Thư mục đang mở trong Finder"
                isDirHint = true
            }
            if rawPath.count > 1 && rawPath.hasSuffix("/") {
                isDirHint = true
            }
            if rawPath.lowercased().hasPrefix("file://"), let fileURL = URL(string: rawPath) {
                isDirHint = isDirHint || fileURL.hasDirectoryPath
                rawPath = fileURL.path
            }
            let hasTrailingSlash = rawPath.count > 1 && rawPath.hasSuffix("/")
            if hasTrailingSlash {
                isDirHint = true
            }
            let cleanPath = hasTrailingSlash ? String(rawPath.dropLast()) : rawPath
            guard !cleanPath.isEmpty else { continue }

            // Avoid blocking FileProvider RPCs on CloudStorage paths!
            if cleanPath.contains("/Library/CloudStorage/") {
                urls.append(URL(fileURLWithPath: cleanPath, isDirectory: isDirHint))
            } else {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: cleanPath, isDirectory: &isDir) {
                    urls.append(URL(fileURLWithPath: cleanPath, isDirectory: isDir.boolValue || isDirHint))
                }
            }
        }

        return (urls, note, scriptSucceeded)
    }

    private func readAXSelectedText() -> String? {
        let sysWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sysWide, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else {
            return nil
        }
        var selectedTextRef: CFTypeRef?
        let elem = focused as! AXUIElement
        if AXUIElementCopyAttributeValue(elem, kAXSelectedTextAttribute as CFString, &selectedTextRef) == .success,
           let str = selectedTextRef as? String {
            return str
        }
        return nil
    }

    private func simulateCopyAndCapture(sourceAppName: String?) async -> ActionTarget? {
        let pb = NSPasteboard.general
        let savedItems = snapshotPasteboard(pb)
        let beforeCount = pb.changeCount

        ClipboardHistoryService.shared.isTemporarilySuspended = true
        defer {
            ClipboardHistoryService.shared.isTemporarilySuspended = false
            ClipboardHistoryService.shared.noteInternalPasteboardWrite()
        }

        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 15_000_000)
            if pb.changeCount != beforeCount {
                break
            }
        }

        guard pb.changeCount != beforeCount else {
            return nil
        }

        let target = extractTarget(from: pb, note: sourceAppName.map { "Chọn từ \($0)" })
        restorePasteboard(pb, snapshot: savedItems)
        return target
    }

    func readFromCurrentClipboard() -> ActionTarget? {
        extractTarget(from: .general, note: "Từ Clipboard")
    }

    private func extractTarget(from pb: NSPasteboard, note: String?) -> ActionTarget? {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            let valid = urls.filter { u in
                u.path.contains("/Library/CloudStorage/") || FileManager.default.fileExists(atPath: u.path)
            }
            if !valid.isEmpty {
                return .files(valid, sourceNote: note)
            }
        }
        if let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty {
            return classifyString(str, note: note)
        }
        if pb == .general,
           let types = pb.types,
           (types.contains(.png) || types.contains(.tiff)),
           let imgURL = ClipboardHistoryService.shared.materializeCurrentClipboardImageURL() {
            return .files([imgURL], sourceNote: "Ảnh chụp / Hình ảnh từ Clipboard")
        }
        return nil
    }

    private func classifyString(_ text: String, note: String?) -> ActionTarget {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("\n"), !trimmed.contains(" "),
           let u = URL(string: trimmed),
           let scheme = u.scheme?.lowercased(),
           ["http", "https", "mailto", "file"].contains(scheme) {
            if scheme == "file", (u.path.contains("/Library/CloudStorage/") || FileManager.default.fileExists(atPath: u.path)) {
                return .files([u], sourceNote: note)
            }
            return .url(u, sourceNote: note)
        }
        if !trimmed.contains("\n") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            if expanded.hasPrefix("/"), (expanded.contains("/Library/CloudStorage/") || FileManager.default.fileExists(atPath: expanded)) {
                return .files([URL(fileURLWithPath: expanded)], sourceNote: note)
            }
        }
        return .text(text, sourceNote: note)
    }

    private func snapshotPasteboard(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        guard let items = pb.pasteboardItems else { return [] }
        return items.map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type] = data
                }
            }
            return dict
        }
    }

    private func restorePasteboard(_ pb: NSPasteboard, snapshot: [[NSPasteboard.PasteboardType: Data]]) {
        pb.clearContents()
        guard !snapshot.isEmpty else { return }
        let restored: [NSPasteboardItem] = snapshot.map { dict in
            let item = NSPasteboardItem()
            for (t, d) in dict {
                item.setData(d, forType: t)
            }
            return item
        }
        pb.writeObjects(restored)
    }
}
