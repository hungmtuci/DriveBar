import SwiftUI
import AppKit
import Carbon

final class SpotlightPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class LauncherPanelController: NSObject, NSWindowDelegate {
    static let shared = LauncherPanelController()

    private var panel: SpotlightPanel?
    private var localKeyMonitor: Any?
    private var flagsMonitor: Any?
    private var mouseMonitor: Any?

    // Standalone Shift-tap Quick Look tracking (Alfred behavior: tap Shift -> Quick Look)
    private var shiftTapStartTime: TimeInterval?
    private var shiftInvalidatedByOtherInput: Bool = false

    var isSuppressingAutoHide: Bool = false
    private var screenshotGraceUntil: TimeInterval = 0
    private(set) var previousFrontApp: NSRunningApplication?

    var shouldSuppressAutoHide: Bool {
        isSuppressingAutoHide || ProcessInfo.processInfo.systemUptime < screenshotGraceUntil
    }

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
            switch LauncherViewModel.shared.screenMode {
            case .search, .contactDetail:
                hide()
                return
            default:
                break
            }
        }
        LauncherViewModel.shared.prepareForSearchLaunch()
        showAndFocus(selectExistingQuery: true)
    }

    func triggerUniversalActionsOnSelection() {
        Task { @MainActor in
            if isVisible {
                switch LauncherViewModel.shared.screenMode {
                case .search:
                    LauncherViewModel.shared.openUniversalActionsForSelectedSearchItem()
                    return
                case .universalActions:
                    if !LauncherViewModel.shared.openedDirectlyInUniversalActions {
                        LauncherViewModel.shared.returnToSearchMode()
                    } else {
                        hide()
                    }
                    return
                default:
                    break
                }
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
        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ownPID {
            previousFrontApp = front
        }

        if WindowSwitcherController.shared.isVisible {
            WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)
        }
        ensurePanelCreated()
        guard let panel else { return }

        isSuppressingAutoHide = true
        positionPanelCenteredOnActiveScreen(panel)
        installKeyboardMonitorsIfNeeded()

        if #available(macOS 14.0, *) {
            NSApp.activate()
        }
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        LauncherViewModel.shared.triggerInputFocus(selectAll: selectExistingQuery)
        NotificationCenter.default.post(name: .driveBarFocusInput, object: nil)

        DispatchQueue.main.async { [weak panel] in
            guard let panel, panel.isVisible else { return }
            if let tf = Self.findEditableTextField(in: panel.contentView) {
                NativeSearchInputField.focusTextField(tf, selectAll: selectExistingQuery)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self, weak panel] in
            self?.isSuppressingAutoHide = false
            guard let panel, panel.isVisible else { return }
            if !QuickLookCoordinator.shared.isQuickLookVisible,
               let tf = Self.findEditableTextField(in: panel.contentView) {
                NativeSearchInputField.focusTextField(tf, selectAll: selectExistingQuery)
            }
        }
    }

    func restoreFocusFromAuxiliaryPanel() {
        guard let panel, panel.isVisible else { return }
        isSuppressingAutoHide = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let tf = Self.findEditableTextField(in: panel.contentView) {
            NativeSearchInputField.focusTextField(tf, selectAll: false)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.isSuppressingAutoHide = false
        }
    }

    private static func findEditableTextField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let tf = view as? NSTextField, tf.isEditable, !tf.isHidden {
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
        shiftTapStartTime = nil
        shiftInvalidatedByOtherInput = false
        isSuppressingAutoHide = false
        screenshotGraceUntil = 0
        if QuickLookCoordinator.shared.isQuickLookVisible {
            QuickLookCoordinator.shared.closeQuickLook(restoreLauncherFocus: false)
        }
        if LargeTypeOverlayController.shared.isVisible {
            LargeTypeOverlayController.shared.dismiss(restoreFocus: false)
        }
        removeKeyboardMonitors()
        LauncherViewModel.shared.activeModifiers = []
        panel?.orderOut(nil)
    }

    func reapplySpaceCollectionBehavior() {
        panel?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    func windowDidResignKey(_ notification: Notification) {
        if shouldSuppressAutoHide {
            return
        }
        if QuickLookCoordinator.shared.isQuickLookVisible {
            return
        }
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

        let hosting = FirstMouseHostingView(rootView: LauncherRootView(viewModel: LauncherViewModel.shared))
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

    // MARK: - Rich Keyboard Navigation (Alfred-grade, Vietnamese IME Safe, Shift Quick Look)

    private func installKeyboardMonitorsIfNeeded() {
        if localKeyMonitor == nil {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isVisible else { return event }
                self.shiftInvalidatedByOtherInput = true
                self.shiftTapStartTime = nil
                if self.handleKeyDown(event) {
                    return nil
                }
                return event
            }
        }

        if flagsMonitor == nil {
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self, self.isVisible else { return event }
                let clean = event.modifierFlags.cleanShortcutModifiers
                let code = Int(event.keyCode)
                LauncherViewModel.shared.activeModifiers = clean

                if (code == kVK_Shift || code == kVK_RightShift) && clean == .shift {
                    self.shiftTapStartTime = ProcessInfo.processInfo.systemUptime
                    self.shiftInvalidatedByOtherInput = false
                } else if clean.isEmpty {
                    if let t0 = self.shiftTapStartTime,
                       !self.shiftInvalidatedByOtherInput,
                       (ProcessInfo.processInfo.systemUptime - t0) < 0.45 {
                        self.shiftTapStartTime = nil
                        LauncherViewModel.shared.toggleQuickLookForCurrentContext()
                    } else {
                        self.shiftTapStartTime = nil
                    }
                } else {
                    self.shiftInvalidatedByOtherInput = true
                    self.shiftTapStartTime = nil
                }
                return event
            }
        }

        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.shiftInvalidatedByOtherInput = true
                self?.shiftTapStartTime = nil
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
        if let mMon = mouseMonitor {
            NSEvent.removeMonitor(mMon)
            mouseMonitor = nil
        }
    }

    private func commitActiveIMEIfNeeded(syncBeforeSubmit: Bool) {
        guard let editor = panel?.firstResponder as? NSTextView else { return }
        if syncBeforeSubmit {
            let live = editor.string
            let preservedIndex = LauncherViewModel.shared.selectedIndex
            let alreadyMatches: Bool = {
                switch LauncherViewModel.shared.screenMode {
                case .search: return LauncherViewModel.shared.searchText == live
                case .universalActions: return LauncherViewModel.shared.actionFilterText == live
                case .destinationPicker: return LauncherViewModel.shared.destinationSearchText == live
                case .contactDetail: return LauncherViewModel.shared.contactDetailFilterText == live
                default: return true
                }
            }()
            if editor.hasMarkedText() {
                editor.unmarkText()
            }
            if !alreadyMatches {
                LauncherViewModel.shared.syncImmediateTextBeforeSubmit(live)
            } else {
                LauncherViewModel.shared.selectedIndex = preservedIndex
            }
        } else if editor.hasMarkedText() {
            editor.unmarkText()
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let vm = LauncherViewModel.shared
        let flags = event.modifierFlags.cleanShortcutModifiers
        let code = Int(event.keyCode)

        // 0. Pass screenshot shortcuts (⌘⇧1..6, ⌘⌃⇧1..6, ⌘⌥⇧1..6) straight through without auto-hiding
        if flags.contains([.command, .shift]),
           (code == kVK_ANSI_1 || code == kVK_ANSI_2 || code == kVK_ANSI_3 ||
            code == kVK_ANSI_4 || code == kVK_ANSI_5 || code == kVK_ANSI_6) {
            screenshotGraceUntil = ProcessInfo.processInfo.systemUptime + 10.0
            return false
        }
        screenshotGraceUntil = 0

        // 1. Escape handling (close Large Type / Quick Look first if open!)
        if code == kVK_Escape {
            if LargeTypeOverlayController.shared.isVisible {
                LargeTypeOverlayController.shared.dismiss(restoreFocus: true)
                return true
            }
            if QuickLookCoordinator.shared.isQuickLookVisible {
                QuickLookCoordinator.shared.closeQuickLook(restoreLauncherFocus: true)
                return true
            }
            commitActiveIMEIfNeeded(syncBeforeSubmit: false)
            vm.handleEscapeKey()
            return true
        }

        // 1.5. In Batch Rename mode, allow Tab / Arrows / Typing to flow naturally to SwiftUI TextFields
        if case .batchRename = vm.screenMode {
            if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
                if let editor = panel?.firstResponder as? NSTextView, editor.hasMarkedText() {
                    editor.unmarkText()
                }
                BatchRenameState.shared.executeCommit(revealInFinder: flags.contains(.command))
                return true
            }
            return false
        }

        // 2. Quick Look: ⌘Y (in addition to standalone Shift tap)
        if flags == .command && code == kVK_ANSI_Y {
            vm.toggleQuickLookForCurrentContext()
            return true
        }

        // 2.5. Pin / Unpin Favorite in Search Mode: ⌘D
        if flags == .command && code == kVK_ANSI_D, case .search = vm.screenMode {
            if vm.togglePinForSelectedItem() {
                return true
            }
        }

        // 2.6. Contact Detail shortcuts: ⌘C (copy field & keep open), ⌘O (open in Contacts.app)
        if case .contactDetail(let contactID, _, _) = vm.screenMode {
            if flags == .command && code == kVK_ANSI_C {
                let selectedLen = (panel?.firstResponder as? NSTextView)?.selectedRange().length ?? 0
                if selectedLen == 0 && vm.copySelectedContactDetailFieldKeepOpen() {
                    return true
                }
            }
            if flags == .command && code == kVK_ANSI_O {
                ContactsSearchService.shared.openInContactsApp(contactID: contactID)
                return true
            }
        }

        // 3. Universal Action Hotkey (default ⌘/) or ⌘K while DriveBar is open
        if Self.matchesBinding(AppSettings.shared.universalActionHotKey, code: code, flags: flags) ||
           (flags == .command && code == kVK_ANSI_Slash) ||
           (flags == .command && code == kVK_ANSI_K) {
            commitActiveIMEIfNeeded(syncBeforeSubmit: false)
            if case .search = vm.screenMode {
                vm.openUniversalActionsForSelectedSearchItem()
            } else if case .universalActions = vm.screenMode {
                if !vm.openedDirectlyInUniversalActions {
                    vm.returnToSearchMode()
                } else {
                    hide()
                }
            }
            return true
        }

        // 4. Open Preferences: ⌘,
        if flags == .command && code == kVK_ANSI_Comma {
            hide()
            AppDelegate.shared?.openSettingsWindow()
            return true
        }

        // 5. Instant row hotkeys: ⌘1 ... ⌘9
        if flags == .command, let numIndex = Self.numberIndex(for: code) {
            commitActiveIMEIfNeeded(syncBeforeSubmit: false)
            vm.executeAtIndex(numIndex, modifiers: [])
            return true
        }

        // 6. File Buffer shortcuts in Search mode: ⌥↑, ⌥↓, ⌥→, ⌥⌫
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

        // 7. Up / Down navigation (or ⌃P / ⌃N)
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

        // 8. Tab -> Open Universal Actions / Drill into Destination Folder / Go Back
        if code == kVK_Tab && (flags.isEmpty || flags == .shift) {
            commitActiveIMEIfNeeded(syncBeforeSubmit: false)
            vm.handleTabKey()
            return true
        }

        // 9. Right / Left Arrow Alfred-style Universal Actions navigation
        if code == kVK_RightArrow && flags.isEmpty {
            let editor = panel?.firstResponder as? NSTextView
            let hasMarked = editor?.hasMarkedText() ?? false
            if !hasMarked {
                let isCursorAtEnd: Bool = {
                    guard let editor else { return true }
                    let sel = editor.selectedRange()
                    return sel.length == 0 && sel.location >= (editor.string as NSString).length
                }()
                switch vm.screenMode {
                case .search:
                    let isBrowse = vm.activeBrowseDirectory != nil || vm.searchText.hasPrefix("/") || vm.searchText.hasPrefix("~/") || vm.searchText.hasPrefix("…") || vm.searchText.hasPrefix("...")
                    let inBrowseWithChildSelected = isBrowse && vm.selectedIndex > 0
                    if vm.searchText.isEmpty || isCursorAtEnd || inBrowseWithChildSelected {
                        if vm.openUniversalActionsForSelectedSearchItem() {
                            return true
                        }
                    }
                case .universalActions:
                    if vm.actionFilterText.isEmpty || isCursorAtEnd {
                        vm.executeCurrentSelection(modifiers: [])
                        return true
                    }
                case .destinationPicker:
                    if isCursorAtEnd && vm.drillIntoSelectedDestinationFolder() {
                        return true
                    }
                case .contactDetail:
                    if vm.contactDetailFilterText.isEmpty || isCursorAtEnd {
                        vm.executeCurrentSelection(modifiers: [])
                        return true
                    }
                default:
                    break
                }
            }
        }

        if code == kVK_LeftArrow && flags.isEmpty {
            let editor = panel?.firstResponder as? NSTextView
            let hasMarked = editor?.hasMarkedText() ?? false
            if !hasMarked {
                switch vm.screenMode {
                case .universalActions:
                    if vm.actionFilterText.isEmpty && !vm.openedDirectlyInUniversalActions {
                        vm.returnToSearchMode()
                        return true
                    }
                case .openWithPicker(_, let prevTarget):
                    vm.openUniversalActions(for: prevTarget, directExternalTrigger: vm.openedDirectlyInUniversalActions)
                    return true
                case .contactDetail:
                    if vm.contactDetailFilterText.isEmpty {
                        vm.returnFromContactDetail()
                        return true
                    }
                default:
                    break
                }
            }
        }

        // 10. Backspace at trailing `/` in Browse Mode pops up one parent folder
        if code == kVK_Delete && flags.isEmpty {
            let hasMarked = (panel?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
            if !hasMarked && vm.popParentFolderIfAtSlashBoundary() {
                return true
            }
        }

        // 11. Enter / Return -> Execute with active modifiers (↩, ⌘↩, ⌥↩, ⌃↩, ⇧↩)
        if code == kVK_Return || code == kVK_ANSI_KeypadEnter {
            commitActiveIMEIfNeeded(syncBeforeSubmit: true)
            vm.executeCurrentSelection(modifiers: flags)
            return true
        }

        return false
    }

    private static func matchesBinding(_ binding: HotKeyBinding, code: Int, flags: NSEvent.ModifierFlags) -> Bool {
        guard Int(binding.keyCode) == code else { return false }
        var expected: NSEvent.ModifierFlags = []
        if binding.hasCommand { expected.insert(.command) }
        if binding.hasOption { expected.insert(.option) }
        if binding.hasControl { expected.insert(.control) }
        if binding.hasShift { expected.insert(.shift) }
        return flags == expected
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
