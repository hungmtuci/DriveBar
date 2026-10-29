import SwiftUI
import AppKit
import ApplicationServices

@MainActor
final class SettingsUIState: ObservableObject {
    static let shared = SettingsUIState()

    enum Tab: String, CaseIterable {
        case general = "Chung & Google Drive"
        case aiMarkdown = "Convert sang Markdown (AI)"
        case actions = "Universal Actions"
    }

    @Published var selectedTab: Tab = .general
    @Published var isDropTargeted: Bool = false
    @Published var axTrusted: Bool = AXIsProcessTrusted()
    @Published var actionFilter: String = ""

    private init() {}
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
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.42, green: 0.16, blue: 0.85), Color(red: 0.14, green: 0.46, blue: 0.96)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 46, height: 46)
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(.white)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text("DriveBar")
                                .font(.system(size: 16.5, weight: .bold))
                            Text("v\(updater.currentVersion)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.14), in: Capsule())
                                .foregroundStyle(.purple)
                        }
                        Text("Tìm kiếm siêu tốc Google Drive & Universal Actions tối ưu Markdown cho AI")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    // Quick Toggle Show/Hide on Dock Button
                    Button {
                        settings.showDockIcon.toggle()
                        settings.statusBannerMessage = settings.showDockIcon
                            ? "Đã hiện biểu tượng DriveBar trên thanh Dock."
                            : "Đã ẩn DriveBar khỏi thanh Dock (chỉ hiện gọn trên Menu Bar)."
                    } label: {
                        Label(
                            settings.showDockIcon ? "Đang hiện trên Dock" : "Đang ẩn trên Dock",
                            systemImage: settings.showDockIcon ? "dock.arrow.up.rectangle" : "menubar.rectangle"
                        )
                        .font(.system(size: 11.5, weight: .semibold))
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
                        .foregroundStyle(.purple)
                    Text(banner)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button {
                        settings.statusBannerMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(Color.purple.opacity(0.09))
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
                        axTrusted: $uiState.axTrusted
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
            .buttonStyle(.borderedProminent)
            .tint(.purple)
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
    @Binding var axTrusted: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Dock Visibility Cards ("Nút ẩn hiện trên Dock")
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

                // 2. Global Hotkeys Section
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Phím tắt Mở thanh Tìm kiếm Google Drive")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Gõ trực tiếp từ khóa không dấu / viết tắt ('sdh', 'bm thong ke'), 'fs ' cho Shared Drives")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                if hotKeyService.recordingTarget == .search {
                                    hotKeyService.stopRecording()
                                    hotKeyService.registerAll()
                                } else {
                                    hotKeyService.startRecording(for: .search)
                                }
                            } label: {
                                Text(hotKeyService.recordingTarget == .search ? "Nhấn phím... (Esc hủy)" : settings.searchHotKey.readableDisplay)
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .frame(minWidth: 125)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(hotKeyService.recordingTarget == .search ? .orange : .purple)

                            Button("Mặc định (⌥Space)") {
                                settings.searchHotKey = .defaultSearch
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Phím tắt Universal Actions (Mọi nơi trên macOS)")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Chọn file trong Finder hoặc bôi đen văn bản bất kỳ rồi bấm phím tắt để Convert sang Markdown")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                if hotKeyService.recordingTarget == .universalAction {
                                    hotKeyService.stopRecording()
                                    hotKeyService.registerAll()
                                } else {
                                    hotKeyService.startRecording(for: .universalAction)
                                }
                            } label: {
                                Text(hotKeyService.recordingTarget == .universalAction ? "Nhấn phím... (Esc hủy)" : settings.universalActionHotKey.readableDisplay)
                                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                                    .frame(minWidth: 125)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(hotKeyService.recordingTarget == .universalAction ? .orange : .indigo)

                            Button("Mặc định (⌘⇧A)") {
                                settings.universalActionHotKey = .defaultUniversalAction
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        if let warn = hotKeyService.registrationWarning {
                            Text("⚠️ \(warn)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(8)
                } label: {
                    Label("Phím tắt Toàn cục (Chạy êm song song với Alfred 5)", systemImage: "command.square.fill")
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
                                        Text("⚡ Real-time FSEvents")
                                            .font(.system(size: 10, weight: .bold))
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
                            .tint(.purple)
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
                            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.purple)

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
                                .tint(.purple)
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
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.purple : Color.secondary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(title)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isSelected ? Color.purple : Color.secondary.opacity(0.5))
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
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.purple.opacity(0.10) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.purple.opacity(0.6) : Color.primary.opacity(0.10), lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
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
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.purple)
                    Text("Kéo & Thả bất kỳ file Word (.doc/.docx), Excel, PDF, Ảnh chụp vào đây để Convert sang Markdown ngay")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Hoặc chọn file trong Finder rồi bấm \(settings.universalActionHotKey.readableDisplay) → Convert to Markdown")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isDropTargeted ? Color.purple.opacity(0.16) : Color.purple.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                        .foregroundStyle(Color.purple.opacity(0.55))
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
                                            .foregroundStyle(.purple)
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
                .foregroundStyle(.purple)
            Text(bodyText)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
