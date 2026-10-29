import SwiftUI
import AppKit
import Carbon

final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    static let shared = LauncherPanelController()

    private var panel: SpotlightPanel?
    private var localKeyMonitor: Any?
    private var flagsMonitor: Any?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    var panelContentView: NSView? {
        panel?.contentView
    }

    private override init() {
        super.init()
    }

    func toggleSearchPanel() {
        if isVisible {
            if case .search = LauncherViewModel.shared.screenMode {
                hide()
                return
            }
        }
        LauncherViewModel.shared.prepareForSearchLaunch()
        showAndFocus(selectExistingQuery: true)
    }

    func triggerUniversalActionsOnSelection() {
        Task { @MainActor in
            if isVisible, case .search = LauncherViewModel.shared.screenMode {
                LauncherViewModel.shared.openUniversalActionsForSelectedSearchItem()
                return
            }

            guard let target = await SelectionCaptureService.shared.captureCurrentSelection() else {
                FloatingToastController.shared.showError(
                    title: "Chưa có mục nào được chọn",
                    subtitle: "Hãy chọn file trong Finder hoặc bôi đen văn bản trước khi nhấn \(AppSettings.shared.universalActionHotKey.readableDisplay)"
                )
                return
            }
            LauncherViewModel.shared.openUniversalActions(for: target, directExternalTrigger: true)
            showAndFocus(selectExistingQuery: false)
        }
    }

    func showAndFocus(selectExistingQuery: Bool = false) {
        ensurePanelCreated()
        guard let panel else { return }

        positionPanelCenteredOnActiveScreen(panel)
        installKeyboardMonitorsIfNeeded()

        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        LauncherViewModel.shared.triggerInputFocus(selectAll: selectExistingQuery)
        NotificationCenter.default.post(name: .driveBarFocusInput, object: nil)

        if let tf = Self.findEditableTextField(in: panel.contentView) {
            NativeSearchInputField.focusTextField(tf, selectAll: selectExistingQuery)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak panel] in
            guard let panel, panel.isVisible else { return }
            if let tf = Self.findEditableTextField(in: panel.contentView) {
                NativeSearchInputField.focusTextField(tf, selectAll: selectExistingQuery)
            }
        }
    }

    private static func findEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField, tf.isEditable {
            return tf
        }
        for sub in view.subviews {
            if let found = findEditableTextField(in: sub) {
                return found
            }
        }
        return nil
    }

    func hide() {
        removeKeyboardMonitors()
        LauncherViewModel.shared.activeModifiers = []
        panel?.orderOut(nil)
    }

    func reapplySpaceCollectionBehavior() {
        panel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    func windowDidResignKey(_ notification: Notification) {
        // Auto-hide spotlight bar when clicking outside (unless QuickLook preview panel is frontmost)
        if let keyWin = NSApp.keyWindow, String(describing: type(of: keyWin)).contains("QLPreview") {
            return
        }
        hide()
    }

    private func ensurePanelCreated() {
        guard panel == nil else { return }
        let rect = NSRect(x: 0, y: 0, width: 760, height: 500)
        let p = SpotlightPanel(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self

        let hosting = NSHostingView(rootView: LauncherRootView(viewModel: LauncherViewModel.shared))
        hosting.frame = rect
        p.contentView = hosting
        self.panel = p
    }

    private func positionPanelCenteredOnActiveScreen(_ panel: NSPanel) {
        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let visible = screen.visibleFrame
        let width: CGFloat = 760
        let height: CGFloat = 500
        let x = round(visible.midX - width / 2)
        let y = round(max(visible.minY + 40, visible.minY + visible.height * 0.56 - height / 2))
        panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    // MARK: - Rich Keyboard Navigation (Alfred-grade, Vietnamese IME Safe)

    private func installKeyboardMonitorsIfNeeded() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isVisible else { return event }
                if self.handleKeyDown(event) {
                    return nil
                }
                return event
            }
        }

        if flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                LauncherViewModel.shared.activeModifiers = event.modifierFlags.cleanShortcutModifiers
                return event
            }
        }
    }

    private func removeKeyboardMonitors() {
        if let mon = localKeyMonitor {
            NSEvent.removeMonitor(mon)
            localKeyMonitor = nil
        }
        if let fMon = flagsMonitor {
            NSEvent.removeMonitor(fMon)
            flagsMonitor = nil
        }
    }

    private func commitActiveIMEIfNeeded(syncBeforeSubmit: Bool) {
        guard let editor = panel?.firstResponder as? NSTextView else { return }
        if syncBeforeSubmit {
            let live = editor.string
            if editor.hasMarkedText() {
                editor.unmarkText()
            }
            LauncherViewModel.shared.syncImmediateTextBeforeSubmit(live)
        } else if editor.hasMarkedText() {
            editor.unmarkText()
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let vm = LauncherViewModel.shared
        let flags = event.modifierFlags.cleanShortcutModifiers
        let code = Int(event.keyCode)

        // 1. Escape handling
        if code == kVK_Escape {
            commitActiveIMEIfNeeded(syncBeforeSubmit: false)
            vm.handleEscapeKey()
            return true
        }

        // 2. Quick Look: ⌘Y
        if flags == .command && code == kVK_ANSI_Y {
            switch vm.screenMode {
            case .search:
                if vm.selectedIndex < vm.searchResults.count,
                   let u = vm.searchResults[vm.selectedIndex].fileURL {
                    QuickLookCoordinator.shared.toggleQuickLook(for: [u])
                }
            case .universalActions(let target):
                QuickLookCoordinator.shared.toggleQuickLook(for: target.fileURLs)
            default:
                break
            }
            return true
        }

        // 3. Open Preferences: ⌘,
        if flags == .command && code == kVK_ANSI_Comma {
            hide()
            AppDelegate.shared?.openSettingsWindow()
            return true
        }

        // 4. Instant row hotkeys: ⌘1 ... ⌘9
        if flags == .command, let numIndex = Self.numberIndex(for: code) {
            commitActiveIMEIfNeeded(syncBeforeSubmit: false)
            vm.executeAtIndex(numIndex, modifiers: [])
            return true
        }

        // 5. File Buffer shortcuts in Search mode: ⌥↑, ⌥↓, ⌥→, ⌥⌫
        if flags == .option, case .search = vm.screenMode {
            if code == kVK_UpArrow {
                if vm.selectedIndex < vm.searchResults.count,
                   let u = vm.searchResults[vm.selectedIndex].fileURL {
                    FileBufferService.shared.add(u)
                }
                return true
            }
            if code == kVK_DownArrow {
                if vm.selectedIndex < vm.searchResults.count,
                   let u = vm.searchResults[vm.selectedIndex].fileURL {
                    FileBufferService.shared.add(u)
                    vm.moveSelection(delta: 1)
                }
                return true
            }
            if code == kVK_RightArrow {
                let buffered = FileBufferService.shared.items
                if !buffered.isEmpty {
                    vm.openUniversalActions(
                        for: .files(buffered, sourceNote: "File Buffer (\(buffered.count) mục)"),
                        directExternalTrigger: false
                    )
                } else {
                    vm.openUniversalActionsForSelectedSearchItem()
                }
                return true
            }
            if code == kVK_Delete {
                FileBufferService.shared.clear()
                return true
            }
        }

        // 6. Up / Down navigation (or ⌃P / ⌃N)
        if (code == kVK_UpArrow && flags.isEmpty) || (flags == .control && code == kVK_ANSI_P) {
            commitActiveIMEIfNeeded(syncBeforeSubmit: false)
            vm.moveSelection(delta: -1)
            return true
        }
        if (code == kVK_DownArrow && flags.isEmpty) || (flags == .control && code == kVK_ANSI_N) {
            commitActiveIMEIfNeeded(syncBeforeSubmit: false)
            vm.moveSelection(delta: 1)
            return true
        }

        // 7. Tab or ⌘K -> Open Universal Actions on selected item (or go back)
        if code == kVK_Tab || (flags == .command && code == kVK_ANSI_K) {
            commitActiveIMEIfNeeded(syncBeforeSubmit: false)
            vm.handleTabKey()
            return true
        }

        // 8. Backspace at trailing `/` in Browse Mode pops up one parent folder
        if code == kVK_Delete && flags.isEmpty {
            let hasMarked = (panel?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
            if !hasMarked && vm.popParentFolderIfAtSlashBoundary() {
                return true
            }
        }

        // 9. Enter / Return -> Execute with active modifiers (↩, ⌘↩, ⌥↩, ⌃↩, ⇧↩)
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            commitActiveIMEIfNeeded(syncBeforeSubmit: true)
            vm.executeCurrentSelection(modifiers: flags)
            return true
        }

        return false
    }

    private static func numberIndex(for keyCode: Int) -> Int? {
        switch keyCode {
        case kVK_ANSI_1: return 0
        case kVK_ANSI_2: return 1
        case kVK_ANSI_3: return 2
        case kVK_ANSI_4: return 3
        case kVK_ANSI_5: return 4
        case kVK_ANSI_6: return 5
        case kVK_ANSI_7: return 6
        case kVK_ANSI_8: return 7
        case kVK_ANSI_9: return 8
        default: return nil
        }
    }
}

extension Notification.Name {
    static let driveBarFocusInput = Notification.Name("driveBarFocusInput")
}
