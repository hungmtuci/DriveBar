import Foundation
import AppKit
import QuickLookUI

@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    nonisolated(unsafe) private var previewURLs: [URL] = []

    var isQuickLookVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    private override init() {
        super.init()
    }

    func toggleQuickLook(for urls: [URL]) {
        if isQuickLookVisible {
            closeQuickLook(restoreLauncherFocus: true)
            return
        }
        showQuickLook(for: urls)
    }

    func showQuickLook(for urls: [URL]) {
        let valid = Self.filterValidPreviewURLs(urls)
        guard !valid.isEmpty, let panel = QLPreviewPanel.shared() else {
            NSSound.beep()
            return
        }
        previewURLs = valid
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    func updateIfVisible(for urls: [URL]) {
        guard isQuickLookVisible, let panel = QLPreviewPanel.shared() else { return }
        let valid = Self.filterValidPreviewURLs(urls)
        guard !valid.isEmpty else { return }
        if previewURLs != valid {
            previewURLs = valid
            panel.dataSource = self
            panel.delegate = self
            panel.reloadData()
            panel.currentPreviewItemIndex = 0
        }
    }

    func closeQuickLook(restoreLauncherFocus: Bool = true) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible {
            panel.orderOut(nil)
        }
        if restoreLauncherFocus && LauncherPanelController.shared.isVisible {
            LauncherPanelController.shared.restoreFocusFromAuxiliaryPanel()
        }
    }

    private static func filterValidPreviewURLs(_ urls: [URL]) -> [URL] {
        urls.filter { u in
            u.path.contains("/Library/CloudStorage/") || FileManager.default.fileExists(atPath: u.path)
        }
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard index >= 0 && index < previewURLs.count else { return nil }
        return previewURLs[index] as NSURL
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let code = Int(event.keyCode)
        // Forward Up / Down arrows while Quick Look is open so user can browse items live!
        if code == 126 { // kVK_UpArrow
            Task { @MainActor in
                LauncherViewModel.shared.moveSelection(delta: -1)
            }
            return true
        }
        if code == 125 { // kVK_DownArrow
            Task { @MainActor in
                LauncherViewModel.shared.moveSelection(delta: 1)
            }
            return true
        }
        return false
    }
}
