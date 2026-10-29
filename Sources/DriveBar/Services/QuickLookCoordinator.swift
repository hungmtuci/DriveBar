import Foundation
import AppKit
import QuickLookUI

@MainActor
final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()

    nonisolated(unsafe) private var previewURLs: [URL] = []

    private override init() {
        super.init()
    }

    func toggleQuickLook(for urls: [URL]) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
            return
        }
        showQuickLook(for: urls)
    }

    func showQuickLook(for urls: [URL]) {
        let valid = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        previewURLs = valid
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURLs.count
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard index >= 0 && index < previewURLs.count else { return nil }
        return previewURLs[index] as NSURL
    }
}
