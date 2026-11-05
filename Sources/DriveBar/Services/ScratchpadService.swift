import Foundation
import AppKit

@MainActor
final class ScratchpadService: ObservableObject {
    static let shared = ScratchpadService()

    @Published var text: String = "" {
        didSet {
            scheduleAutoSave()
        }
    }

    @Published private(set) var isPinnedOnTop: Bool = false {
        didSet {
            UserDefaults.standard.set(isPinnedOnTop, forKey: "drivebar.scratchpad.pinned")
        }
    }

    private var autoSaveTask: Task<Void, Never>?
    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("DriveBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("Scratchpad.md")
        self.isPinnedOnTop = UserDefaults.standard.bool(forKey: "drivebar.scratchpad.pinned")

        loadInitialText()
    }

    var filePathString: String {
        (fileURL.path as NSString).abbreviatingWithTildeInPath
    }

    var wordCount: Int {
        let comps = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        return comps.count
    }

    var charCount: Int {
        text.count
    }

    func togglePin() {
        isPinnedOnTop.toggle()
    }

    private func loadInitialText() {
        if FileManager.default.fileExists(atPath: fileURL.path),
           let content = try? String(contentsOf: fileURL, encoding: .utf8) {
            self.text = content
        } else {
            let defaultWelcome = L(
                "# Ghi chú nháp (Scratchpad)\n\n- Ghi chép nhanh ý tưởng, đường link hoặc văn bản nháp tại đây.\n- Tự động lưu tức thì vào `\(filePathString)`.\n",
                "# Scratchpad Notes\n\n- Quick scratchpad for notes, links, and snippets.\n- Auto-saves instantly to `\(filePathString)`.\n"
            )
            self.text = defaultWelcome
            try? defaultWelcome.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    private func scheduleAutoSave() {
        autoSaveTask?.cancel()
        let currentText = self.text
        let targetURL = self.fileURL

        autoSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000) // 350ms debounce
            guard !Task.isCancelled else { return }
            do {
                try currentText.write(to: targetURL, atomically: true, encoding: .utf8)
            } catch {
                // Silently fallback
            }
        }
    }

    func saveImmediately() {
        autoSaveTask?.cancel()
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    func appendLine(_ rawLine: String) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let bullet = "- [ ] \(trimmed)"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = bullet + "\n"
        } else if text.hasSuffix("\n") {
            text += bullet + "\n"
        } else {
            text += "\n" + bullet + "\n"
        }
        saveImmediately()

        FloatingToastController.shared.showSuccess(
            title: L("Đã thêm vào Ghi chú nháp", "Appended to Scratchpad"),
            subtitle: bullet
        )
    }

    func clear() {
        text = ""
        saveImmediately()
    }

    func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        FloatingToastController.shared.showSuccess(
            title: L("Đã sao chép toàn bộ ghi chú", "Copied all notes"),
            subtitle: L("Sẵn sàng dán (⌘V) vào bất kỳ ứng dụng nào", "Ready to paste (⌘V) into any app")
        )
    }

    func exportToFile() {
        let panel = NSSavePanel()
        panel.title = L("Lưu Ghi chú nháp thành tệp Markdown", "Save Scratchpad as Markdown")
        panel.nameFieldStringValue = "Scratchpad-\(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none).replacingOccurrences(of: "/", with: "-")).md"
        panel.allowedContentTypes = [.plainText]

        if panel.runModal() == .OK, let targetURL = panel.url {
            do {
                try text.write(to: targetURL, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([targetURL])
                FloatingToastController.shared.showSuccess(
                    title: L("Đã xuất tệp thành công", "Successfully exported file"),
                    subtitle: targetURL.lastPathComponent
                )
            } catch {
                FloatingToastController.shared.showError(
                    title: L("Xuất tệp thất bại", "Export failed"),
                    subtitle: error.localizedDescription
                )
            }
        }
    }
}
