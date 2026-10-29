import SwiftUI
import AppKit
import ApplicationServices
import Carbon

@MainActor
final class SettingsUIState: ObservableObject {
    static let shared = SettingsUIState()

    enum Tab: String, CaseIterable {
        case general = "Phím tắt & Google Drive"
        case windowSwitcher = "Windows Preview (⌘Tab)"
        case aiMarkdown = "Convert sang Markdown (AI)"
        case actions = "Universal Actions"
    }

    @Published var selectedTab: Tab = .general
    @Published var isDropTargeted: Bool = false
    @Published var axTrusted: Bool = AXIsProcessTrusted()
    @Published var screenCaptureTrusted: Bool = CGPreflightScreenCaptureAccess()
    @Published var actionFilter: String = ""

    // Manual Custom Shortcut Builder State (avoids @State macro in CommandLineTools)
    @Published var manualBuilderTarget: HotKeyService.RecordingTarget?
    @Published var manualCmd: Bool = true
    @Published var manualOpt: Bool = false
    @Published var manualCtrl: Bool = false
    @Published var manualShift: Bool = false
    @Published var manualKeyCode: UInt32 = UInt32(kVK_Space)

    private init() {}

    func toggleManualBuilder(for target: HotKeyService.RecordingTarget, current: HotKeyBinding) {
        if manualBuilderTarget == target {
            manualBuilderTarget = nil
            return
        }
        HotKeyService.shared.stopRecording()
        HotKeyService.shared.registerAll()
        manualCmd = current.hasCommand
        manualOpt = current.hasOption
        manualCtrl = current.hasControl
        manualShift = current.hasShift
        manualKeyCode = current.keyCode
        manualBuilderTarget = target
    }

    var constructedManualBinding: HotKeyBinding? {
        var mods: UInt32 = 0
        if manualCtrl { mods |= UInt32(controlKey) }
        if manualOpt { mods |= UInt32(optionKey) }
        if manualShift { mods |= UInt32(shiftKey) }
        if manualCmd { mods |= UInt32(cmdKey) }
        let isFKey = (Int(manualKeyCode) >= kVK_F1 && Int(manualKeyCode) <= kVK_F19)
        guard mods != 0 || isFKey else { return nil }
        return HotKeyBinding(keyCode: manualKeyCode, carbonModifiers: mods)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var driveService = GoogleDriveIndexService.shared
    @ObservedObject private var hotKeyService = HotKeyService.shared
    @ObservedObject private var updater = UpdateCheckerService.shared
    @ObservedObject private var uiState = SettingsUIState.shared

    var body: some View {
        VStack(spacing: 0) {
            // Top Header Banner with Quick Dock Toggle & 1-Click Auto-Update Button
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 44, height: 44)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("DriveBar")
                                .font(.system(size: 16, weight: .semibold))
                            Text("v\(updater.currentVersion)")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .foregroundStyle(.secondary)
                        }
                        Text("Google Drive • Windows Preview (⌘Tab) • Convert Markdown cho AI")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Quick Shortcut Recorder Badges in Header
                    Button {
                        uiState.selectedTab = .general
                        hotKeyService.startRecording(for: .search)
                    } label: {
                        Label(
                            hotKeyService.recordingTarget == .search
                                ? (hotKeyService.liveModifiersPreview.isEmpty ? "Nhấn phím..." : hotKeyService.liveModifiersPreview)
                                : "Tìm: \(settings.searchHotKey.readableDisplay)",
                            systemImage: "command"
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(hotKeyService.recordingTarget == .search ? .orange : nil)
                    .controlSize(.small)
                    .help("Bấm để tự thiết lập phím tắt gọi nhanh DriveBar (Mặc định: ⌘Space)")

                    Button {
                        uiState.selectedTab = .general
                        hotKeyService.startRecording(for: .universalAction)
                    } label: {
                        Label(
                            hotKeyService.recordingTarget == .universalAction
                                ? (hotKeyService.liveModifiersPreview.isEmpty ? "Nhấn phím..." : hotKeyService.liveModifiersPreview)
                                : "Action: \(settings.universalActionHotKey.readableDisplay)",
                            systemImage: "bolt.horizontal"
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(hotKeyService.recordingTarget == .universalAction ? .orange : nil)
                    .controlSize(.small)
                    .help("Bấm để tự thiết lập phím tắt mở Universal Actions trên Finder (Mặc định: ⌘/)")

                    Button {
                        uiState.selectedTab = .windowSwitcher
                        hotKeyService.startRecording(for: .windowSwitcher)
                    } label: {
                        Label(
                            hotKeyService.recordingTarget == .windowSwitcher
                                ? (hotKeyService.liveModifiersPreview.isEmpty ? "Nhấn phím..." : hotKeyService.liveModifiersPreview)
                                : "Cửa sổ: \(settings.windowSwitcherHotKey.readableDisplay)",
                            systemImage: "macwindow.on.rectangle"
                        )
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(hotKeyService.recordingTarget == .windowSwitcher ? .orange : nil)
                    .controlSize(.small)
                    .help("Bấm để tự thiết lập phím tắt mở Windows Preview (Mặc định: ⌘⇥)")

                    // Quick Toggle Show/Hide on Dock Button
                    Button {
                        settings.showDockIcon.toggle()
                        settings.statusBannerMessage = settings.showDockIcon
                            ? "Đã hiện biểu tượng DriveBar trên thanh Dock."
                            : "Đã ẩn DriveBar khỏi thanh Dock (chỉ hiện gọn trên Menu Bar)."
                    } label: {
                        Label(
                            settings.showDockIcon ? "Hiện Dock" : "Ẩn Dock",
                            systemImage: settings.showDockIcon ? "dock.arrow.up.rectangle" : "menubar.rectangle"
                        )
                        .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    // Quick 1-Click Auto-Update Button
                    headerUpdateButton
                }

                Picker("", selection: $uiState.selectedTab) {
                    ForEach(SettingsUIState.Tab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Color.primary.opacity(0.03))

            Divider()

            if let banner = settings.statusBannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.secondary)
                    Text(banner)
                        .font(.system(size: 12, weight: .regular))
                    Spacer()
                    Button {
                        settings.statusBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.04))
                Divider()
            }

            // Tab Body
            Group {
                switch uiState.selectedTab {
                case .general:
                    GeneralSettingsTab(
                        settings: settings,
                        driveService: driveService,
                        hotKeyService: hotKeyService,
                        updater: updater,
                        syncService: SyncAndLatchingService.shared,
                        uiState: uiState,
                        axTrusted: $uiState.axTrusted
                    )
                case .windowSwitcher:
                    WindowSwitcherSettingsTab(
                        settings: settings,
                        hotKeyService: hotKeyService,
                        switcherController: WindowSwitcherController.shared,
                        switcherService: WindowSwitcherService.shared,
                        uiState: uiState
                    )
                case .aiMarkdown:
                    AIMarkdownSettingsTab(settings: settings, isDropTargeted: $uiState.isDropTargeted)
                case .actions:
                    UniversalActionsChecklistTab(settings: settings, uiState: uiState)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 840, height: 640)
        .onAppear {
            uiState.axTrusted = AXIsProcessTrusted()
            uiState.screenCaptureTrusted = CGPreflightScreenCaptureAccess()
            WindowSwitcherService.shared.refreshPermissionStates()
            settings.refreshLaunchAtLoginStatus()
        }
    }

    @ViewBuilder
    private var headerUpdateButton: some View {
        switch updater.state {
        case .available(let ver, _, _, _):
            Button {
                updater.installAvailableUpdate()
            } label: {
                Label("Tự động cập nhật v\(ver)", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)

        case .checking:
            Button {} label: {
                Label("Đang kiểm tra...", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11.5))
            }
            .controlSize(.small)
            .disabled(true)

        case .downloading(let ver):
            Button {} label: {
                Label("Đang tải v\(ver)...", systemImage: "arrow.down.circle")
                    .font(.system(size: 11.5))
            }
            .controlSize(.small)
            .disabled(true)

        case .installing(let ver):
            Button {} label: {
                Label("Đang cài v\(ver)...", systemImage: "gearshape.2")
                    .font(.system(size: 11.5))
            }
            .controlSize(.small)
            .disabled(true)

        default:
            Button {
                updater.checkForUpdatesManually()
            } label: {
                Label("Kiểm tra cập nhật", systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11.5, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

// MARK: - Tab 1: General, Dock Visibility, Auto-Update & Google Drive

private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var driveService: GoogleDriveIndexService
    @ObservedObject var hotKeyService: HotKeyService
    @ObservedObject var updater: UpdateCheckerService
    @ObservedObject var syncService: SyncAndLatchingService
    @ObservedObject var uiState: SettingsUIState
    @Binding var axTrusted: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Global Custom Hotkeys Section (Default: Command + Space)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        // A. Search Launcher Hotkey Row
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text("Phím tắt Mở thanh Tìm kiếm Google Drive")
                                            .font(.system(size: 13, weight: .semibold))
                                        shortcutStatusPill(isActive: hotKeyService.isSearchHotKeyActive)
                                    }
                                    Text("Mặc định: Command + Space (⌘Space) • Bấm nút bên phải rồi nhấn tổ hợp phím bất kỳ bạn muốn")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()

                                Button {
                                    uiState.manualBuilderTarget = nil
                                    if hotKeyService.recordingTarget == .search {
                                        hotKeyService.stopRecording()
                                        hotKeyService.registerAll()
                                    } else {
                                        hotKeyService.startRecording(for: .search)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: hotKeyService.recordingTarget == .search ? "record.circle.fill" : "keyboard")
                                        Text(recorderButtonTitle(for: .search, current: settings.searchHotKey))
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    }
                                    .frame(minWidth: 155)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(hotKeyService.recordingTarget == .search ? .orange : .accentColor)

                                Button("Mặc định (⌘Space)") {
                                    hotKeyService.applyRecordedBinding(.defaultSearch, for: .search)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(settings.searchHotKey == .defaultSearch && hotKeyService.recordingTarget == nil)
                            }

                            // Quick 1-Click Presets + Manual Builder Toggle for Search
                            HStack(spacing: 6) {
                                Text("Chọn nhanh:")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                presetChip(title: "⌘Space (Mặc định)", binding: .commandSpace, current: settings.searchHotKey, target: .search)
                                presetChip(title: "⌥Space", binding: .optionSpace, current: settings.searchHotKey, target: .search)
                                presetChip(title: "⌃Space", binding: .controlSpace, current: settings.searchHotKey, target: .search)
                                presetChip(title: "⌘⇧Space", binding: .commandShiftSpace, current: settings.searchHotKey, target: .search)

                                Spacer()

                                Button {
                                    uiState.toggleManualBuilder(for: .search, current: settings.searchHotKey)
                                } label: {
                                    Label(
                                        uiState.manualBuilderTarget == .search ? "Ẩn ghép phím" : "Tự ghép phím thủ công",
                                        systemImage: uiState.manualBuilderTarget == .search ? "chevron.up" : "slider.horizontal.3"
                                    )
                                    .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }

                            if uiState.manualBuilderTarget == .search {
                                manualShortcutBuilderRow(for: .search)
                            }
                        }

                        Divider()

                        // B. Universal Actions Hotkey Row (Finder & Global)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text("Phím tắt Mở Universal Actions khi thao tác trên Finder")
                                            .font(.system(size: 13, weight: .semibold))
                                        shortcutStatusPill(isActive: hotKeyService.isUniversalHotKeyActive)
                                    }
                                    Text("Mặc định: Command + / (⌘/) • Chọn file/thư mục trong Finder (hoặc URL / văn bản bôi đen) rồi nhấn phím tắt")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()

                                Button {
                                    uiState.manualBuilderTarget = nil
                                    if hotKeyService.recordingTarget == .universalAction {
                                        hotKeyService.stopRecording()
                                        hotKeyService.registerAll()
                                    } else {
                                        hotKeyService.startRecording(for: .universalAction)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: hotKeyService.recordingTarget == .universalAction ? "record.circle.fill" : "keyboard")
                                        Text(recorderButtonTitle(for: .universalAction, current: settings.universalActionHotKey))
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    }
                                    .frame(minWidth: 155)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(hotKeyService.recordingTarget == .universalAction ? .orange : .accentColor)

                                Button("Mặc định (⌘/)") {
                                    hotKeyService.applyRecordedBinding(.defaultUniversalAction, for: .universalAction)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(settings.universalActionHotKey == .defaultUniversalAction && hotKeyService.recordingTarget == nil)
                            }

                            HStack(spacing: 6) {
                                Text("Chọn nhanh:")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                presetChip(title: "⌘/ (Mặc định)", binding: .commandSlash, current: settings.universalActionHotKey, target: .universalAction)
                                presetChip(title: "⌘\\", binding: .commandBackslash, current: settings.universalActionHotKey, target: .universalAction)
                                presetChip(title: "⌥⌘/", binding: .optionCommandSlash, current: settings.universalActionHotKey, target: .universalAction)
                                presetChip(title: "⌘⇧A", binding: .commandShiftA, current: settings.universalActionHotKey, target: .universalAction)
                                presetChip(title: "⌘⇧M", binding: .commandShiftM, current: settings.universalActionHotKey, target: .universalAction)

                                Spacer()

                                Button {
                                    uiState.toggleManualBuilder(for: .universalAction, current: settings.universalActionHotKey)
                                } label: {
                                    Label(
                                        uiState.manualBuilderTarget == .universalAction ? "Ẩn ghép phím" : "Tự ghép phím thủ công",
                                        systemImage: uiState.manualBuilderTarget == .universalAction ? "chevron.up" : "slider.horizontal.3"
                                    )
                                    .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }

                            if uiState.manualBuilderTarget == .universalAction {
                                manualShortcutBuilderRow(for: .universalAction)
                            }
                        }

                        if let warn = hotKeyService.registrationWarning {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(warn)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.orange)
                                Spacer()
                                Button("Mở Cài đặt Bàn phím macOS") {
                                    hotKeyService.openMacOSKeyboardShortcutsSettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                            }
                            .padding(8)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(8)
                } label: {
                    HStack {
                        Label("Thiết lập Phím tắt Toàn cục (Mặc định: Tìm kiếm ⌘Space • Finder Action ⌘/)", systemImage: "command.square.fill")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Khôi phục mặc định") {
                            settings.resetShortcutsToDefault()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                    }
                }

                // 2. Dock Visibility Cards ("Nút ẩn hiện trên Dock")
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            dockOptionCard(
                                isSelected: settings.showDockIcon,
                                title: "Hiện trên thanh Dock & Menu Bar",
                                subtitle: "Hiển thị icon DriveBar trên thanh Dock, Cmd+Tab và cho phép kéo thả file trực tiếp vào icon trên Dock để Convert sang Markdown.",
                                symbol: "dock.arrow.up.rectangle"
                            ) {
                                settings.showDockIcon = true
                            }

                            dockOptionCard(
                                isSelected: !settings.showDockIcon,
                                title: "Ẩn khỏi thanh Dock (Chỉ Menu Bar)",
                                subtitle: "Ẩn hoàn toàn khỏi thanh Dock và Cmd+Tab để tối ưu không gian màn hình, gọi nhanh mọi lúc bằng phím tắt như Alfred.",
                                symbol: "menubar.rectangle"
                            ) {
                                settings.showDockIcon = false
                            }
                        }

                        Divider()

                        HStack(spacing: 24) {
                            Toggle("Tự khởi động cùng macOS (Launch at Login)", isOn: Binding(
                                get: { settings.launchAtLogin },
                                set: { settings.toggleLaunchAtLogin($0) }
                            ))
                            .toggleStyle(.switch)

                            Toggle("Hiển thị thêm Ứng dụng macOS khi gõ tìm kiếm", isOn: $settings.includeMacAppsInSearch)
                                .toggleStyle(.switch)
                        }
                        .font(.system(size: 12.5, weight: .medium))
                    }
                    .padding(8)
                } label: {
                    Label("Hiển thị trên Thanh Dock & Khởi động", systemImage: "dock.rectangle")
                        .font(.system(size: 13, weight: .semibold))
                }

                // 3. Google Drive Index Section (Real-time FSEvents + Multi-Account)
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: driveService.accountRoot != nil ? "checkmark.icloud.fill" : "exclamationmark.icloud.fill")
                                .foregroundStyle(driveService.accountRoot != nil ? .green : .orange)
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(driveService.accountRoot ?? "Chưa tìm thấy thư mục Google Drive")
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .lineLimit(1)
                                    if driveService.isRealtimeWatcherActive {
                                        Text("Real-time FSEvents")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.green.opacity(0.14), in: Capsule())
                                    }
                                }
                                HStack(spacing: 14) {
                                    Text("My Drive: **\(driveService.folderCount.formatted())** thư mục")
                                    Text("Shared Drives & Shortcuts: **\(driveService.sharedCount.formatted())** mục")
                                    if let updated = driveService.lastCacheUpdate {
                                        Text("Cập nhật: \(updated.formatted(date: .abbreviated, time: .shortened))")
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.system(size: 11.5))
                            }
                            Spacer()
                        }

                        HStack(spacing: 16) {
                            Toggle("Tự động cập nhật tức thời bằng FSEvents khi tạo/đổi tên thư mục", isOn: $settings.enableRealtimeFSEvents)
                                .font(.system(size: 12))

                            Spacer()

                            if !driveService.availableAccounts.isEmpty {
                                Picker("Tài khoản:", selection: $settings.selectedDriveAccountFilter) {
                                    Text("Tất cả (\(driveService.availableAccounts.count))").tag("ALL")
                                    ForEach(driveService.availableAccounts) { acc in
                                        Text(acc.email).tag(acc.email)
                                    }
                                }
                                .frame(maxWidth: 260)
                                .controlSize(.small)
                            }
                        }

                        HStack(spacing: 10) {
                            Button {
                                driveService.rebuildAllCaches()
                            } label: {
                                Label(
                                    driveService.isRebuildingFolders ? (driveService.rebuildProgressText ?? "Đang quét...") : "Quét lại Cache Google Drive ngay",
                                    systemImage: "arrow.clockwise"
                                )
                            }
                            .disabled(driveService.isRebuildingFolders)

                            Button {
                                driveService.clearAllHistory()
                                settings.statusBannerMessage = "Đã xóa sạch lịch sử mở thư mục gần đây."
                            } label: {
                                Label("Xóa lịch sử gần đây", systemImage: "trash")
                            }

                            Button {
                                LauncherPanelController.shared.toggleSearchPanel()
                            } label: {
                                Label("Mở thử Thanh Tìm Kiếm", systemImage: "magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Chỉ mục Tìm kiếm Siêu tốc Google Drive (Real-time & Đa tài khoản)", systemImage: "externaldrive.fill.badge.icloud")
                        .font(.system(size: 13, weight: .semibold))
                }

                // 3.5. Syncthing P2P Sync & Action Latching
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Toggle("Đồng bộ Lịch sử gần đây, Cài đặt & Thói quen qua Syncthing P2P (iMac ↔ MacBook Pro)", isOn: $settings.enableSyncthingSync)
                                .font(.system(size: 12.5, weight: .medium))
                            Spacer()
                            Button("Đồng bộ ngay") {
                                syncService.syncNow()
                                settings.statusBannerMessage = "Đã đồng bộ dữ liệu thành công với \(settings.syncthingFolderPath)."
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!settings.enableSyncthingSync)
                        }

                        if settings.enableSyncthingSync {
                            HStack(spacing: 8) {
                                Text("Thư mục Sync:")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                                TextField("~/Sync/Alfred/DriveBar", text: $settings.syncthingFolderPath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                Button("Mở thư mục") {
                                    let p = syncService.expandedSyncDir
                                    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(URL(fileURLWithPath: p))
                                }
                                .controlSize(.small)
                            }

                            Text("✓ Đã ánh xạ đường dẫn tương đối thông minh (tự khớp user `hunglx` trên iMac & `hunglexuan` trên MacBook Pro) • Đang đồng bộ \(syncService.syncedRecordCount) mục lịch sử.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        Divider()

                        HStack {
                            Toggle("Học thói quen dùng Universal Action (Action Latching — tự đẩy Action hay chọn lên đầu theo đuôi file)", isOn: $settings.enableActionLatching)
                                .font(.system(size: 12))
                            Spacer()
                            if syncService.learnedActionCount > 0 {
                                Button("Đặt lại (\(syncService.learnedActionCount))") {
                                    syncService.resetActionLatching()
                                    settings.statusBannerMessage = "Đã đặt lại thứ tự học thói quen Universal Actions."
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Đồng bộ P2P (Syncthing) & Học Thói Quen Thông Minh", systemImage: "arrow.triangle.2.circlepath.icloud.fill")
                        .font(.system(size: 13, weight: .semibold))
                }

                // 4. GitHub Auto-Update & Accessibility Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.triangle.2.circlepath.circle")
                                .font(.system(size: 21))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cập nhật tự động qua GitHub Releases (hungmtuci/DriveBar)")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(updateStatusSubtitle)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Button("Trang GitHub") {
                                if let u = URL(string: "https://github.com/hungmtuci/DriveBar") {
                                    NSWorkspace.shared.open(u)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if case .available(let ver, _, _, _) = updater.state {
                                Button {
                                    updater.installAvailableUpdate()
                                } label: {
                                    Label("Tải & Cập nhật tự động v\(ver)", systemImage: "arrow.down.circle.fill")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.green)
                                .controlSize(.small)
                            } else {
                                Button {
                                    updater.checkForUpdatesManually()
                                } label: {
                                    Label(updater.isBusy ? "Đang xử lý..." : "Kiểm tra & Cập nhật tự động", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(updater.isBusy)
                            }
                        }

                        Divider()

                        HStack {
                            Image(systemName: axTrusted ? "checkmark.shield.fill" : "shield.lefthalf.filled")
                                .foregroundStyle(axTrusted ? .green : .orange)
                            Text(axTrusted
                                 ? "Đã cấp quyền Accessibility: Bắt văn bản bôi đen ở mọi ứng dụng."
                                 : "Tùy chọn: Cấp quyền Accessibility để bắt đoạn văn bản đang bôi đen trong Chrome/Word (Finder hoạt động ngay không cần quyền này).")
                                .font(.system(size: 11.5))
                            Spacer()
                            if !axTrusted {
                                Button("Cấp quyền Accessibility") {
                                    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                                    _ = AXIsProcessTrustedWithOptions(opts)
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                        axTrusted = AXIsProcessTrusted()
                                    }
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Đồng bộ GitHub & Tự động Cập nhật", systemImage: "icloud.and.arrow.down.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(20)
        }
    }

    private func recorderButtonTitle(for target: HotKeyService.RecordingTarget, current: HotKeyBinding) -> String {
        guard hotKeyService.recordingTarget == target else {
            return "\(current.readableDisplay)  •  Đổi"
        }
        if !hotKeyService.liveModifiersPreview.isEmpty {
            return hotKeyService.liveModifiersPreview
        }
        return "Nhấn phím... (Esc hủy)"
    }

    private func shortcutStatusPill(isActive: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isActive ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(isActive ? "Đang hoạt động" : "Trùng phím")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isActive ? Color.green : Color.orange)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((isActive ? Color.green : Color.orange).opacity(0.13), in: Capsule())
    }

    private func presetChip(
        title: String,
        binding: HotKeyBinding,
        current: HotKeyBinding,
        target: HotKeyService.RecordingTarget
    ) -> some View {
        let isSelected = (current == binding)
        return Button {
            uiState.manualBuilderTarget = nil
            hotKeyService.applyRecordedBinding(binding, for: target)
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func manualShortcutBuilderRow(for target: HotKeyService.RecordingTarget) -> some View {
        HStack(spacing: 10) {
            Text("Giữ phím:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Toggle("⌘ Command", isOn: $uiState.manualCmd)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5, weight: .semibold))
            Toggle("⌥ Option", isOn: $uiState.manualOpt)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5, weight: .semibold))
            Toggle("⌃ Control", isOn: $uiState.manualCtrl)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5, weight: .semibold))
            Toggle("⇧ Shift", isOn: $uiState.manualShift)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5, weight: .semibold))

            Text("+")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)

            Picker("", selection: $uiState.manualKeyCode) {
                ForEach(HotKeyBinding.selectableKeys, id: \.keyCode) { item in
                    Text(item.label).tag(item.keyCode)
                }
            }
            .labelsHidden()
            .frame(width: 155)
            .controlSize(.small)

            Spacer()

            Button("Áp dụng") {
                if let built = uiState.constructedManualBinding {
                    hotKeyService.applyRecordedBinding(built, for: target)
                    uiState.manualBuilderTarget = nil
                } else {
                    NSSound.beep()
                    settings.statusBannerMessage = "Vui lòng tick ít nhất 1 phím bổ trợ (⌘, ⌥, ⌃, ⇧) hoặc chọn phím chức năng F1–F12."
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var updateStatusSubtitle: String {
        switch updater.state {
        case .idle:
            return "Phiên bản hiện tại: v\(updater.currentVersion) • Tự động tải gói .zip, gỡ Gatekeeper và khởi động lại bằng 1 cú nhấp."
        case .checking:
            return "Đang đối chiếu phiên bản mới nhất trên GitHub..."
        case .upToDate(let v):
            return "✓ Bạn đang sử dụng phiên bản mới nhất (v\(v))."
        case .available(let v, _, _, _):
            return "Đã có bản mới v\(v)! Bấm nút màu xanh bên phải để tự động tải về và nâng cấp."
        case .downloading(let v):
            return "Đang tải gói cập nhật DriveBar v\(v)..."
        case .installing(let v):
            return "Đang cài đặt DriveBar v\(v) vào /Applications và khởi động lại..."
        case .failed(let msg):
            return msg
        }
    }

    private func dockOptionCard(
        isSelected: Bool,
        title: String,
        subtitle: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.45))
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.07) : Color.primary.opacity(0.025))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.10), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Tab 1B: Windows Preview (⌘Tab Multi-Window, Multi-Space & Multi-Display Switcher)

private struct WindowSwitcherSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeyService: HotKeyService
    @ObservedObject var switcherController: WindowSwitcherController
    @ObservedObject var switcherService: WindowSwitcherService
    @ObservedObject var uiState: SettingsUIState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Hotkeys & Activation Card
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        // A. Primary Window Switcher (Default: ⌘Tab)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 10) {
                                Toggle("", isOn: $settings.enableWindowSwitcher)
                                    .labelsHidden()
                                    .toggleStyle(.switch)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 8) {
                                        Text("Chuyển đổi tất cả cửa sổ đang chạy (Windows Preview)")
                                            .font(.system(size: 13, weight: .semibold))
                                        switcherStatusBadge
                                    }
                                    Text("Mặc định: Command + Tab (⌘⇥) • Hiển thị từng cửa sổ riêng lẻ của mọi ứng dụng và phóng to nội dung trực tiếp")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    uiState.manualBuilderTarget = nil
                                    if hotKeyService.recordingTarget == .windowSwitcher {
                                        hotKeyService.stopRecording()
                                        hotKeyService.registerAll()
                                    } else {
                                        hotKeyService.startRecording(for: .windowSwitcher)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: hotKeyService.recordingTarget == .windowSwitcher ? "record.circle.fill" : "keyboard")
                                        Text(recorderButtonTitle(for: .windowSwitcher, current: settings.windowSwitcherHotKey))
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    }
                                    .frame(minWidth: 150)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(hotKeyService.recordingTarget == .windowSwitcher ? .orange : .accentColor)
                                .disabled(!settings.enableWindowSwitcher)

                                Button("Mặc định (⌘⇥)") {
                                    hotKeyService.applyRecordedBinding(.defaultWindowSwitcher, for: .windowSwitcher)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!settings.enableWindowSwitcher || (settings.windowSwitcherHotKey == .defaultWindowSwitcher && hotKeyService.recordingTarget == nil))
                            }

                            HStack(spacing: 6) {
                                Text("Chọn nhanh:")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                presetChip(title: "⌘⇥ (Mặc định)", binding: .commandTab, current: settings.windowSwitcherHotKey, target: .windowSwitcher)
                                presetChip(title: "⌥⇥ (Option + Tab)", binding: .optionTab, current: settings.windowSwitcherHotKey, target: .windowSwitcher)
                                presetChip(title: "⌃⇥ (Control + Tab)", binding: .controlTab, current: settings.windowSwitcherHotKey, target: .windowSwitcher)

                                Spacer()

                                Button {
                                    uiState.toggleManualBuilder(for: .windowSwitcher, current: settings.windowSwitcherHotKey)
                                } label: {
                                    Label(
                                        uiState.manualBuilderTarget == .windowSwitcher ? "Ẩn ghép phím" : "Tự ghép phím thủ công",
                                        systemImage: uiState.manualBuilderTarget == .windowSwitcher ? "chevron.up" : "slider.horizontal.3"
                                    )
                                    .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(!settings.enableWindowSwitcher)
                            }

                            if uiState.manualBuilderTarget == .windowSwitcher {
                                manualShortcutBuilderRow(for: .windowSwitcher)
                            }
                        }

                        Divider()

                        // B. Same-App Window Switcher (Default: ⌘`)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 10) {
                                Toggle("", isOn: $settings.enableSameAppSwitcher)
                                    .labelsHidden()
                                    .toggleStyle(.switch)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Chuyển nhanh giữa các cửa sổ của CÙNG 1 ứng dụng đang mở")
                                        .font(.system(size: 13, weight: .semibold))
                                    Text("Mặc định: Command + ` (⌘`) • Thuận tiện khi mở nhiều cửa sổ Word, Excel, Finder hoặc Chrome cùng lúc")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    uiState.manualBuilderTarget = nil
                                    if hotKeyService.recordingTarget == .sameAppWindowSwitcher {
                                        hotKeyService.stopRecording()
                                        hotKeyService.registerAll()
                                    } else {
                                        hotKeyService.startRecording(for: .sameAppWindowSwitcher)
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: hotKeyService.recordingTarget == .sameAppWindowSwitcher ? "record.circle.fill" : "keyboard")
                                        Text(recorderButtonTitle(for: .sameAppWindowSwitcher, current: settings.sameAppSwitcherHotKey))
                                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    }
                                    .frame(minWidth: 150)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(hotKeyService.recordingTarget == .sameAppWindowSwitcher ? .orange : .accentColor)
                                .disabled(!settings.enableSameAppSwitcher)

                                Button("Mặc định (⌘`)") {
                                    hotKeyService.applyRecordedBinding(.defaultSameAppSwitcher, for: .sameAppWindowSwitcher)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(!settings.enableSameAppSwitcher || (settings.sameAppSwitcherHotKey == .defaultSameAppSwitcher && hotKeyService.recordingTarget == nil))
                            }

                            HStack(spacing: 6) {
                                Text("Chọn nhanh:")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)

                                presetChip(title: "⌘` (Mặc định)", binding: .commandGrave, current: settings.sameAppSwitcherHotKey, target: .sameAppWindowSwitcher)
                                presetChip(title: "⌥` (Option + `)", binding: .optionGrave, current: settings.sameAppSwitcherHotKey, target: .sameAppWindowSwitcher)

                                Spacer()

                                Button {
                                    uiState.toggleManualBuilder(for: .sameAppWindowSwitcher, current: settings.sameAppSwitcherHotKey)
                                } label: {
                                    Label(
                                        uiState.manualBuilderTarget == .sameAppWindowSwitcher ? "Ẩn ghép phím" : "Tự ghép phím thủ công",
                                        systemImage: uiState.manualBuilderTarget == .sameAppWindowSwitcher ? "chevron.up" : "slider.horizontal.3"
                                    )
                                    .font(.system(size: 11, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.mini)
                                .disabled(!settings.enableSameAppSwitcher)
                            }

                            if uiState.manualBuilderTarget == .sameAppWindowSwitcher {
                                manualShortcutBuilderRow(for: .sameAppWindowSwitcher)
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    HStack {
                        Label("Phím tắt Kích hoạt Windows Preview (⌘Tab & ⌘`)", systemImage: "macwindow.on.rectangle")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button {
                            switcherController.openPinnedFromMenuOrSearch()
                        } label: {
                            Label("Mở thử Windows Preview ngay", systemImage: "rectangle.grid.1x2")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }

                // 2. Display Scope, Live Zoom & Minimized/Hidden Window Visibility
                GroupBox {
                    VStack(alignment: .leading, spacing: 11) {
                        HStack(spacing: 12) {
                            Text("Phạm vi hiển thị cửa sổ:")
                                .font(.system(size: 12.5, weight: .medium))
                            Picker("", selection: $settings.windowSwitcherScope) {
                                ForEach(WindowSwitcherScope.allCases, id: \.self) { scope in
                                    Text(scope.rawValue).tag(scope)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Divider()

                        Toggle(
                            "Phóng to nội dung cửa sổ đang chọn (hiển thị khung xem trước độ phân giải cao phía trên thanh chọn)",
                            isOn: $settings.windowSwitcherShowZoomPreview
                        )
                        .font(.system(size: 12.5, weight: .medium))

                        Toggle(
                            "Hiển thị các cửa sổ đang thu nhỏ dưới thanh Dock (Minimize — tự động khôi phục khi chọn)",
                            isOn: $settings.windowSwitcherShowMinimized
                        )
                        .font(.system(size: 12.5, weight: .medium))

                        Toggle(
                            "Hiển thị cửa sổ của ứng dụng đang ẩn (⌘H — tự động hiện lại ứng dụng khi chọn)",
                            isOn: $settings.windowSwitcherShowHiddenApps
                        )
                        .font(.system(size: 12.5, weight: .medium))

                        Toggle(
                            "Hiển thị cả các ứng dụng đang chạy nhưng chưa mở cửa sổ nào",
                            isOn: $settings.windowSwitcherShowWindowlessApps
                        )
                        .font(.system(size: 12.5, weight: .medium))
                    }
                    .padding(8)
                } label: {
                    Label("Chế độ Hiển thị, Phóng to Nội dung & Lọc Cửa sổ (Minimize / Desktop / Màn hình)", systemImage: "sparkles.tv")
                        .font(.system(size: 13, weight: .semibold))
                }

                // 3. System Permissions Required for ⌘Tab Override & Live Window Thumbnails
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Image(systemName: switcherService.hasAccessibilityPermission ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                                .font(.system(size: 18))
                                .foregroundStyle(switcherService.hasAccessibilityPermission ? .green : .orange)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quyền Accessibility (Trợ năng) — Bắt phím ⌘Tab & Nhảy chính xác đến từng cửa sổ")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(switcherService.hasAccessibilityPermission
                                     ? "Đã cấp quyền: Hỗ trợ giữ ⌘ + Tab di chuyển lần lượt, nhả ⌘ nhảy ngay tới đúng cửa sổ con hoặc Desktop khác."
                                     : "Cần cấp quyền để ghi đè ⌘Tab mặc định của macOS và kích hoạt chính xác cửa sổ con khi 1 ứng dụng mở nhiều cửa sổ.")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if !switcherService.hasAccessibilityPermission {
                                Button("Cấp quyền Accessibility...") {
                                    switcherService.promptAccessibilityPermission()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }

                        Divider()

                        HStack(spacing: 10) {
                            Image(systemName: switcherService.hasScreenRecordingPermission ? "checkmark.rectangle.stack.fill" : "rectangle.dashed.badge.record")
                                .font(.system(size: 18))
                                .foregroundStyle(switcherService.hasScreenRecordingPermission ? .green : .orange)
                                .frame(width: 24)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quyền Ghi màn hình (Screen Recording) — Chụp ảnh nội dung trực tiếp của từng cửa sổ")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text(switcherService.hasScreenRecordingPermission
                                     ? "Đã cấp quyền: Hiển thị ảnh xem trước sắc nét và phóng to nội dung trực tiếp cho mọi cửa sổ trên các màn hình."
                                     : "Tùy chọn khuyến nghị: Cấp quyền để xem trước ảnh chụp nội dung thực tế của từng cửa sổ (nếu chưa cấp vẫn hiện biểu tượng & tên cửa sổ).")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if !switcherService.hasScreenRecordingPermission {
                                Button("Cấp quyền Ghi màn hình...") {
                                    switcherService.promptScreenRecordingPermission()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                        }

                        HStack {
                            Text("Sau khi bật quyền trong Cài đặt hệ thống macOS, bấm Làm mới để kích hoạt ngay không cần khởi động lại.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Làm mới trạng thái quyền") {
                                switcherService.refreshPermissionStates()
                                switcherController.refreshEventTapState()
                                hotKeyService.registerAll()
                                uiState.axTrusted = switcherService.hasAccessibilityPermission
                                uiState.screenCaptureTrusted = switcherService.hasScreenRecordingPermission
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Quyền Hệ thống cho Windows Preview", systemImage: "lock.shield")
                        .font(.system(size: 13, weight: .semibold))
                }

                // 4. Quick Keyboard Reference Inside Windows Preview
                GroupBox {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("• Giữ ⌘ + bấm Tab / ⇧Tab (hoặc `): Di chuyển lần lượt, nhả ⌘ để chọn.")
                            Text("• Phím mũi tên ← → ↑ ↓ + Enter: Điều hướng tự do & nhảy tới cửa sổ.")
                            Text("• Di chuột & Click: Xem phóng to tức thì và nhảy đến cửa sổ.")
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("• Space: Ẩn / hiện khung phóng to nội dung phía trên.")
                            Text("• Phím W / M / H / Q: Đóng cửa sổ (W), Minimize (M), Ẩn App (H), Thoát App (Q).")
                            Text("• Phím 1 / 2 / 3 / 4: Đổi nhanh Màn hình (1), Minimize (2), App ẩn (3), Cùng App (4).")
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(8)
                } label: {
                    Label("Phím Thao tác Nhanh ngay trong màn hình Windows Preview", systemImage: "keyboard")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .padding(20)
        }
        .onAppear {
            switcherService.refreshPermissionStates()
            switcherController.refreshEventTapState()
        }
    }

    @ViewBuilder
    private var switcherStatusBadge: some View {
        if !settings.enableWindowSwitcher {
            statusCapsule(title: "Đang tắt", color: .secondary)
        } else if switcherController.isEventTapActive {
            statusCapsule(title: "Đang hoạt động", color: .green)
        } else if hotKeyService.isWindowSwitcherCarbonFallbackActive {
            statusCapsule(title: "Chế độ phím tắt", color: .green)
        } else {
            statusCapsule(title: "Cần quyền Accessibility", color: .orange)
        }
    }

    private func statusCapsule(title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func recorderButtonTitle(for target: HotKeyService.RecordingTarget, current: HotKeyBinding) -> String {
        guard hotKeyService.recordingTarget == target else {
            return "\(current.readableDisplay)  •  Đổi"
        }
        if !hotKeyService.liveModifiersPreview.isEmpty {
            return hotKeyService.liveModifiersPreview
        }
        return "Nhấn phím... (Esc hủy)"
    }

    private func presetChip(
        title: String,
        binding: HotKeyBinding,
        current: HotKeyBinding,
        target: HotKeyService.RecordingTarget
    ) -> some View {
        let isSelected = (current == binding)
        return Button {
            uiState.manualBuilderTarget = nil
            hotKeyService.applyRecordedBinding(binding, for: target)
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
        }
        .buttonStyle(.plain)
    }

    private func manualShortcutBuilderRow(for target: HotKeyService.RecordingTarget) -> some View {
        HStack(spacing: 10) {
            Text("Giữ phím:")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            Toggle("⌘ Command", isOn: $uiState.manualCmd)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5, weight: .semibold))
            Toggle("⌥ Option", isOn: $uiState.manualOpt)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5, weight: .semibold))
            Toggle("⌃ Control", isOn: $uiState.manualCtrl)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5, weight: .semibold))
            Toggle("⇧ Shift", isOn: $uiState.manualShift)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5, weight: .semibold))

            Text("+")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)

            Picker("", selection: $uiState.manualKeyCode) {
                ForEach(HotKeyBinding.selectableKeys, id: \.keyCode) { item in
                    Text(item.label).tag(item.keyCode)
                }
            }
            .labelsHidden()
            .frame(width: 155)
            .controlSize(.small)

            Spacer()

            Button("Áp dụng") {
                if let built = uiState.constructedManualBinding {
                    hotKeyService.applyRecordedBinding(built, for: target)
                    uiState.manualBuilderTarget = nil
                } else {
                    NSSound.beep()
                    settings.statusBannerMessage = "Vui lòng tick ít nhất 1 phím bổ trợ (⌘, ⌥, ⌃, ⇧) hoặc chọn phím chức năng F1–F12."
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Tab 2: Convert to Markdown & AI Optimization

private struct AIMarkdownSettingsTab: View {
    @ObservedObject var settings: AppSettings
    @Binding var isDropTargeted: Bool

    var body: some View {
        let diag = MarkdownConverterService.shared.engineDiagnostics()

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("Xuất tệp <tên_file>.md nằm ngay cạnh tệp gốc khi bấm 'Convert to Markdown'", isOn: $settings.saveMarkdownBesideSource)
                        Toggle("Tự động Copy toàn bộ nội dung Markdown vào Clipboard (sẵn sàng ⌘V ngay vào Claude / ChatGPT / Gemini)", isOn: $settings.autoCopyMarkdownToClipboard)
                        Toggle("Bọc thẻ cấu trúc XML <documents><document index=\"...\"> khi gộp hoặc chọn nhiều file cùng lúc", isOn: $settings.wrapMultiFilesInXMLTags)
                        HStack(spacing: 12) {
                            Toggle("Tự động chia nhỏ tài liệu siêu dài (Smart Chunking theo H1/H2 → _Chunks/)", isOn: $settings.enableSmartChunking)
                            Spacer()
                            if settings.enableSmartChunking {
                                Picker("Ngưỡng mỗi phần:", selection: $settings.smartChunkMaxTokens) {
                                    Text("15.000 tokens").tag(15_000)
                                    Text("25.000 tokens").tag(25_000)
                                    Text("40.000 tokens").tag(40_000)
                                }
                                .frame(width: 220)
                                .controlSize(.small)
                            }
                        }
                        Toggle("Tự động kích hoạt Apple Vision OCR (Tiếng Việt + Tiếng Anh) khi PDF scan hoặc Ảnh không có lớp chữ", isOn: $settings.enableVisionOCR)
                        Toggle("Tối ưu hóa dữ liệu cho AI đọc (Chuẩn hóa Unicode NFC Tiếng Việt, xóa ký tự ẩn & gộp dòng trắng thừa để giảm ~15-25% Token)", isOn: $settings.optimizeMarkdownTokens)
                        Toggle("Chèn khối YAML Frontmatter (tên file gốc, định dạng, thời gian) ở đầu file Markdown", isOn: $settings.includeMetadataHeader)
                    }
                    .padding(8)
                } label: {
                    Label("Hành vi Convert to Markdown (Tối ưu cho LLM)", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 13, weight: .semibold))
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        EngineRow(
                            title: "AI Document Toolkit (PyMuPDF4LLM + MarkItDown)",
                            ready: diag.toolkitReady,
                            detail: diag.pythonPath ?? "Chưa tìm thấy .venv — Tự động dùng Engine Swift nội bộ"
                        )
                        EngineRow(
                            title: "LibreOffice Headless (.doc, .xls, .ppt, .rtf → PDF/MD)",
                            ready: diag.libreOfficeReady,
                            detail: diag.sofficePath ?? "Chưa cài LibreOffice — Tự động dùng macOS textutil AST"
                        )
                        EngineRow(
                            title: "Google Workspace (.gdoc/.gsheet/.gslides) & Web URL AI Reader",
                            ready: true,
                            detail: "Tích hợp trực tiếp luồng xuất Markdown / CSV bảng biểu & lọc bài viết Web sạch"
                        )
                        EngineRow(
                            title: "Apple Vision Neural OCR (Tiếng Việt vi-VN & en-US)",
                            ready: true,
                            detail: "Tích hợp sẵn trên Apple Silicon (xử lý PDF scan dấu đỏ & ảnh chụp)"
                        )
                        EngineRow(
                            title: "Native Swift HTML/Table/PDFKit Fallback Engine",
                            ready: true,
                            detail: "Đảm bảo app luôn chạy độc lập 100% trên mọi máy Mac"
                        )

                        Divider().padding(.vertical, 4)

                        HStack {
                            Text("Thư mục AI Toolkit:")
                                .font(.system(size: 12))
                            TextField("~/Developer/AI/ai-document-toolkit", text: $settings.aiToolkitPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Trạng thái các Bộ máy Chuyển đổi (Hybrid Engines)", systemImage: "cpu.fill")
                        .font(.system(size: 13, weight: .semibold))
                }

                // Interactive Drag-and-Drop Test Bench
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text("Kéo & Thả bất kỳ file Word (.doc/.docx), Excel, PDF, Ảnh chụp vào đây để Convert sang Markdown ngay")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Hoặc chọn file trong Finder rồi bấm \(settings.universalActionHotKey.readableDisplay) → Convert to Markdown")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.025))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        .foregroundStyle(isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor))
                )
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
                    Task { @MainActor in
                        var urls: [URL] = []
                        for p in providers {
                            if let item = try? await p.loadItem(forTypeIdentifier: "public.file-url", options: nil),
                               let data = item as? Data,
                               let u = URL(dataRepresentation: data, relativeTo: nil) {
                                urls.append(u)
                            }
                        }
                        guard !urls.isEmpty else { return }
                        if let def = UniversalActionCatalog.all.first(where: { $0.id == "ai.convert_md" }) {
                            UniversalActionExecutor.shared.execute(
                                action: def,
                                target: .files(urls),
                                viewModel: LauncherViewModel.shared
                            )
                        }
                    }
                    return true
                }
            }
            .padding(20)
        }
    }
}

private struct EngineRow: View {
    let title: String
    let ready: Bool
    let detail: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ready ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(ready ? .green : .orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

// MARK: - Tab 3: Universal Actions Checklist

private struct UniversalActionsChecklistTab: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var uiState: SettingsUIState

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Danh mục Universal Actions:")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    TextField("Tìm action...", text: $uiState.actionFilter)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                }

                List {
                    ForEach(ActionCategory.allCases, id: \.self) { category in
                        let filter = uiState.actionFilter
                        let items = UniversalActionCatalog.all.filter {
                            $0.category == category &&
                            (filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) || $0.subtitle.localizedCaseInsensitiveContains(filter))
                        }
                        if !items.isEmpty {
                            Section(category.rawValue) {
                                ForEach(items) { item in
                                    HStack(spacing: 10) {
                                        Toggle("", isOn: Binding(
                                            get: { settings.isActionEnabled(item.id) },
                                            set: { settings.setActionEnabled(item.id, enabled: $0) }
                                        ))
                                        .labelsHidden()

                                        Image(systemName: item.sfSymbol)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 18)

                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.title)
                                                .font(.system(size: 12.5, weight: .medium))
                                            Text(item.subtitle)
                                                .font(.system(size: 10.5))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    .padding(.vertical, 1)
                                }
                            }
                        }
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))

                HStack {
                    Text("Một số hành động chỉ xuất hiện theo ngữ cảnh (ví dụ Google Drive hoặc Gói ứng dụng).")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Bật tất cả") {
                        settings.disabledActionIDs.removeAll()
                    }
                    .controlSize(.small)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                Text("Hướng dẫn Thao tác Nhanh")
                    .font(.system(size: 14, weight: .bold))

                GuideBlock(
                    title: "1. Từ Finder hoặc bất kỳ ứng dụng nào",
                    bodyText: "Chọn 1 hoặc nhiều file trong Finder (hoặc bôi đen đoạn văn bản) → Nhấn \(settings.universalActionHotKey.readableDisplay) → Gõ 'md' hoặc nhấn Enter để Convert sang Markdown ngay."
                )

                GuideBlock(
                    title: "2. Ngay trong kết quả tìm kiếm Google Drive",
                    bodyText: "Nhấn \(settings.searchHotKey.readableDisplay) → Gõ tên thư mục không dấu/viết tắt → Nhấn Enter để duyệt file bên trong → Chọn file bất kỳ và nhấn Tab (⇥) hoặc ⇧↩ để mở Universal Actions."
                )

                GuideBlock(
                    title: "3. Gom nhiều file bằng File Buffer",
                    bodyText: "Khi đang duyệt file trong DriveBar: nhấn ⌥↑ hoặc ⌥↓ để gom nhiều file từ nhiều thư mục khác nhau vào Buffer → Nhấn ⌥→ → Chọn 'Gộp tài liệu sang 1 File AI Context (.md)'."
                )

                GuideBlock(
                    title: "4. Phím bổ trợ (Modifiers)",
                    bodyText: "• ⌥↩ trên Convert to Markdown: Chỉ Copy Markdown vào Clipboard, không tạo file .md.\n• ⌘↩ trên kết quả tìm kiếm: Mở trong Finder.\n• ⌥↩ trên kết quả Google Drive: Copy link chia sẻ.\n• ⌘Y: Xem nhanh Quick Look."
                )

                Spacer()
            }
            .padding(18)
            .frame(width: 285)
            .background(Color.primary.opacity(0.02))
        }
    }
}

private struct GuideBlock: View {
    let title: String
    let bodyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(bodyText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
