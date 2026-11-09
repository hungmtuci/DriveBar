import SwiftUI
import AppKit
import ApplicationServices
import Carbon
import Contacts

// MARK: - Settings UI State (ObservableObject)

@MainActor
final class SettingsUIState: ObservableObject {
    static let shared = SettingsUIState()

    enum Tab: String, CaseIterable, Identifiable {
        case general = "general"
        case googleDrive = "googleDrive"
        case windowSwitcher = "windowSwitcher"
        case systemAndContacts = "systemAndContacts"
        case aiMarkdown = "aiMarkdown"
        case actions = "actions"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .general: return L("Cài đặt chung", "General")
            case .googleDrive: return L("Google Drive & Đồng bộ", "Google Drive & Sync")
            case .windowSwitcher: return L("Windows Preview", "Windows Preview")
            case .systemAndContacts: return L("Hệ thống & Danh bạ", "System & Contacts")
            case .aiMarkdown: return L("Convert Markdown", "Convert Markdown")
            case .actions: return L("Universal Actions", "Universal Actions")
            }
        }

        var sfSymbol: String {
            switch self {
            case .general: return "gearshape"
            case .googleDrive: return "icloud"
            case .windowSwitcher: return "macwindow.on.rectangle"
            case .systemAndContacts: return "terminal"
            case .aiMarkdown: return "doc.text"
            case .actions: return "bolt.horizontal"
            }
        }

        var pageSubtitle: String {
            switch self {
            case .general:
                return L("Khởi động, ngôn ngữ, thanh Dock, phím tắt toàn cục và lịch sử Clipboard", "Startup, language, Dock, global shortcuts, and Clipboard history")
            case .googleDrive:
                return L("Chỉ mục tìm kiếm tức thời Google Drive và đồng bộ đa thiết bị", "Instant Google Drive index and multi-device sync")
            case .windowSwitcher:
                return L("Chuyển đổi và xem trước trực tiếp các cửa sổ đang mở trên mọi màn hình", "Switch and live preview open windows across displays")
            case .systemAndContacts:
                return L("Tra cứu Danh bạ ('c ') và điều khiển hệ thống macOS ('s ')", "Search Contacts ('c ') and run macOS system commands ('s ')")
            case .aiMarkdown:
                return L("Tùy chọn chuyển đổi tài liệu sang Markdown tối ưu cho LLM", "Options for converting documents to Markdown for LLMs")
            case .actions:
                return L("Quản lý danh mục hành động nhanh trên tệp tin, thư mục và văn bản", "Manage quick actions on files, folders, and text")
            }
        }
    }

    @Published var selectedTab: Tab = .general
    @Published var isDropTargeted: Bool = false
    @Published var axTrusted: Bool = AXIsProcessTrusted()
    @Published var screenCaptureTrusted: Bool = CGPreflightScreenCaptureAccess()
    @Published var actionFilter: String = ""
    @Published var systemCommandFilter: String = ""

    // Manual Custom Shortcut Builder State
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

// MARK: - Root Settings Window View (Authentic macOS System Settings Two-Column Layout)

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var driveService = GoogleDriveIndexService.shared
    @ObservedObject private var hotKeyService = HotKeyService.shared
    @ObservedObject private var updater = UpdateCheckerService.shared
    @ObservedObject private var uiState = SettingsUIState.shared

    var body: some View {
        HStack(spacing: 0) {
            // Left Sidebar (macOS Frosted Sidebar extending behind traffic lights)
            sidebarColumn
                .frame(width: 222)
                .background(
                    VisualEffectFrostView(material: .sidebar, blendingMode: .behindWindow)
                        .ignoresSafeArea()
                )

            // Vertical Hairline Divider
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
                .ignoresSafeArea()

            // Right Detail Pane
            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    Color(nsColor: .windowBackgroundColor)
                        .ignoresSafeArea()
                )
        }
        .frame(minWidth: 780, idealWidth: 860, maxWidth: .infinity, minHeight: 540, idealHeight: 620, maxHeight: .infinity)
        .onAppear {
            uiState.axTrusted = AXIsProcessTrusted()
            uiState.screenCaptureTrusted = CGPreflightScreenCaptureAccess()
            WindowSwitcherService.shared.refreshPermissionStates()
            settings.refreshLaunchAtLoginStatus()
        }
    }

    // MARK: - Left Sidebar

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Clearance for macOS traffic-light window controls
            Color.clear
                .frame(height: 38)

            // Clean App Identity Header
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text("DriveBar")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(L("Phiên bản \(updater.currentVersion)", "Version \(updater.currentVersion)"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)

            // Sidebar Navigation List
            VStack(spacing: 2) {
                ForEach(SettingsUIState.Tab.allCases) { tab in
                    sidebarRow(for: tab)
                }
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)

            Divider()
                .padding(.horizontal, 14)

            // Compact Update Status Footer in Sidebar
            sidebarUpdateFooter
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
        }
    }

    private func sidebarRow(for tab: SettingsUIState.Tab) -> some View {
        let isSelected = (uiState.selectedTab == tab)
        return Button {
            if uiState.selectedTab != tab {
                hotKeyService.stopRecording()
                hotKeyService.registerAll()
                uiState.manualBuilderTarget = nil
                uiState.selectedTab = tab
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: tab.sfSymbol)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(width: 18, alignment: .center)

                Text(tab.title)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sidebarUpdateFooter: some View {
        switch updater.state {
        case .available(let ver, _, _, _):
            HStack(spacing: 8) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text(L("Bản mới v\(ver)", "New v\(ver)"))
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(L("Cập nhật", "Update")) {
                    updater.installAvailableUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text(L("Đang kiểm tra...", "Checking..."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

        case .downloading(let ver):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text(L("Đang tải v\(ver)...", "Downloading v\(ver)..."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

        case .installing(let ver):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text(L("Đang cài v\(ver)...", "Installing v\(ver)..."))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
                Text(L("Đã là bản mới nhất", "Up to date"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(L("Kiểm tra", "Check")) {
                    updater.checkForUpdatesManually()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

        default:
            HStack(spacing: 6) {
                Text(L("Cập nhật tự động", "Auto-update"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button(L("Kiểm tra", "Check")) {
                    updater.checkForUpdatesManually()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
    }

    // MARK: - Right Detail Column

    private var detailColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top Page Title Bar
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(uiState.selectedTab.title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(uiState.selectedTab.pageSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                detailHeaderTrailingControl
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            // Optional Dismissible Notification Banner
            if let banner = settings.statusBannerMessage {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                    Text(banner)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button {
                        settings.statusBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.035))

                Divider()
            }

            // Active Pane Content
            Group {
                switch uiState.selectedTab {
                case .general:
                    GeneralSettingsPane(
                        settings: settings,
                        hotKeyService: hotKeyService,
                        updater: updater,
                        uiState: uiState
                    )
                case .googleDrive:
                    GoogleDriveSettingsPane(
                        settings: settings,
                        driveService: driveService,
                        syncService: SyncAndLatchingService.shared
                    )
                case .windowSwitcher:
                    WindowSwitcherSettingsPane(
                        settings: settings,
                        hotKeyService: hotKeyService,
                        switcherController: WindowSwitcherController.shared,
                        switcherService: WindowSwitcherService.shared,
                        uiState: uiState
                    )
                case .systemAndContacts:
                    SystemAndContactsSettingsPane(
                        settings: settings,
                        uiState: uiState
                    )
                case .aiMarkdown:
                    AIMarkdownSettingsPane(
                        settings: settings,
                        isDropTargeted: $uiState.isDropTargeted
                    )
                case .actions:
                    UniversalActionsSettingsPane(
                        settings: settings,
                        uiState: uiState
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var detailHeaderTrailingControl: some View {
        switch uiState.selectedTab {
        case .general:
            Button {
                LauncherPanelController.shared.toggleSearchPanel()
            } label: {
                Label(L("Mở Tìm kiếm", "Open Search"), systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .googleDrive:
            Button {
                LauncherPanelController.shared.toggleSearchPanel()
            } label: {
                Label(L("Mở Tìm kiếm", "Open Search"), systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .windowSwitcher:
            Button {
                WindowSwitcherController.shared.openPinnedFromMenuOrSearch()
            } label: {
                Label(L("Mở xem thử", "Preview"), systemImage: "macwindow.on.rectangle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .systemAndContacts:
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                TextField(L("Tìm lệnh hệ thống...", "Filter commands..."), text: $uiState.systemCommandFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 155)
                if !uiState.systemCommandFilter.isEmpty {
                    Button {
                        uiState.systemCommandFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
            )

        case .aiMarkdown:
            EmptyView()

        case .actions:
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                TextField(L("Tìm hành động...", "Filter actions..."), text: $uiState.actionFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 155)
                if !uiState.actionFilter.isEmpty {
                    Button {
                        uiState.actionFilter = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4.5)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
            )
        }
    }
}

// MARK: - Reusable Native macOS Sonoma / Sequoia System Settings Building Blocks

private struct MacSettingsSection<HeaderTrailing: View, Content: View>: View {
    let title: String?
    let footer: String?
    let headerTrailing: HeaderTrailing
    let content: Content

    init(
        title: String? = nil,
        footer: String? = nil,
        @ViewBuilder headerTrailing: () -> HeaderTrailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.footer = footer
        self.headerTrailing = headerTrailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if title != nil || !(HeaderTrailing.self == EmptyView.self) {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                    }
                    Spacer()
                    headerTrailing
                }
                .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.75), lineWidth: 0.75)
            )

            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 1)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct MacSettingsRowDivider: View {
    var leadingInset: CGFloat = 14

    var body: some View {
        Divider()
            .padding(.leading, leadingInset)
    }
}

private struct MacSettingsRow<Trailing: View>: View {
    let symbol: String?
    let title: String
    let subtitle: String?
    let statusDotColor: Color?
    let statusText: String?
    let trailing: Trailing

    init(
        symbol: String? = nil,
        title: String,
        subtitle: String? = nil,
        statusDotColor: Color? = nil,
        statusText: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.symbol = symbol
        self.title = title
        self.subtitle = subtitle
        self.statusDotColor = statusDotColor
        self.statusText = statusText
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, alignment: .center)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.primary)

                    if let statusDotColor, let statusText {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(statusDotColor)
                                .frame(width: 5.5, height: 5.5)
                            Text(statusText)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Color.primary.opacity(0.05), in: Capsule())
                    }
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct MacSettingsToggleRow: View {
    let title: String
    let subtitle: String?
    @Binding var isOn: Bool

    init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        self._isOn = isOn
    }

    var body: some View {
        MacSettingsRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

// MARK: - Native Keycap Shortcut Recorder Control + Preset Menu

private struct MacShortcutPreset: Identifiable {
    let id: String
    let label: String
    let binding: HotKeyBinding

    init(_ label: String, binding: HotKeyBinding) {
        self.id = "\(binding.carbonModifiers)-\(binding.keyCode)-\(label)"
        self.label = label
        self.binding = binding
    }
}

private struct MacShortcutRecorderControl: View {
    @ObservedObject var hotKeyService: HotKeyService
    @ObservedObject var uiState: SettingsUIState
    let target: HotKeyService.RecordingTarget
    let current: HotKeyBinding
    let defaultBinding: HotKeyBinding
    let presets: [MacShortcutPreset]
    var isEnabled: Bool = true

    private var isRecording: Bool {
        hotKeyService.recordingTarget == target
    }

    private var keycapLabel: String {
        guard isRecording else {
            return current.readableDisplay
        }
        if !hotKeyService.liveModifiersPreview.isEmpty {
            return hotKeyService.liveModifiersPreview
        }
        return L("Nhấn phím...", "Press shortcut...")
    }

    var body: some View {
        HStack(spacing: 6) {
            // Native Keycap Recorder Field
            Button {
                uiState.manualBuilderTarget = nil
                if isRecording {
                    hotKeyService.stopRecording()
                    hotKeyService.registerAll()
                } else {
                    hotKeyService.startRecording(for: target)
                }
            } label: {
                HStack(spacing: 5) {
                    if isRecording {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                    }
                    Text(keycapLabel)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(isRecording ? Color.orange : Color.primary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 96, minHeight: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.orange.opacity(0.10) : Color(nsColor: .textBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isRecording ? Color.orange : Color(nsColor: .separatorColor),
                            lineWidth: isRecording ? 1.25 : 0.85
                        )
                )
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(L("Bấm vào ô rồi nhấn tổ hợp phím mới (Nhấn Esc để hủy)", "Click and press new shortcut (Press Esc to cancel)"))

            // Compact Preset & Options Menu
            Menu {
                Section(L("Tổ hợp phím gợi ý", "Preset Shortcuts")) {
                    ForEach(presets) { preset in
                        Button {
                            uiState.manualBuilderTarget = nil
                            hotKeyService.applyRecordedBinding(preset.binding, for: target)
                        } label: {
                            if current == preset.binding {
                                Text("✓ \(preset.label)")
                            } else {
                                Text(preset.label)
                            }
                        }
                    }
                }

                Divider()

                Button(uiState.manualBuilderTarget == target ? L("Ẩn bảng ghép phím thủ công", "Hide manual shortcut builder") : L("Tự ghép phím thủ công...", "Manual shortcut builder...")) {
                    uiState.toggleManualBuilder(for: target, current: current)
                }

                Button(L("Khôi phục mặc định (\(defaultBinding.readableDisplay))", "Restore default (\(defaultBinding.readableDisplay))")) {
                    uiState.manualBuilderTarget = nil
                    hotKeyService.applyRecordedBinding(defaultBinding, for: target)
                }
                .disabled(current == defaultBinding && !isRecording)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(!isEnabled)
            .help(L("Chọn nhanh tổ hợp phím gợi ý hoặc tự ghép phím thủ công", "Choose a preset shortcut or build manually"))
        }
        .opacity(isEnabled ? 1.0 : 0.45)
    }
}

private struct MacManualShortcutBuilderBar: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeyService: HotKeyService
    @ObservedObject var uiState: SettingsUIState
    let target: HotKeyService.RecordingTarget

    var body: some View {
        HStack(spacing: 10) {
            Text(L("Ghép phím:", "Key Combo:"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)

            Toggle("⌘", isOn: $uiState.manualCmd)
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
            Toggle("⌥", isOn: $uiState.manualOpt)
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
            Toggle("⌃", isOn: $uiState.manualCtrl)
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))
            Toggle("⇧", isOn: $uiState.manualShift)
                .toggleStyle(.checkbox)
                .font(.system(size: 12, weight: .medium))

            Text("+")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Picker("", selection: $uiState.manualKeyCode) {
                ForEach(HotKeyBinding.selectableKeys, id: \.keyCode) { item in
                    Text(item.label).tag(item.keyCode)
                }
            }
            .labelsHidden()
            .frame(width: 145)
            .controlSize(.small)

            Spacer()

            Button(L("Hủy", "Cancel")) {
                uiState.manualBuilderTarget = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(L("Áp dụng", "Apply")) {
                if let built = uiState.constructedManualBinding {
                    hotKeyService.applyRecordedBinding(built, for: target)
                    uiState.manualBuilderTarget = nil
                } else {
                    NSSound.beep()
                    settings.statusBannerMessage = L(
                        "Vui lòng chọn ít nhất 1 phím bổ trợ (⌘, ⌥, ⌃, ⇧) hoặc phím F1–F12.",
                        "Please select at least 1 modifier (⌘, ⌥, ⌃, ⇧) or F1–F12."
                    )
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.025))
    }
}

// MARK: - Pane 1: Cài đặt chung (General, Shortcuts, Clipboard & Permissions)

private struct GeneralSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeyService: HotKeyService
    @ObservedObject var updater: UpdateCheckerService
    @ObservedObject var uiState: SettingsUIState
    @ObservedObject private var clipboardService = ClipboardHistoryService.shared
    @ObservedObject private var driveService = GoogleDriveIndexService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. Startup & Appearance
                MacSettingsSection(title: L("Khởi động & Giao diện", "Startup & Appearance")) {
                    MacSettingsRow(
                        title: L("Ngôn ngữ hiển thị", "Display Language"),
                        subtitle: L("Tự động theo ngôn ngữ hệ thống macOS hoặc chọn cố định Tiếng Việt / English", "Match macOS system language automatically or choose Vietnamese / English")
                    ) {
                        Picker("", selection: $settings.appLanguage) {
                            ForEach(AppLanguagePreference.allCases) { pref in
                                Text(pref.displayTitle).tag(pref)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 220)
                    }

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Khởi động cùng macOS", "Launch at login"),
                        subtitle: L("Tự động chạy nền DriveBar ngay khi đăng nhập vào máy Mac", "Automatically start DriveBar in the background upon login"),
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.toggleLaunchAtLogin($0) }
                        )
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Bật bảng Tìm kiếm khi khởi động", "Show Search window on startup"),
                        subtitle: L("Tự động mở sẵn bảng Tìm kiếm chính (\(settings.searchHotKey.readableDisplay)) ngay khi khởi động DriveBar", "Automatically show the search bar (\(settings.searchHotKey.readableDisplay)) when DriveBar starts"),
                        isOn: $settings.showLauncherOnStartup
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Hiển thị biểu tượng trên thanh Dock", "Show Dock icon"),
                        subtitle: L("Khi tắt, ứng dụng chỉ hiển thị gọn trên thanh Menu Bar phía trên", "When disabled, DriveBar stays quietly in the menu bar"),
                        isOn: $settings.showDockIcon
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Tìm kèm ứng dụng macOS", "Include macOS applications"),
                        subtitle: L("Hiển thị thêm ứng dụng trong /Applications khi gõ tìm kiếm chung (hoặc dùng tiền tố 'a ')", "Include apps from /Applications in search (or use 'a ' prefix)"),
                        isOn: $settings.includeMacAppsInSearch
                    )
                }

                // 2. Global Keyboard Shortcuts
                MacSettingsSection(
                    title: L("Phím tắt toàn cục", "Global Shortcuts"),
                    headerTrailing: {
                        Button(L("Khôi phục mặc định", "Restore Defaults")) {
                            uiState.manualBuilderTarget = nil
                            settings.resetShortcutsToDefault()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                    }
                ) {
                    MacSettingsRow(
                        title: L("Mở thanh Tìm kiếm", "Open Search Bar"),
                        subtitle: L("Tìm nhanh Google Drive, thư mục Mac ('m '), ứng dụng, danh bạ ('c ') và lệnh hệ thống ('s ')", "Fast search for Google Drive, Mac folders ('m '), apps, contacts ('c ') and system commands ('s ')"),
                        statusDotColor: hotKeyService.isSearchHotKeyActive ? nil : .orange,
                        statusText: hotKeyService.isSearchHotKeyActive ? nil : L("Trùng phím", "Conflict")
                    ) {
                        MacShortcutRecorderControl(
                            hotKeyService: hotKeyService,
                            uiState: uiState,
                            target: .search,
                            current: settings.searchHotKey,
                            defaultBinding: .defaultSearch,
                            presets: [
                                MacShortcutPreset(L("⌘Space (Mặc định)", "⌘Space (Default)"), binding: .commandSpace),
                                MacShortcutPreset("⌥Space", binding: .optionSpace),
                                MacShortcutPreset("⌃Space", binding: .controlSpace),
                                MacShortcutPreset("⌘⇧Space", binding: .commandShiftSpace)
                            ]
                        )
                    }

                    if uiState.manualBuilderTarget == .search {
                        MacSettingsRowDivider()
                        MacManualShortcutBuilderBar(
                            settings: settings,
                            hotKeyService: hotKeyService,
                            uiState: uiState,
                            target: .search
                        )
                    }

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: "Universal Actions",
                        subtitle: L("Chọn tệp trong Finder hoặc bôi đen văn bản rồi nhấn phím tắt để thao tác", "Select files in Finder or highlight text and press shortcut to act"),
                        statusDotColor: hotKeyService.isUniversalHotKeyActive ? nil : .orange,
                        statusText: hotKeyService.isUniversalHotKeyActive ? nil : L("Trùng phím", "Conflict")
                    ) {
                        MacShortcutRecorderControl(
                            hotKeyService: hotKeyService,
                            uiState: uiState,
                            target: .universalAction,
                            current: settings.universalActionHotKey,
                            defaultBinding: .defaultUniversalAction,
                            presets: [
                                MacShortcutPreset(L("⌘/ (Mặc định)", "⌘/ (Default)"), binding: .commandSlash),
                                MacShortcutPreset("⌘\\", binding: .commandBackslash),
                                MacShortcutPreset("⌥⌘/", binding: .optionCommandSlash),
                                MacShortcutPreset("⌘⇧A", binding: .commandShiftA),
                                MacShortcutPreset("⌘⇧M", binding: .commandShiftM)
                            ]
                        )
                    }

                    if uiState.manualBuilderTarget == .universalAction {
                        MacSettingsRowDivider()
                        MacManualShortcutBuilderBar(
                            settings: settings,
                            hotKeyService: hotKeyService,
                            uiState: uiState,
                            target: .universalAction
                        )
                    }

                    if let warn = hotKeyService.registrationWarning {
                        MacSettingsRowDivider()
                        HStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.orange)
                            Text(warn)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Button(L("Cài đặt Bàn phím...", "Keyboard Settings...")) {
                                hotKeyService.openMacOSKeyboardShortcutsSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }

                // 2.5. Custom Mac Folders ('m' prefix search mode)
                MacSettingsSection(
                    title: L("Thư mục tìm kiếm trên Mac ('m')", "Mac Folders Search ('m')"),
                    footer: driveService.isRebuildingMacFolders
                        ? L("Đang lập chỉ mục các thư mục Mac ở nền...", "Indexing Mac folders in background...")
                        : L("Đã lập chỉ mục RAM tức thì \(driveService.macFolderItemCount.formatted()) thư mục con & tệp tin (hỗ trợ gõ không dấu Tiếng Việt, chữ viết tắt và theo dõi FSEvents).", "RAM-indexed \(driveService.macFolderItemCount.formatted()) subfolders & files (instant search, accents-free & FSEvents live monitoring)."),
                    headerTrailing: {
                        HStack(spacing: 6) {
                            Button {
                                driveService.rebuildMacFoldersCacheInBackground()
                            } label: {
                                Label(driveService.isRebuildingMacFolders ? L("Đang quét...", "Scanning...") : L("Quét lại", "Re-scan"), systemImage: "arrow.clockwise")
                                    .font(.system(size: 11.5, weight: .regular))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(driveService.isRebuildingMacFolders || settings.customMacFolders.isEmpty)

                            Button {
                                settings.promptAddCustomMacFolder()
                            } label: {
                                Label(L("Thêm thư mục...", "Add Folder..."), systemImage: "folder.badge.plus")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Các thư mục trên máy Mac được đưa vào phạm vi tìm kiếm nhanh khi bạn gõ tiền tố 'm' hoặc 'm <từ khóa>' trong thanh tìm kiếm.", "Mac folders included in search when typing 'm' or 'm <query>' in search bar."))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.top, 10)
                            .padding(.bottom, 4)

                        if settings.customMacFolders.isEmpty {
                            HStack {
                                Spacer()
                                VStack(spacing: 6) {
                                    Image(systemName: "folder.badge.questionmark")
                                        .font(.system(size: 24))
                                        .foregroundStyle(.tertiary)
                                    Text(L("Chưa có thư mục nào được thêm", "No custom folders added yet"))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(.secondary)
                                    Button(L("Chọn thư mục trên Mac...", "Choose Mac Folder...")) {
                                        settings.promptAddCustomMacFolder()
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                .padding(.vertical, 14)
                                Spacer()
                            }
                        } else {
                            ForEach(Array(settings.customMacFolders.enumerated()), id: \.element) { idx, folderPath in
                                if idx > 0 {
                                    MacSettingsRowDivider(leadingInset: 42)
                                }
                                HStack(spacing: 10) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18, alignment: .center)

                                    VStack(alignment: .leading, spacing: 1) {
                                        Text((folderPath as NSString).lastPathComponent)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)

                                        Text(folderPath.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }

                                    Spacer()

                                    Button {
                                        let url = URL(fileURLWithPath: folderPath)
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    } label: {
                                        Image(systemName: "arrow.up.forward.app")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help(L("Mở thư mục trong Finder", "Reveal folder in Finder"))

                                    Button {
                                        settings.removeCustomMacFolder(folderPath)
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                    .help(L("Xóa khỏi danh sách tìm kiếm (m)", "Remove from Mac folder search (m)"))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                            }
                            .padding(.bottom, 4)
                        }
                    }
                }

                // 3. Clipboard History & Pinned Items
                MacSettingsSection(
                    title: L("Lịch sử Clipboard & Mục đã ghim", "Clipboard History & Pinned Items"),
                    footer: L("Cú pháp tra cứu nhanh trong thanh tìm kiếm: 'm ' Thư mục Mac • 'c ' Danh bạ không dấu • 'cb ' Lịch sử Clipboard • 'a ' Ứng dụng • 'ff ' Tệp tin • 's ' Lệnh hệ thống • 'ocr' nhận diện chữ từ ảnh • nhập phép tính trực tiếp.", "Quick prefixes in search bar: 'm ' Mac Folders • 'c ' Contacts • 'cb ' Clipboard • 'a ' Apps • 'ff ' Files • 's ' System Commands • 'ocr' OCR image • direct math calculations.")
                ) {
                    MacSettingsToggleRow(
                        title: L("Lưu lịch sử Clipboard", "Save Clipboard History"),
                        subtitle: L("Tự động lưu văn bản, liên kết, tệp và ảnh chụp (bỏ qua dữ liệu mật khẩu nhạy cảm)", "Automatically store copied text, links, files and images (skips sensitive password managers)"),
                        isOn: $settings.enableClipboardHistory
                    )

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: L("Dữ liệu Clipboard hiện có", "Current Clipboard History"),
                        subtitle: L("\(clipboardService.entries.count) mục đã lưu — gõ 'cb ' trong thanh tìm kiếm để xem và dán lại", "\(clipboardService.entries.count) items stored — type 'cb ' in search to view and paste")
                    ) {
                        HStack(spacing: 6) {
                            Button(L("Mở ('cb ')", "Open ('cb ')")) {
                                LauncherViewModel.shared.prepareForSearchLaunch()
                                LauncherViewModel.shared.searchText = "cb "
                                LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button(L("Xóa lịch sử", "Clear History")) {
                                clipboardService.clearHistory()
                                settings.statusBannerMessage = L("Đã xóa sạch lịch sử Clipboard.", "Cleared Clipboard history.")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(clipboardService.entries.isEmpty)
                        }
                    }

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: L("Mục đã ghim đầu danh sách", "Pinned Items at Top"),
                        subtitle: L("\(settings.pinnedPaths.count) mục đang ghim (nhấn ⌘D trên kết quả tìm kiếm để ghim hoặc bỏ ghim)", "\(settings.pinnedPaths.count) pinned items (press ⌘D on search result to pin or unpin)")
                    ) {
                        Button(L("Bỏ ghim tất cả", "Unpin All")) {
                            settings.pinnedPaths = []
                            LauncherViewModel.shared.refreshSearchResults()
                            settings.statusBannerMessage = L("Đã gỡ toàn bộ các mục đã ghim.", "Unpinned all items.")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(settings.pinnedPaths.isEmpty)
                    }
                }

                // 4. Permissions & Updates
                MacSettingsSection(title: L("Quyền hệ thống & Phiên bản", "System Permissions & Updates")) {
                    MacSettingsRow(
                        symbol: "hand.raised",
                        title: L("Quyền Trợ năng (Accessibility)", "Accessibility Permission"),
                        subtitle: uiState.axTrusted
                            ? L("Đã cấp quyền bắt văn bản đang chọn và điều khiển cửa sổ ứng dụng", "Granted permission to capture selection and control windows")
                            : L("Cho phép lấy đoạn văn bản bôi đen ở trình duyệt và điều khiển cửa sổ", "Allows capturing highlighted text and window switching"),
                        statusDotColor: uiState.axTrusted ? .green : .orange,
                        statusText: uiState.axTrusted ? L("Đã cấp", "Granted") : L("Chưa cấp", "Not Granted")
                    ) {
                        if uiState.axTrusted {
                            Text(L("Đang bật", "Enabled"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Button(L("Cấp quyền...", "Grant...")) {
                                let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                                _ = AXIsProcessTrustedWithOptions(opts)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    uiState.axTrusted = AXIsProcessTrusted()
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    MacSettingsRowDivider(leadingInset: 46)

                    MacSettingsRow(
                        symbol: "arrow.triangle.2.circlepath",
                        title: L("Cập nhật phần mềm", "Software Update"),
                        subtitle: updateStatusDescription
                    ) {
                        HStack(spacing: 6) {
                            Button("GitHub") {
                                if let u = URL(string: "https://github.com/hungmtuci/DriveBar") {
                                    NSWorkspace.shared.open(u)
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            if case .available(let ver, _, _, _) = updater.state {
                                Button(L("Cập nhật v\(ver)", "Update v\(ver)")) {
                                    updater.installAvailableUpdate()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Button(updater.isBusy ? L("Đang kiểm tra...", "Checking...") : L("Kiểm tra cập nhật", "Check for Updates")) {
                                    updater.checkForUpdatesManually()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(updater.isBusy)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }

    private var updateStatusDescription: String {
        switch updater.state {
        case .idle:
            return L("Phiên bản hiện tại: v\(updater.currentVersion) • Nguồn: GitHub Releases (hungmtuci/DriveBar)", "Current version: v\(updater.currentVersion) • Source: GitHub Releases (hungmtuci/DriveBar)")
        case .checking:
            return L("Đang kiểm tra phiên bản mới trên GitHub...", "Checking for updates on GitHub...")
        case .upToDate(let v):
            return L("Bạn đang sử dụng phiên bản mới nhất (v\(v))", "You are using the latest version (v\(v))")
        case .available(let v, _, _, _):
            return L("Đã có phiên bản mới v\(v) sẵn sàng tải về và cài đặt tự động", "New update v\(v) available to download and install automatically")
        case .downloading(let v):
            return L("Đang tải gói cập nhật DriveBar v\(v)...", "Downloading DriveBar update v\(v)...")
        case .installing(let v):
            return L("Đang cài đặt DriveBar v\(v) vào /Applications...", "Installing DriveBar v\(v) into /Applications...")
        case .failed(let msg):
            return msg
        }
    }
}

// MARK: - Pane 2: Google Drive & Đồng bộ

private struct GoogleDriveSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var driveService: GoogleDriveIndexService
    @ObservedObject var syncService: SyncAndLatchingService
    @ObservedObject private var localSyncService = LocalFolderDriveSyncService.shared

    private var cleanDriveRootPath: String {
        guard let root = driveService.accountRoot else {
            return L("Chưa tìm thấy thư mục Google Drive trong ~/Library/CloudStorage", "No Google Drive folder found in ~/Library/CloudStorage")
        }
        return (root as NSString).abbreviatingWithTildeInPath
    }

    private var indexSummaryText: String {
        var parts = [
            L("\(driveService.folderCount.formatted()) thư mục", "\(driveService.folderCount.formatted()) folders"),
            L("\(driveService.sharedCount.formatted()) mục được chia sẻ", "\(driveService.sharedCount.formatted()) shared items"),
            L("\(driveService.fileCount.formatted()) tệp tin", "\(driveService.fileCount.formatted()) files")
        ]
        if let updated = driveService.lastCacheUpdate {
            parts.append(L("Cập nhật \(updated.formatted(date: .abbreviated, time: .shortened))", "Updated \(updated.formatted(date: .abbreviated, time: .shortened))"))
        }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 0. Local Mac Folders <-> Google Drive Desktop Sync (Finder Right-Click & Antigravity)
                localFolderDriveSyncSection

                // 1. Google Drive Index
                MacSettingsSection(title: L("Chỉ mục Google Drive", "Google Drive Index")) {
                    MacSettingsRow(
                        symbol: "externaldrive.badge.icloud",
                        title: cleanDriveRootPath,
                        subtitle: indexSummaryText,
                        statusDotColor: driveService.accountRoot != nil ? .green : .orange,
                        statusText: driveService.isRealtimeWatcherActive ? "FSEvents" : (driveService.accountRoot != nil ? L("Đã kết nối", "Connected") : L("Chưa kết nối", "Disconnected"))
                    ) {
                        if let root = driveService.accountRoot {
                            Button(L("Mở Finder", "Open Finder")) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: root))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if !driveService.availableAccounts.isEmpty {
                        MacSettingsRowDivider(leadingInset: 46)

                        MacSettingsRow(
                            title: L("Tài khoản hiển thị", "Account Filter"),
                            subtitle: L("Giới hạn kết quả tìm kiếm theo tài khoản Google Drive cụ thể", "Filter search results to a specific Google Drive account")
                        ) {
                            Picker("", selection: $settings.selectedDriveAccountFilter) {
                                Text(L("Tất cả tài khoản (\(driveService.availableAccounts.count))", "All Accounts (\(driveService.availableAccounts.count))")).tag("ALL")
                                ForEach(driveService.availableAccounts) { acc in
                                    Text(acc.email).tag(acc.email)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(width: 230)
                            .controlSize(.small)
                        }
                    }

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Theo dõi thay đổi tức thời (FSEvents)", "Live Change Monitoring (FSEvents)"),
                        subtitle: L("Tự động cập nhật chỉ mục ngay khi tạo mới, xóa hoặc đổi tên thư mục", "Automatically update index when folders are created, renamed, or deleted"),
                        isOn: $settings.enableRealtimeFSEvents
                    )

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: L("Bộ nhớ đệm & Lịch sử truy cập", "Cache & Access History"),
                        subtitle: L("Làm mới thủ công toàn bộ cây thư mục hoặc xóa danh sách mở gần đây", "Manually refresh full folder tree or clear recent history")
                    ) {
                        HStack(spacing: 6) {
                            Button(L("Xóa lịch sử mở", "Clear History")) {
                                driveService.clearAllHistory()
                                settings.statusBannerMessage = L("Đã xóa lịch sử mở thư mục gần đây.", "Cleared recently opened folders history.")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                driveService.rebuildAllCaches()
                            } label: {
                                Text(driveService.isRebuildingFolders ? (driveService.rebuildProgressText ?? L("Đang quét...", "Scanning...")) : L("Quét lại chỉ mục", "Rebuild Index"))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(driveService.isRebuildingFolders)
                        }
                    }
                }

                // 2. Syncthing P2P Sync & Smart Action Latching
                MacSettingsSection(
                    title: L("Đồng bộ đa máy & Học thói quen", "Multi-Device Sync & Learning"),
                    footer: settings.enableSyncthingSync
                        ? L("Tự động ánh xạ đường dẫn tương đối giữa các máy Mac khác tên người dùng • Đang đồng bộ \(syncService.syncedRecordCount) mục lịch sử.", "Automatically maps relative paths across different Mac usernames • Currently syncing \(syncService.syncedRecordCount) records.")
                        : nil
                ) {
                    MacSettingsToggleRow(
                        title: L("Đồng bộ qua Syncthing P2P", "Sync via Syncthing P2P"),
                        subtitle: L("Chia sẻ lịch sử mở gần đây và thói quen sử dụng giữa iMac và MacBook", "Share recent history and habits between iMac and MacBook"),
                        isOn: $settings.enableSyncthingSync
                    )

                    if settings.enableSyncthingSync {
                        MacSettingsRowDivider()

                        MacSettingsRow(
                            title: L("Thư mục đồng bộ", "Sync Folder"),
                            subtitle: L("Đường dẫn thư mục được chia sẻ qua Syncthing", "Folder path shared via Syncthing")
                        ) {
                            HStack(spacing: 6) {
                                TextField("~/Sync/Alfred/DriveBar", text: $settings.syncthingFolderPath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .frame(width: 195)

                                Button(L("Mở", "Open")) {
                                    let p = syncService.expandedSyncDir
                                    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(URL(fileURLWithPath: p))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button(L("Đồng bộ ngay", "Sync Now")) {
                                    syncService.syncNow()
                                    settings.statusBannerMessage = L("Đã đồng bộ dữ liệu với \(settings.syncthingFolderPath).", "Data synced with \(settings.syncthingFolderPath).")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: L("Tự học thói quen Universal Actions", "Smart Action Latching"),
                        subtitle: L("Tự động đưa hành động thường chọn lên đầu danh sách theo từng định dạng tệp", "Promote frequently chosen actions to the top per file type")
                    ) {
                        HStack(spacing: 8) {
                            if syncService.learnedActionCount > 0 {
                                Button(L("Đặt lại (\(syncService.learnedActionCount))", "Reset (\(syncService.learnedActionCount))")) {
                                    syncService.resetActionLatching()
                                    settings.statusBannerMessage = L("Đã đặt lại dữ liệu học thói quen Universal Actions.", "Reset action latching habits.")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Toggle("", isOn: $settings.enableActionLatching)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }

    @ViewBuilder
    private var localFolderDriveSyncSection: some View {
        MacSettingsSection(
            title: L("Đồng bộ Thư mục trên ổ cứng Mac ↔ Google Drive (Chuột phải Finder & Antigravity)", "Sync Local Mac Folders ↔ Google Drive (Finder Right-Click & Antigravity)"),
            footer: L(
                "Bấm chuột phải vào bất kỳ thư mục nào trong Finder → chọn 'Quick Actions' (Tác vụ nhanh) → 'Đồng bộ với Google Drive (DriveBar)...' hoặc 'Đồng bộ nhanh 1 chạm vào Google Drive'. Mọi thay đổi trong thư mục Antigravity trên ổ Mac sẽ tự động đồng bộ 2 chiều thời gian thực với Google Drive Desktop.",
                "Right-click any folder in Finder → 'Quick Actions' → 'Đồng bộ với Google Drive (DriveBar)...' or 'Đồng bộ nhanh 1 chạm vào Google Drive'. Changes in local Antigravity folders sync 2-way in real time with Google Drive Desktop."
            ),
            headerTrailing: {
                HStack(spacing: 6) {
                    Button {
                        localSyncService.syncAllEnabledPairs(showToast: true)
                    } label: {
                        Label(
                            localSyncService.isGlobalSyncing ? L("Đang đồng bộ...", "Syncing...") : L("Đồng bộ tất cả", "Sync All"),
                            systemImage: "arrow.triangle.2.circlepath"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(localSyncService.syncedPairs.isEmpty || localSyncService.isGlobalSyncing)

                    Button {
                        FolderSyncDialogController.shared.presentSharedLinkDialog()
                    } label: {
                        Label(L("Dán Link được chia sẻ...", "Paste Shared Link..."), systemImage: "link.icloud.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        promptAddLocalFolderForDriveSync()
                    } label: {
                        Label(L("Thêm thư mục...", "Add Folder..."), systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        ) {
            MacSettingsRow(
                symbol: "folder.badge.gearshape",
                title: L("Thư mục đích mặc định trong My Drive", "Default Destination Subfolder in My Drive"),
                subtitle: L("Khi đồng bộ nhanh từ ~/Documents/antigravity, cấu trúc dự án con sẽ được giữ nguyên trong thư mục này", "When quick-syncing from ~/Documents/antigravity, project subfolder hierarchy is preserved here")
            ) {
                HStack(spacing: 6) {
                    TextField("00. Antigravity_Sync", text: $localSyncService.defaultDriveSyncSubfolder)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(width: 175)

                    Button(L("Mở", "Open")) {
                        if let myDrive = localSyncService.activeMyDriveRoot() {
                            let sub = localSyncService.defaultDriveSyncSubfolder.trimmingCharacters(in: .whitespacesAndNewlines)
                            let target = sub.isEmpty ? myDrive : (myDrive as NSString).appendingPathComponent(sub)
                            try? FileManager.default.createDirectory(atPath: target, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(URL(fileURLWithPath: target))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            MacSettingsRowDivider()

            MacSettingsRow(
                symbol: "contextualmenu.and.cursorarrow",
                title: L("Menu Chuột phải Finder (Quick Actions & Services)", "Finder Right-Click Menu (Quick Actions & Services)"),
                subtitle: L("Đã cài đặt 'Đồng bộ với Google Drive' & 'Dán Link Copy' trong ~/Library/Services", "Installed 'Đồng bộ với Google Drive' & 'Dán Link Copy' in ~/Library/Services"),
                statusDotColor: .green,
                statusText: L("Đã kích hoạt", "Installed")
            ) {
                Button(L("Làm mới Menu Chuột phải", "Refresh Finder Menu")) {
                    localSyncService.installFinderQuickActionsIfNeeded(force: true)
                    FloatingToastController.shared.showSuccess(
                        title: L("Đã làm mới Menu Chuột phải Finder!", "Refreshed Finder Right-Click Menu!"),
                        subtitle: L("Bấm chuột phải vào thư mục → Quick Actions / Services", "Right-click a folder → Quick Actions / Services"),
                        symbol: "contextualmenu.and.cursorarrow"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            MacSettingsRowDivider()

            if localSyncService.syncedPairs.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "icloud.and.arrow.up")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text(L("Chưa có thư mục ổ cứng Mac nào đang đồng bộ với Google Drive", "No local Mac folders synced with Google Drive yet"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Button(L("Chọn thư mục trên Mac để đồng bộ...", "Choose Mac Folder to Sync...")) {
                            promptAddLocalFolderForDriveSync()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 14)
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(localSyncService.syncedPairs.enumerated()), id: \.element.id) { idx, pair in
                        if idx > 0 {
                            MacSettingsRowDivider(leadingInset: 42)
                        }
                        HStack(spacing: 10) {
                            Image(
                                systemName: pair.isRemoteLinkBroken == true
                                    ? "exclamationmark.icloud.fill"
                                    : (pair.isEnabled ? "checkmark.icloud.fill" : "icloud.slash")
                            )
                            .font(.system(size: 15))
                            .foregroundStyle(
                                pair.isRemoteLinkBroken == true
                                    ? .red
                                    : (pair.isEnabled ? .green : .secondary)
                            )
                            .frame(width: 20, alignment: .center)
                            .help(
                                pair.isRemoteLinkBroken == true
                                    ? L("⚠️ Link Google Drive được chia sẻ đã bị khóa/thu hồi quyền truy cập. Toàn bộ file đã tải về máy được giữ nguyên 100%.", "⚠️ Shared Google Drive link was locked/revoked. All downloaded local files remain 100% intact.")
                                    : L("Đang đồng bộ hoạt động", "Active sync")
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(pair.folderName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.primary)

                                    Text(pair.syncMode.localizedShortBadge)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(pair.syncMode == .remoteSharedLink ? .indigo : .blue)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1.5)
                                        .background((pair.syncMode == .remoteSharedLink ? Color.indigo : Color.blue).opacity(0.12), in: Capsule())

                                    if pair.isRemoteLinkBroken == true {
                                        Text(L("⚠️ Link bị khóa (Giữ nguyên file)", "⚠️ Link Locked (Files Preserved)"))
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.red)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(Color.red.opacity(0.14), in: Capsule())
                                    }

                                    let byteStr = ByteCountFormatter.string(fromByteCount: pair.lastSyncTotalBytes, countStyle: .file)
                                    Text("\(pair.lastSyncFileCount) \(L("tệp", "files")) (\(byteStr))")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.secondary)

                                    if let owner = pair.remoteOwnerName, !owner.isEmpty {
                                        Text("• \(owner)")
                                            .font(.system(size: 10.5))
                                            .foregroundStyle(.secondary)
                                    }

                                    if let level = pair.shareAccessLevel, level != .unknown, pair.syncMode != .remoteSharedLink {
                                        Text(level.localizedBadge)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(level == .restricted ? .orange : (level == .writer ? .purple : .green))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1.5)
                                            .background(
                                                (level == .restricted ? Color.orange : (level == .writer ? Color.purple : Color.green)).opacity(0.12),
                                                in: Capsule()
                                            )
                                    }
                                }

                                Text("\(pair.prettyLocalPath)  ↔  \(pair.prettyDrivePath)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Menu {
                                Button {
                                    localSyncService.setSharePermission(forPath: pair.localPath, level: .reader, showToast: true)
                                } label: {
                                    Label(L("🌐 Lấy link Public — Chỉ xem (Copy Link)", "🌐 Public Link — View Only (Copy Link)"), systemImage: "globe")
                                }

                                Button {
                                    localSyncService.setSharePermission(forPath: pair.localPath, level: .writer, showToast: true)
                                } label: {
                                    Label(L("✏️ Lấy link Public — Cho phép sửa (Copy Link)", "✏️ Public Link — Can Edit (Copy Link)"), systemImage: "pencil.and.outline")
                                }

                                Divider()

                                Button {
                                    localSyncService.setSharePermission(forPath: pair.localPath, level: .restricted, showToast: true)
                                } label: {
                                    Label(L("🔒 Khóa lại — Hạn chế (Chỉ mình tôi)", "🔒 Lock — Restricted (Owner Only)"), systemImage: "lock.fill")
                                }
                            } label: {
                                HStack(spacing: 3) {
                                    Image(systemName: "link.badge.plus")
                                        .font(.system(size: 11))
                                    Text(L("Chia sẻ", "Share"))
                                        .font(.system(size: 11, weight: .medium))
                                }
                            }
                            .menuStyle(.borderedButton)
                            .controlSize(.small)
                            .fixedSize()
                            .help(L("Lấy link chia sẻ Public (Xem / Sửa) hoặc Khóa lại", "Get Public Share Link (View / Edit) or Lock"))

                            Button {
                                localSyncService.syncPairNow(id: pair.id, showToast: true)
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help(L("Đồng bộ ngay lập tức", "Sync now"))

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pair.localPath)])
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help(L("Mở thư mục gốc trên ổ Mac", "Reveal local Mac folder in Finder"))

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pair.driveTargetPath)])
                            } label: {
                                Image(systemName: "externaldrive.badge.icloud")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help(L("Mở thư mục đích trong Google Drive Finder", "Reveal destination folder in Google Drive"))

                            Button {
                                if let gd = GoogleDriveIndexService.googleDriveURLs(for: pair.driveTargetPath, isDirectoryHint: true) {
                                    NSWorkspace.shared.open(gd.webURL)
                                } else {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pair.driveTargetPath)])
                                }
                            } label: {
                                Image(systemName: "globe")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help(L("Mở trên trình duyệt Google Drive Web", "Open in Google Drive Web"))

                            Button {
                                FolderSyncDialogController.shared.presentDialog(forLocalPath: pair.localPath)
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .help(L("Cấu hình đường dẫn đích & chế độ đồng bộ", "Configure destination & sync mode"))

                            Button {
                                localSyncService.removeSyncPair(id: pair.id, restoreRealFolderIfSymlink: true, showToast: true)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(L("Ngừng đồng bộ thư mục này", "Stop syncing this folder"))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func promptAddLocalFolderForDriveSync() {
        let panel = NSOpenPanel()
        panel.title = L("Chọn thư mục trên ổ cứng Mac để đồng bộ với Google Drive", "Choose a Mac folder to sync with Google Drive")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Tiếp tục", "Continue")
        let antigravityPath = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/antigravity")
        if FileManager.default.fileExists(atPath: antigravityPath) {
            panel.directoryURL = URL(fileURLWithPath: antigravityPath)
        }
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            FolderSyncDialogController.shared.present(forFolderURLs: panel.urls, instantIfSingle: false)
        }
    }
}

// MARK: - Pane 3: Windows Preview (⌘Tab Multi-Window, Multi-Space & Multi-Display Switcher)

private struct WindowSwitcherSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var hotKeyService: HotKeyService
    @ObservedObject var switcherController: WindowSwitcherController
    @ObservedObject var switcherService: WindowSwitcherService
    @ObservedObject var uiState: SettingsUIState

    private var switcherStatusInfo: (Color, String) {
        if !settings.enableWindowSwitcher {
            return (.secondary, L("Đang tắt", "Disabled"))
        } else if switcherController.isEventTapActive {
            return (.green, L("Đang hoạt động", "Active"))
        } else if hotKeyService.isWindowSwitcherCarbonFallbackActive {
            return (.green, L("Chế độ phím tắt", "Shortcut Mode"))
        } else {
            return (.orange, L("Cần quyền Trợ năng", "Needs Accessibility"))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. Activation & Shortcuts
                MacSettingsSection(title: L("Kích hoạt & Phím tắt", "Activation & Shortcuts")) {
                    MacSettingsRow(
                        title: L("Chuyển đổi tất cả cửa sổ (Windows Preview)", "Switch all windows (Windows Preview)"),
                        subtitle: L("Hiển thị các cửa sổ đang chạy của mọi ứng dụng kèm ảnh xem trước trực tiếp", "Show running windows across all applications with live visual previews"),
                        statusDotColor: switcherStatusInfo.0,
                        statusText: switcherStatusInfo.1
                    ) {
                        HStack(spacing: 10) {
                            MacShortcutRecorderControl(
                                hotKeyService: hotKeyService,
                                uiState: uiState,
                                target: .windowSwitcher,
                                current: settings.windowSwitcherHotKey,
                                defaultBinding: .defaultWindowSwitcher,
                                presets: [
                                    MacShortcutPreset(L("⌘⇥ (Mặc định)", "⌘⇥ (Default)"), binding: .commandTab),
                                    MacShortcutPreset("⌥⇥ (Option + Tab)", binding: .optionTab),
                                    MacShortcutPreset("⌃⇥ (Control + Tab)", binding: .controlTab)
                                ],
                                isEnabled: settings.enableWindowSwitcher
                            )

                            Toggle("", isOn: $settings.enableWindowSwitcher)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }

                    if uiState.manualBuilderTarget == .windowSwitcher {
                        MacSettingsRowDivider()
                        MacManualShortcutBuilderBar(
                            settings: settings,
                            hotKeyService: hotKeyService,
                            uiState: uiState,
                            target: .windowSwitcher
                        )
                    }

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: L("Chuyển cửa sổ trong cùng ứng dụng", "Switch windows of same app"),
                        subtitle: L("Chuyển nhanh giữa nhiều cửa sổ của ứng dụng đang mở hiện tại", "Cycle between windows belonging to the frontmost application")
                    ) {
                        HStack(spacing: 10) {
                            MacShortcutRecorderControl(
                                hotKeyService: hotKeyService,
                                uiState: uiState,
                                target: .sameAppWindowSwitcher,
                                current: settings.sameAppSwitcherHotKey,
                                defaultBinding: .defaultSameAppSwitcher,
                                presets: [
                                    MacShortcutPreset(L("⌘` (Mặc định)", "⌘` (Default)"), binding: .commandGrave),
                                    MacShortcutPreset("⌥` (Option + `)", binding: .optionGrave)
                                ],
                                isEnabled: settings.enableSameAppSwitcher
                            )

                            Toggle("", isOn: $settings.enableSameAppSwitcher)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }

                    if uiState.manualBuilderTarget == .sameAppWindowSwitcher {
                        MacSettingsRowDivider()
                        MacManualShortcutBuilderBar(
                            settings: settings,
                            hotKeyService: hotKeyService,
                            uiState: uiState,
                            target: .sameAppWindowSwitcher
                        )
                    }
                }

                // 2. Display & Filtering Behavior
                MacSettingsSection(title: L("Hiển thị & Hành vi", "Display & Behavior")) {
                    MacSettingsRow(
                        title: L("Phạm vi màn hình", "Display Scope"),
                        subtitle: L("Chọn không gian màn hình để liệt kê cửa sổ đang mở", "Select spaces and displays to include running windows")
                    ) {
                        Picker("", selection: $settings.windowSwitcherScope) {
                            ForEach(WindowSwitcherScope.allCases, id: \.self) { scope in
                                Text(scope.displayName).tag(scope)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 245)
                        .controlSize(.small)
                    }

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Giữ bảng chọn mở sau khi nhả phím ⌘", "Keep open after releasing ⌘"),
                        subtitle: L("Cho phép dùng phím mũi tên điều hướng hoặc gõ từ khóa lọc cửa sổ (nhấn ↩ để chọn)", "Navigate with arrow keys or type to filter windows (press ↩ to select)"),
                        isOn: Binding(
                            get: { !settings.windowSwitcherReleaseToActivate },
                            set: { settings.windowSwitcherReleaseToActivate = !$0 }
                        )
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Bấm phím Space hoặc Option để mở cửa sổ", "Press Space or Option to open"),
                        subtitle: L("Mở và kích hoạt ngay cửa sổ đang chọn khi nhấn Space, Option, Command hoặc Enter", "Immediately activate selected window when pressing Space, Option, Command or Enter"),
                        isOn: $settings.windowSwitcherSpaceToActivate
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Phóng to nội dung cửa sổ đang chọn", "Show Zoom Preview"),
                        subtitle: L("Hiển thị khung xem trước độ phân giải cao phía trên thanh chọn cửa sổ", "Show high-resolution preview above the switcher cards"),
                        isOn: $settings.windowSwitcherShowZoomPreview
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Hiển thị cửa sổ đang thu nhỏ (Minimize)", "Show Minimized Windows"),
                        subtitle: L("Bao gồm cửa sổ thu nhỏ dưới thanh Dock và tự động khôi phục khi chọn", "Include windows minimized in Dock and restore upon selection"),
                        isOn: $settings.windowSwitcherShowMinimized
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Hiển thị ứng dụng đang ẩn (⌘H)", "Show Hidden Apps (⌘H)"),
                        subtitle: L("Bao gồm cửa sổ của ứng dụng đang ẩn và tự động hiện lại khi chọn", "Include windows of hidden apps and unhide upon selection"),
                        isOn: $settings.windowSwitcherShowHiddenApps
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Hiển thị ứng dụng không có cửa sổ", "Show Windowless Apps"),
                        subtitle: L("Liệt kê thêm các ứng dụng đang chạy nền chưa mở cửa sổ nào", "Include background running apps that have no open windows"),
                        isOn: $settings.windowSwitcherShowWindowlessApps
                    )
                }

                // 3. System Permissions
                MacSettingsSection(
                    title: L("Quyền hệ thống cho Windows Preview", "System Permissions for Windows Preview"),
                    headerTrailing: {
                        Button(L("Làm mới trạng thái", "Refresh Status")) {
                            switcherService.refreshPermissionStates()
                            switcherController.refreshEventTapState()
                            hotKeyService.registerAll()
                            uiState.axTrusted = switcherService.hasAccessibilityPermission
                            uiState.screenCaptureTrusted = switcherService.hasScreenRecordingPermission
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                    }
                ) {
                    MacSettingsRow(
                        symbol: "hand.raised",
                        title: L("Quyền Trợ năng (Accessibility)", "Accessibility Permission"),
                        subtitle: L("Bắt tổ hợp phím ⌘⇥ và chuyển tiêu điểm chính xác tới từng cửa sổ con", "Intercepts ⌘⇥ shortcut and switches focus to target windows"),
                        statusDotColor: switcherService.hasAccessibilityPermission ? .green : .orange,
                        statusText: switcherService.hasAccessibilityPermission ? L("Đã cấp", "Granted") : L("Cần cấp quyền", "Action Required")
                    ) {
                        if switcherService.hasAccessibilityPermission {
                            Text(L("Đang bật", "Enabled"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Button(L("Cấp quyền...", "Grant...")) {
                                switcherService.promptAccessibilityPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    MacSettingsRowDivider(leadingInset: 46)

                    MacSettingsRow(
                        symbol: "rectangle.dashed.badge.record",
                        title: L("Quyền Ghi màn hình (Screen Recording)", "Screen Recording Permission"),
                        subtitle: L("Chụp ảnh xem trước trực tiếp nội dung thực tế của các cửa sổ", "Captures live visual content previews of open windows"),
                        statusDotColor: switcherService.hasScreenRecordingPermission ? .green : .orange,
                        statusText: switcherService.hasScreenRecordingPermission ? L("Đã cấp", "Granted") : L("Tùy chọn", "Optional")
                    ) {
                        if switcherService.hasScreenRecordingPermission {
                            Text(L("Đang bật", "Enabled"))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Button(L("Cấp quyền...", "Grant...")) {
                                switcherService.promptScreenRecordingPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                // 4. Compact Shortcut Reference Card
                MacSettingsSection(title: L("Phím thao tác trong Windows Preview", "Windows Preview Keyboard Controls")) {
                    ShortcutHintGridRow(
                        leftKey: "← → / ⇥",
                        leftDesc: L("Di chuyển qua các cửa sổ", "Navigate windows"),
                        rightKey: "↑ / ↓",
                        rightDesc: L("Hiện cửa sổ cùng ứng dụng / Quay lại tất cả", "Same-app windows / All apps")
                    )
                    MacSettingsRowDivider()
                    ShortcutHintGridRow(
                        leftKey: "↩ / ⌘ / ⌥ / Space / Click",
                        leftDesc: L("Mở ngay cửa sổ đang chọn", "Open selected window"),
                        rightKey: "⌃← ⌃→ ⌃↑ ⌃↓",
                        rightDesc: L("Chia cửa sổ Trái / Phải / Tối đa / Giữa", "Snap Left / Right / Maximize / Center")
                    )
                    MacSettingsRowDivider()
                    ShortcutHintGridRow(
                        leftKey: L("Gõ ký tự", "Type characters"),
                        leftDesc: L("Lọc theo tên ứng dụng hoặc cửa sổ", "Filter by app or window title"),
                        rightKey: "⌘W / ⌘M / ⌘H / ⌘Q",
                        rightDesc: L("Đóng / Thu nhỏ / Ẩn / Thoát ứng dụng", "Close / Minimize / Hide / Quit")
                    )
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .onAppear {
            switcherService.refreshPermissionStates()
            switcherController.refreshEventTapState()
        }
    }
}

private struct ShortcutHintGridRow: View {
    let leftKey: String
    let leftDesc: String
    let rightKey: String
    let rightDesc: String

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 8) {
                Text(leftKey)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(leftDesc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Text(rightKey)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(rightDesc)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8.5)
    }
}

// MARK: - Pane 4: Hệ thống & Danh bạ (`c ` & `s `)

private struct SystemAndContactsSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var uiState: SettingsUIState
    @ObservedObject private var contactsService = ContactsSearchService.shared

    private var contactsStatusInfo: (Color, String) {
        if contactsService.isAuthorized {
            return (.green, L("\(contactsService.contacts.count) liên hệ", "\(contactsService.contacts.count) contacts"))
        } else if contactsService.authorizationStatus == .notDetermined {
            return (.secondary, L("Chưa cấp quyền", "Not Determined"))
        } else {
            return (.orange, L("Bị từ chối", "Denied"))
        }
    }

    private var contactsSubtitle: String {
        if contactsService.isAuthorized {
            return L(
                "Gõ 'c <tên không dấu, viết tắt hoặc SĐT>' rồi nhấn ↩ để xem chi tiết và chọn mục sao chép",
                "Type 'c <name, initials, or phone>' and press ↩ to inspect and copy"
            )
        } else if contactsService.authorizationStatus == .notDetermined {
            return L(
                "Cấp quyền truy cập để tìm nhanh liên hệ bằng Tiếng Việt không dấu ngay trong thanh tìm kiếm",
                "Grant access to search contacts instantly right from the search bar"
            )
        } else {
            return L(
                "Mở Cài đặt Quyền riêng tư của macOS → Contacts và bật công tắc cho phép DriveBar",
                "Open macOS Privacy & Security → Contacts and toggle DriveBar ON"
            )
        }
    }

    var body: some View {
        let normalizedFilter = GoogleDriveIndexService.removeAccents(uiState.systemCommandFilter)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. Contacts Lookup (`c `)
                MacSettingsSection(
                    title: L("Danh bạ macOS ('c ')", "macOS Contacts ('c ')"),
                    footer: L("Trong màn hình chi tiết liên hệ: nhấn ↩ để sao chép, ⌘C sao chép và giữ mở, ⌥↩ sao chép và dán ngay, hoặc ⇧ để phóng to chữ.", "In contact details: press ↩ to copy, ⌘C to copy and stay open, ⌥↩ to copy and paste immediately, or ⇧ to zoom text.")
                ) {
                    MacSettingsRow(
                        symbol: "person.crop.circle",
                        title: L("Tra cứu Danh bạ Tiếng Việt không dấu", "Search Contacts (Accents-Free)"),
                        subtitle: contactsSubtitle,
                        statusDotColor: contactsStatusInfo.0,
                        statusText: contactsStatusInfo.1
                    ) {
                        HStack(spacing: 6) {
                            if contactsService.isAuthorized {
                                Button(L("Làm mới", "Reload")) {
                                    contactsService.reloadContacts(force: true)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(contactsService.isLoading)
                            } else if contactsService.authorizationStatus == .notDetermined {
                                Button(L("Cấp quyền...", "Grant...")) {
                                    contactsService.requestAccessIfNeeded()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Button(L("Cài đặt Quyền...", "Privacy Settings...")) {
                                    contactsService.openContactsPrivacySettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Button(L("Mở ('c ')", "Open ('c ')")) {
                                LauncherViewModel.shared.prepareForSearchLaunch()
                                LauncherViewModel.shared.searchText = "c "
                                LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                // 2. Alfred-Parity System Commands Header Bar
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Lệnh Hệ thống ('s ' hoặc gõ trực tiếp từ khóa)", "System Commands ('s ' or direct keyword)"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(L("Mở danh sách ('s ')", "Open list ('s ')")) {
                        LauncherViewModel.shared.prepareForSearchLaunch()
                        LauncherViewModel.shared.searchText = "s "
                        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))

                    Text("•")
                        .foregroundStyle(.tertiary)

                    Button(L("Khôi phục mặc định", "Restore Defaults")) {
                        settings.resetSystemCommandsToDefault()
                        settings.statusBannerMessage = L("Đã bật toàn bộ lệnh hệ thống và khôi phục tùy chọn xác nhận mặc định.", "Enabled all system commands and restored default confirmation prompts.")
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }
                .padding(.horizontal, 4)
                .padding(.bottom, -10)

                // 3. Inset-Grouped Cards per SystemUtilityCategory
                ForEach(SystemUtilityCategory.allCases, id: \.self) { category in
                    let commands = InstantUtilityService.allSystemCommands.filter { cmd in
                        guard cmd.category == category else { return false }
                        guard !normalizedFilter.isEmpty else { return true }
                        let hay = GoogleDriveIndexService.removeAccents(
                            "\(cmd.primaryKeyword) \(cmd.bilingualSearchText)"
                        ).lowercased()
                        return hay.contains(normalizedFilter)
                    }

                    if !commands.isEmpty {
                        MacSettingsSection(title: category.localizedTitle) {
                            ForEach(Array(commands.enumerated()), id: \.element.id) { idx, cmd in
                                if idx > 0 {
                                    MacSettingsRowDivider(leadingInset: 46)
                                }

                                SystemCommandSettingsRow(
                                    command: cmd,
                                    settings: settings
                                )
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
        .onAppear {
            contactsService.refreshAuthorizationStatus()
            if contactsService.isAuthorized {
                contactsService.reloadContacts(force: false)
            }
        }
    }
}

private struct SystemCommandSettingsRow: View {
    let command: SystemUtilityDefinition
    @ObservedObject var settings: AppSettings

    var body: some View {
        let isEnabled = settings.isSystemCommandEnabled(command.id)

        HStack(alignment: .center, spacing: 12) {
            Image(systemName: command.sfSymbol)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(isEnabled ? Color.secondary : Color.secondary.opacity(0.45))
                .frame(width: 20, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(command.title)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(isEnabled ? .primary : .secondary)

                    Text(command.primaryKeyword)
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5.5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                }

                Text(command.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if command.supportsConfirmation {
                Toggle(L("Xác nhận", "Confirm"), isOn: Binding(
                    get: { settings.requiresSystemCommandConfirmation(command.id) },
                    set: { settings.setSystemCommandConfirmation(command.id, confirm: $0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .disabled(!isEnabled)
                .help(L("Hiển thị hộp thoại xác nhận trước khi thực thi (giữ phím ⌥ khi nhấn ↩ để bỏ qua)", "Show confirmation dialog before executing (hold ⌥ on ↩ to bypass)"))
            }

            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { settings.setSystemCommandEnabled(command.id, enabled: $0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}

// MARK: - Pane 5: Convert Markdown & AI Optimization

private struct AIMarkdownSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @Binding var isDropTargeted: Bool

    var body: some View {
        let diag = MarkdownConverterService.shared.engineDiagnostics()

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. Output & LLM Optimization
                MacSettingsSection(title: L("Đầu ra & Tối ưu hóa cho LLM", "Output & LLM Optimization")) {
                    MacSettingsToggleRow(
                        title: L("Lưu tệp .md cạnh tệp gốc", "Save .md file beside source file"),
                        subtitle: L("Tạo tệp <tên_file>.md cùng thư mục khi chạy Convert to Markdown", "Create <filename>.md in same folder when converting to Markdown"),
                        isOn: $settings.saveMarkdownBesideSource
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Tự động sao chép vào Clipboard", "Automatically copy to Clipboard"),
                        subtitle: L("Sẵn sàng dán (⌘V) ngay vào Claude, ChatGPT hoặc Gemini sau khi chuyển đổi", "Ready to paste (⌘V) into Claude, ChatGPT or Gemini right after conversion"),
                        isOn: $settings.autoCopyMarkdownToClipboard
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Chèn khối thông tin YAML Frontmatter", "Include YAML Frontmatter metadata"),
                        subtitle: L("Đính kèm tên tệp gốc, định dạng và thời gian chuyển đổi ở đầu tệp Markdown", "Attach original filename, format, and conversion timestamp at the top of Markdown"),
                        isOn: $settings.includeMetadataHeader
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Bọc thẻ cấu trúc XML khi gộp nhiều tệp", "Wrap XML structural tags when merging files"),
                        subtitle: L("Đóng gói theo chuẩn <documents><document> giúp mô hình AI phân tách ngữ cảnh", "Package in <documents><document> schema to help AI models separate context"),
                        isOn: $settings.wrapMultiFilesInXMLTags
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Tối ưu hóa Token & chuẩn hóa Tiếng Việt", "Optimize Tokens & Vietnamese Normalization"),
                        subtitle: L("Chuẩn hóa Unicode NFC, xóa ký tự ẩn và gộp dòng trắng thừa (~15–25% nhẹ hơn)", "Normalize Unicode NFC, strip hidden characters and collapse blank lines (~15–25% lighter)"),
                        isOn: $settings.optimizeMarkdownTokens
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: L("Nhận diện văn bản Apple Vision OCR", "Apple Vision Neural OCR text recognition"),
                        subtitle: L("Tự động trích xuất chữ Tiếng Việt và Tiếng Anh khi gặp PDF scan hoặc ảnh chụp", "Automatically extract Vietnamese and English text from scanned PDFs or images"),
                        isOn: $settings.enableVisionOCR
                    )

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: L("Chia nhỏ tài liệu dài (Smart Chunking)", "Split long documents (Smart Chunking)"),
                        subtitle: L("Tự động tách theo mục H1/H2 vào thư mục _Chunks khi vượt ngưỡng token", "Automatically split by H1/H2 headings into _Chunks folder when exceeding token limit")
                    ) {
                        HStack(spacing: 10) {
                            if settings.enableSmartChunking {
                                Picker("", selection: $settings.smartChunkMaxTokens) {
                                    Text(L("15.000 tokens", "15,000 tokens")).tag(15_000)
                                    Text(L("25.000 tokens", "25,000 tokens")).tag(25_000)
                                    Text(L("40.000 tokens", "40,000 tokens")).tag(40_000)
                                }
                                .labelsHidden()
                                .pickerStyle(.menu)
                                .frame(width: 130)
                                .controlSize(.small)
                            }

                            Toggle("", isOn: $settings.enableSmartChunking)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)
                        }
                    }
                }

                // 2. Hybrid Engines Status
                MacSettingsSection(title: L("Bộ máy chuyển đổi (Hybrid Engines)", "Conversion Engines (Hybrid Engines)")) {
                    MacEngineStatusRow(
                        title: "AI Document Toolkit (PyMuPDF4LLM + MarkItDown)",
                        detail: diag.pythonPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? L("Chưa cài đặt — tự động dùng bộ chuyển đổi Swift nội bộ", "Not installed — automatically falls back to native Swift engine"),
                        isReady: diag.toolkitReady
                    )

                    MacSettingsRowDivider()

                    MacEngineStatusRow(
                        title: "LibreOffice Headless (.doc, .xls, .ppt, .rtf)",
                        detail: diag.sofficePath ?? L("Chưa cài đặt — tự động dùng macOS textutil AST", "Not installed — automatically falls back to macOS textutil AST"),
                        isReady: diag.libreOfficeReady
                    )

                    MacSettingsRowDivider()

                    MacEngineStatusRow(
                        title: "Google Workspace (.gdoc, .gsheet, .gslides) & Web Reader",
                        detail: L("Xuất trực tiếp cấu trúc bảng biểu và bài viết sạch sang Markdown", "Directly export tables and clean article content to Markdown"),
                        isReady: true
                    )

                    MacSettingsRowDivider()

                    MacEngineStatusRow(
                        title: "Apple Vision Neural OCR & Native Swift Fallback",
                        detail: L("Hoạt động độc lập trên macOS không cần phụ thuộc bên ngoài", "Runs natively on macOS without any external dependencies"),
                        isReady: true
                    )

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: L("Đường dẫn AI Toolkit", "AI Toolkit Path"),
                        subtitle: L("Thư mục chứa môi trường Python tùy chọn", "Directory containing optional Python virtual environment")
                    ) {
                        TextField("~/Developer/AI/ai-document-toolkit", text: $settings.aiToolkitPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 250)
                    }
                }

                // 3. Clean Native Drop Zone
                MacSettingsSection(title: L("Chuyển đổi nhanh bằng Kéo & Thả", "Quick Conversion via Drag & Drop")) {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                        Text(L("Kéo và thả tệp Word, Excel, PDF hoặc Ảnh vào đây để chuyển sang Markdown", "Drag and drop Word, Excel, PDF, or Image files here to convert to Markdown"))
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text(L("Hoặc chọn tệp trong Finder rồi nhấn \(settings.universalActionHotKey.readableDisplay)", "Or select files in Finder and press \(settings.universalActionHotKey.readableDisplay)"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 22)
                    .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
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
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }
}

private struct MacEngineStatusRow: View {
    let title: String
    let detail: String
    let isReady: Bool

    var body: some View {
        MacSettingsRow(title: title, subtitle: detail) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isReady ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 6, height: 6)
                Text(isReady ? L("Sẵn sàng", "Ready") : L("Dự phòng", "Fallback"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Pane 6: Universal Actions

private struct UniversalActionsSettingsPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var uiState: SettingsUIState

    var body: some View {
        let filter = uiState.actionFilter.trimmingCharacters(in: .whitespacesAndNewlines)

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Quick Reference Card
                MacSettingsSection(
                    title: L("Cách gọi nhanh Universal Actions", "Quick Access to Universal Actions"),
                    headerTrailing: {
                        if !settings.disabledActionIDs.isEmpty {
                            Button(L("Bật lại tất cả (\(settings.disabledActionIDs.count) đang tắt)", "Enable all (\(settings.disabledActionIDs.count) disabled)")) {
                                settings.disabledActionIDs.removeAll()
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                        }
                    }
                ) {
                    ShortcutHintGridRow(
                        leftKey: settings.universalActionHotKey.readableDisplay,
                        leftDesc: L("Mở trên tệp Finder hoặc văn bản đang chọn", "Open for selected Finder file or highlighted text"),
                        rightKey: "⇥ / ⇧↩",
                        rightDesc: L("Mở từ kết quả tìm kiếm DriveBar", "Open from DriveBar search results")
                    )
                    MacSettingsRowDivider()
                    ShortcutHintGridRow(
                        leftKey: "⌥↑ / ⌥↓ → ⌥→",
                        leftDesc: L("Gom nhiều tệp vào Buffer để xử lý hàng loạt", "Collect files into Buffer for batch processing"),
                        rightKey: "⌥↩",
                        rightDesc: L("Chỉ sao chép Markdown (không tạo tệp .md)", "Copy Markdown only (skip .md file creation)")
                    )
                }

                // Categories of Actions as Native Inset-Grouped Cards
                ForEach(ActionCategory.allCases, id: \.self) { category in
                    let items = UniversalActionCatalog.all.filter { item in
                        item.category == category &&
                        (filter.isEmpty ||
                         item.bilingualSearchText.localizedCaseInsensitiveContains(filter))
                    }

                    if !items.isEmpty {
                        MacSettingsSection(title: category.localizedTitle) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                                if idx > 0 {
                                    MacSettingsRowDivider(leadingInset: 46)
                                }

                                MacSettingsRow(
                                    symbol: item.sfSymbol,
                                    title: item.title,
                                    subtitle: item.subtitle
                                ) {
                                    Toggle("", isOn: Binding(
                                        get: { settings.isActionEnabled(item.id) },
                                        set: { settings.setActionEnabled(item.id, enabled: $0) }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 20)
        }
    }
}
