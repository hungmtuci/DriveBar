import SwiftUI
import AppKit

@MainActor
final class FolderSyncDialogController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = FolderSyncDialogController()

    private var window: NSWindow?
    @Published var currentLocalPath: String = ""
    @Published var targetDrivePath: String = ""
    @Published var selectedMode: FolderSyncMode = .twoWayMirror
    @Published var currentShareLevel: DriveShareAccessLevel = .unknown
    @Published var currentShareURL: String = ""
    @Published var isUpdatingSharePermission: Bool = false

    private override init() {
        super.init()
    }

    func present(forFolderURLs urls: [URL], instantIfSingle: Bool = false) {
        let validFolders: [String] = urls.compactMap { url in
            let p = (url.path as NSString).standardizingPath
            guard !p.isEmpty else { return nil }
            let ext = (p as NSString).pathExtension.lowercased()
            let knownFileExts: Set<String> = [
                "docx", "doc", "xlsx", "xls", "pptx", "ppt", "pdf", "txt", "md",
                "csv", "json", "py", "swift", "js", "ts", "html", "png", "jpg", "jpeg", "zip"
            ]
            if knownFileExts.contains(ext) {
                return (p as NSString).deletingLastPathComponent
            }
            return p
        }

        guard let firstFolder = validFolders.first else {
            FloatingToastController.shared.showError(
                title: L("Không tìm thấy thư mục hợp lệ", "No valid folder found"),
                subtitle: L("Hãy chọn một thư mục trên ổ cứng Mac để đồng bộ với Google Drive", "Select a folder on Mac disk to sync with Google Drive")
            )
            return
        }

        if instantIfSingle {
            for folder in validFolders {
                _ = LocalFolderDriveSyncService.shared.addOrUpdateSyncPair(
                    localPath: folder,
                    driveTargetPath: nil,
                    mode: .twoWayMirror,
                    showToast: true
                )
            }
            return
        }

        // If multiple folders selected, sync any extras and show dialog for the first (or batch)
        if validFolders.count > 1 {
            for extra in validFolders.dropFirst() {
                _ = LocalFolderDriveSyncService.shared.addOrUpdateSyncPair(
                    localPath: extra,
                    driveTargetPath: nil,
                    mode: .twoWayMirror,
                    showToast: false
                )
            }
        }

        presentDialog(forLocalPath: firstFolder, extraFolderCount: max(0, validFolders.count - 1))
    }

    func presentDialog(forLocalPath localPath: String, extraFolderCount: Int = 0) {
        LauncherPanelController.shared.hide()
        LocalFolderDriveSyncService.shared.reloadPairsFromSharedFileIfAvailable()
        let stdLocal = (localPath as NSString).standardizingPath
        self.currentLocalPath = stdLocal

        if let pair = LocalFolderDriveSyncService.shared.pair(forLocalOrDrivePath: stdLocal) {
            self.targetDrivePath = pair.driveTargetPath
            self.selectedMode = pair.syncMode
            self.currentShareLevel = pair.shareAccessLevel ?? .unknown
            self.currentShareURL = pair.shareURLString ?? ""
        } else {
            self.targetDrivePath = LocalFolderDriveSyncService.shared.suggestedDriveTargetPath(for: stdLocal)
            self.selectedMode = .twoWayMirror
            self.currentShareLevel = .unknown
            self.currentShareURL = ""
        }

        self.isUpdatingSharePermission = true
        LocalFolderDriveSyncService.shared.fetchSharePermissionStatus(forPath: stdLocal) { [weak self] res in
            guard let self else { return }
            self.isUpdatingSharePermission = false
            if res.ok {
                self.currentShareLevel = res.parsedLevel
                if let url = res.shareUrl {
                    self.currentShareURL = url
                }
            }
        }

        let rootView = FolderSyncDialogView(
            localPath: self.currentLocalPath,
            extraFolderCount: extraFolderCount,
            onClose: { [weak self] in
                self?.closeWindow()
            }
        )

        if let existing = window {
            existing.contentView = NSHostingView(rootView: rootView)
        } else {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 500),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = L("Đồng bộ Thư mục với Google Drive", "Sync Folder with Google Drive")
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.isReleasedWhenClosed = false
            win.level = .floating
            win.delegate = self
            win.contentView = NSHostingView(rootView: rootView)
            win.center()
            self.window = win
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        window?.orderOut(nil)
    }
}

private struct FolderSyncDialogView: View {
    let localPath: String
    let extraFolderCount: Int
    let onClose: () -> Void

    @ObservedObject private var syncService = LocalFolderDriveSyncService.shared
    @ObservedObject private var dialog = FolderSyncDialogController.shared

    private var existingPair: SyncedFolderPair? {
        syncService.pair(forLocalOrDrivePath: localPath)
    }

    private var folderName: String {
        (localPath as NSString).lastPathComponent
    }

    private var prettyLocalPath: String {
        (localPath as NSString).abbreviatingWithTildeInPath
    }

    private var prettyDriveTarget: String {
        if let range = dialog.targetDrivePath.range(of: "/My Drive/") {
            return "My Drive/" + dialog.targetDrivePath[range.upperBound...]
        }
        return (dialog.targetDrivePath as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color.cyan.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 46, height: 46)
                    Image(systemName: existingPair != nil ? "checkmark.icloud.fill" : "icloud.and.arrow.up.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(L("Đồng bộ Thư mục Mac ↔ Google Drive", "Sync Mac Folder ↔ Google Drive"))
                            .font(.system(size: 16, weight: .bold))

                        if existingPair != nil {
                            Text(L("ĐANG ĐỒNG BỘ", "ACTIVE SYNC"))
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.green)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.14), in: Capsule())
                        }
                    }

                    Text(
                        extraFolderCount > 0
                            ? L("Thư mục '\(folderName)' (+ \(extraFolderCount) thư mục khác đã chọn)", "Folder '\(folderName)' (+ \(extraFolderCount) other selected folders)")
                            : L("Tự động đồng bộ thư mục trên ổ cứng Mac với Google Drive đang chạy trên máy", "Automatically sync this local Mac folder with Google Drive on your Mac")
                    )
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.top, 10)

            // 1. Source & Destination Cards
            VStack(alignment: .leading, spacing: 10) {
                // Local Source Folder
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.blue)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("THƯ MỤC NGUỒN (TRÊN Ổ CỨNG MAC)", "SOURCE FOLDER (ON MAC DISK)"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(folderName)
                            .font(.system(size: 13.5, weight: .semibold))
                        Text(prettyLocalPath)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer()

                    Button(L("Mở Finder", "Reveal")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: localPath)])
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
                )

                // Destination in Google Drive
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.fill.badge.icloud")
                            .font(.system(size: 18))
                            .foregroundStyle(.teal)
                            .frame(width: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("THƯ MỤC ĐÍCH TRÊN GOOGLE DRIVE DESKTOP", "DESTINATION IN GOOGLE DRIVE DESKTOP"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text(prettyDriveTarget)
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }

                        Spacer()
                    }

                    HStack(spacing: 8) {
                        Button {
                            chooseCustomDriveDestination()
                        } label: {
                            Label(L("Chọn thư mục khác trên Google Drive...", "Choose Folder in Google Drive..."), systemImage: "folder.badge.gearshape")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button(L("Đặt mặc định (Antigravity_Sync)", "Reset to Default")) {
                            dialog.targetDrivePath = syncService.suggestedDriveTargetPath(for: localPath)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Spacer()

                        if FileManager.default.fileExists(atPath: dialog.targetDrivePath) {
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dialog.targetDrivePath)])
                            } label: {
                                Label(L("Mở trong GDrive", "Open in GDrive"), systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(12)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
                )
            }

            // 2. Sync Mode Selection
            VStack(alignment: .leading, spacing: 8) {
                Text(L("CHẾ ĐỘ ĐỒNG BỘ", "SYNC MODE"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                ForEach(FolderSyncMode.allCases) { mode in
                    Button {
                        dialog.selectedMode = mode
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: dialog.selectedMode == mode ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(dialog.selectedMode == mode ? Color.accentColor : .secondary)
                                .padding(.top, 2)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(mode.localizedTitle)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(.primary)
                                Text(mode.localizedSubtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(dialog.selectedMode == mode ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(dialog.selectedMode == mode ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            // 3. Share Permissions Card (Public Read / Public Edit / Lock Restricted)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(L("CHIA SẺ & PHÂN QUYỀN LINK GOOGLE DRIVE", "GOOGLE DRIVE LINK SHARING & PERMISSIONS"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer()

                    if dialog.isUpdatingSharePermission {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.75)
                    }

                    Text(dialog.currentShareLevel.localizedBadge)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(
                            dialog.currentShareLevel == .restricted ? Color.orange :
                            (dialog.currentShareLevel == .writer ? Color.purple :
                             (dialog.currentShareLevel == .reader ? Color.green : Color.secondary))
                        )
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            (dialog.currentShareLevel == .restricted ? Color.orange :
                             (dialog.currentShareLevel == .writer ? Color.purple :
                              (dialog.currentShareLevel == .reader ? Color.green : Color.secondary))).opacity(0.14),
                            in: Capsule()
                        )
                }

                HStack(spacing: 8) {
                    Button {
                        applyShareLevel(.reader)
                    } label: {
                        Label(
                            L("Lấy link Public (Chỉ xem)", "Public Link (View Only)"),
                            systemImage: "globe"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(dialog.currentShareLevel == .reader ? .green : .blue)
                    .controlSize(.regular)
                    .disabled(dialog.isUpdatingSharePermission)

                    Button {
                        applyShareLevel(.writer)
                    } label: {
                        Label(
                            L("Lấy link Public (Chỉnh sửa)", "Public Link (Can Edit)"),
                            systemImage: "pencil.and.outline"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(dialog.currentShareLevel == .writer ? .purple : .indigo)
                    .controlSize(.regular)
                    .disabled(dialog.isUpdatingSharePermission)

                    Button {
                        applyShareLevel(.restricted)
                    } label: {
                        Label(
                            L("Khóa lại (Chỉ mình tôi)", "Lock (Restricted)"),
                            systemImage: "lock.fill"
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(dialog.isUpdatingSharePermission)
                }

                if !dialog.currentShareURL.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "link")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Text(dialog.currentShareURL)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(dialog.currentShareURL, forType: .string)
                            FloatingToastController.shared.showSuccess(
                                title: L("Đã chép liên kết Google Drive vào Clipboard!", "Copied Google Drive link to Clipboard!"),
                                subtitle: folderName,
                                symbol: "doc.on.clipboard.fill"
                            )
                        } label: {
                            Label(L("Copy Link", "Copy Link"), systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .padding(.top, 2)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
            )

            // 4. Existing Pair Actions (if already synced)
            if let pair = existingPair {
                HStack(spacing: 10) {
                    let byteStr = ByteCountFormatter.string(fromByteCount: pair.lastSyncTotalBytes, countStyle: .file)
                    Label(
                        L("\(pair.lastSyncFileCount) tệp (\(byteStr))", "\(pair.lastSyncFileCount) files (\(byteStr))"),
                        systemImage: "doc.on.doc.fill"
                    )
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)

                    if let last = pair.lastSyncedAt {
                        Text("• " + L("Cập nhật \(last.formatted(date: .omitted, time: .standard))", "Synced \(last.formatted(date: .omitted, time: .standard))"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        if let gd = GoogleDriveIndexService.googleDriveURLs(for: pair.driveTargetPath, isDirectoryHint: true) {
                            NSWorkspace.shared.open(gd.webURL)
                        } else {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pair.driveTargetPath)])
                        }
                    } label: {
                        Label(L("Mở GDrive Web", "Open GDrive Web"), systemImage: "globe")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(role: .destructive) {
                        syncService.removeSyncPair(id: pair.id, restoreRealFolderIfSymlink: true, showToast: true)
                        onClose()
                    } label: {
                        Label(L("Ngừng đồng bộ", "Stop Sync"), systemImage: "icloud.slash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.horizontal, 4)
            }

            Divider()

            // Footer Buttons
            HStack {
                Button(L("Quản lý tất cả thư mục đồng bộ...", "Manage All Synced Folders...")) {
                    onClose()
                    SettingsUIState.shared.selectedTab = .googleDrive
                    AppDelegate.shared?.openSettingsWindow()
                }
                .buttonStyle(.link)
                .font(.system(size: 12))

                Spacer()

                Button(L("Đóng", "Cancel")) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)

                Button {
                    _ = syncService.addOrUpdateSyncPair(
                        localPath: localPath,
                        driveTargetPath: dialog.targetDrivePath,
                        mode: dialog.selectedMode,
                        showToast: true
                    )
                    onClose()
                } label: {
                    Label(
                        existingPair != nil
                            ? L("Cập nhật & Đồng bộ ngay", "Update & Sync Now")
                            : L("Bắt đầu Đồng bộ với Google Drive", "Start Syncing with Google Drive"),
                        systemImage: "arrow.triangle.2.circlepath.icloud.fill"
                    )
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(width: 610)
    }

    private func applyShareLevel(_ level: DriveShareAccessLevel) {
        if existingPair == nil {
            _ = syncService.addOrUpdateSyncPair(
                localPath: localPath,
                driveTargetPath: dialog.targetDrivePath,
                mode: dialog.selectedMode,
                showToast: false
            )
        }
        dialog.isUpdatingSharePermission = true
        syncService.setSharePermission(forPath: localPath, level: level, showToast: true) { res in
            dialog.isUpdatingSharePermission = false
            if res.ok {
                dialog.currentShareLevel = res.parsedLevel
                if let url = res.shareUrl {
                    dialog.currentShareURL = url
                }
            }
        }
    }

    private func chooseCustomDriveDestination() {
        let panel = NSOpenPanel()
        panel.title = L("Chọn thư mục trên Google Drive để chứa '\(folderName)'", "Choose a Google Drive parent folder for '\(folderName)'")
        panel.message = L("Thư mục '\(folderName)' sẽ được tạo và đồng bộ bên trong thư mục bạn chọn", "Folder '\(folderName)' will be created and synced inside the selected directory")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Chọn thư mục này", "Choose Folder")

        if let myDrive = syncService.activeMyDriveRoot() {
            panel.directoryURL = URL(fileURLWithPath: myDrive)
        }

        if panel.runModal() == .OK, let pickedURL = panel.url {
            let pickedPath = (pickedURL.path as NSString).standardizingPath
            if (pickedPath as NSString).lastPathComponent == folderName {
                dialog.targetDrivePath = pickedPath
            } else {
                dialog.targetDrivePath = (pickedPath as NSString).appendingPathComponent(folderName)
            }
        }
    }
}
