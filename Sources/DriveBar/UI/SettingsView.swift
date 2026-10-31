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
        case general = "Cài đặt chung"
        case googleDrive = "Google Drive & Đồng bộ"
        case windowSwitcher = "Windows Preview"
        case systemAndContacts = "Hệ thống & Danh bạ"
        case aiMarkdown = "Convert Markdown"
        case actions = "Universal Actions"

        var id: String { rawValue }

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
                return "Khởi động, thanh Dock, phím tắt toàn cục và lịch sử Clipboard"
            case .googleDrive:
                return "Chỉ mục tìm kiếm tức thời Google Drive và đồng bộ đa thiết bị"
            case .windowSwitcher:
                return "Chuyển đổi và xem trước trực tiếp các cửa sổ đang mở trên mọi màn hình"
            case .systemAndContacts:
                return "Tra cứu Danh bạ không dấu ('c ') và điều khiển hệ thống macOS ('s ')"
            case .aiMarkdown:
                return "Tùy chọn chuyển đổi tài liệu sang Markdown tối ưu cho LLM"
            case .actions:
                return "Quản lý danh mục hành động nhanh trên tệp tin, thư mục và văn bản"
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
                    Text("Phiên bản \(updater.currentVersion)")
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

                Text(tab.rawValue)
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
                Text("Bản mới v\(ver)")
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Cập nhật") {
                    updater.installAvailableUpdate()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }

        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text("Đang kiểm tra...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

        case .downloading(let ver):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text("Đang tải v\(ver)...")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

        case .installing(let ver):
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.mini)
                Text("Đang cài v\(ver)...")
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
                Text("Đã là bản mới nhất")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Kiểm tra") {
                    updater.checkForUpdatesManually()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }

        default:
            HStack(spacing: 6) {
                Text("Cập nhật tự động")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Kiểm tra") {
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
                    Text(uiState.selectedTab.rawValue)
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
                Label("Mở Tìm kiếm", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .googleDrive:
            Button {
                LauncherPanelController.shared.toggleSearchPanel()
            } label: {
                Label("Mở Tìm kiếm", systemImage: "magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .windowSwitcher:
            Button {
                WindowSwitcherController.shared.openPinnedFromMenuOrSearch()
            } label: {
                Label("Mở xem thử", systemImage: "macwindow.on.rectangle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .systemAndContacts:
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                TextField("Tìm lệnh hệ thống...", text: $uiState.systemCommandFilter)
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
                TextField("Tìm hành động...", text: $uiState.actionFilter)
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
        return "Nhấn phím..."
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
            .help("Bấm vào ô rồi nhấn tổ hợp phím mới (Nhấn Esc để hủy)")

            // Compact Preset & Options Menu
            Menu {
                Section("Tổ hợp phím gợi ý") {
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

                Button(uiState.manualBuilderTarget == target ? "Ẩn bảng ghép phím thủ công" : "Tự ghép phím thủ công...") {
                    uiState.toggleManualBuilder(for: target, current: current)
                }

                Button("Khôi phục mặc định (\(defaultBinding.readableDisplay))") {
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
            .help("Chọn nhanh tổ hợp phím gợi ý hoặc tự ghép phím thủ công")
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
            Text("Ghép phím:")
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

            Button("Hủy") {
                uiState.manualBuilderTarget = nil
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Áp dụng") {
                if let built = uiState.constructedManualBinding {
                    hotKeyService.applyRecordedBinding(built, for: target)
                    uiState.manualBuilderTarget = nil
                } else {
                    NSSound.beep()
                    settings.statusBannerMessage = "Vui lòng chọn ít nhất 1 phím bổ trợ (⌘, ⌥, ⌃, ⇧) hoặc phím F1–F12."
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. Startup & Appearance
                MacSettingsSection(title: "Khởi động & Giao diện") {
                    MacSettingsToggleRow(
                        title: "Khởi động cùng macOS",
                        subtitle: "Tự động chạy nền DriveBar ngay khi đăng nhập vào máy Mac",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { settings.toggleLaunchAtLogin($0) }
                        )
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Bật bảng Tìm kiếm khi khởi động",
                        subtitle: "Tự động mở sẵn bảng Tìm kiếm chính (\(settings.searchHotKey.readableDisplay)) ngay khi khởi động DriveBar",
                        isOn: $settings.showLauncherOnStartup
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Hiển thị biểu tượng trên thanh Dock",
                        subtitle: "Khi tắt, ứng dụng chỉ hiển thị gọn trên thanh Menu Bar phía trên",
                        isOn: $settings.showDockIcon
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Tìm kèm ứng dụng macOS",
                        subtitle: "Hiển thị thêm ứng dụng trong /Applications khi gõ tìm kiếm chung (hoặc dùng tiền tố 'a ')",
                        isOn: $settings.includeMacAppsInSearch
                    )
                }

                // 2. Global Keyboard Shortcuts
                MacSettingsSection(
                    title: "Phím tắt toàn cục",
                    headerTrailing: {
                        Button("Khôi phục mặc định") {
                            uiState.manualBuilderTarget = nil
                            settings.resetShortcutsToDefault()
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11.5))
                    }
                ) {
                    MacSettingsRow(
                        title: "Mở thanh Tìm kiếm",
                        subtitle: "Tìm nhanh Google Drive, ứng dụng, danh bạ ('c ') và lệnh hệ thống ('s ')",
                        statusDotColor: hotKeyService.isSearchHotKeyActive ? nil : .orange,
                        statusText: hotKeyService.isSearchHotKeyActive ? nil : "Trùng phím"
                    ) {
                        MacShortcutRecorderControl(
                            hotKeyService: hotKeyService,
                            uiState: uiState,
                            target: .search,
                            current: settings.searchHotKey,
                            defaultBinding: .defaultSearch,
                            presets: [
                                MacShortcutPreset("⌘Space (Mặc định)", binding: .commandSpace),
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
                        subtitle: "Chọn tệp trong Finder hoặc bôi đen văn bản rồi nhấn phím tắt để thao tác",
                        statusDotColor: hotKeyService.isUniversalHotKeyActive ? nil : .orange,
                        statusText: hotKeyService.isUniversalHotKeyActive ? nil : "Trùng phím"
                    ) {
                        MacShortcutRecorderControl(
                            hotKeyService: hotKeyService,
                            uiState: uiState,
                            target: .universalAction,
                            current: settings.universalActionHotKey,
                            defaultBinding: .defaultUniversalAction,
                            presets: [
                                MacShortcutPreset("⌘/ (Mặc định)", binding: .commandSlash),
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
                            Button("Cài đặt Bàn phím...") {
                                hotKeyService.openMacOSKeyboardShortcutsSettings()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }

                // 3. Clipboard History & Pinned Items
                MacSettingsSection(
                    title: "Lịch sử Clipboard & Mục đã ghim",
                    footer: "Cú pháp tra cứu nhanh trong thanh tìm kiếm: 'c ' Danh bạ không dấu • 'cb ' Lịch sử Clipboard • 'a ' Ứng dụng • 'ff ' Tệp tin • 's ' Lệnh hệ thống • 'ocr' nhận diện chữ từ ảnh • nhập phép tính trực tiếp."
                ) {
                    MacSettingsToggleRow(
                        title: "Lưu lịch sử Clipboard",
                        subtitle: "Tự động lưu văn bản, liên kết, tệp và ảnh chụp (bỏ qua dữ liệu mật khẩu nhạy cảm)",
                        isOn: $settings.enableClipboardHistory
                    )

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: "Dữ liệu Clipboard hiện có",
                        subtitle: "\(clipboardService.entries.count) mục đã lưu — gõ 'cb ' trong thanh tìm kiếm để xem và dán lại"
                    ) {
                        HStack(spacing: 6) {
                            Button("Mở ('cb ')") {
                                LauncherViewModel.shared.prepareForSearchLaunch()
                                LauncherViewModel.shared.searchText = "cb "
                                LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("Xóa lịch sử") {
                                clipboardService.clearHistory()
                                settings.statusBannerMessage = "Đã xóa sạch lịch sử Clipboard."
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(clipboardService.entries.isEmpty)
                        }
                    }

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: "Mục đã ghim đầu danh sách",
                        subtitle: "\(settings.pinnedPaths.count) mục đang ghim (nhấn ⌘D trên kết quả tìm kiếm để ghim hoặc bỏ ghim)"
                    ) {
                        Button("Bỏ ghim tất cả") {
                            settings.pinnedPaths = []
                            LauncherViewModel.shared.refreshSearchResults()
                            settings.statusBannerMessage = "Đã gỡ toàn bộ các mục đã ghim."
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(settings.pinnedPaths.isEmpty)
                    }
                }

                // 4. Permissions & Updates
                MacSettingsSection(title: "Quyền hệ thống & Phiên bản") {
                    MacSettingsRow(
                        symbol: "hand.raised",
                        title: "Quyền Trợ năng (Accessibility)",
                        subtitle: uiState.axTrusted
                            ? "Đã cấp quyền bắt văn bản đang chọn và điều khiển cửa sổ ứng dụng"
                            : "Cho phép lấy đoạn văn bản bôi đen ở trình duyệt và điều khiển cửa sổ",
                        statusDotColor: uiState.axTrusted ? .green : .orange,
                        statusText: uiState.axTrusted ? "Đã cấp" : "Chưa cấp"
                    ) {
                        if uiState.axTrusted {
                            Text("Đang bật")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Cấp quyền...") {
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
                        title: "Cập nhật phần mềm",
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
                                Button("Cập nhật v\(ver)") {
                                    updater.installAvailableUpdate()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Button(updater.isBusy ? "Đang kiểm tra..." : "Kiểm tra cập nhật") {
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
            return "Phiên bản hiện tại: v\(updater.currentVersion) • Nguồn: GitHub Releases (hungmtuci/DriveBar)"
        case .checking:
            return "Đang kiểm tra phiên bản mới trên GitHub..."
        case .upToDate(let v):
            return "Bạn đang sử dụng phiên bản mới nhất (v\(v))"
        case .available(let v, _, _, _):
            return "Đã có phiên bản mới v\(v) sẵn sàng tải về và cài đặt tự động"
        case .downloading(let v):
            return "Đang tải gói cập nhật DriveBar v\(v)..."
        case .installing(let v):
            return "Đang cài đặt DriveBar v\(v) vào /Applications..."
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

    private var cleanDriveRootPath: String {
        guard let root = driveService.accountRoot else {
            return "Chưa tìm thấy thư mục Google Drive trong ~/Library/CloudStorage"
        }
        return (root as NSString).abbreviatingWithTildeInPath
    }

    private var indexSummaryText: String {
        var parts = [
            "\(driveService.folderCount.formatted()) thư mục",
            "\(driveService.sharedCount.formatted()) mục được chia sẻ",
            "\(driveService.fileCount.formatted()) tệp tin"
        ]
        if let updated = driveService.lastCacheUpdate {
            parts.append("Cập nhật \(updated.formatted(date: .abbreviated, time: .shortened))")
        }
        return parts.joined(separator: " • ")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. Google Drive Index
                MacSettingsSection(title: "Chỉ mục Google Drive") {
                    MacSettingsRow(
                        symbol: "externaldrive.badge.icloud",
                        title: cleanDriveRootPath,
                        subtitle: indexSummaryText,
                        statusDotColor: driveService.accountRoot != nil ? .green : .orange,
                        statusText: driveService.isRealtimeWatcherActive ? "FSEvents" : (driveService.accountRoot != nil ? "Đã kết nối" : "Chưa kết nối")
                    ) {
                        if let root = driveService.accountRoot {
                            Button("Mở Finder") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: root))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }

                    if !driveService.availableAccounts.isEmpty {
                        MacSettingsRowDivider(leadingInset: 46)

                        MacSettingsRow(
                            title: "Tài khoản hiển thị",
                            subtitle: "Giới hạn kết quả tìm kiếm theo tài khoản Google Drive cụ thể"
                        ) {
                            Picker("", selection: $settings.selectedDriveAccountFilter) {
                                Text("Tất cả tài khoản (\(driveService.availableAccounts.count))").tag("ALL")
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
                        title: "Theo dõi thay đổi tức thời (FSEvents)",
                        subtitle: "Tự động cập nhật chỉ mục ngay khi tạo mới, xóa hoặc đổi tên thư mục",
                        isOn: $settings.enableRealtimeFSEvents
                    )

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: "Bộ nhớ đệm & Lịch sử truy cập",
                        subtitle: "Làm mới thủ công toàn bộ cây thư mục hoặc xóa danh sách mở gần đây"
                    ) {
                        HStack(spacing: 6) {
                            Button("Xóa lịch sử mở") {
                                driveService.clearAllHistory()
                                settings.statusBannerMessage = "Đã xóa lịch sử mở thư mục gần đây."
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                driveService.rebuildAllCaches()
                            } label: {
                                Text(driveService.isRebuildingFolders ? (driveService.rebuildProgressText ?? "Đang quét...") : "Quét lại chỉ mục")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(driveService.isRebuildingFolders)
                        }
                    }
                }

                // 2. Syncthing P2P Sync & Smart Action Latching
                MacSettingsSection(
                    title: "Đồng bộ đa máy & Học thói quen",
                    footer: settings.enableSyncthingSync
                        ? "Tự động ánh xạ đường dẫn tương đối giữa các máy Mac khác tên người dùng • Đang đồng bộ \(syncService.syncedRecordCount) mục lịch sử."
                        : nil
                ) {
                    MacSettingsToggleRow(
                        title: "Đồng bộ qua Syncthing P2P",
                        subtitle: "Chia sẻ lịch sử mở gần đây và thói quen sử dụng giữa iMac và MacBook",
                        isOn: $settings.enableSyncthingSync
                    )

                    if settings.enableSyncthingSync {
                        MacSettingsRowDivider()

                        MacSettingsRow(
                            title: "Thư mục đồng bộ",
                            subtitle: "Đường dẫn thư mục được chia sẻ qua Syncthing"
                        ) {
                            HStack(spacing: 6) {
                                TextField("~/Sync/Alfred/DriveBar", text: $settings.syncthingFolderPath)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .frame(width: 195)

                                Button("Mở") {
                                    let p = syncService.expandedSyncDir
                                    try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
                                    NSWorkspace.shared.open(URL(fileURLWithPath: p))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Đồng bộ ngay") {
                                    syncService.syncNow()
                                    settings.statusBannerMessage = "Đã đồng bộ dữ liệu với \(settings.syncthingFolderPath)."
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: "Tự học thói quen Universal Actions",
                        subtitle: "Tự động đưa hành động thường chọn lên đầu danh sách theo từng định dạng tệp"
                    ) {
                        HStack(spacing: 8) {
                            if syncService.learnedActionCount > 0 {
                                Button("Đặt lại (\(syncService.learnedActionCount))") {
                                    syncService.resetActionLatching()
                                    settings.statusBannerMessage = "Đã đặt lại dữ liệu học thói quen Universal Actions."
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
            return (.secondary, "Đang tắt")
        } else if switcherController.isEventTapActive {
            return (.green, "Đang hoạt động")
        } else if hotKeyService.isWindowSwitcherCarbonFallbackActive {
            return (.green, "Chế độ phím tắt")
        } else {
            return (.orange, "Cần quyền Trợ năng")
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 1. Activation & Shortcuts
                MacSettingsSection(title: "Kích hoạt & Phím tắt") {
                    MacSettingsRow(
                        title: "Chuyển đổi tất cả cửa sổ (Windows Preview)",
                        subtitle: "Hiển thị các cửa sổ đang chạy của mọi ứng dụng kèm ảnh xem trước trực tiếp",
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
                                    MacShortcutPreset("⌘⇥ (Mặc định)", binding: .commandTab),
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
                        title: "Chuyển cửa sổ trong cùng ứng dụng",
                        subtitle: "Chuyển nhanh giữa nhiều cửa sổ của ứng dụng đang mở hiện tại"
                    ) {
                        HStack(spacing: 10) {
                            MacShortcutRecorderControl(
                                hotKeyService: hotKeyService,
                                uiState: uiState,
                                target: .sameAppWindowSwitcher,
                                current: settings.sameAppSwitcherHotKey,
                                defaultBinding: .defaultSameAppSwitcher,
                                presets: [
                                    MacShortcutPreset("⌘` (Mặc định)", binding: .commandGrave),
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
                MacSettingsSection(title: "Hiển thị & Hành vi") {
                    MacSettingsRow(
                        title: "Phạm vi màn hình",
                        subtitle: "Chọn không gian màn hình để liệt kê cửa sổ đang mở"
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
                        title: "Giữ bảng chọn mở sau khi nhả phím ⌘",
                        subtitle: "Cho phép dùng phím mũi tên điều hướng hoặc gõ từ khóa lọc cửa sổ (nhấn ↩ để chọn)",
                        isOn: Binding(
                            get: { !settings.windowSwitcherReleaseToActivate },
                            set: { settings.windowSwitcherReleaseToActivate = !$0 }
                        )
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Bấm phím Space hoặc Option để mở cửa sổ",
                        subtitle: "Mở và kích hoạt ngay cửa sổ đang chọn khi nhấn Space, Option, Command hoặc Enter",
                        isOn: $settings.windowSwitcherSpaceToActivate
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Phóng to nội dung cửa sổ đang chọn",
                        subtitle: "Hiển thị khung xem trước độ phân giải cao phía trên thanh chọn cửa sổ",
                        isOn: $settings.windowSwitcherShowZoomPreview
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Hiển thị cửa sổ đang thu nhỏ (Minimize)",
                        subtitle: "Bao gồm cửa sổ thu nhỏ dưới thanh Dock và tự động khôi phục khi chọn",
                        isOn: $settings.windowSwitcherShowMinimized
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Hiển thị ứng dụng đang ẩn (⌘H)",
                        subtitle: "Bao gồm cửa sổ của ứng dụng đang ẩn và tự động hiện lại khi chọn",
                        isOn: $settings.windowSwitcherShowHiddenApps
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Hiển thị ứng dụng không có cửa sổ",
                        subtitle: "Liệt kê thêm các ứng dụng đang chạy nền chưa mở cửa sổ nào",
                        isOn: $settings.windowSwitcherShowWindowlessApps
                    )
                }

                // 3. System Permissions
                MacSettingsSection(
                    title: "Quyền hệ thống cho Windows Preview",
                    headerTrailing: {
                        Button("Làm mới trạng thái") {
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
                        title: "Quyền Trợ năng (Accessibility)",
                        subtitle: "Bắt tổ hợp phím ⌘⇥ và chuyển tiêu điểm chính xác tới từng cửa sổ con",
                        statusDotColor: switcherService.hasAccessibilityPermission ? .green : .orange,
                        statusText: switcherService.hasAccessibilityPermission ? "Đã cấp" : "Cần cấp quyền"
                    ) {
                        if switcherService.hasAccessibilityPermission {
                            Text("Đang bật")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Cấp quyền...") {
                                switcherService.promptAccessibilityPermission()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    MacSettingsRowDivider(leadingInset: 46)

                    MacSettingsRow(
                        symbol: "rectangle.dashed.badge.record",
                        title: "Quyền Ghi màn hình (Screen Recording)",
                        subtitle: "Chụp ảnh xem trước trực tiếp nội dung thực tế của các cửa sổ",
                        statusDotColor: switcherService.hasScreenRecordingPermission ? .green : .orange,
                        statusText: switcherService.hasScreenRecordingPermission ? "Đã cấp" : "Tùy chọn"
                    ) {
                        if switcherService.hasScreenRecordingPermission {
                            Text("Đang bật")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Cấp quyền...") {
                                switcherService.promptScreenRecordingPermission()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }

                // 4. Compact Shortcut Reference Card
                MacSettingsSection(title: "Phím thao tác trong Windows Preview") {
                    ShortcutHintGridRow(
                        leftKey: "← → / ⇥",
                        leftDesc: "Di chuyển qua các cửa sổ",
                        rightKey: "↑ / ↓",
                        rightDesc: "Hiện cửa sổ cùng ứng dụng / Quay lại tất cả"
                    )
                    MacSettingsRowDivider()
                    ShortcutHintGridRow(
                        leftKey: "↩ / ⌘ / ⌥ / Space / Click",
                        leftDesc: "Mở ngay cửa sổ đang chọn",
                        rightKey: "⌃← ⌃→ ⌃↑ ⌃↓",
                        rightDesc: "Chia cửa sổ Trái / Phải / Tối đa / Giữa"
                    )
                    MacSettingsRowDivider()
                    ShortcutHintGridRow(
                        leftKey: "Gõ ký tự",
                        leftDesc: "Lọc theo tên ứng dụng hoặc cửa sổ",
                        rightKey: "⌘W / ⌘M / ⌘H / ⌘Q",
                        rightDesc: "Đóng / Thu nhỏ / Ẩn / Thoát ứng dụng"
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
            return (.green, "\(contactsService.contacts.count) liên hệ")
        } else if contactsService.authorizationStatus == .notDetermined {
            return (.secondary, "Chưa cấp quyền")
        } else {
            return (.orange, "Bị từ chối")
        }
    }

    private var contactsSubtitle: String {
        if contactsService.isAuthorized {
            return "Gõ 'c <tên không dấu, viết tắt hoặc SĐT>' rồi nhấn ↩ để xem chi tiết và chọn mục sao chép"
        } else if contactsService.authorizationStatus == .notDetermined {
            return "Cấp quyền truy cập để tìm nhanh liên hệ bằng Tiếng Việt không dấu ngay trong thanh tìm kiếm"
        } else {
            return "Mở Cài đặt Quyền riêng tư của macOS → Contacts và bật công tắc cho phép DriveBar"
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
                    title: "Danh bạ macOS ('c ')",
                    footer: "Trong màn hình chi tiết liên hệ: nhấn ↩ để sao chép, ⌘C sao chép và giữ mở, ⌥↩ sao chép và dán ngay, hoặc ⇧ để phóng to chữ."
                ) {
                    MacSettingsRow(
                        symbol: "person.crop.circle",
                        title: "Tra cứu Danh bạ Tiếng Việt không dấu",
                        subtitle: contactsSubtitle,
                        statusDotColor: contactsStatusInfo.0,
                        statusText: contactsStatusInfo.1
                    ) {
                        HStack(spacing: 6) {
                            if contactsService.isAuthorized {
                                Button("Làm mới") {
                                    contactsService.reloadContacts(force: true)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .disabled(contactsService.isLoading)
                            } else if contactsService.authorizationStatus == .notDetermined {
                                Button("Cấp quyền...") {
                                    contactsService.requestAccessIfNeeded()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            } else {
                                Button("Cài đặt Quyền...") {
                                    contactsService.openContactsPrivacySettings()
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }

                            Button("Mở ('c ')") {
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
                    Text("Lệnh Hệ thống ('s ' hoặc gõ trực tiếp từ khóa)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Mở danh sách ('s ')") {
                        LauncherViewModel.shared.prepareForSearchLaunch()
                        LauncherViewModel.shared.searchText = "s "
                        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))

                    Text("•")
                        .foregroundStyle(.tertiary)

                    Button("Khôi phục mặc định") {
                        settings.resetSystemCommandsToDefault()
                        settings.statusBannerMessage = "Đã bật toàn bộ lệnh hệ thống và khôi phục tùy chọn xác nhận mặc định."
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
                            "\(cmd.primaryKeyword) \(cmd.title) \(cmd.subtitle) \(cmd.keywords.joined(separator: " "))"
                        ).lowercased()
                        return hay.contains(normalizedFilter)
                    }

                    if !commands.isEmpty {
                        MacSettingsSection(title: category.rawValue) {
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
                Toggle("Xác nhận", isOn: Binding(
                    get: { settings.requiresSystemCommandConfirmation(command.id) },
                    set: { settings.setSystemCommandConfirmation(command.id, confirm: $0) }
                ))
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .disabled(!isEnabled)
                .help("Hiển thị hộp thoại xác nhận trước khi thực thi (giữ phím ⌥ khi nhấn ↩ để bỏ qua)")
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
                MacSettingsSection(title: "Đầu ra & Tối ưu hóa cho LLM") {
                    MacSettingsToggleRow(
                        title: "Lưu tệp .md cạnh tệp gốc",
                        subtitle: "Tạo tệp <tên_file>.md cùng thư mục khi chạy Convert to Markdown",
                        isOn: $settings.saveMarkdownBesideSource
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Tự động sao chép vào Clipboard",
                        subtitle: "Sẵn sàng dán (⌘V) ngay vào Claude, ChatGPT hoặc Gemini sau khi chuyển đổi",
                        isOn: $settings.autoCopyMarkdownToClipboard
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Chèn khối thông tin YAML Frontmatter",
                        subtitle: "Đính kèm tên tệp gốc, định dạng và thời gian chuyển đổi ở đầu tệp Markdown",
                        isOn: $settings.includeMetadataHeader
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Bọc thẻ cấu trúc XML khi gộp nhiều tệp",
                        subtitle: "Đóng gói theo chuẩn <documents><document> giúp mô hình AI phân tách ngữ cảnh",
                        isOn: $settings.wrapMultiFilesInXMLTags
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Tối ưu hóa Token & chuẩn hóa Tiếng Việt",
                        subtitle: "Chuẩn hóa Unicode NFC, xóa ký tự ẩn và gộp dòng trắng thừa (~15–25% nhẹ hơn)",
                        isOn: $settings.optimizeMarkdownTokens
                    )

                    MacSettingsRowDivider()

                    MacSettingsToggleRow(
                        title: "Nhận diện văn bản Apple Vision OCR",
                        subtitle: "Tự động trích xuất chữ Tiếng Việt và Tiếng Anh khi gặp PDF scan hoặc ảnh chụp",
                        isOn: $settings.enableVisionOCR
                    )

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: "Chia nhỏ tài liệu dài (Smart Chunking)",
                        subtitle: "Tự động tách theo mục H1/H2 vào thư mục _Chunks khi vượt ngưỡng token"
                    ) {
                        HStack(spacing: 10) {
                            if settings.enableSmartChunking {
                                Picker("", selection: $settings.smartChunkMaxTokens) {
                                    Text("15.000 tokens").tag(15_000)
                                    Text("25.000 tokens").tag(25_000)
                                    Text("40.000 tokens").tag(40_000)
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
                MacSettingsSection(title: "Bộ máy chuyển đổi (Hybrid Engines)") {
                    MacEngineStatusRow(
                        title: "AI Document Toolkit (PyMuPDF4LLM + MarkItDown)",
                        detail: diag.pythonPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Chưa cài đặt — tự động dùng bộ chuyển đổi Swift nội bộ",
                        isReady: diag.toolkitReady
                    )

                    MacSettingsRowDivider()

                    MacEngineStatusRow(
                        title: "LibreOffice Headless (.doc, .xls, .ppt, .rtf)",
                        detail: diag.sofficePath ?? "Chưa cài đặt — tự động dùng macOS textutil AST",
                        isReady: diag.libreOfficeReady
                    )

                    MacSettingsRowDivider()

                    MacEngineStatusRow(
                        title: "Google Workspace (.gdoc, .gsheet, .gslides) & Web Reader",
                        detail: "Xuất trực tiếp cấu trúc bảng biểu và bài viết sạch sang Markdown",
                        isReady: true
                    )

                    MacSettingsRowDivider()

                    MacEngineStatusRow(
                        title: "Apple Vision Neural OCR & Native Swift Fallback",
                        detail: "Hoạt động độc lập trên macOS không cần phụ thuộc bên ngoài",
                        isReady: true
                    )

                    MacSettingsRowDivider()

                    MacSettingsRow(
                        title: "Đường dẫn AI Toolkit",
                        subtitle: "Thư mục chứa môi trường Python tùy chọn"
                    ) {
                        TextField("~/Developer/AI/ai-document-toolkit", text: $settings.aiToolkitPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(width: 250)
                    }
                }

                // 3. Clean Native Drop Zone
                MacSettingsSection(title: "Chuyển đổi nhanh bằng Kéo & Thả") {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 22, weight: .regular))
                            .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                        Text("Kéo và thả tệp Word, Excel, PDF hoặc Ảnh vào đây để chuyển sang Markdown")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.primary)
                        Text("Hoặc chọn tệp trong Finder rồi nhấn \(settings.universalActionHotKey.readableDisplay)")
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
                Text(isReady ? "Sẵn sàng" : "Dự phòng")
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
                    title: "Cách gọi nhanh Universal Actions",
                    headerTrailing: {
                        if !settings.disabledActionIDs.isEmpty {
                            Button("Bật lại tất cả (\(settings.disabledActionIDs.count) đang tắt)") {
                                settings.disabledActionIDs.removeAll()
                            }
                            .buttonStyle(.link)
                            .font(.system(size: 11.5))
                        }
                    }
                ) {
                    ShortcutHintGridRow(
                        leftKey: settings.universalActionHotKey.readableDisplay,
                        leftDesc: "Mở trên tệp Finder hoặc văn bản đang chọn",
                        rightKey: "⇥ / ⇧↩",
                        rightDesc: "Mở từ kết quả tìm kiếm DriveBar"
                    )
                    MacSettingsRowDivider()
                    ShortcutHintGridRow(
                        leftKey: "⌥↑ / ⌥↓ → ⌥→",
                        leftDesc: "Gom nhiều tệp vào Buffer để xử lý hàng loạt",
                        rightKey: "⌥↩",
                        rightDesc: "Chỉ sao chép Markdown (không tạo tệp .md)"
                    )
                }

                // Categories of Actions as Native Inset-Grouped Cards
                ForEach(ActionCategory.allCases, id: \.self) { category in
                    let items = UniversalActionCatalog.all.filter { item in
                        item.category == category &&
                        (filter.isEmpty ||
                         item.title.localizedCaseInsensitiveContains(filter) ||
                         item.subtitle.localizedCaseInsensitiveContains(filter))
                    }

                    if !items.isEmpty {
                        MacSettingsSection(title: category.rawValue) {
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
