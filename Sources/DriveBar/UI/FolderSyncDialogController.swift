import SwiftUI
import AppKit

@MainActor
final class FolderSyncDialogController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = FolderSyncDialogController()

    private var window: NSWindow?
    @Published var isSharedLinkMode: Bool = false
    @Published var currentLocalPath: String = ""
    @Published var targetDrivePath: String = ""
    @Published var selectedMode: FolderSyncMode = .twoWayMirror
    @Published var currentShareLevel: DriveShareAccessLevel = .unknown
    @Published var currentShareURL: String = ""
    @Published var isUpdatingSharePermission: Bool = false

    // Shared Link Subscription properties
    @Published var sharedURLInput: String = ""
    @Published var sharedInspectResult: SharedFolderInspectResult? = nil
    @Published var isInspectingSharedURL: Bool = false
    @Published var isStartingSharedCopy: Bool = false
    @Published var sharedLocalTargetPath: String = ""
    @Published var sharedDriveMirrorPath: String = ""
    @Published var customSharedParentDir: String? = nil
    @Published var copyIntoSubfolder: Bool = true

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
            if pair.syncMode == .remoteSharedLink {
                self.isSharedLinkMode = true
                self.sharedURLInput = pair.remoteSharedURL ?? pair.shareURLString ?? ""
                self.sharedLocalTargetPath = pair.localPath
                self.sharedDriveMirrorPath = pair.driveTargetPath
                if !self.sharedURLInput.isEmpty {
                    inspectCurrentSharedURL(keepExistingPaths: true)
                }
            } else {
                self.isSharedLinkMode = false
            }
        } else {
            self.isSharedLinkMode = false
            self.targetDrivePath = LocalFolderDriveSyncService.shared.suggestedDriveTargetPath(for: stdLocal)
            self.selectedMode = .twoWayMirror
            self.currentShareLevel = .unknown
            self.currentShareURL = ""
        }

        if !self.isSharedLinkMode {
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
        }

        showDialogWindow(extraFolderCount: extraFolderCount)
    }

    func presentSharedLinkDialog(initialURL: String? = nil, targetParentDir: String? = nil) {
        LauncherPanelController.shared.hide()
        LocalFolderDriveSyncService.shared.reloadPairsFromSharedFileIfAvailable()
        self.isSharedLinkMode = true
        self.sharedInspectResult = nil

        if let targetParentDir, !targetParentDir.isEmpty {
            let stdParent = (targetParentDir as NSString).standardizingPath
            self.customSharedParentDir = stdParent
            self.currentLocalPath = stdParent
        } else {
            self.customSharedParentDir = nil
        }
        self.copyIntoSubfolder = true

        var candidateURL = (initialURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if candidateURL.isEmpty,
           let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           clip.contains("drive.google.com") || clip.contains("docs.google.com") {
            candidateURL = clip
        }

        self.sharedURLInput = candidateURL
        recomputeSharedTargetPaths(folderNameHint: nil)

        if !candidateURL.isEmpty {
            inspectCurrentSharedURL(keepExistingPaths: false)
        }

        showDialogWindow(extraFolderCount: 0)
    }

    func recomputeSharedTargetPaths(folderNameHint: String? = nil) {
        let resolvedName = (folderNameHint ?? sharedInspectResult?.folderName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = resolvedName.isEmpty ? "Shared_GDrive_Folder" : resolvedName

        if let parent = customSharedParentDir, !parent.isEmpty {
            if copyIntoSubfolder {
                self.sharedLocalTargetPath = (parent as NSString).appendingPathComponent(fallbackName)
            } else {
                self.sharedLocalTargetPath = parent
            }
            self.sharedDriveMirrorPath = LocalFolderDriveSyncService.shared.suggestedDriveTargetPath(for: self.sharedLocalTargetPath)
        } else {
            if let sugLocal = sharedInspectResult?.suggestedLocalPath, !sugLocal.isEmpty {
                self.sharedLocalTargetPath = sugLocal
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                self.sharedLocalTargetPath = "\(home)/Documents/antigravity/00. Shared_GDrive/\(fallbackName)"
            }
            if let sugDrive = sharedInspectResult?.suggestedDrivePath, !sugDrive.isEmpty {
                self.sharedDriveMirrorPath = sugDrive
            } else {
                self.sharedDriveMirrorPath = LocalFolderDriveSyncService.shared.suggestedDriveTargetPath(for: self.sharedLocalTargetPath)
            }
        }
    }

    func inspectCurrentSharedURL(keepExistingPaths: Bool = false) {
        let trimmed = sharedURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.isInspectingSharedURL = true
        LocalFolderDriveSyncService.shared.inspectSharedDriveURL(trimmed) { [weak self] res in
            guard let self else { return }
            self.isInspectingSharedURL = false
            self.sharedInspectResult = res
            if !keepExistingPaths {
                self.recomputeSharedTargetPaths(folderNameHint: res.folderName)
            }
        }
    }

    private func showDialogWindow(extraFolderCount: Int) {
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
                contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
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
    @FocusState private var isURLFieldFocused: Bool

    private var existingPair: SyncedFolderPair? {
        if dialog.isSharedLinkMode {
            let trimmedURL = dialog.sharedURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if let fid = dialog.sharedInspectResult?.folderId, !fid.isEmpty,
               let match = syncService.syncedPairs.first(where: { $0.remoteFolderID == fid }) {
                return match
            }
            if !trimmedURL.isEmpty,
               let match = syncService.syncedPairs.first(where: { $0.remoteSharedURL == trimmedURL }) {
                return match
            }
            if !dialog.sharedLocalTargetPath.isEmpty {
                return syncService.pair(forLocalOrDrivePath: dialog.sharedLocalTargetPath)
            }
            return nil
        }
        return syncService.pair(forLocalOrDrivePath: localPath)
    }

    private var folderName: String {
        if dialog.isSharedLinkMode {
            if let name = dialog.sharedInspectResult?.folderName, !name.isEmpty {
                return name
            }
            let last = (dialog.sharedLocalTargetPath as NSString).lastPathComponent
            return last.isEmpty ? "Shared_GDrive" : last
        }
        return (localPath as NSString).lastPathComponent
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
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: existingPair?.isRemoteLinkBroken == true
                                    ? [Color.red, Color.orange]
                                    : (dialog.isSharedLinkMode ? [Color.indigo, Color.teal] : [Color.blue, Color.cyan.opacity(0.85)]),
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 46, height: 46)
                    Image(
                        systemName: existingPair?.isRemoteLinkBroken == true
                            ? "exclamationmark.icloud.fill"
                            : (dialog.isSharedLinkMode ? "icloud.and.arrow.down.fill" : (existingPair != nil ? "checkmark.icloud.fill" : "icloud.and.arrow.up.fill"))
                    )
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(
                            dialog.isSharedLinkMode
                                ? L("Tải & Theo dõi Link Thư mục Google Drive được chia sẻ", "Download & Subscribe to Shared Google Drive Folder Link")
                                : L("Đồng bộ Thư mục Mac ↔ Google Drive", "Sync Mac Folder ↔ Google Drive")
                        )
                        .font(.system(size: 15.5, weight: .bold))

                        if let pair = existingPair {
                            if pair.isRemoteLinkBroken == true {
                                Text(L("⚠️ LINK ĐÃ BỊ KHÓA", "⚠️ LINK LOCKED"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.red.opacity(0.14), in: Capsule())
                            } else {
                                Text(L("ĐANG ĐỒNG BỘ", "ACTIVE SYNC"))
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.14), in: Capsule())
                            }
                        }
                    }

                    Text(
                        dialog.isSharedLinkMode
                            ? L("Tự động copy nội dung về máy, kiểm tra cập nhật mới định kỳ và giữ nguyên 100% file nếu link bị khóa", "Auto-copy shared folder to Mac, poll for updates, and preserve 100% of local files if link is locked")
                            : (extraFolderCount > 0
                                ? L("Thư mục '\(folderName)' (+ \(extraFolderCount) thư mục khác đã chọn)", "Folder '\(folderName)' (+ \(extraFolderCount) other selected folders)")
                                : L("Tự động đồng bộ thư mục trên ổ cứng Mac với Google Drive đang chạy trên máy", "Automatically sync this local Mac folder with Google Drive on your Mac"))
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.top, 8)

            // Mode Switcher Tab
            HStack(spacing: 8) {
                Button {
                    dialog.isSharedLinkMode = false
                    if dialog.currentLocalPath.isEmpty {
                        let home = FileManager.default.homeDirectoryForCurrentUser.path
                        dialog.currentLocalPath = "\(home)/Documents/antigravity"
                        dialog.targetDrivePath = syncService.suggestedDriveTargetPath(for: dialog.currentLocalPath)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "folder.fill.badge.gearshape")
                        Text(L("Thư mục trên ổ cứng Mac", "Local Mac Folder"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(!dialog.isSharedLinkMode ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(!dialog.isSharedLinkMode ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Button {
                    dialog.isSharedLinkMode = true
                    if dialog.customSharedParentDir == nil, !localPath.isEmpty {
                        dialog.customSharedParentDir = localPath
                    }
                    dialog.recomputeSharedTargetPaths(folderNameHint: dialog.sharedInspectResult?.folderName)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        isURLFieldFocused = true
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link.icloud.fill")
                        Text(L("Dán Link Copy (từ GDrive)", "Paste Shared GDrive Link"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(dialog.isSharedLinkMode ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(dialog.isSharedLinkMode ? Color.accentColor : Color(nsColor: .separatorColor), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }

            if dialog.isSharedLinkMode {
                sharedLinkModeContent
            } else {
                localFolderModeContent
            }

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
                        if let remoteURL = pair.remoteSharedURL, let url = URL(string: remoteURL) {
                            NSWorkspace.shared.open(url)
                        } else if let gd = GoogleDriveIndexService.googleDriveURLs(for: pair.driveTargetPath, isDirectoryHint: true) {
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
                    if dialog.isSharedLinkMode {
                        startSharedLinkCopyAndClose()
                    } else {
                        _ = syncService.addOrUpdateSyncPair(
                            localPath: localPath,
                            driveTargetPath: dialog.targetDrivePath,
                            mode: dialog.selectedMode,
                            showToast: true
                        )
                        onClose()
                    }
                } label: {
                    Label(
                        dialog.isSharedLinkMode
                            ? (existingPair != nil
                                ? L("Kiểm tra & Copy Cập nhật ngay", "Check & Copy Updates Now")
                                : (dialog.customSharedParentDir != nil
                                    ? L("Copy về Thư mục này & Đồng bộ", "Copy Here & Watch Updates")
                                    : L("Copy về máy & Theo dõi Đồng bộ", "Copy to Mac & Start Watching")))
                            : (existingPair != nil
                                ? L("Cập nhật & Đồng bộ ngay", "Update & Sync Now")
                                : L("Bắt đầu Đồng bộ với Google Drive", "Start Syncing with Google Drive")),
                        systemImage: dialog.isSharedLinkMode ? "icloud.and.arrow.down.fill" : "arrow.triangle.2.circlepath.icloud.fill"
                    )
                    .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(dialog.isStartingSharedCopy)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(width: 620)
    }

    private func startSharedLinkCopyAndClose() {
        let trimmedURL = dialog.sharedURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            FloatingToastController.shared.showError(
                title: L("Chưa nhập Link Google Drive", "Missing Google Drive Link"),
                subtitle: L("Hãy dán liên kết thư mục Google Drive được chia sẻ", "Please paste a shared Google Drive folder link")
            )
            return
        }

        // If user pasted link and immediately hit Copy before folderName inspection completed, fetch folderName first
        if dialog.copyIntoSubfolder, (dialog.sharedInspectResult?.folderName ?? "").isEmpty {
            dialog.isStartingSharedCopy = true
            syncService.inspectSharedDriveURL(trimmedURL) { res in
                dialog.isStartingSharedCopy = false
                dialog.sharedInspectResult = res
                dialog.recomputeSharedTargetPaths(folderNameHint: res.folderName)
                _ = syncService.addOrUpdateSharedURLSync(
                    remoteURL: trimmedURL,
                    localPath: dialog.sharedLocalTargetPath,
                    driveTargetPath: dialog.sharedDriveMirrorPath,
                    folderID: res.folderId,
                    ownerName: res.ownerName,
                    showToast: true
                )
                onClose()
            }
        } else {
            dialog.recomputeSharedTargetPaths(folderNameHint: dialog.sharedInspectResult?.folderName)
            _ = syncService.addOrUpdateSharedURLSync(
                remoteURL: trimmedURL,
                localPath: dialog.sharedLocalTargetPath,
                driveTargetPath: dialog.sharedDriveMirrorPath,
                folderID: dialog.sharedInspectResult?.folderId,
                ownerName: dialog.sharedInspectResult?.ownerName,
                showToast: true
            )
            onClose()
        }
    }

    @ViewBuilder
    private var sharedLinkModeContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Shared URL Input Card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("1. DÁN LINK THƯ MỤC GOOGLE DRIVE ĐƯỢC CHIA SẺ", "1. PASTE SHARED GOOGLE DRIVE FOLDER LINK"))
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if dialog.isInspectingSharedURL || dialog.isStartingSharedCopy {
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                            Text(L("Đang kiểm tra link...", "Inspecting link..."))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack(spacing: 8) {
                    TextField(
                        L("Dán link https://drive.google.com/drive/folders/... (⌘V)", "Paste https://drive.google.com/drive/folders/... (⌘V)"),
                        text: $dialog.sharedURLInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($isURLFieldFocused)
                    .onChange(of: dialog.sharedURLInput) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.contains("drive.google.com") || trimmed.contains("docs.google.com") {
                            dialog.inspectCurrentSharedURL(keepExistingPaths: false)
                        }
                    }
                    .onSubmit {
                        startSharedLinkCopyAndClose()
                    }

                    Button {
                        if let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !clip.isEmpty {
                            dialog.sharedURLInput = clip
                            dialog.inspectCurrentSharedURL(keepExistingPaths: false)
                        }
                    } label: {
                        Label(L("Dán Link", "Paste"), systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .controlSize(.regular)

                    Button {
                        dialog.inspectCurrentSharedURL(keepExistingPaths: false)
                    } label: {
                        Label(L("Kiểm tra", "Check"), systemImage: "magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .disabled(dialog.sharedURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || dialog.isInspectingSharedURL)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        isURLFieldFocused = true
                    }
                }

                // Inspection Status Banner
                if let res = dialog.sharedInspectResult {
                    sharedInspectBanner(res)
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
            )

            // 2. Local Folder Destination Card
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill.badge.plus")
                        .font(.system(size: 18))
                        .foregroundStyle(.blue)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(
                            dialog.customSharedParentDir != nil
                                ? L("2. THƯ MỤC ĐÍCH TRÊN FINDER (SẼ TỰ ĐỘNG COPY VỀ ĐÂY)", "2. TARGET FINDER FOLDER (AUTO-COPIED HERE)")
                                : L("2. THƯ MỤC LƯU TRÊN Ổ CỨNG MAC (TỰ ĐỘNG COPY VỀ MÁY)", "2. LOCAL MAC FOLDER (AUTO-DOWNLOADED COPY)")
                        )
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        Text((dialog.sharedLocalTargetPath as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    Spacer()
                }

                if let parent = dialog.customSharedParentDir, !parent.isEmpty {
                    let parentName = (parent as NSString).lastPathComponent
                    Toggle(isOn: Binding(
                        get: { dialog.copyIntoSubfolder },
                        set: { newVal in
                            dialog.copyIntoSubfolder = newVal
                            dialog.recomputeSharedTargetPaths(folderNameHint: dialog.sharedInspectResult?.folderName)
                        }
                    )) {
                        Text(
                            dialog.copyIntoSubfolder
                                ? L("Tạo thư mục con theo tên GDrive bên trong '\(parentName)' (Khuyên dùng)", "Create subfolder named after GDrive folder inside '\(parentName)' (Recommended)")
                                : L("Copy thẳng toàn bộ tệp trực tiếp vào trong '\(parentName)'", "Copy all files directly inside '\(parentName)'")
                        )
                        .font(.system(size: 11.5))
                    }
                    .toggleStyle(.checkbox)
                }

                HStack(spacing: 8) {
                    Button {
                        chooseCustomSharedLocalDestination()
                    } label: {
                        Label(L("Chọn thư mục khác trên Mac...", "Choose Another Mac Folder..."), systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if FileManager.default.fileExists(atPath: dialog.sharedLocalTargetPath) {
                        Button(L("Mở Finder", "Reveal")) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dialog.sharedLocalTargetPath)])
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Spacer()
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
            )

            // 3. Protection & Auto-Sync Policy Banner
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 17))
                    .foregroundStyle(.teal)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Cơ chế Đồng bộ Bảo toàn Dữ liệu (Additive Sync & Broken-Link Guard)", "Data-Preserving Sync (Additive Sync & Broken-Link Guard)"))
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        L(
                            "• Tự động tải toàn bộ thư mục con, file tài liệu & chuyển đổi Google Docs/Sheets/Slides về máy.\n• Tự động kiểm tra định kỳ: khi chủ sở hữu thêm hoặc sửa file mới, máy sẽ tự động cập nhật về.\n• Nếu chủ sở hữu khóa link hoặc xóa file: hiển thị huy hiệu cảnh báo đỏ (☁️⚠️) trên thư mục nhưng KHÔNG XÓA bất kỳ dữ liệu nào đã tải về máy.",
                            "• Downloads all subfolders, files & exports Google Docs/Sheets/Slides to Mac.\n• Polls periodically for new or updated files.\n• If link is locked or revoked: shows red warning badge (☁️⚠️) on folder without deleting any local files."
                        )
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .background(Color.teal.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.teal.opacity(0.3), lineWidth: 0.75)
            )
        }
    }

    @ViewBuilder
    private func sharedInspectBanner(_ res: SharedFolderInspectResult) -> some View {
        let resolvedName: String = res.folderName ?? folderName
        let ownerText: String = {
            if let owner = res.ownerName, !owner.isEmpty {
                return L("Chủ sở hữu: \(owner)", "Owner: \(owner)")
            }
            return ""
        }()

        if res.ok && res.isBroken != true {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.icloud.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(resolvedName)
                            .font(.system(size: 13, weight: .bold))
                        Text(L("Đang mở chia sẻ", "Accessible"))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Color.green.opacity(0.14), in: Capsule())
                    }
                    if !ownerText.isEmpty {
                        Text(ownerText)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(10)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
            )
        } else {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.icloud.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("⚠️ Link chia sẻ đã bị khóa hoặc thu hồi quyền truy cập!", "⚠️ Shared link is locked or access was revoked!"))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundStyle(.red)
                    Text(
                        L(
                            "Biểu tượng cảnh báo đứt gãy (☁️⚠️) sẽ hiển thị trên thư mục Mac, nhưng 100% dữ liệu đã tải về máy được GIỮ NGUYÊN (không xóa bất kỳ file nào).",
                            "Broken link badge (☁️⚠️) will appear on the Mac folder, while 100% of already downloaded files remain untouched."
                        )
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(10)
            .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.red.opacity(0.4), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private var localFolderModeContent: some View {
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

            ForEach(FolderSyncMode.localFolderModes) { mode in
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
    }

    private func chooseCustomSharedLocalDestination() {
        let panel = NSOpenPanel()
        panel.title = L("Chọn thư mục trên máy Mac để lưu nội dung tải về", "Choose a local Mac folder to save downloaded contents")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Chọn thư mục này", "Choose Folder")

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        panel.directoryURL = URL(fileURLWithPath: "\(home)/Documents")

        if panel.runModal() == .OK, let pickedURL = panel.url {
            let pickedPath = (pickedURL.path as NSString).standardizingPath
            dialog.customSharedParentDir = pickedPath
            dialog.recomputeSharedTargetPaths(folderNameHint: dialog.sharedInspectResult?.folderName)
        }
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
