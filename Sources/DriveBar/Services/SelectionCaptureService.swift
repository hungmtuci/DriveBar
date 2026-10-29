import Foundation
import AppKit
import ApplicationServices
import Carbon

@MainActor
final class SelectionCaptureService {
    static let shared = SelectionCaptureService()

    private init() {}

    /// Captures currently selected file(s) in Finder, or selected text/URL in the frontmost application.
    /// Falls back cleanly to Clipboard contents if no active selection is detected.
    func captureCurrentSelection() async -> ActionTarget? {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let bundleID = frontApp?.bundleIdentifier ?? ""

        // 1. If Finder is frontmost, grab Finder's selected items directly
        if bundleID == "com.apple.finder" {
            let urls = await Task.detached(priority: .userInitiated) {
                Self.fetchFinderSelectionURLs()
            }.value
            if !urls.isEmpty {
                return .files(urls, sourceNote: "Đang chọn trong Finder")
            }
        }

        // 2. Try Accessibility API for selected text without touching Clipboard
        if AXIsProcessTrusted(), let selectedText = readAXSelectedText(), !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return classifyString(selectedText, note: "Văn bản bôi đen (\(frontApp?.localizedName ?? "App"))")
        }

        // 3. Try non-destructive simulated ⌘C if Accessibility is granted
        if AXIsProcessTrusted() {
            if let captured = await simulateCopyAndCapture(sourceAppName: frontApp?.localizedName) {
                return captured
            }
        }

        // 4. Even if Finder wasn't frontmost, check if Finder has an active selection when Clipboard is empty
        let finderURLs = await Task.detached(priority: .userInitiated) {
            Self.fetchFinderSelectionURLs()
        }.value
        if !finderURLs.isEmpty {
            return .files(finderURLs, sourceNote: "Đang chọn trong Finder")
        }

        // 5. Fallback to current Clipboard content
        return readFromCurrentClipboard()
    }

    nonisolated static func fetchFinderSelectionURLs() -> [URL] {
        let script = """
        tell application "Finder"
            set theSelection to selection
            set outList to ""
            repeat with itemRef in theSelection
                try
                    set outList to outList & POSIX path of (itemRef as alias) & linefeed
                end try
            end repeat
            return outList
        end tell
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
        } catch {
            return []
        }
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

        let src = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        keyDown?.flags = .maskCommand
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Wait up to 90ms for pasteboard change
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
            let valid = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !valid.isEmpty {
                return .files(valid, sourceNote: note)
            }
        }
        if let str = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !str.isEmpty {
            return classifyString(str, note: note)
        }
        return nil
    }

    private func classifyString(_ text: String, note: String?) -> ActionTarget {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains("\n"), !trimmed.contains(" "),
           let u = URL(string: trimmed),
           let scheme = u.scheme?.lowercased(),
           ["http", "https", "mailto", "file"].contains(scheme) {
            if scheme == "file", FileManager.default.fileExists(atPath: u.path) {
                return .files([u], sourceNote: note)
            }
            return .url(u, sourceNote: note)
        }
        if !trimmed.contains("\n"), FileManager.default.fileExists(atPath: (trimmed as NSString).expandingTildeInPath) {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return .files([URL(fileURLWithPath: expanded)], sourceNote: note)
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
