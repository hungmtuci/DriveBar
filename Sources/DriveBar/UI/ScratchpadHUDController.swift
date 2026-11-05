import AppKit
import SwiftUI
import Combine

@MainActor
final class ScratchpadHUDController: NSObject, NSWindowDelegate {
    static let shared = ScratchpadHUDController()

    private var panel: ScratchpadPanel?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
        observePinState()
    }

    private func observePinState() {
        ScratchpadService.shared.$isPinnedOnTop
            .sink { [weak self] pinned in
                guard let self, let panel = self.panel else { return }
                panel.level = pinned ? .floating : .normal
            }
            .store(in: &cancellables)
    }

    func toggle() {
        if let panel = self.panel, panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            setupPanel()
        }

        guard let panel else { return }
        panel.level = ScratchpadService.shared.isPinnedOnTop ? .floating : .normal

        if !panel.isVisible {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func hide() {
        ScratchpadService.shared.saveImmediately()
        panel?.orderOut(nil)
    }

    private func setupPanel() {
        let p = ScratchpadPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        p.isReleasedWhenClosed = false
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = true
        p.standardWindowButton(.closeButton)?.isHidden = true
        p.standardWindowButton(.miniaturizeButton)?.isHidden = true
        p.standardWindowButton(.zoomButton)?.isHidden = true
        p.minSize = NSSize(width: 420, height: 300)
        p.delegate = self
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.setFrameAutosaveName("DriveBarScratchpadPanel")

        let rootView = ScratchpadView { [weak self] in
            self?.hide()
        }

        let hostingView = NSHostingView(rootView: rootView)
        p.contentView = hostingView

        self.panel = p
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        if !ScratchpadService.shared.isPinnedOnTop {
            // If not pinned on top, auto save immediately
            ScratchpadService.shared.saveImmediately()
        }
    }
}

private final class ScratchpadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        ScratchpadHUDController.shared.hide()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            ScratchpadHUDController.shared.hide()
            return
        }
        super.keyDown(with: event)
    }
}
