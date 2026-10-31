import SwiftUI
import AppKit
import Carbon
import ApplicationServices
import CoreGraphics

final class WindowSwitcherStagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            let handled = MainActor.assumeIsolated { () -> Bool in
                let ctrl = WindowSwitcherController.shared
                guard ctrl.isVisible, !ctrl.shouldSuppressAutoDismiss else { return false }
                guard ctrl.stripCardSwiftUIFrame != .zero else { return false }
                let loc = event.locationInWindow
                let inPreview = ctrl.isPointInsidePreviewCard(loc, windowHeight: self.frame.height)
                let inStrip = ctrl.isPointInsideStripCard(loc, windowHeight: self.frame.height)
                if !inPreview && !inStrip {
                    ctrl.dismissWithoutActivating(restorePreviousApp: true)
                    return true
                }
                if event.type == .leftMouseDown {
                    if ctrl.isPointInsidePreviewContentArea(loc, windowHeight: self.frame.height) {
                        ctrl.commitSelectionAndDismiss()
                        return true
                    }
                    if ctrl.isPointInsideStripThumbnailsArea(loc, windowHeight: self.frame.height) {
                        if let clickedIdx = ctrl.resolveThumbnailIndexAtLocation(loc) {
                            WindowSwitcherService.shared.selectedIndex = clickedIdx
                        }
                        ctrl.commitSelectionAndDismiss()
                        return true
                    }
                }
                return false
            }
            if handled {
                return
            }
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if MainActor.assumeIsolated({ WindowSwitcherController.shared.handleLocalNSEventShortcut(event) }) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct SharedTapConfig: Sendable {
    var enableWindowSwitcher: Bool = true
    var windowSwitcherHotKey: HotKeyBinding = .defaultWindowSwitcher
    var enableSameAppSwitcher: Bool = true
    var sameAppSwitcherHotKey: HotKeyBinding = .defaultSameAppSwitcher
    var releaseToActivate: Bool = false
    var spaceToActivate: Bool = true
    var isSwitcherVisible: Bool = false
    var isPinnedOpen: Bool = true
    var activeHoldModifierMaskRaw: UInt64 = 0
    var lastModifierFlagsRaw: UInt64 = 0
    var cmdTapStartUptime: TimeInterval = 0
    var cmdTapInvalidated: Bool = true
    var optTapStartUptime: TimeInterval = 0
    var optTapInvalidated: Bool = true
    var lastFlagsTimestamp: CGEventTimestamp = 0
    var recordingTarget: HotKeyService.RecordingTarget? = nil
    var screenshotGraceUntil: TimeInterval = 0
    var didResignDuringScreenshotGrace: Bool = false
}

@MainActor
final class WindowSwitcherController: NSObject, ObservableObject {
    static let shared = WindowSwitcherController()

    @Published private(set) var isVisible: Bool = false
    @Published private(set) var isEventTapActive: Bool = false
    @Published var isPinnedOpen: Bool = true
    @Published private(set) var openedDirectlyInSameAppMode: Bool = false

    var isSuppressingResignDismiss: Bool = false
    private var screenshotGraceUntil: TimeInterval = 0

    var shouldSuppressAutoDismiss: Bool {
        isSuppressingResignDismiss || ProcessInfo.processInfo.systemUptime < screenshotGraceUntil
    }

    var previewCardSwiftUIFrame: CGRect = .zero
    var stripCardSwiftUIFrame: CGRect = .zero

    func isPointInsidePreviewCard(_ loc: NSPoint, windowHeight: CGFloat) -> Bool {
        guard previewCardSwiftUIFrame != .zero else { return false }
        let appKitY = windowHeight - previewCardSwiftUIFrame.maxY
        let appKitRect = NSRect(
            x: previewCardSwiftUIFrame.minX,
            y: appKitY,
            width: previewCardSwiftUIFrame.width,
            height: previewCardSwiftUIFrame.height
        ).insetBy(dx: -8, dy: -8)
        return appKitRect.contains(loc)
    }

    /// Checks if a location is specifically inside the magnified preview content area of the preview card
    /// (excluding its top 38pt window header which contains close/quit/minimize buttons).
    func isPointInsidePreviewContentArea(_ loc: NSPoint, windowHeight: CGFloat) -> Bool {
        guard previewCardSwiftUIFrame != .zero else { return false }
        let appKitY = windowHeight - previewCardSwiftUIFrame.maxY
        let appKitRect = NSRect(
            x: previewCardSwiftUIFrame.minX,
            y: appKitY,
            width: previewCardSwiftUIFrame.width,
            height: previewCardSwiftUIFrame.height
        )
        guard appKitRect.contains(loc) else { return false }
        let contentArea = NSRect(
            x: previewCardSwiftUIFrame.minX,
            y: appKitY,
            width: previewCardSwiftUIFrame.width,
            height: max(0, previewCardSwiftUIFrame.height - 38)
        )
        return contentArea.contains(loc)
    }

    /// Checks if a point is inside the middle thumbnail row of the bottom strip card
    /// (excluding its top search field and bottom footer buttons).
    func isPointInsideStripThumbnailsArea(_ loc: NSPoint, windowHeight: CGFloat) -> Bool {
        guard stripCardSwiftUIFrame != .zero else { return false }
        let appKitY = windowHeight - stripCardSwiftUIFrame.maxY
        let appKitRect = NSRect(
            x: stripCardSwiftUIFrame.minX,
            y: appKitY,
            width: stripCardSwiftUIFrame.width,
            height: stripCardSwiftUIFrame.height
        )
        guard appKitRect.contains(loc) else { return false }
        let thumbnailArea = NSRect(
            x: stripCardSwiftUIFrame.minX,
            y: appKitY + 36,
            width: stripCardSwiftUIFrame.width,
            height: max(0, stripCardSwiftUIFrame.height - 44 - 36)
        )
        return thumbnailArea.contains(loc)
    }

    /// Resolves which thumbnail card index was clicked in the thumbnail row.
    func resolveThumbnailIndexAtLocation(_ loc: NSPoint) -> Int? {
        let svc = WindowSwitcherService.shared
        guard !svc.items.isEmpty, stripCardSwiftUIFrame != .zero else { return nil }
        let relX = loc.x - (stripCardSwiftUIFrame.minX + 18)
        guard relX >= 0 else { return nil }
        let cardSpan: CGFloat = 196 + 10 // card width + spacing
        let rawIdx = Int(relX / cardSpan)
        if rawIdx >= 0 && rawIdx < svc.items.count {
            return rawIdx
        }
        return nil
    }

    func isPointInsideStripCard(_ loc: NSPoint, windowHeight: CGFloat) -> Bool {
        guard stripCardSwiftUIFrame != .zero else { return true }
        let appKitY = windowHeight - stripCardSwiftUIFrame.maxY
        let appKitRect = NSRect(
            x: stripCardSwiftUIFrame.minX,
            y: appKitY,
            width: stripCardSwiftUIFrame.width,
            height: stripCardSwiftUIFrame.height
        ).insetBy(dx: -8, dy: -8)
        return appKitRect.contains(loc)
    }

    private var stagePanel: WindowSwitcherStagePanel?
    private var permissionPollTimer: Timer?
    private var localKeyMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalClickMonitor: Any?

    private var previousFrontApp: NSRunningApplication?
    private var activeHoldModifierMask: CGEventFlags = []
    private var lastAcceptedHoverMouseLocation: NSPoint = .zero
    private var lastQuickActionUptime: TimeInterval = 0

    // Dedicated off-main EventTap thread & lock-protected state (prevents WindowServer timeout stalls!)
    nonisolated(unsafe) private let tapStateLock = NSLock()
    nonisolated(unsafe) private var sharedTapConfig = SharedTapConfig()
    nonisolated(unsafe) fileprivate var eventTap: CFMachPort?
    nonisolated(unsafe) private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?

    private override init() {
        super.init()
    }

    func start() {
        syncSharedTapConfiguration()
        refreshEventTapState()
        startPermissionWatchdogIfNeeded()
    }

    func syncSharedTapConfiguration() {
        let settings = AppSettings.shared
        let recTarget = HotKeyService.shared.recordingTarget
        let visible = self.isVisible
        let pinned = self.isPinnedOpen
        let holdRaw = self.activeHoldModifierMask.rawValue
        let graceUntil = self.screenshotGraceUntil

        tapStateLock.lock()
        sharedTapConfig.enableWindowSwitcher = settings.enableWindowSwitcher
        sharedTapConfig.windowSwitcherHotKey = settings.windowSwitcherHotKey
        sharedTapConfig.enableSameAppSwitcher = settings.enableSameAppSwitcher
        sharedTapConfig.sameAppSwitcherHotKey = settings.sameAppSwitcherHotKey
        sharedTapConfig.releaseToActivate = settings.windowSwitcherReleaseToActivate
        sharedTapConfig.spaceToActivate = settings.windowSwitcherSpaceToActivate
        sharedTapConfig.isSwitcherVisible = visible
        sharedTapConfig.isPinnedOpen = pinned
        sharedTapConfig.activeHoldModifierMaskRaw = holdRaw
        sharedTapConfig.recordingTarget = recTarget
        sharedTapConfig.screenshotGraceUntil = graceUntil
        if !visible {
            sharedTapConfig.didResignDuringScreenshotGrace = false
            sharedTapConfig.cmdTapStartUptime = 0
            sharedTapConfig.cmdTapInvalidated = true
            sharedTapConfig.optTapStartUptime = 0
            sharedTapConfig.optTapInvalidated = true
        }
        tapStateLock.unlock()
    }

    func refreshEventTapState() {
        syncSharedTapConfiguration()
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

        tapStateLock.lock()
        let existingTap = eventTap
        tapStateLock.unlock()

        if let existingTap {
            if !CGEvent.tapIsEnabled(tap: existingTap) {
                CGEvent.tapEnable(tap: existingTap, enable: true)
            }
            isEventTapActive = CGEvent.tapIsEnabled(tap: existingTap)
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
                controller.tapStateLock.lock()
                let tap = controller.eventTap
                controller.tapStateLock.unlock()
                if let tap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            let consumed = controller.handleCGEventOffMain(type: type, event: event)
            return consumed ? nil : Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            self.isEventTapActive = false
            startPermissionWatchdogIfNeeded()
            return
        }

        tapStateLock.lock()
        self.eventTap = createdTap
        tapStateLock.unlock()

        // Host the CGEventTap Mach port on a dedicated .userInteractive RunLoop thread
        // so UI layout / ScreenCaptureKit / AX calls NEVER delay WindowServer event delivery!
        let readySemaphore = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self else {
                readySemaphore.signal()
                return
            }
            let rl = CFRunLoopGetCurrent()
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0)
            CFRunLoopAddSource(rl, src, .commonModes)
            CGEvent.tapEnable(tap: createdTap, enable: true)

            self.tapStateLock.lock()
            self.tapRunLoop = rl
            self.tapStateLock.unlock()

            // Keep RunLoop alive until explicitly stopped
            let keepAlivePort = Port()
            RunLoop.current.add(keepAlivePort, forMode: .common)
            readySemaphore.signal()
            CFRunLoopRun()
            RunLoop.current.remove(keepAlivePort, forMode: .common)
        }
        thread.name = "com.hunglx.DriveBar.WindowSwitcherEventTap"
        thread.qualityOfService = .userInteractive
        self.tapThread = thread
        thread.start()
        _ = readySemaphore.wait(timeout: .now() + 0.5)

        self.isEventTapActive = CGEvent.tapIsEnabled(tap: createdTap)
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
    }

    private func tearDownEventTap() {
        tapStateLock.lock()
        let tap = eventTap
        let rl = tapRunLoop
        eventTap = nil
        tapRunLoop = nil
        tapStateLock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let rl {
            CFRunLoopStop(rl)
        }
        tapThread = nil
        isEventTapActive = false
    }

    private func startPermissionWatchdogIfNeeded() {
        guard permissionPollTimer == nil else { return }
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                WindowSwitcherService.shared.refreshPermissionStates()
                if AXIsProcessTrusted() {
                    self.refreshEventTapState()
                    HotKeyService.shared.registerAll()
                }
            }
        }
    }

    // MARK: - Sub-Millisecond Off-Main CGEventTap Handler (Zero Main-Thread Blocking!)

    nonisolated private func handleCGEventOffMain(type: CGEventType, event: CGEvent) -> Bool {
        tapStateLock.lock()
        let cfg = sharedTapConfig
        tapStateLock.unlock()

        // 0. Shortcut Recording Mode in Settings (allows recording ⌘Tab / ⌘` directly)
        if let recTarget = cfg.recordingTarget, type == .keyDown {
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            if !Self.isPureModifierKeyCode(code) {
                let carbonMods = Self.carbonModifiers(from: event.flags)
                if code == kVK_Escape && carbonMods == 0 {
                    DispatchQueue.main.async {
                        HotKeyService.shared.stopRecording()
                        HotKeyService.shared.registerAll()
                    }
                    return true
                }
                if carbonMods != 0 || (code >= kVK_F1 && code <= kVK_F19) {
                    let binding = HotKeyBinding(keyCode: UInt32(code), carbonModifiers: carbonMods)
                    DispatchQueue.main.async {
                        HotKeyService.shared.applyRecordedBinding(binding, for: recTarget)
                    }
                    return true
                }
            }
        }

        // 1. Modifier Flags Tracking:
        //    - Standalone Command tap (bấm phím ⌘ sau khi duyệt cửa sổ -> mở ngay cửa sổ đang chọn)
        //    - Optional Modifier-Release Commit (when releaseToActivate is enabled in Settings)
        if type == .flagsChanged {
            let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
            let currentMods = Self.cleanCGModifiers(event.flags)
            processModifierFlagsChange(code: code, cleanMods: currentMods, timestamp: event.timestamp)
            return false
        }

        guard type == .keyDown else { return false }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let cleanFlags = Self.cleanCGModifiers(event.flags)
        let isAutoRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        invalidateStandaloneCmdAndOptTap()

        // 2. Primary Window Switcher Trigger (e.g. ⌘Tab or ⌘⇧Tab)
        if cfg.enableWindowSwitcher,
           let backward = Self.matchesSwitcherTrigger(binding: cfg.windowSwitcherHotKey, keyCode: code, flags: cleanFlags) {
            if !cfg.isSwitcherVisible {
                let holdMask = Self.holdModifierMask(for: cfg.windowSwitcherHotKey)
                let pinned = !cfg.releaseToActivate || holdMask.isEmpty
                tapStateLock.lock()
                sharedTapConfig.isSwitcherVisible = true
                sharedTapConfig.isPinnedOpen = pinned
                sharedTapConfig.activeHoldModifierMaskRaw = holdMask.rawValue
                sharedTapConfig.lastModifierFlagsRaw = cleanFlags.rawValue
                sharedTapConfig.cmdTapStartUptime = 0
                sharedTapConfig.cmdTapInvalidated = true
                sharedTapConfig.optTapStartUptime = 0
                sharedTapConfig.optTapInvalidated = true
                tapStateLock.unlock()

                DispatchQueue.main.async {
                    WindowSwitcherController.shared.presentSwitcher(
                        sameAppOnly: false,
                        moveBackward: backward,
                        holdModifierMask: holdMask,
                        pinnedOpen: pinned,
                        selectNextOnOpen: true
                    )
                }
            } else {
                DispatchQueue.main.async {
                    let ctrl = WindowSwitcherController.shared
                    let svc = WindowSwitcherService.shared
                    if svc.sessionSameAppPID != nil {
                        svc.clearSameAppFilter()
                    }
                    ctrl.stepFromKeyboard(delta: backward ? -1 : 1)
                }
            }
            return true
        }

        // 3. Same-App Window Switcher Trigger (e.g. ⌘` or ⌘⇧`)
        if cfg.enableSameAppSwitcher,
           let backward = Self.matchesSwitcherTrigger(binding: cfg.sameAppSwitcherHotKey, keyCode: code, flags: cleanFlags) {
            if !cfg.isSwitcherVisible {
                let holdMask = Self.holdModifierMask(for: cfg.sameAppSwitcherHotKey)
                let pinned = !cfg.releaseToActivate || holdMask.isEmpty
                tapStateLock.lock()
                sharedTapConfig.isSwitcherVisible = true
                sharedTapConfig.isPinnedOpen = pinned
                sharedTapConfig.activeHoldModifierMaskRaw = holdMask.rawValue
                sharedTapConfig.lastModifierFlagsRaw = cleanFlags.rawValue
                sharedTapConfig.cmdTapStartUptime = 0
                sharedTapConfig.cmdTapInvalidated = true
                sharedTapConfig.optTapStartUptime = 0
                sharedTapConfig.optTapInvalidated = true
                tapStateLock.unlock()

                DispatchQueue.main.async {
                    WindowSwitcherController.shared.presentSwitcher(
                        sameAppOnly: true,
                        moveBackward: backward,
                        holdModifierMask: holdMask,
                        pinnedOpen: pinned,
                        selectNextOnOpen: true
                    )
                }
            } else {
                DispatchQueue.main.async {
                    WindowSwitcherController.shared.stepFromKeyboard(delta: backward ? -1 : 1)
                }
            }
            return true
        }

        // 4. Active Switcher Keyboard Navigation, Actions & Live Search Pass-Through
        guard cfg.isSwitcherVisible else { return false }
        return Self.routeVisibleSwitcherKeyOffMain(
            code: code,
            cleanFlags: cleanFlags,
            isAutoRepeat: isAutoRepeat,
            controller: self
        )
    }

    nonisolated private func invalidateStandaloneCmdAndOptTap() {
        tapStateLock.lock()
        sharedTapConfig.cmdTapStartUptime = 0
        sharedTapConfig.cmdTapInvalidated = true
        sharedTapConfig.optTapStartUptime = 0
        sharedTapConfig.optTapInvalidated = true
        tapStateLock.unlock()
    }

    nonisolated private func processModifierFlagsChange(
        code: Int,
        cleanMods: CGEventFlags,
        timestamp: CGEventTimestamp
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        var shouldCommit = false

        tapStateLock.lock()
        if timestamp != 0 && timestamp == sharedTapConfig.lastFlagsTimestamp {
            tapStateLock.unlock()
            return
        }
        if timestamp != 0 {
            sharedTapConfig.lastFlagsTimestamp = timestamp
        }

        let cfg = sharedTapConfig
        let prevMods = CGEventFlags(rawValue: cfg.lastModifierFlagsRaw)
        sharedTapConfig.lastModifierFlagsRaw = cleanMods.rawValue

        if cfg.isSwitcherVisible {
            let holdMask = CGEventFlags(rawValue: cfg.activeHoldModifierMaskRaw)
            if cfg.releaseToActivate && !cfg.isPinnedOpen && !holdMask.isEmpty && !cleanMods.contains(holdMask) {
                sharedTapConfig.isSwitcherVisible = false
                sharedTapConfig.cmdTapStartUptime = 0
                sharedTapConfig.cmdTapInvalidated = true
                sharedTapConfig.optTapStartUptime = 0
                sharedTapConfig.optTapInvalidated = true
                shouldCommit = true
            } else if (code == kVK_Command || code == kVK_RightCommand)
                        && cleanMods == .maskCommand
                        && prevMods.isEmpty {
                sharedTapConfig.cmdTapStartUptime = now
                sharedTapConfig.cmdTapInvalidated = false
            } else if (code == kVK_Option || code == kVK_RightOption)
                        && cleanMods == .maskAlternate
                        && prevMods.isEmpty {
                sharedTapConfig.optTapStartUptime = now
                sharedTapConfig.optTapInvalidated = false
            } else if cleanMods.isEmpty {
                let hadValidCmdTap = !cfg.cmdTapInvalidated && cfg.cmdTapStartUptime > 0 && (now - cfg.cmdTapStartUptime) < 0.60
                let hadValidOptTap = !cfg.optTapInvalidated && cfg.optTapStartUptime > 0 && (now - cfg.optTapStartUptime) < 0.60
                if hadValidCmdTap || hadValidOptTap {
                    sharedTapConfig.isSwitcherVisible = false
                    sharedTapConfig.cmdTapStartUptime = 0
                    sharedTapConfig.cmdTapInvalidated = true
                    sharedTapConfig.optTapStartUptime = 0
                    sharedTapConfig.optTapInvalidated = true
                    shouldCommit = true
                } else {
                    sharedTapConfig.cmdTapStartUptime = 0
                    sharedTapConfig.cmdTapInvalidated = true
                    sharedTapConfig.optTapStartUptime = 0
                    sharedTapConfig.optTapInvalidated = true
                }
            } else {
                sharedTapConfig.cmdTapStartUptime = 0
                sharedTapConfig.cmdTapInvalidated = true
                sharedTapConfig.optTapStartUptime = 0
                sharedTapConfig.optTapInvalidated = true
            }
        }
        tapStateLock.unlock()

        if shouldCommit {
            DispatchQueue.main.async {
                WindowSwitcherController.shared.commitSelectionAndDismiss()
            }
        }
    }

    nonisolated private static func routeVisibleSwitcherKeyOffMain(
        code: Int,
        cleanFlags: CGEventFlags,
        isAutoRepeat: Bool,
        controller: WindowSwitcherController
    ) -> Bool {
        let hasShift = cleanFlags.contains(.maskShift)
        let hasCmd = cleanFlags.contains(.maskCommand)
        let hasCtrl = cleanFlags.contains(.maskControl)
        let hasOpt = cleanFlags.contains(.maskAlternate)

        let isExactCmd = (cleanFlags == .maskCommand)
        let isExactCtrl = (cleanFlags == .maskControl)
        let isExactCmdOrCtrl = isExactCmd || isExactCtrl

        // Pass system & third-party screenshot shortcuts (⌘⇧1..6, ⌘⌃⇧1..6, ⌘⌥⇧1..6) straight through untouched,
        // and temporarily suppress auto-dismiss so users can even drag-capture Windows Preview itself!
        if hasCmd && hasShift && Self.isScreenshotShortcutKeyCode(code) {
            let deadline = ProcessInfo.processInfo.systemUptime + 10.0
            controller.tapStateLock.lock()
            controller.sharedTapConfig.screenshotGraceUntil = deadline
            controller.sharedTapConfig.didResignDuringScreenshotGrace = false
            controller.tapStateLock.unlock()
            DispatchQueue.main.async {
                WindowSwitcherController.shared.activateScreenshotCaptureGrace(until: deadline)
            }
            return false
        }

        switch code {
        case kVK_Escape where (cleanFlags.isEmpty || isExactCmd):
            let now = ProcessInfo.processInfo.systemUptime
            controller.tapStateLock.lock()
            let passToScreenshotUI = (now < controller.sharedTapConfig.screenshotGraceUntil)
                && controller.sharedTapConfig.didResignDuringScreenshotGrace
            controller.sharedTapConfig.screenshotGraceUntil = 0
            controller.sharedTapConfig.didResignDuringScreenshotGrace = false
            controller.tapStateLock.unlock()

            if passToScreenshotUI {
                DispatchQueue.main.async {
                    WindowSwitcherController.shared.clearScreenshotCaptureGrace()
                }
                return false
            }

            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.handleEscapeInSwitcher()
            }
            return true

        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard cleanFlags.isEmpty || cleanFlags == .maskShift || cleanFlags == .maskCommand || cleanFlags == .maskAlternate else { break }
            controller.tapStateLock.lock()
            controller.sharedTapConfig.isSwitcherVisible = false
            controller.sharedTapConfig.cmdTapStartUptime = 0
            controller.sharedTapConfig.cmdTapInvalidated = true
            controller.sharedTapConfig.optTapStartUptime = 0
            controller.sharedTapConfig.optTapInvalidated = true
            controller.sharedTapConfig.screenshotGraceUntil = 0
            controller.sharedTapConfig.didResignDuringScreenshotGrace = false
            controller.tapStateLock.unlock()
            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.commitSelectionAndDismiss()
            }
            return true

        case kVK_Space:
            if isExactCtrl {
                DispatchQueue.main.async {
                    let ctrl = WindowSwitcherController.shared
                    ctrl.clearScreenshotCaptureGrace()
                    ctrl.pinOpenFromInteraction()
                    AppSettings.shared.windowSwitcherShowZoomPreview.toggle()
                }
                return true
            }
            let validSpaceMods = cleanFlags.isEmpty || cleanFlags == .maskShift || cleanFlags == .maskCommand || cleanFlags == .maskAlternate
            controller.tapStateLock.lock()
            let spaceEnabled = controller.sharedTapConfig.spaceToActivate
            controller.tapStateLock.unlock()
            if validSpaceMods && (spaceEnabled || cleanFlags == .maskAlternate || cleanFlags == .maskCommand) {
                controller.tapStateLock.lock()
                controller.sharedTapConfig.isSwitcherVisible = false
                controller.sharedTapConfig.cmdTapStartUptime = 0
                controller.sharedTapConfig.cmdTapInvalidated = true
                controller.sharedTapConfig.optTapStartUptime = 0
                controller.sharedTapConfig.optTapInvalidated = true
                controller.sharedTapConfig.screenshotGraceUntil = 0
                controller.sharedTapConfig.didResignDuringScreenshotGrace = false
                controller.tapStateLock.unlock()
                DispatchQueue.main.async {
                    let ctrl = WindowSwitcherController.shared
                    ctrl.clearScreenshotCaptureGrace()
                    ctrl.commitSelectionAndDismiss()
                }
                return true
            }

        case kVK_Tab where !hasOpt:
            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.stepFromKeyboard(delta: hasShift ? -1 : 1)
            }
            return true

        case kVK_ANSI_Grave where (hasCmd || hasOpt || hasCtrl) && !(hasCmd && hasOpt):
            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.stepFromKeyboard(delta: hasShift ? 1 : -1)
            }
            return true

        case kVK_LeftArrow where isExactCtrl:
            controller.tapStateLock.lock()
            controller.sharedTapConfig.isSwitcherVisible = false
            controller.tapStateLock.unlock()
            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.commitSnapSelectionAndDismiss(.leftHalf)
            }
            return true

        case kVK_RightArrow where isExactCtrl:
            controller.tapStateLock.lock()
            controller.sharedTapConfig.isSwitcherVisible = false
            controller.tapStateLock.unlock()
            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.commitSnapSelectionAndDismiss(.rightHalf)
            }
            return true

        case kVK_UpArrow where isExactCtrl:
            controller.tapStateLock.lock()
            controller.sharedTapConfig.isSwitcherVisible = false
            controller.tapStateLock.unlock()
            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.commitSnapSelectionAndDismiss(.maximize)
            }
            return true

        case kVK_DownArrow where isExactCtrl:
            controller.tapStateLock.lock()
            controller.sharedTapConfig.isSwitcherVisible = false
            controller.tapStateLock.unlock()
            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.commitSnapSelectionAndDismiss(.centerRestore)
            }
            return true

        case kVK_RightArrow:
            guard !hasShift && !hasOpt && !hasCtrl else { break }
            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.pinOpenFromInteraction()
                ctrl.stepFromKeyboard(delta: 1)
            }
            return true

        case kVK_LeftArrow:
            guard !hasShift && !hasOpt && !hasCtrl else { break }
            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.pinOpenFromInteraction()
                ctrl.stepFromKeyboard(delta: -1)
            }
            return true

        case kVK_UpArrow:
            guard !hasShift && !hasOpt && !hasCtrl else { break }
            if !isAutoRepeat {
                DispatchQueue.main.async {
                    WindowSwitcherController.shared.handleUpArrowSameApp()
                }
            }
            return true

        case kVK_DownArrow:
            guard !hasShift && !hasOpt && !hasCtrl else { break }
            DispatchQueue.main.async {
                WindowSwitcherController.shared.handleDownArrowInSwitcher(isAutoRepeat: isAutoRepeat)
            }
            return true

        default:
            break
        }

        // Option + Command + Q (⌥⌘Q) -> Force Quit selected application
        if code == kVK_ANSI_Q && cleanFlags == [.maskCommand, .maskAlternate] {
            DispatchQueue.main.async {
                WindowSwitcherController.shared.triggerQuitSelectedApp(force: true)
            }
            return true
        }

        // Strict single-modifier Quick Window Actions (NEVER swallow ⌘⇧1..4 screenshot chords or ⌘⌥ / ⌘⌃ system shortcuts!)
        if isExactCmdOrCtrl {
            switch code {
            case kVK_ANSI_W:
                DispatchQueue.main.async {
                    WindowSwitcherController.shared.triggerCloseSelectedWindow()
                }
                return true

            case kVK_ANSI_M:
                DispatchQueue.main.async {
                    WindowSwitcherController.shared.triggerMinimizeSelectedWindow()
                }
                return true

            case kVK_ANSI_H:
                DispatchQueue.main.async {
                    WindowSwitcherController.shared.triggerHideSelectedApp()
                }
                return true

            case kVK_ANSI_Q where isExactCmd:
                DispatchQueue.main.async {
                    WindowSwitcherController.shared.triggerQuitSelectedApp(force: false)
                }
                return true

            case kVK_ANSI_Y:
                DispatchQueue.main.async {
                    let ctrl = WindowSwitcherController.shared
                    ctrl.clearScreenshotCaptureGrace()
                    ctrl.pinOpenFromInteraction()
                    AppSettings.shared.windowSwitcherShowZoomPreview.toggle()
                }
                return true

            case kVK_ANSI_1:
                DispatchQueue.main.async {
                    let ctrl = WindowSwitcherController.shared
                    ctrl.clearScreenshotCaptureGrace()
                    ctrl.pinOpenFromInteraction()
                    AppSettings.shared.windowSwitcherScope = AppSettings.shared.windowSwitcherScope.nextCycle()
                    WindowSwitcherService.shared.rebuildFilteredItemsPreservingSelection()
                }
                return true

            case kVK_ANSI_2:
                DispatchQueue.main.async {
                    let ctrl = WindowSwitcherController.shared
                    ctrl.clearScreenshotCaptureGrace()
                    ctrl.pinOpenFromInteraction()
                    AppSettings.shared.windowSwitcherShowMinimized.toggle()
                    WindowSwitcherService.shared.rebuildFilteredItemsPreservingSelection()
                }
                return true

            case kVK_ANSI_3:
                DispatchQueue.main.async {
                    let ctrl = WindowSwitcherController.shared
                    ctrl.clearScreenshotCaptureGrace()
                    ctrl.pinOpenFromInteraction()
                    AppSettings.shared.windowSwitcherShowHiddenApps.toggle()
                    WindowSwitcherService.shared.rebuildFilteredItemsPreservingSelection()
                }
                return true

            case kVK_ANSI_4:
                DispatchQueue.main.async {
                    let ctrl = WindowSwitcherController.shared
                    ctrl.clearScreenshotCaptureGrace()
                    ctrl.pinOpenFromInteraction()
                    ctrl.toggleSameAppFilterLive()
                }
                return true

            case kVK_Delete where isExactCmd:
                DispatchQueue.main.async {
                    let ctrl = WindowSwitcherController.shared
                    ctrl.clearScreenshotCaptureGrace()
                    ctrl.pinOpenFromInteraction()
                    WindowSwitcherService.shared.filterQuery = ""
                }
                return true

            case kVK_ANSI_F where isExactCmd:
                DispatchQueue.main.async {
                    let ctrl = WindowSwitcherController.shared
                    ctrl.clearScreenshotCaptureGrace()
                    ctrl.pinOpenFromInteraction()
                    WindowSwitcherService.shared.triggerSearchInputFocus()
                }
                return true

            default:
                break
            }
        }

        // Let normal printable characters, Backspace, Space, Vietnamese Telex IME, and ⌘A/⌘C/⌘V/⌘X
        // flow directly into the focused search NSTextField inside WindowSwitcherStagePanel!
        if !hasCmd && !hasCtrl && !hasOpt {
            DispatchQueue.main.async {
                let ctrl = WindowSwitcherController.shared
                ctrl.clearScreenshotCaptureGrace()
                ctrl.pinOpenFromInteraction()
                ctrl.lastAcceptedHoverMouseLocation = NSEvent.mouseLocation
                if let panel = ctrl.stagePanel, let tf = Self.findEditableTextField(in: panel.contentView) {
                    if panel.firstResponder !== tf && panel.firstResponder !== tf.currentEditor() {
                        NativeSearchInputField.focusTextField(tf, selectAll: false)
                    }
                }
            }
        }
        return false
    }

    // MARK: - Main-Thread Navigation & Focus Helpers

    func activateScreenshotCaptureGrace(until deadline: TimeInterval) {
        screenshotGraceUntil = deadline
        pinOpenFromInteraction()
        syncSharedTapConfiguration()
    }

    func clearScreenshotCaptureGrace() {
        guard screenshotGraceUntil != 0 else { return }
        screenshotGraceUntil = 0
        tapStateLock.lock()
        sharedTapConfig.screenshotGraceUntil = 0
        sharedTapConfig.didResignDuringScreenshotGrace = false
        tapStateLock.unlock()
    }

    func noteAppDidResignActiveDuringScreenshotGrace() {
        guard ProcessInfo.processInfo.systemUptime < screenshotGraceUntil else { return }
        tapStateLock.lock()
        sharedTapConfig.didResignDuringScreenshotGrace = true
        tapStateLock.unlock()
    }

    func pinOpenFromInteraction() {
        if !isPinnedOpen {
            isPinnedOpen = true
            syncSharedTapConfiguration()
        }
    }

    func stepFromKeyboard(delta: Int) {
        lastAcceptedHoverMouseLocation = NSEvent.mouseLocation
        WindowSwitcherService.shared.stepSelection(delta: delta)
    }

    func handleUpArrowSameApp() {
        guard isVisible else { return }
        clearScreenshotCaptureGrace()
        pinOpenFromInteraction()
        lastAcceptedHoverMouseLocation = NSEvent.mouseLocation
        let svc = WindowSwitcherService.shared
        if svc.sessionSameAppPID != nil {
            svc.clearSameAppFilter()
        } else if let cur = svc.selectedItem {
            svc.focusSameAppWindows(for: cur)
        } else if let prev = previousFrontApp {
            svc.focusSameAppPID(prev.processIdentifier, appName: prev.localizedName, appIcon: prev.icon)
        }
    }

    func handleDownArrowInSwitcher(isAutoRepeat: Bool) {
        guard isVisible else { return }
        clearScreenshotCaptureGrace()
        pinOpenFromInteraction()
        lastAcceptedHoverMouseLocation = NSEvent.mouseLocation
        let svc = WindowSwitcherService.shared
        if svc.sessionSameAppPID != nil {
            if !isAutoRepeat {
                svc.clearSameAppFilter()
            }
        } else {
            svc.stepSelection(delta: 1)
        }
    }

    func handleEscapeInSwitcher() {
        let svc = WindowSwitcherService.shared
        if !svc.filterQuery.isEmpty {
            lastAcceptedHoverMouseLocation = NSEvent.mouseLocation
            svc.filterQuery = ""
            svc.triggerSearchInputFocus()
        } else if svc.sessionSameAppPID != nil && !openedDirectlyInSameAppMode {
            lastAcceptedHoverMouseLocation = NSEvent.mouseLocation
            svc.clearSameAppFilter()
            svc.triggerSearchInputFocus()
        } else {
            dismissWithoutActivating(restorePreviousApp: true)
        }
    }

    // MARK: - Present, Commit & Dismiss

    func openPinnedFromMenuOrSearch(sameAppOnly: Bool = false) {
        presentSwitcher(
            sameAppOnly: sameAppOnly,
            moveBackward: false,
            holdModifierMask: [],
            pinnedOpen: true,
            selectNextOnOpen: false
        )
    }

    func handleCarbonHotKeyFallback(sameAppOnly: Bool) {
        if isVisible {
            stepFromKeyboard(delta: 1)
            return
        }
        let binding = sameAppOnly ? AppSettings.shared.sameAppSwitcherHotKey : AppSettings.shared.windowSwitcherHotKey
        let holdMask = Self.holdModifierMask(for: binding)
        presentSwitcher(
            sameAppOnly: sameAppOnly,
            moveBackward: false,
            holdModifierMask: holdMask,
            pinnedOpen: true,
            selectNextOnOpen: true
        )
    }

    func presentSwitcher(
        sameAppOnly: Bool,
        moveBackward: Bool,
        holdModifierMask: CGEventFlags,
        pinnedOpen: Bool,
        selectNextOnOpen: Bool = true
    ) {
        if LauncherPanelController.shared.isVisible {
            LauncherPanelController.shared.hide()
        }

        // Verify live Accessibility / EventTap health right before presenting
        refreshEventTapState()

        let ownPID = ProcessInfo.processInfo.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ownPID {
            self.previousFrontApp = front
        }

        let targetSamePID: pid_t? = sameAppOnly ? previousFrontApp?.processIdentifier : nil

        self.openedDirectlyInSameAppMode = sameAppOnly
        self.activeHoldModifierMask = holdModifierMask
        self.isPinnedOpen = pinnedOpen
        self.lastAcceptedHoverMouseLocation = NSEvent.mouseLocation
        self.isSuppressingResignDismiss = true
        self.screenshotGraceUntil = 0

        let liveFlags = Self.cgFlags(from: NSEvent.modifierFlags)
        tapStateLock.lock()
        sharedTapConfig.lastModifierFlagsRaw = liveFlags.rawValue
        sharedTapConfig.cmdTapStartUptime = 0
        sharedTapConfig.cmdTapInvalidated = true
        sharedTapConfig.optTapStartUptime = 0
        sharedTapConfig.optTapInvalidated = true
        tapStateLock.unlock()

        self.previewCardSwiftUIFrame = .zero
        self.stripCardSwiftUIFrame = .zero

        WindowSwitcherService.shared.reloadSessionWindows(
            sameAppPID: targetSamePID,
            frontmostPIDBeforePresentation: previousFrontApp?.processIdentifier,
            selectPreviousWindow: selectNextOnOpen,
            moveBackward: moveBackward
        )

        ensureStagePanelCreated()
        guard let panel = stagePanel else {
            self.isSuppressingResignDismiss = false
            syncSharedTapConfiguration()
            return
        }

        let mouseLoc = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        if let screen {
            panel.setFrame(screen.frame, display: true)
        }

        isVisible = true
        syncSharedTapConfiguration()
        installAuxiliaryMonitors()

        if #available(macOS 14.0, *) {
            NSApp.activate()
        }
        NSApp.activate(ignoringOtherApps: true)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            guard let self else { return }
            self.isSuppressingResignDismiss = false
        }
    }

    // MARK: - Deduplicated Quick Window / App Actions (⌘W, ⌘Q, ⌥⌘Q, ⌘M, ⌘H)

    private func claimQuickActionGate(preserveHoldModeIfCommandDown: Bool = true) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        guard (now - lastQuickActionUptime) >= 0.04 else { return false }
        lastQuickActionUptime = now
        clearScreenshotCaptureGrace()
        if !(preserveHoldModeIfCommandDown && NSEvent.modifierFlags.contains(.command)) {
            pinOpenFromInteraction()
        }
        return true
    }

    func triggerCloseSelectedWindow() {
        guard isVisible, claimQuickActionGate() else { return }
        WindowSwitcherService.shared.closeSelectedWindow()
    }

    func triggerCloseWindowItem(_ item: SwitchableWindowItem) {
        guard isVisible, claimQuickActionGate(preserveHoldModeIfCommandDown: false) else { return }
        WindowSwitcherService.shared.closeWindow(item)
    }

    func triggerQuitSelectedApp(force: Bool = false) {
        guard isVisible, claimQuickActionGate() else { return }
        WindowSwitcherService.shared.quitSelectedApp(force: force)
    }

    func triggerQuitAppForItem(_ item: SwitchableWindowItem, force: Bool = false) {
        guard isVisible, claimQuickActionGate(preserveHoldModeIfCommandDown: false) else { return }
        WindowSwitcherService.shared.quitApp(for: item, force: force)
    }

    func triggerMinimizeSelectedWindow() {
        guard isVisible, claimQuickActionGate() else { return }
        WindowSwitcherService.shared.toggleMinimizeSelectedWindow()
    }

    func triggerMinimizeWindowItem(_ item: SwitchableWindowItem) {
        guard isVisible, claimQuickActionGate(preserveHoldModeIfCommandDown: false) else { return }
        if let idx = WindowSwitcherService.shared.items.firstIndex(where: { $0.id == item.id }) {
            WindowSwitcherService.shared.selectedIndex = idx
        }
        WindowSwitcherService.shared.toggleMinimizeSelectedWindow()
    }

    func triggerHideSelectedApp() {
        guard isVisible, claimQuickActionGate() else { return }
        WindowSwitcherService.shared.toggleHideSelectedApp()
    }

    func triggerHideAppForItem(_ item: SwitchableWindowItem) {
        guard isVisible, claimQuickActionGate(preserveHoldModeIfCommandDown: false) else { return }
        if let idx = WindowSwitcherService.shared.items.firstIndex(where: { $0.id == item.id }) {
            WindowSwitcherService.shared.selectedIndex = idx
        }
        WindowSwitcherService.shared.toggleHideSelectedApp()
    }

    func handleLocalNSEventShortcut(_ event: NSEvent) -> Bool {
        guard isVisible else { return false }
        invalidateStandaloneCmdAndOptTap()
        let cgFlags = Self.cgFlags(from: event.modifierFlags)
        if Self.routeVisibleSwitcherKeyOffMain(
            code: Int(event.keyCode),
            cleanFlags: cgFlags,
            isAutoRepeat: event.isARepeat,
            controller: self
        ) {
            return true
        }

        // Layout-independent character fallback for non-QWERTY keyboards
        let ch = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if cgFlags == [.maskCommand, .maskAlternate] && ch == "q" {
            triggerQuitSelectedApp(force: true)
            return true
        }
        if cgFlags == .maskCommand || cgFlags == .maskControl {
            switch ch {
            case "w":
                triggerCloseSelectedWindow()
                return true
            case "q" where cgFlags == .maskCommand:
                triggerQuitSelectedApp(force: false)
                return true
            case "m":
                triggerMinimizeSelectedWindow()
                return true
            case "h":
                triggerHideSelectedApp()
                return true
            case "y":
                clearScreenshotCaptureGrace()
                pinOpenFromInteraction()
                AppSettings.shared.windowSwitcherShowZoomPreview.toggle()
                return true
            default:
                break
            }
        }
        return false
    }

    func selectAndActivateAtIndex(_ index: Int) {
        let svc = WindowSwitcherService.shared
        guard index >= 0 && index < svc.items.count else { return }
        svc.selectedIndex = index
        commitSelectionAndDismiss()
    }

    func hoverItemAtIndex(_ index: Int) {
        guard isVisible else { return }
        let cur = NSEvent.mouseLocation
        // Ignore synthetic SwiftUI .onHover caused by horizontal ScrollView scrolling under a stationary mouse!
        guard hypot(cur.x - lastAcceptedHoverMouseLocation.x, cur.y - lastAcceptedHoverMouseLocation.y) >= 6.0 else {
            return
        }
        lastAcceptedHoverMouseLocation = cur
        let svc = WindowSwitcherService.shared
        svc.isKeyboardNavigating = false
        if index >= 0 && index < svc.items.count && svc.selectedIndex != index {
            svc.selectedIndex = index
        }
    }

    func toggleSameAppFilterLive() {
        let svc = WindowSwitcherService.shared
        lastAcceptedHoverMouseLocation = NSEvent.mouseLocation
        if svc.sessionSameAppPID != nil {
            svc.clearSameAppFilter()
        } else if let cur = svc.selectedItem {
            svc.focusSameAppWindows(for: cur)
        } else if let prev = previousFrontApp {
            svc.focusSameAppPID(prev.processIdentifier, appName: prev.localizedName, appIcon: prev.icon)
        }
    }

    func commitSelectionAndDismiss() {
        guard isVisible else { return }
        let chosen = WindowSwitcherService.shared.selectedItem
        dismissWithoutActivating(restorePreviousApp: false)
        if let chosen {
            WindowSwitcherService.shared.activateWindow(chosen)
        }
    }

    func commitSnapSelectionAndDismiss(_ placement: WindowSnapPlacement) {
        guard isVisible else { return }
        let chosen = WindowSwitcherService.shared.selectedItem
        dismissWithoutActivating(restorePreviousApp: false)
        if let chosen {
            WindowSwitcherService.shared.snapAndActivateWindow(chosen, placement: placement)
        }
    }

    func dismissWithoutActivating(restorePreviousApp: Bool = true) {
        guard isVisible else {
            syncSharedTapConfiguration()
            return
        }
        isVisible = false
        isPinnedOpen = true
        activeHoldModifierMask = []
        screenshotGraceUntil = 0
        syncSharedTapConfiguration()
        removeAuxiliaryMonitors()
        stagePanel?.orderOut(nil)

        if restorePreviousApp,
           let prev = previousFrontApp,
           !prev.isTerminated {
            NSApp.yieldActivation(to: prev)
            prev.activate()
        }
    }

    private func ensureStagePanelCreated() {
        guard stagePanel == nil else { return }
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let p = WindowSwitcherStagePanel(
            contentRect: frame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.level = .popUpMenu
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.acceptsMouseMovedEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

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

    private func installAuxiliaryMonitors() {
        removeAuxiliaryMonitors()

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .leftMouseUp]) { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if now < self.screenshotGraceUntil {
                    if event.type == .leftMouseUp {
                        let shortened = min(self.screenshotGraceUntil, now + 0.35)
                        self.screenshotGraceUntil = shortened
                        self.syncSharedTapConfiguration()
                    }
                    return
                }
                if event.type == .leftMouseDown || event.type == .rightMouseDown {
                    self.dismissWithoutActivating(restorePreviousApp: true)
                }
            }
        }

        // Always install local keyboard monitor so shortcuts (⌘W, ⌘Q, ⌥⌘Q, ⌘M, ⌘H, ← →, Esc) work 100%
        // even if CGEventTap is temporarily inactive or Accessibility is not yet toggled after an app update!
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }
            if self.handleLocalNSEventShortcut(event) {
                return nil
            }
            return event
        }

        // Always install local flags monitor (deduplicated by hardware CGEventTimestamp) so standalone ⌘-tap
        // and release-to-activate work 100% reliably even during Secure Input or when EventTap is offline.
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self, self.isVisible else { return event }
            let cgFlags = Self.cgFlags(from: event.modifierFlags)
            let ts = event.cgEvent?.timestamp ?? 0
            self.processModifierFlagsChange(code: Int(event.keyCode), cleanMods: cgFlags, timestamp: ts)
            return event
        }
    }

    private func removeAuxiliaryMonitors() {
        if let m = globalClickMonitor { NSEvent.removeMonitor(m); globalClickMonitor = nil }
        if let m = localKeyMonitor { NSEvent.removeMonitor(m); localKeyMonitor = nil }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m); localFlagsMonitor = nil }
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

    // MARK: - Modifier Matching Helpers (Nonisolated for 0ms EventTap Use)

    nonisolated private static func cleanCGModifiers(_ flags: CGEventFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.maskCommand) { result.insert(.maskCommand) }
        if flags.contains(.maskAlternate) { result.insert(.maskAlternate) }
        if flags.contains(.maskControl) { result.insert(.maskControl) }
        if flags.contains(.maskShift) { result.insert(.maskShift) }
        return result
    }

    nonisolated private static func cgFlags(from nsFlags: NSEvent.ModifierFlags) -> CGEventFlags {
        let clean = nsFlags.intersection(.deviceIndependentFlagsMask)
        var out: CGEventFlags = []
        if clean.contains(.command) { out.insert(.maskCommand) }
        if clean.contains(.option) { out.insert(.maskAlternate) }
        if clean.contains(.control) { out.insert(.maskControl) }
        if clean.contains(.shift) { out.insert(.maskShift) }
        return out
    }

    nonisolated private static func holdModifierMask(for binding: HotKeyBinding) -> CGEventFlags {
        var mask: CGEventFlags = []
        if binding.hasCommand { mask.insert(.maskCommand) }
        if binding.hasOption { mask.insert(.maskAlternate) }
        if binding.hasControl { mask.insert(.maskControl) }
        if mask.isEmpty && binding.hasShift { mask.insert(.maskShift) }
        return mask
    }

    nonisolated private static func matchesSwitcherTrigger(binding: HotKeyBinding, keyCode: Int, flags: CGEventFlags) -> Bool? {
        guard Int(binding.keyCode) == keyCode else { return nil }
        var expected: CGEventFlags = []
        if binding.hasCommand { expected.insert(.maskCommand) }
        if binding.hasOption { expected.insert(.maskAlternate) }
        if binding.hasControl { expected.insert(.maskControl) }
        if binding.hasShift { expected.insert(.maskShift) }

        if flags == expected {
            return false
        }
        if !binding.hasShift {
            var withShift = expected
            withShift.insert(.maskShift)
            if flags == withShift {
                return true
            }
        }
        return nil
    }

    nonisolated private static func carbonModifiers(from flags: CGEventFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.maskControl) { mods |= UInt32(controlKey) }
        if flags.contains(.maskAlternate) { mods |= UInt32(optionKey) }
        if flags.contains(.maskShift) { mods |= UInt32(shiftKey) }
        if flags.contains(.maskCommand) { mods |= UInt32(cmdKey) }
        return mods
    }

    nonisolated private static func isScreenshotShortcutKeyCode(_ code: Int) -> Bool {
        switch code {
        case kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6:
            return true
        default:
            return false
        }
    }

    nonisolated private static func isPureModifierKeyCode(_ code: Int) -> Bool {
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
