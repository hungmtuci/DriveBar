import SwiftUI
import AppKit
import Carbon
import ApplicationServices
import CoreGraphics

final class WindowSwitcherStagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class WindowSwitcherController: NSObject, ObservableObject {
    static let shared = WindowSwitcherController()

    @Published private(set) var isVisible: Bool = false
    @Published private(set) var isEventTapActive: Bool = false
    @Published var isPinnedOpen: Bool = false

    private var stagePanel: WindowSwitcherStagePanel?
    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var permissionPollTimer: Timer?
    private var localKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var mouseMoveMonitor: Any?
    private var globalMouseMoveMonitor: Any?
    private var globalClickMonitor: Any?

    private var activeHoldModifierMask: CGEventFlags = []
    private var launchMouseLocation: NSPoint = .zero
    private var hasUserMovedMouseSinceLaunch: Bool = false

    private override init() {
        super.init()
    }

    func start() {
        refreshEventTapState()
        startPermissionWatchdogIfNeeded()
    }

    func refreshEventTapState() {
        let settings = AppSettings.shared
        let wantsSwitcher = settings.enableWindowSwitcher || settings.enableSameAppSwitcher
        WindowSwitcherService.shared.refreshPermissionStates()

        guard wantsSwitcher && AXIsProcessTrusted() else {
            tearDownEventTap()
            if wantsSwitcher {
                startPermissionWatchdogIfNeeded()
            }
            return
        }

        if let tap = eventTap {
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            isEventTapActive = CGEvent.tapIsEnabled(tap: tap)
            return
        }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }
            let controller = Unmanaged<WindowSwitcherController>.fromOpaque(userInfo).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated {
                    if let tap = controller.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                }
                return Unmanaged.passUnretained(event)
            }

            let consumed = MainActor.assumeIsolated {
                controller.handleCGEvent(type: type, event: event)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        if let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: createdTap, enable: true)
            self.eventTap = createdTap
            self.runLoopSource = src
            self.isEventTapActive = true
            permissionPollTimer?.invalidate()
            permissionPollTimer = nil
        } else {
            self.isEventTapActive = false
            startPermissionWatchdogIfNeeded()
        }
    }

    private func tearDownEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        isEventTapActive = false
    }

    private func startPermissionWatchdogIfNeeded() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                WindowSwitcherService.shared.refreshPermissionStates()
                if AXIsProcessTrusted() {
                    self.refreshEventTapState()
                }
            }
        }
    }

    // MARK: - Session-Level Event Tap Handling (⌘Tab, ⌘⇧Tab, ⌘`, Arrows, Modifier Release)

    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        let settings = AppSettings.shared

        // 0. If user is actively recording a custom shortcut in Settings, allow capturing ⌘Tab / ⌘` directly!
        if let recTarget = HotKeyService.shared.recordingTarget, type == .keyDown {
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if !Self.isPureModifierKeyCode(code) {
                let carbonMods = Self.carbonModifiers(from: event.flags)
                if code == kVK_Escape && carbonMods == 0 {
                    HotKeyService.shared.stopRecording()
                    HotKeyService.shared.registerAll()
                    return true
                }
                if carbonMods != 0 || (code >= kVK_F1 && code <= kVK_F19) {
                    let binding = HotKeyBinding(keyCode: UInt32(code), carbonModifiers: carbonMods)
                    HotKeyService.shared.applyRecordedBinding(binding, for: recTarget)
                    return true
                }
            }
        }

        if type == .flagsChanged {
            guard isVisible, !isPinnedOpen, !activeHoldModifierMask.isEmpty else {
                return false
            }
            let currentMods = Self.cleanCGModifiers(event.flags)
            if !currentMods.contains(activeHoldModifierMask) {
                commitSelectionAndDismiss()
            }
            return false
        }

        guard type == .keyDown else { return false }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let cleanFlags = Self.cleanCGModifiers(event.flags)

        // 1. Check Primary Window Switcher Trigger (e.g. ⌘Tab or ⌘⇧Tab)
        if settings.enableWindowSwitcher,
           let backward = Self.matchesSwitcherTrigger(binding: settings.windowSwitcherHotKey, keyCode: code, flags: cleanFlags) {
            if !isVisible {
                let holdMask = Self.holdModifierMask(for: settings.windowSwitcherHotKey)
                presentSwitcher(
                    sameAppOnly: false,
                    moveBackward: backward,
                    holdModifierMask: holdMask,
                    pinnedOpen: holdMask.isEmpty
                )
            } else {
                if WindowSwitcherService.shared.sessionSameAppPID != nil {
                    WindowSwitcherService.shared.sessionSameAppPID = nil
                    WindowSwitcherService.shared.rebuildFilteredItemsPreservingSelection()
                }
                WindowSwitcherService.shared.stepSelection(delta: backward ? -1 : 1)
            }
            return true
        }

        // 2. Check Same-App Window Switcher Trigger (e.g. ⌘` or ⌘⇧`)
        if settings.enableSameAppSwitcher,
           let backward = Self.matchesSwitcherTrigger(binding: settings.sameAppSwitcherHotKey, keyCode: code, flags: cleanFlags) {
            if !isVisible {
                let holdMask = Self.holdModifierMask(for: settings.sameAppSwitcherHotKey)
                presentSwitcher(
                    sameAppOnly: true,
                    moveBackward: backward,
                    holdModifierMask: holdMask,
                    pinnedOpen: holdMask.isEmpty
                )
            } else {
                WindowSwitcherService.shared.stepSelection(delta: backward ? -1 : 1)
            }
            return true
        }

        // 3. When Switcher Is Visible, Handle Navigation & In-Place Window Actions
        guard isVisible else { return false }
        return handleSwitcherKeyCode(code: code, cgFlags: cleanFlags)
    }

    private func handleSwitcherKeyCode(code: Int, cgFlags: CGEventFlags) -> Bool {
        let svc = WindowSwitcherService.shared
        let hasShift = cgFlags.contains(.maskShift)

        switch code {
        case kVK_Escape:
            dismissWithoutActivating()
            return true

        case kVK_Return, kVK_ANSI_KeypadEnter:
            commitSelectionAndDismiss()
            return true

        case kVK_Tab:
            svc.stepSelection(delta: hasShift ? -1 : 1)
            return true

        case kVK_ANSI_Grave:
            svc.stepSelection(delta: hasShift ? 1 : -1)
            return true

        case kVK_RightArrow, kVK_DownArrow:
            svc.stepSelection(delta: 1)
            return true

        case kVK_LeftArrow, kVK_UpArrow:
            svc.stepSelection(delta: -1)
            return true

        case kVK_Space:
            // Space toggles Large Zoomed Preview & pins switcher open for hands-free arrow browsing
            isPinnedOpen = true
            AppSettings.shared.windowSwitcherShowZoomPreview.toggle()
            return true

        case kVK_ANSI_W:
            svc.closeSelectedWindow()
            return true

        case kVK_ANSI_M:
            svc.toggleMinimizeSelectedWindow()
            return true

        case kVK_ANSI_H:
            svc.toggleHideSelectedApp()
            return true

        case kVK_ANSI_Q:
            svc.quitSelectedApp()
            return true

        case kVK_ANSI_1:
            isPinnedOpen = true
            AppSettings.shared.windowSwitcherScope = AppSettings.shared.windowSwitcherScope.nextCycle()
            svc.rebuildFilteredItemsPreservingSelection()
            return true

        case kVK_ANSI_2:
            isPinnedOpen = true
            AppSettings.shared.windowSwitcherShowMinimized.toggle()
            svc.rebuildFilteredItemsPreservingSelection()
            return true

        case kVK_ANSI_3:
            isPinnedOpen = true
            AppSettings.shared.windowSwitcherShowHiddenApps.toggle()
            svc.rebuildFilteredItemsPreservingSelection()
            return true

        case kVK_ANSI_4, kVK_ANSI_A:
            isPinnedOpen = true
            toggleSameAppFilterLive()
            return true

        default:
            return false
        }
    }

    // MARK: - Present, Commit & Dismiss

    func openPinnedFromMenuOrSearch(sameAppOnly: Bool = false) {
        presentSwitcher(
            sameAppOnly: sameAppOnly,
            moveBackward: false,
            holdModifierMask: [],
            pinnedOpen: true
        )
    }

    func handleCarbonHotKeyFallback(sameAppOnly: Bool) {
        if isVisible {
            WindowSwitcherService.shared.stepSelection(delta: 1)
            return
        }
        let binding = sameAppOnly ? AppSettings.shared.sameAppSwitcherHotKey : AppSettings.shared.windowSwitcherHotKey
        let holdMask = Self.holdModifierMask(for: binding)
        presentSwitcher(
            sameAppOnly: sameAppOnly,
            moveBackward: false,
            holdModifierMask: holdMask,
            pinnedOpen: !isEventTapActive
        )
    }

    func presentSwitcher(
        sameAppOnly: Bool,
        moveBackward: Bool,
        holdModifierMask: CGEventFlags,
        pinnedOpen: Bool
    ) {
        if LauncherPanelController.shared.isVisible {
            LauncherPanelController.shared.hide()
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        let targetSamePID: pid_t? = sameAppOnly ? frontApp?.processIdentifier : nil

        self.activeHoldModifierMask = holdModifierMask
        self.isPinnedOpen = pinnedOpen
        self.launchMouseLocation = NSEvent.mouseLocation
        self.hasUserMovedMouseSinceLaunch = false

        WindowSwitcherService.shared.reloadSessionWindows(
            sameAppPID: targetSamePID,
            selectPreviousWindow: !pinnedOpen,
            moveBackward: moveBackward
        )

        ensureStagePanelCreated()
        guard let panel = stagePanel else { return }

        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen {
            panel.setFrame(screen.frame, display: true)
        }

        isVisible = true
        installAuxiliaryMonitors(activateIfNeeded: !isEventTapActive)
        panel.orderFrontRegardless()
        if !isEventTapActive {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    func selectAndActivateAtIndex(_ index: Int) {
        let svc = WindowSwitcherService.shared
        guard index >= 0 && index < svc.items.count else { return }
        svc.selectedIndex = index
        commitSelectionAndDismiss()
    }

    func hoverItemAtIndex(_ index: Int) {
        guard isVisible, hasUserMovedMouseSinceLaunch else { return }
        let svc = WindowSwitcherService.shared
        if index >= 0 && index < svc.items.count && svc.selectedIndex != index {
            svc.selectedIndex = index
        }
    }

    func toggleSameAppFilterLive() {
        let svc = WindowSwitcherService.shared
        if svc.sessionSameAppPID != nil {
            svc.sessionSameAppPID = nil
        } else if let cur = svc.selectedItem {
            svc.sessionSameAppPID = cur.pid
        } else if let front = NSWorkspace.shared.frontmostApplication {
            svc.sessionSameAppPID = front.processIdentifier
        }
        svc.rebuildFilteredItemsPreservingSelection()
    }

    func commitSelectionAndDismiss() {
        let chosen = WindowSwitcherService.shared.selectedItem
        dismissWithoutActivating()
        if let chosen {
            WindowSwitcherService.shared.activateWindow(chosen)
        }
    }

    func dismissWithoutActivating() {
        guard isVisible else { return }
        isVisible = false
        isPinnedOpen = false
        activeHoldModifierMask = []
        removeAuxiliaryMonitors()
        stagePanel?.orderOut(nil)
    }

    private func ensureStagePanelCreated() {
        guard stagePanel == nil else { return }
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let p = WindowSwitcherStagePanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let root = WindowSwitcherOverlayView(
            controller: self,
            service: WindowSwitcherService.shared,
            settings: AppSettings.shared
        )
        let hosting = FirstMouseHostingView(rootView: root)
        hosting.frame = frame
        p.contentView = hosting
        self.stagePanel = p
    }

    private func installAuxiliaryMonitors(activateIfNeeded: Bool) {
        removeAuxiliaryMonitors()

        mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.checkMouseMovementThreshold()
            return event
        }
        globalMouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in
                self?.checkMouseMovementThreshold()
            }
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.dismissWithoutActivating()
            }
        }

        if activateIfNeeded {
            localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isVisible else { return event }
                let cgFlags = Self.cgFlags(from: event.modifierFlags)
                if self.handleSwitcherKeyCode(code: Int(event.keyCode), cgFlags: cgFlags) {
                    return nil
                }
                return event
            }
            localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                guard let self, self.isVisible, !self.isPinnedOpen, !self.activeHoldModifierMask.isEmpty else {
                    return event
                }
                let cgFlags = Self.cgFlags(from: event.modifierFlags)
                if !cgFlags.contains(self.activeHoldModifierMask) {
                    self.commitSelectionAndDismiss()
                }
                return event
            }
        }
    }

    private func checkMouseMovementThreshold() {
        guard !hasUserMovedMouseSinceLaunch else { return }
        let cur = NSEvent.mouseLocation
        if hypot(cur.x - launchMouseLocation.x, cur.y - launchMouseLocation.y) > 6 {
            hasUserMovedMouseSinceLaunch = true
        }
    }

    private func removeAuxiliaryMonitors() {
        if let m = mouseMoveMonitor { NSEvent.removeMonitor(m); mouseMoveMonitor = nil }
        if let m = globalMouseMoveMonitor { NSEvent.removeMonitor(m); globalMouseMoveMonitor = nil }
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
    }

    // MARK: - Modifier Matching Helpers

    private static func cleanCGModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.maskCommand) { result.insert(.maskCommand) }
        if flags.contains(.maskAlternate) { result.insert(.maskAlternate) }
        if flags.contains(.maskControl) { result.insert(.maskControl) }
        if flags.contains(.maskShift) { result.insert(.maskShift) }
        return result
    }

    private static func cgFlags(from nsFlags: NSEvent.ModifierFlags) -> CGEventFlags {
        let clean = nsFlags.intersection(.deviceIndependentFlagsMask)
        var out: CGEventFlags = []
        if clean.contains(.command) { out.insert(.maskCommand) }
        if clean.contains(.option) { out.insert(.maskAlternate) }
        if clean.contains(.control) { out.insert(.maskControl) }
        if clean.contains(.shift) { out.insert(.maskShift) }
        return out
    }

    private static func holdModifierMask(for binding: HotKeyBinding) -> CGEventFlags {
        var mask: CGEventFlags = []
        if binding.hasCommand { mask.insert(.maskCommand) }
        if binding.hasOption { mask.insert(.maskAlternate) }
        if binding.hasControl { mask.insert(.maskControl) }
        if mask.isEmpty && binding.hasShift { mask.insert(.maskShift) }
        return mask
    }

    /// Returns `Bool` (`isBackward`) if `keyCode` + `flags` matches `binding` (allowing optional extra Shift for backward cycling on Tab/Grave).
    private static func matchesSwitcherTrigger(binding: HotKeyBinding, keyCode: Int, flags: CGEventFlags) -> Bool? {
        guard Int(binding.keyCode) == keyCode else { return nil }
        var expected: CGEventFlags = []
        if binding.hasCommand { expected.insert(.maskCommand) }
        if binding.hasOption { expected.insert(.maskAlternate) }
        if binding.hasControl { expected.insert(.maskControl) }
        if binding.hasShift { expected.insert(.maskShift) }

        if flags == expected {
            return false
        }
        // Allow Shift+<Trigger> (e.g. ⌘⇧Tab or ⌥⇧Tab or ⌘⇧`) for reverse cycling!
        if !binding.hasShift {
            var withShift = expected
            withShift.insert(.maskShift)
            if flags == withShift {
                return true
            }
        }
        return nil
    }

    private static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.maskControl) { mods |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { mods |= UInt32(optionKey) }
        if flags.contains(.maskShift) { mods |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { mods |= UInt32(cmdKey) }
        return mods
    }

    private static func isPureModifierKeyCode(_ code: Int) -> Bool {
        switch code {
        case kVK_Command, kVK_RightCommand,
             kVK_Shift, kVK_RightShift,
             kVK_Option, kVK_RightOption,
             kVK_Control, kVK_RightControl,
             kVK_CapsLock, kVK_Function:
            return true
        default:
            return false
        }
    }
}
