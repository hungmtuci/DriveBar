import Foundation
import AppKit
import Carbon

@MainActor
final class HotKeyService: ObservableObject {
    static let shared = HotKeyService()

    enum RecordingTarget: Equatable {
        case search
        case universalAction
        case windowSwitcher
        case sameAppWindowSwitcher
    }

    @Published private(set) var recordingTarget: RecordingTarget?
    @Published private(set) var liveModifiersPreview: String = ""
    @Published private(set) var isSearchHotKeyActive: Bool = false
    @Published private(set) var isUniversalHotKeyActive: Bool = false
    @Published private(set) var isWindowSwitcherCarbonFallbackActive: Bool = false
    @Published private(set) var registrationWarning: String?

    var onToggleSearch: (() -> Void)?
    var onTriggerUniversalAction: (() -> Void)?

    private var searchHotKeyRef: EventHotKeyRef?
    private var universalHotKeyRef: EventHotKeyRef?
    private var windowSwitcherHotKeyRef: EventHotKeyRef?
    private var sameAppHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var recordingKeyMonitor: Any?
    private var recordingFlagsMonitor: Any?
    private var recordingCancelObservers: [NSObjectProtocol] = []

    private init() {}

    func installAndRegisterAll() {
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                if hotKeyID.id == 1 {
                    Task { @MainActor in
                        HotKeyService.shared.onToggleSearch?()
                    }
                } else if hotKeyID.id == 2 {
                    Task { @MainActor in
                        HotKeyService.shared.onTriggerUniversalAction?()
                    }
                } else if hotKeyID.id == 3 {
                    Task { @MainActor in
                        WindowSwitcherController.shared.handleCarbonHotKeyFallback(sameAppOnly: false)
                    }
                } else if hotKeyID.id == 4 {
                    Task { @MainActor in
                        WindowSwitcherController.shared.handleCarbonHotKeyFallback(sameAppOnly: true)
                    }
                }
                return noErr
            }

            InstallEventHandler(
                GetApplicationEventTarget(),
                callback,
                1,
                &eventType,
                nil,
                &eventHandlerRef
            )
        }

        registerAll()
    }

    func registerAll() {
        unregisterHotKeysOnly()
        registrationWarning = nil

        let settings = AppSettings.shared
        let searchID = EventHotKeyID(signature: OSType(0x44525642), id: 1) // 'DRVB'
        let s1 = RegisterEventHotKey(
            settings.searchHotKey.keyCode,
            settings.searchHotKey.carbonModifiers,
            searchID,
            GetApplicationEventTarget(),
            0,
            &searchHotKeyRef
        )
        isSearchHotKeyActive = (s1 == noErr)

        let uaID = EventHotKeyID(signature: OSType(0x44525642), id: 2)
        let s2 = RegisterEventHotKey(
            settings.universalActionHotKey.keyCode,
            settings.universalActionHotKey.carbonModifiers,
            uaID,
            GetApplicationEventTarget(),
            0,
            &universalHotKeyRef
        )
        isUniversalHotKeyActive = (s2 == noErr)

        // Carbon fallback when EventTap is not active yet and user selected a non-⌘Tab shortcut (e.g. ⌥Tab)
        isWindowSwitcherCarbonFallbackActive = false
        if !WindowSwitcherController.shared.isEventTapActive {
            if settings.enableWindowSwitcher && settings.windowSwitcherHotKey != .commandTab {
                let winID = EventHotKeyID(signature: OSType(0x44525642), id: 3)
                let s3 = RegisterEventHotKey(
                    settings.windowSwitcherHotKey.keyCode,
                    settings.windowSwitcherHotKey.carbonModifiers,
                    winID,
                    GetApplicationEventTarget(),
                    0,
                    &windowSwitcherHotKeyRef
                )
                isWindowSwitcherCarbonFallbackActive = (s3 == noErr)
            }
            if settings.enableSameAppSwitcher && settings.sameAppSwitcherHotKey != .commandTab {
                let sameID = EventHotKeyID(signature: OSType(0x44525642), id: 4)
                _ = RegisterEventHotKey(
                    settings.sameAppSwitcherHotKey.keyCode,
                    settings.sameAppSwitcherHotKey.carbonModifiers,
                    sameID,
                    GetApplicationEventTarget(),
                    0,
                    &sameAppHotKeyRef
                )
            }
        }

        var conflicts: [String] = []
        if !isSearchHotKeyActive {
            let disp = settings.searchHotKey.readableDisplay
            if settings.searchHotKey == .commandSpace {
                conflicts.append("Phím tắt Tìm kiếm (\(disp)) đang bị Spotlight hoặc ứng dụng khác giữ — hãy tắt 'Show Spotlight search' trong Cài đặt bàn phím macOS hoặc chọn phím khác.")
            } else {
                conflicts.append("Phím tắt Tìm kiếm (\(disp)) đang bị hệ thống hoặc ứng dụng khác chiếm giữ.")
            }
        }
        if !isUniversalHotKeyActive {
            let uaDisp = settings.universalActionHotKey.readableDisplay
            conflicts.append("Phím tắt Universal Actions (\(uaDisp)) đang bị ứng dụng khác (như Alfred) chiếm giữ — hãy đóng ứng dụng trùng hoặc chọn phím tắt khác.")
        }
        if !conflicts.isEmpty {
            registrationWarning = conflicts.joined(separator: " ")
        }
    }

    private func unregisterHotKeysOnly() {
        if let ref = searchHotKeyRef {
            UnregisterEventHotKey(ref)
            searchHotKeyRef = nil
        }
        if let ref = universalHotKeyRef {
            UnregisterEventHotKey(ref)
            universalHotKeyRef = nil
        }
        if let ref = windowSwitcherHotKeyRef {
            UnregisterEventHotKey(ref)
            windowSwitcherHotKeyRef = nil
        }
        if let ref = sameAppHotKeyRef {
            UnregisterEventHotKey(ref)
            sameAppHotKeyRef = nil
        }
    }

    // MARK: - Open Settings & Immediately Record

    func openSettingsAndRecord(_ target: RecordingTarget) {
        switch target {
        case .search, .universalAction:
            SettingsUIState.shared.selectedTab = .general
        case .windowSwitcher, .sameAppWindowSwitcher:
            SettingsUIState.shared.selectedTab = .windowSwitcher
        }
        AppDelegate.shared?.openSettingsWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            self.startRecording(for: target)
        }
    }

    func openMacOSKeyboardShortcutsSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?Shortcuts",
            "x-apple.systempreferences:com.apple.Keyboard-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts"
        ]
        for str in urls {
            if let u = URL(string: str), NSWorkspace.shared.open(u) {
                return
            }
        }
    }

    // MARK: - Live Custom Shortcut Recorder

    func startRecording(for target: RecordingTarget) {
        stopRecording()
        recordingTarget = target
        liveModifiersPreview = ""
        unregisterHotKeysOnly()

        // Ensure window is key & no SwiftUI button swallows Space / Return
        NSApp.activate(ignoringOtherApps: true)
        NSApp.keyWindow?.makeFirstResponder(nil)

        let nc = NotificationCenter.default
        let obs1 = nc.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingTarget != nil else { return }
                self.stopRecording()
                self.registerAll()
            }
        }
        let obs2 = nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.recordingTarget != nil else { return }
                self.stopRecording()
                self.registerAll()
            }
        }
        recordingCancelObservers = [obs1, obs2]

        recordingFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let mods = Self.carbonModifiers(from: event.modifierFlags)
            self.liveModifiersPreview = mods != 0 ? "\(HotKeyBinding.modifiersDisplay(for: mods)) + ..." : ""
            return event
        }

        recordingKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let code = Int(event.keyCode)

            // Ignore pure modifier virtual keyCodes if any slip through
            if Self.isPureModifierKeyCode(code) {
                return nil
            }

            let carbonMods = Self.carbonModifiers(from: event.modifierFlags)

            // Escape without modifiers cancels recording and restores active shortcuts
            if code == kVK_Escape && carbonMods == 0 {
                self.stopRecording()
                self.registerAll()
                return nil
            }

            let isFunctionKey = (code >= kVK_F1 && code <= kVK_F19)
            guard carbonMods != 0 || isFunctionKey else {
                NSSound.beep()
                AppSettings.shared.statusBannerMessage = "Hãy giữ ít nhất 1 phím bổ trợ (⌘, ⌥, ⌃, ⇧) kèm phím chữ/số/Space (nhấn Esc để hủy)."
                return nil
            }

            let newBinding = HotKeyBinding(keyCode: UInt32(code), carbonModifiers: carbonMods)
            self.applyRecordedBinding(newBinding, for: target)
            return nil
        }
    }

    func applyRecordedBinding(_ newBinding: HotKeyBinding, for target: RecordingTarget) {
        stopRecording()
        switch target {
        case .search:
            if AppSettings.shared.universalActionHotKey == newBinding {
                NSSound.beep()
                registerAll()
                AppSettings.shared.statusBannerMessage = "Phím tắt \(newBinding.readableDisplay) đang dùng cho Universal Actions. Hãy chọn tổ hợp khác."
                return
            }
            AppSettings.shared.searchHotKey = newBinding
            let ok = isSearchHotKeyActive
            AppSettings.shared.statusBannerMessage = ok
                ? "Đã thiết lập phím tắt Mở Tìm kiếm: \(newBinding.readableDisplay)"
                : "Đã lưu \(newBinding.readableDisplay), nhưng phím này đang bị ứng dụng khác/Spotlight giữ."
            if ok {
                FloatingToastController.shared.showSuccess(
                    title: "Đã đổi phím tắt Tìm kiếm: \(newBinding.readableDisplay)",
                    subtitle: "Bấm \(newBinding.readableDisplay) ở bất kỳ đâu để gọi nhanh DriveBar"
                )
            }

        case .universalAction:
            if AppSettings.shared.searchHotKey == newBinding {
                NSSound.beep()
                registerAll()
                AppSettings.shared.statusBannerMessage = "Phím tắt \(newBinding.readableDisplay) đang dùng cho Thanh Tìm kiếm. Hãy chọn tổ hợp khác."
                return
            }
            AppSettings.shared.universalActionHotKey = newBinding
            let ok = isUniversalHotKeyActive
            AppSettings.shared.statusBannerMessage = ok
                ? "Đã thiết lập phím tắt Universal Actions: \(newBinding.readableDisplay)"
                : "Đã lưu \(newBinding.readableDisplay), nhưng phím này đang bị ứng dụng khác giữ."
            if ok {
                FloatingToastController.shared.showSuccess(
                    title: "Đã đổi phím tắt Universal Actions: \(newBinding.readableDisplay)",
                    subtitle: "Chọn file hoặc văn bản rồi bấm \(newBinding.readableDisplay)"
                )
            }

        case .windowSwitcher:
            AppSettings.shared.windowSwitcherHotKey = newBinding
            AppSettings.shared.statusBannerMessage = "Đã thiết lập phím tắt Windows Preview: \(newBinding.readableDisplay)"
            FloatingToastController.shared.showSuccess(
                title: "Đã đổi phím tắt Windows Preview: \(newBinding.readableDisplay)",
                subtitle: "Bấm \(newBinding.readableDisplay) để mở danh sách & phóng to cửa sổ đang chạy"
            )

        case .sameAppWindowSwitcher:
            AppSettings.shared.sameAppSwitcherHotKey = newBinding
            AppSettings.shared.statusBannerMessage = "Đã thiết lập phím tắt chuyển cửa sổ cùng ứng dụng: \(newBinding.readableDisplay)"
            FloatingToastController.shared.showSuccess(
                title: "Đã đổi phím tắt cửa sổ cùng ứng dụng: \(newBinding.readableDisplay)",
                subtitle: "Bấm \(newBinding.readableDisplay) để chuyển nhanh giữa các cửa sổ của ứng dụng hiện tại"
            )
        }
    }

    func stopRecording() {
        recordingTarget = nil
        liveModifiersPreview = ""
        if let monitor = recordingKeyMonitor {
            NSEvent.removeMonitor(monitor)
            recordingKeyMonitor = nil
        }
        if let fMonitor = recordingFlagsMonitor {
            NSEvent.removeMonitor(fMonitor)
            recordingFlagsMonitor = nil
        }
        for obs in recordingCancelObservers {
            NotificationCenter.default.removeObserver(obs)
        }
        recordingCancelObservers.removeAll()
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let clean = flags.intersection(.deviceIndependentFlagsMask)
        var carbonMods: UInt32 = 0
        if clean.contains(.control) { carbonMods |= UInt32(controlKey) }
        if clean.contains(.option) { carbonMods |= UInt32(optionKey) }
        if clean.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        if clean.contains(.command) { carbonMods |= UInt32(cmdKey) }
        return carbonMods
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
