import Foundation
import AppKit
import Carbon

@MainActor
final class HotKeyService: ObservableObject {
    static let shared = HotKeyService()

    enum RecordingTarget: Equatable {
        case search
        case universalAction
    }

    @Published private(set) var recordingTarget: RecordingTarget?
    @Published private(set) var registrationWarning: String?

    var onToggleSearch: (() -> Void)?
    var onTriggerUniversalAction: (() -> Void)?

    private var searchHotKeyRef: EventHotKeyRef?
    private var universalHotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var recordingMonitor: Any?

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

        let uaID = EventHotKeyID(signature: OSType(0x44525642), id: 2)
        let s2 = RegisterEventHotKey(
            settings.universalActionHotKey.keyCode,
            settings.universalActionHotKey.carbonModifiers,
            uaID,
            GetApplicationEventTarget(),
            0,
            &universalHotKeyRef
        )

        if s1 != noErr || s2 != noErr {
            registrationWarning = "Một phím tắt đang bị ứng dụng khác chiếm giữ. Bạn có thể bấm Thu phím mới ngay bên dưới."
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
    }

    // MARK: - Live Custom Shortcut Recorder

    func startRecording(for target: RecordingTarget) {
        stopRecording()
        recordingTarget = target
        unregisterHotKeysOnly()

        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                self.stopRecording()
                self.registerAll()
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var carbonMods: UInt32 = 0
            if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
            if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
            if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
            if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }

            let isFunctionKey = (Int(event.keyCode) >= kVK_F1 && Int(event.keyCode) <= kVK_F12)
            guard carbonMods != 0 || isFunctionKey else {
                NSSound.beep()
                return nil
            }

            let newBinding = HotKeyBinding(keyCode: UInt32(event.keyCode), carbonModifiers: carbonMods)
            let recordedFor = self.recordingTarget
            self.stopRecording()

            if recordedFor == .search {
                AppSettings.shared.searchHotKey = newBinding
                AppSettings.shared.statusBannerMessage = "Đã đặt phím tắt mở Tìm kiếm: \(newBinding.readableDisplay)"
            } else if recordedFor == .universalAction {
                AppSettings.shared.universalActionHotKey = newBinding
                AppSettings.shared.statusBannerMessage = "Đã đặt phím tắt Universal Actions: \(newBinding.readableDisplay)"
            }
            return nil
        }
    }

    func stopRecording() {
        recordingTarget = nil
        if let monitor = recordingMonitor {
            NSEvent.removeMonitor(monitor)
            recordingMonitor = nil
        }
    }
}
