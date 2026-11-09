import Foundation
import AppKit
import CoreServices
import Darwin

enum FolderSyncMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case twoWayMirror = "two_way_mirror"
    case symlinkToDrive = "symlink_to_drive"
    case remoteSharedLink = "remote_shared_link"

    var id: String { rawValue }

    static var localFolderModes: [FolderSyncMode] {
        [.twoWayMirror, .symlinkToDrive]
    }

    var localizedTitle: String {
        switch self {
        case .twoWayMirror:
            return L(
                "Đồng bộ 2 chiều thời gian thực (Giữ thư mục thật trên ổ Mac)",
                "Two-Way Real-Time Sync (Keep real folder on Mac disk)"
            )
        case .symlinkToDrive:
            return L(
                "Di chuyển sang Google Drive & Tạo Symlink tại ổ Mac",
                "Move to Google Drive & Create Symlink on Mac disk"
            )
        case .remoteSharedLink:
            return L(
                "Theo dõi & Tải tự động Link Google Drive được chia sẻ",
                "Auto-Pull & Monitor Shared Google Drive Link"
            )
        }
    }

    var localizedShortBadge: String {
        switch self {
        case .twoWayMirror:
            return L("2 Chiều (FSEvents)", "2-Way (FSEvents)")
        case .symlinkToDrive:
            return L("Symlink", "Symlink")
        case .remoteSharedLink:
            return L("Link Chia sẻ (Auto-Pull)", "Shared Link (Auto-Pull)")
        }
    }

    var localizedSubtitle: String {
        switch self {
        case .twoWayMirror:
            return L(
                "An toàn 100% cho Antigravity, Git, Python & chạy Offline. Mọi thay đổi ở ổ cứng Mac hoặc Google Drive đều tự động cập nhật 2 chiều tức thời.",
                "100% safe for Antigravity, Git, Python & offline work. Changes on Mac disk or Google Drive sync both ways in real time."
            )
        case .symlinkToDrive:
            return L(
                "Chuyển dữ liệu vật lý vào Google Drive và đặt liên kết tượng trưng (ln -s) ở vị trí cũ để tiết kiệm dung lượng ổ cứng.",
                "Moves physical files into Google Drive and leaves a symbolic link (ln -s) at the original Mac path to save disk space."
            )
        case .remoteSharedLink:
            return L(
                "Tự động tải nội dung thư mục chia sẻ về máy và liên tục kiểm tra cập nhật mới. Nếu link bị khóa lại, hiện cảnh báo đứt gãy nhưng không xóa dữ liệu đã tải.",
                "Automatically downloads shared folder contents and checks for updates. If locked/revoked, shows a broken-link warning without deleting downloaded files."
            )
        }
    }
}

enum DriveShareAccessLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case restricted = "restricted"
    case reader = "reader"
    case writer = "writer"
    case unknown = "unknown"

    var id: String { rawValue }

    var localizedBadge: String {
        switch self {
        case .restricted:
            return L("🔒 Đã khóa (Chỉ mình tôi)", "🔒 Locked (Restricted)")
        case .reader:
            return L("🌐 Public (Chỉ xem)", "🌐 Public (View Only)")
        case .writer:
            return L("✏️ Public (Chỉnh sửa)", "✏️ Public (Can Edit)")
        case .unknown:
            return L("☁️ Chưa kiểm tra quyền", "☁️ Unchecked")
        }
    }

    var sfSymbol: String {
        switch self {
        case .restricted: return "lock.fill"
        case .reader: return "globe"
        case .writer: return "pencil.and.outline"
        case .unknown: return "questionmark.circle"
        }
    }
}

struct DriveSharePermissionResult: Codable, Sendable {
    let ok: Bool
    let fileId: String?
    let accessLevel: String?
    let shareUrl: String?
    let errorMessage: String?

    var parsedLevel: DriveShareAccessLevel {
        DriveShareAccessLevel(rawValue: accessLevel ?? "unknown") ?? .unknown
    }
}

struct SharedFolderInspectResult: Codable, Sendable {
    let ok: Bool
    let isBroken: Bool?
    let folderId: String?
    let resourceKey: String?
    let folderName: String?
    let mimeType: String?
    let ownerName: String?
    let suggestedLocalPath: String?
    let suggestedDrivePath: String?
    let errorMessage: String?
}

struct SyncedFolderPair: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var localPath: String
    var driveTargetPath: String
    var syncMode: FolderSyncMode
    var isEnabled: Bool
    var createdAt: Date
    var lastSyncedAt: Date?
    var lastSyncFileCount: Int
    var lastSyncTotalBytes: Int64
    var lastError: String?
    var knownRelativeFiles: Set<String>
    var shareAccessLevel: DriveShareAccessLevel?
    var shareURLString: String?
    var remoteSharedURL: String?
    var remoteFolderID: String?
    var remoteOwnerName: String?
    var isRemoteLinkBroken: Bool?

    var folderName: String {
        (localPath as NSString).lastPathComponent
    }

    var prettyLocalPath: String {
        (localPath as NSString).abbreviatingWithTildeInPath
    }

    var prettyDrivePath: String {
        if let range = driveTargetPath.range(of: "/My Drive/") {
            return "My Drive/" + driveTargetPath[range.upperBound...]
        }
        return (driveTargetPath as NSString).abbreviatingWithTildeInPath
    }
}

struct SyncExecutionReport: Sendable {
    let pairID: UUID
    let copiedToDrive: Int
    let copiedToLocal: Int
    let trashedCount: Int
    let totalFiles: Int
    let totalBytes: Int64
    let errorMessage: String?
}

@MainActor
final class LocalFolderDriveSyncService: ObservableObject {
    static let shared = LocalFolderDriveSyncService()

    @Published private(set) var syncedPairs: [SyncedFolderPair] = []
    @Published private(set) var activeSyncingIDs: Set<UUID> = []
    @Published private(set) var isGlobalSyncing: Bool = false
    @Published var defaultDriveSyncSubfolder: String {
        didSet {
            UserDefaults.standard.set(defaultDriveSyncSubfolder, forKey: Self.defaultSubfolderKey)
        }
    }

    nonisolated private static let pairsStorageKey = "drivebar.localFolderSyncPairs.v1"
    nonisolated private static let defaultSubfolderKey = "drivebar.defaultDriveSyncSubfolder.v1"
    nonisolated private static let finderSyncTagVI = "Đồng bộ GDrive"

    private let syncQueue = DispatchQueue(label: "com.hunglx.DriveBar.LocalFolderDriveSyncQueue", qos: .utility)
    private var fsEventStream: FSEventStreamRef?
    private var debounceWorkItem: DispatchWorkItem?
    private var periodicTimer: Timer?
    private var lastInternalWriteTimestamp: [UUID: TimeInterval] = [:]

    nonisolated private static let ignoredDirectoryNames: Set<String> = [
        ".git", "node_modules", "__pycache__", ".build", ".swiftpm",
        ".venv", "venv", ".pytest_cache", ".mypy_cache", ".next",
        ".nuxt", ".tmp.driveupload", ".tmp", ".Trash"
    ]

    nonisolated private static let ignoredFileNames: Set<String> = [
        ".DS_Store", ".localized", "Icon\r"
    ]

    nonisolated private static let cloudStubExtensions: Set<String> = [
        "gdoc", "gsheet", "gslides", "gform", "gdraw", "gmap", "gsite", "gscript"
    ]

    private init() {
        let savedSubfolder = UserDefaults.standard.string(forKey: Self.defaultSubfolderKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let savedSubfolder, !savedSubfolder.isEmpty {
            self.defaultDriveSyncSubfolder = savedSubfolder
        } else {
            self.defaultDriveSyncSubfolder = "00. Antigravity_Sync"
        }
        loadPairs()
    }

    func start() {
        installFinderQuickActionsIfNeeded(force: true)
        reloadPairsFromSharedFileIfAvailable()
        restartFSEventsMonitor()
        startPeriodicTimer()
        // Trigger initial background sync shortly after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else { return }
            self.reloadPairsFromSharedFileIfAvailable()
            if !Self.isSyncDaemonRunning() {
                self.syncAllEnabledPairs(showToast: false)
            }
        }
    }

    // MARK: - Persistence

    nonisolated private static func sharedConfigDirPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/drivebar-sync")
    }

    nonisolated private static func sharedPairsFilePath() -> String {
        (sharedConfigDirPath() as NSString).appendingPathComponent("sync_pairs.json")
    }

    nonisolated private static func makeJSONDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .secondsSince1970
        return dec
    }

    nonisolated private static func makeJSONEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .secondsSince1970
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }

    func reloadPairsFromSharedFileIfAvailable() {
        let path = Self.sharedPairsFilePath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? Self.makeJSONDecoder().decode([SyncedFolderPair].self, from: data) else {
            return
        }
        if decoded != syncedPairs {
            let oldBrokenIDs = Set(syncedPairs.filter { $0.isRemoteLinkBroken == true }.map(\.id))
            syncedPairs = decoded
            if let encoded = try? Self.makeJSONEncoder().encode(decoded) {
                UserDefaults.standard.set(encoded, forKey: Self.pairsStorageKey)
            }
            for pair in decoded where pair.isRemoteLinkBroken == true && !oldBrokenIDs.contains(pair.id) {
                FloatingToastController.shared.showError(
                    title: L("⚠️ Link Google Drive chia sẻ đã bị khóa!", "⚠️ Shared Google Drive Link Locked!"),
                    subtitle: L(
                        "'\(pair.folderName)' • Đã giữ nguyên toàn bộ \(pair.lastSyncFileCount) tệp trên máy Mac của bạn",
                        "'\(pair.folderName)' • Kept all \(pair.lastSyncFileCount) downloaded files intact on your Mac"
                    )
                )
            }
        }
    }

    private func loadPairs() {
        let path = Self.sharedPairsFilePath()
        if let fileData = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = try? Self.makeJSONDecoder().decode([SyncedFolderPair].self, from: fileData) {
            syncedPairs = decoded
            if let encoded = try? Self.makeJSONEncoder().encode(decoded) {
                UserDefaults.standard.set(encoded, forKey: Self.pairsStorageKey)
            }
            return
        }
        if let data = UserDefaults.standard.data(forKey: Self.pairsStorageKey),
           let decoded = (try? Self.makeJSONDecoder().decode([SyncedFolderPair].self, from: data)) ?? (try? JSONDecoder().decode([SyncedFolderPair].self, from: data)) {
            syncedPairs = decoded
            savePairs()
            return
        }
        syncedPairs = []
    }

    private func savePairs() {
        guard let data = try? Self.makeJSONEncoder().encode(syncedPairs) else { return }
        UserDefaults.standard.set(data, forKey: Self.pairsStorageKey)
        let dir = Self.sharedConfigDirPath()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: Self.sharedPairsFilePath()), options: .atomic)
    }

    // MARK: - Query & Path Mapping Helpers

    func pair(forLocalOrDrivePath path: String) -> SyncedFolderPair? {
        let std = (path as NSString).standardizingPath
        return syncedPairs.first {
            (std == ($0.localPath as NSString).standardizingPath) ||
            (std == ($0.driveTargetPath as NSString).standardizingPath)
        }
    }

    func enclosingPair(forPath path: String) -> SyncedFolderPair? {
        let std = (path as NSString).standardizingPath
        for pair in syncedPairs where pair.isEnabled {
            let localStd = (pair.localPath as NSString).standardizingPath
            if std == localStd || std.hasPrefix(localStd + "/") {
                return pair
            }
            let driveStd = (pair.driveTargetPath as NSString).standardizingPath
            if std == driveStd || std.hasPrefix(driveStd + "/") {
                return pair
            }
        }
        return nil
    }

    /// Maps a local path inside a synced folder to its corresponding path inside Google Drive.
    nonisolated static func mappedDrivePath(forLocalPath path: String) -> String? {
        var pairs: [SyncedFolderPair] = []
        if let data = UserDefaults.standard.data(forKey: Self.pairsStorageKey),
           let decoded = (try? makeJSONDecoder().decode([SyncedFolderPair].self, from: data)) ?? (try? JSONDecoder().decode([SyncedFolderPair].self, from: data)) {
            pairs = decoded
        } else if let fileData = try? Data(contentsOf: URL(fileURLWithPath: sharedPairsFilePath())),
                  let decoded = try? makeJSONDecoder().decode([SyncedFolderPair].self, from: fileData) {
            pairs = decoded
        }
        guard !pairs.isEmpty else { return nil }
        let std = (path as NSString).standardizingPath
        for pair in pairs where pair.isEnabled {
            let localStd = (pair.localPath as NSString).standardizingPath
            if std == localStd {
                return pair.driveTargetPath
            }
            if std.hasPrefix(localStd + "/") {
                let rel = String(std.dropFirst(localStd.count + 1))
                return (pair.driveTargetPath as NSString).appendingPathComponent(rel)
            }
        }
        return nil
    }

    func activeMyDriveRoot() -> String? {
        if let myDrive = GoogleDriveIndexService.shared.myDrivePath,
           FileManager.default.fileExists(atPath: myDrive) {
            return myDrive
        }
        let cloudStorage = (NSHomeDirectory() as NSString).appendingPathComponent("Library/CloudStorage")
        if let items = try? FileManager.default.contentsOfDirectory(atPath: cloudStorage) {
            for item in items.sorted() where item.hasPrefix("GoogleDrive-") {
                let candidate = ((cloudStorage as NSString).appendingPathComponent(item) as NSString)
                    .appendingPathComponent("My Drive")
                if FileManager.default.fileExists(atPath: candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    /// Computes a smart default destination inside Google Drive's My Drive.
    /// If the folder is inside `~/Documents/antigravity/<Project>/<Subfolder>`, preserves `<Project>/<Subfolder>`.
    func suggestedDriveTargetPath(for localPath: String, customBaseDir: String? = nil) -> String {
        let stdLocal = (localPath as NSString).standardizingPath
        let myDrive = activeMyDriveRoot() ?? ((NSHomeDirectory() as NSString).appendingPathComponent("Library/CloudStorage/GoogleDrive/My Drive"))
        let baseRoot: String
        if let customBaseDir, !customBaseDir.isEmpty {
            baseRoot = customBaseDir
        } else {
            let sub = defaultDriveSyncSubfolder.trimmingCharacters(in: .whitespacesAndNewlines)
            baseRoot = sub.isEmpty ? myDrive : (myDrive as NSString).appendingPathComponent(sub)
        }

        let antigravityRoot = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/antigravity")
        if stdLocal.hasPrefix(antigravityRoot + "/") {
            let rel = String(stdLocal.dropFirst(antigravityRoot.count + 1))
            if !rel.isEmpty {
                return (baseRoot as NSString).appendingPathComponent(rel)
            }
        }

        let folderName = (stdLocal as NSString).lastPathComponent
        return (baseRoot as NSString).appendingPathComponent(folderName)
    }

    // MARK: - Add / Update / Remove Synced Folder Pair

    @discardableResult
    func addOrUpdateSyncPair(
        localPath: String,
        driveTargetPath: String? = nil,
        mode: FolderSyncMode = .twoWayMirror,
        showToast: Bool = true
    ) -> SyncedFolderPair? {
        let stdLocal = (localPath as NSString).standardizingPath
        guard !stdLocal.isEmpty else { return nil }

        // Prevent syncing a folder that is already inside Google Drive directly to itself
        let targetDrive = ((driveTargetPath ?? suggestedDriveTargetPath(for: stdLocal)) as NSString).standardizingPath
        if stdLocal == targetDrive {
            if showToast {
                FloatingToastController.shared.showError(
                    title: L("Thư mục nguồn và đích trùng nhau", "Source and destination folders are identical"),
                    subtitle: (stdLocal as NSString).lastPathComponent
                )
            }
            return nil
        }

        let pair: SyncedFolderPair
        if let idx = syncedPairs.firstIndex(where: { ($0.localPath as NSString).standardizingPath == stdLocal }) {
            var existing = syncedPairs[idx]
            existing.driveTargetPath = targetDrive
            existing.syncMode = mode
            existing.isEnabled = true
            existing.lastError = nil
            syncedPairs[idx] = existing
            pair = existing
        } else {
            let newPair = SyncedFolderPair(
                id: UUID(),
                localPath: stdLocal,
                driveTargetPath: targetDrive,
                syncMode: mode,
                isEnabled: true,
                createdAt: Date(),
                lastSyncedAt: nil,
                lastSyncFileCount: 0,
                lastSyncTotalBytes: 0,
                lastError: nil,
                knownRelativeFiles: []
            )
            syncedPairs.insert(newPair, at: 0)
            pair = newPair
        }

        savePairs()
        restartFSEventsMonitor()
        syncPairNow(id: pair.id, showToast: showToast)
        return pair
    }

    func removeSyncPair(id: UUID, restoreRealFolderIfSymlink: Bool = true, showToast: Bool = true) {
        guard let idx = syncedPairs.firstIndex(where: { $0.id == id }) else { return }
        let pair = syncedPairs[idx]
        syncedPairs.remove(at: idx)
        savePairs()
        restartFSEventsMonitor()

        syncQueue.async {
            Self.cleanupRemovedPairOnBackgroundQueue(pair: pair, restoreSymlink: restoreRealFolderIfSymlink)
        }

        if showToast {
            FloatingToastController.shared.showSuccess(
                title: L("Đã ngừng đồng bộ thư mục với Google Drive", "Stopped syncing folder with Google Drive"),
                subtitle: pair.folderName,
                symbol: "icloud.slash.fill"
            )
        }
    }

    func togglePairEnabled(id: UUID) {
        guard let idx = syncedPairs.firstIndex(where: { $0.id == id }) else { return }
        syncedPairs[idx].isEnabled.toggle()
        let enabled = syncedPairs[idx].isEnabled
        let idVal = syncedPairs[idx].id
        savePairs()
        restartFSEventsMonitor()
        if enabled {
            syncPairNow(id: idVal, showToast: true)
        }
    }

    // MARK: - Google Drive Share Permissions (Public Read, Public Edit, Lock/Restricted)

    func fetchSharePermissionStatus(
        forPath path: String,
        completion: (@MainActor (DriveSharePermissionResult) -> Void)? = nil
    ) {
        let resolvedDrivePath = Self.mappedDrivePath(forLocalPath: path) ?? pair(forLocalOrDrivePath: path)?.driveTargetPath ?? path
        syncQueue.async { [weak self] in
            let res = Self.runSharePermissionHelper(driveOrLocalPath: resolvedDrivePath, action: "status")
            Task { @MainActor [weak self] in
                if let self, res.ok {
                    self.updateCachedShareStatus(forPath: path, resolvedDrivePath: resolvedDrivePath, result: res)
                }
                completion?(res)
            }
        }
    }

    func setSharePermission(
        forPath path: String,
        level: DriveShareAccessLevel,
        showToast: Bool = true,
        completion: (@MainActor (DriveSharePermissionResult) -> Void)? = nil
    ) {
        let folderName = (path as NSString).lastPathComponent
        let resolvedDrivePath = Self.mappedDrivePath(forLocalPath: path) ?? pair(forLocalOrDrivePath: path)?.driveTargetPath ?? path

        if showToast {
            let progressTitle: String
            switch level {
            case .reader:
                progressTitle = L("Đang mở quyền Public (Chỉ xem) & lấy link...", "Enabling Public View & copying link...")
            case .writer:
                progressTitle = L("Đang mở quyền Public (Chỉnh sửa) & lấy link...", "Enabling Public Edit & copying link...")
            case .restricted, .unknown:
                progressTitle = L("Đang khóa link chia sẻ công khai...", "Locking public share link...")
            }
            FloatingToastController.shared.showProgress(title: progressTitle, subtitle: folderName)
        }

        syncQueue.async { [weak self] in
            let res = Self.runSharePermissionHelper(driveOrLocalPath: resolvedDrivePath, action: level.rawValue)
            Task { @MainActor [weak self] in
                if let self, res.ok {
                    self.updateCachedShareStatus(forPath: path, resolvedDrivePath: resolvedDrivePath, result: res)
                }
                if res.ok, (level == .reader || level == .writer), let urlStr = res.shareUrl {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(urlStr, forType: .string)
                }
                if showToast {
                    if res.ok {
                        switch level {
                        case .reader:
                            FloatingToastController.shared.showSuccess(
                                title: L("Đã bật Public (Chỉ xem) & Copy Link!", "Public View Enabled & Link Copied!"),
                                subtitle: "\(folderName) • \(res.shareUrl ?? "")",
                                symbol: "globe"
                            )
                        case .writer:
                            FloatingToastController.shared.showSuccess(
                                title: L("Đã bật Public (Chỉnh sửa) & Copy Link!", "Public Edit Enabled & Link Copied!"),
                                subtitle: "\(folderName) • \(res.shareUrl ?? "")",
                                symbol: "pencil.and.outline"
                            )
                        case .restricted, .unknown:
                            FloatingToastController.shared.showSuccess(
                                title: L("Đã khóa link chia sẻ Google Drive!", "Locked Google Drive Share Link!"),
                                subtitle: L("\(folderName) • Chỉ mình bạn mới có quyền truy cập", "\(folderName) • Restricted to owner only"),
                                symbol: "lock.fill"
                            )
                        }
                    } else {
                        FloatingToastController.shared.showError(
                            title: L("Không đổi được quyền chia sẻ Google Drive", "Failed to update Google Drive permissions"),
                            subtitle: res.errorMessage ?? folderName
                        )
                    }
                }
                completion?(res)
            }
        }
    }

    private func updateCachedShareStatus(forPath path: String, resolvedDrivePath: String, result: DriveSharePermissionResult) {
        let stdA = (path as NSString).standardizingPath
        let stdB = (resolvedDrivePath as NSString).standardizingPath
        if let idx = syncedPairs.firstIndex(where: {
            ($0.localPath as NSString).standardizingPath == stdA ||
            ($0.driveTargetPath as NSString).standardizingPath == stdA ||
            ($0.driveTargetPath as NSString).standardizingPath == stdB
        }) {
            syncedPairs[idx].shareAccessLevel = result.parsedLevel
            if let url = result.shareUrl {
                syncedPairs[idx].shareURLString = url
            }
            savePairs()
        }
    }

    nonisolated private static func runSharePermissionHelper(driveOrLocalPath: String, action: String) -> DriveSharePermissionResult {
        let script = helperScriptPath()
        guard FileManager.default.fileExists(atPath: script) else {
            return DriveSharePermissionResult(ok: false, fileId: nil, accessLevel: nil, shareUrl: nil, errorMessage: "Missing gdrive_folder_sync.py")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonExecutablePath())
        if action == "status" {
            proc.arguments = [script, "--share-status", driveOrLocalPath]
        } else {
            proc.arguments = [script, "--share-set", action, driveOrLocalPath]
        }
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if let decoded = try? JSONDecoder().decode(DriveSharePermissionResult.self, from: data) {
                return decoded
            }
        } catch {
            return DriveSharePermissionResult(ok: false, fileId: nil, accessLevel: nil, shareUrl: nil, errorMessage: error.localizedDescription)
        }
        return DriveSharePermissionResult(ok: false, fileId: nil, accessLevel: nil, shareUrl: nil, errorMessage: "Invalid response from helper")
    }

    // MARK: - Subscribe & Auto-Pull Shared Google Drive Folder Link

    func inspectSharedDriveURL(
        _ urlOrID: String,
        completion: @escaping @MainActor (SharedFolderInspectResult) -> Void
    ) {
        let trimmed = urlOrID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion(SharedFolderInspectResult(
                ok: false, isBroken: false, folderId: nil, resourceKey: nil,
                folderName: nil, mimeType: nil, ownerName: nil,
                suggestedLocalPath: nil, suggestedDrivePath: nil,
                errorMessage: L("Vui lòng nhập hoặc dán link Google Drive", "Please paste a Google Drive link")
            ))
            return
        }
        syncQueue.async {
            let script = Self.helperScriptPath()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: Self.pythonExecutablePath())
            proc.arguments = [script, "--inspect-shared-url", trimmed]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            var result = SharedFolderInspectResult(
                ok: false, isBroken: false, folderId: nil, resourceKey: nil,
                folderName: nil, mimeType: nil, ownerName: nil,
                suggestedLocalPath: nil, suggestedDrivePath: nil,
                errorMessage: L("Không thể kiểm tra link Google Drive", "Unable to inspect Google Drive link")
            )
            do {
                try proc.run()
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if let decoded = try? JSONDecoder().decode(SharedFolderInspectResult.self, from: data) {
                    result = decoded
                }
            } catch {
                result = SharedFolderInspectResult(
                    ok: false, isBroken: false, folderId: nil, resourceKey: nil,
                    folderName: nil, mimeType: nil, ownerName: nil,
                    suggestedLocalPath: nil, suggestedDrivePath: nil,
                    errorMessage: error.localizedDescription
                )
            }
            Task { @MainActor in
                completion(result)
            }
        }
    }

    @discardableResult
    func addOrUpdateSharedURLSync(
        remoteURL: String,
        localPath: String,
        driveTargetPath: String? = nil,
        folderID: String? = nil,
        ownerName: String? = nil,
        showToast: Bool = true
    ) -> SyncedFolderPair? {
        let stdLocal = (localPath as NSString).standardizingPath
        let cleanURL = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stdLocal.isEmpty, !cleanURL.isEmpty else { return nil }
        let targetDrive = ((driveTargetPath ?? suggestedDriveTargetPath(for: stdLocal)) as NSString).standardizingPath

        let pair: SyncedFolderPair
        if let idx = syncedPairs.firstIndex(where: {
            ($0.localPath as NSString).standardizingPath == stdLocal ||
            (folderID != nil && $0.remoteFolderID == folderID)
        }) {
            var existing = syncedPairs[idx]
            existing.localPath = stdLocal
            existing.driveTargetPath = targetDrive
            existing.syncMode = .remoteSharedLink
            existing.remoteSharedURL = cleanURL
            if let folderID { existing.remoteFolderID = folderID }
            if let ownerName { existing.remoteOwnerName = ownerName }
            existing.isEnabled = true
            existing.lastError = nil
            existing.isRemoteLinkBroken = false
            syncedPairs[idx] = existing
            pair = existing
        } else {
            let newPair = SyncedFolderPair(
                id: UUID(),
                localPath: stdLocal,
                driveTargetPath: targetDrive,
                syncMode: .remoteSharedLink,
                isEnabled: true,
                createdAt: Date(),
                lastSyncedAt: nil,
                lastSyncFileCount: 0,
                lastSyncTotalBytes: 0,
                lastError: nil,
                knownRelativeFiles: [],
                shareAccessLevel: nil,
                shareURLString: cleanURL,
                remoteSharedURL: cleanURL,
                remoteFolderID: folderID,
                remoteOwnerName: ownerName,
                isRemoteLinkBroken: false
            )
            syncedPairs.insert(newPair, at: 0)
            pair = newPair
        }

        savePairs()
        restartFSEventsMonitor()
        syncPairNow(id: pair.id, showToast: showToast)
        return pair
    }

    // MARK: - Sync Execution

    func syncAllEnabledPairs(showToast: Bool = false) {
        let enabled = syncedPairs.filter(\.isEnabled)
        guard !enabled.isEmpty else { return }
        for pair in enabled {
            syncPairNow(id: pair.id, showToast: showToast)
        }
    }

    func syncPairNow(id: UUID, showToast: Bool = true) {
        guard let pair = syncedPairs.first(where: { $0.id == id }) else { return }
        guard !activeSyncingIDs.contains(id) else { return }

        activeSyncingIDs.insert(id)
        isGlobalSyncing = !activeSyncingIDs.isEmpty

        if showToast {
            FloatingToastController.shared.showProgress(
                title: L("Đang đồng bộ với Google Drive...", "Syncing with Google Drive..."),
                subtitle: "\(pair.folderName) → \(pair.prettyDrivePath)"
            )
        }

        lastInternalWriteTimestamp[id] = Date().timeIntervalSince1970

        syncQueue.async { [weak self] in
            let (updatedPair, report) = Self.performSyncOnBackgroundQueue(pair: pair)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.lastInternalWriteTimestamp[id] = Date().timeIntervalSince1970
                self.activeSyncingIDs.remove(id)
                self.isGlobalSyncing = !self.activeSyncingIDs.isEmpty

                if let idx = self.syncedPairs.firstIndex(where: { $0.id == id }) {
                    self.syncedPairs[idx] = updatedPair
                    self.savePairs()
                }

                // Refresh DriveBar index so the new Google Drive folder is immediately searchable
                GoogleDriveIndexService.shared.noteExternalDirectoryCreated(at: updatedPair.driveTargetPath)

                if updatedPair.isRemoteLinkBroken == true {
                    FloatingToastController.shared.showError(
                        title: L("⚠️ Link Google Drive chia sẻ đã bị khóa!", "⚠️ Shared Google Drive Link Locked!"),
                        subtitle: L(
                            "'\(updatedPair.folderName)' • Đã giữ nguyên toàn bộ \(updatedPair.lastSyncFileCount) tệp trên máy Mac của bạn",
                            "'\(updatedPair.folderName)' • Kept all \(updatedPair.lastSyncFileCount) downloaded files intact on your Mac"
                        )
                    )
                } else if showToast {
                    if let err = report.errorMessage {
                        FloatingToastController.shared.showError(
                            title: L("Lỗi đồng bộ Google Drive", "Google Drive sync error"),
                            subtitle: "\(updatedPair.folderName): \(err)"
                        )
                    } else {
                        let byteStr = ByteCountFormatter.string(fromByteCount: report.totalBytes, countStyle: .file)
                        FloatingToastController.shared.showSuccess(
                            title: L("Đã đồng bộ '\(updatedPair.folderName)' với Google Drive!", "Synced '\(updatedPair.folderName)' with Google Drive!"),
                            subtitle: L(
                                "\(report.totalFiles) tệp (\(byteStr)) • Đích: \(updatedPair.prettyDrivePath)",
                                "\(report.totalFiles) files (\(byteStr)) • Target: \(updatedPair.prettyDrivePath)"
                            ),
                            symbol: "checkmark.icloud.fill"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Core Background Sync Engine

    private struct HelperSyncResponse: Decodable {
        let ok: Bool
        let isBrokenLink: Bool?
        let copiedToDrive: Int
        let copiedToLocal: Int
        let trashedCount: Int
        let totalFiles: Int
        let totalBytes: Int64
        let knownRelativeFiles: [String]
        let syncedAt: Double?
        let folderName: String?
        let ownerName: String?
        let errorMessage: String?
    }

    nonisolated private static func helperScriptPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/drivebar-sync/gdrive_folder_sync.py")
    }

    nonisolated private static func pythonExecutablePath() -> String {
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3.11") {
            return "/opt/homebrew/bin/python3.11"
        }
        if FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/python3") {
            return "/opt/homebrew/bin/python3"
        }
        return "/usr/bin/python3"
    }

    nonisolated private static func cleanupRemovedPairOnBackgroundQueue(pair: SyncedFolderPair, restoreSymlink: Bool) {
        let script = helperScriptPath()
        if FileManager.default.fileExists(atPath: script) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonExecutablePath())
            if restoreSymlink {
                proc.arguments = [script, "--restore-symlink", pair.localPath, pair.driveTargetPath]
            } else {
                proc.arguments = [script, "--untag", pair.localPath]
            }
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            return
        }
        if restoreSymlink && Self.isSymbolicLink(atPath: pair.localPath) {
            try? FileManager.default.removeItem(atPath: pair.localPath)
            if FileManager.default.fileExists(atPath: pair.driveTargetPath) {
                try? FileManager.default.copyItem(atPath: pair.driveTargetPath, toPath: pair.localPath)
            }
        }
    }

    private struct DaemonBatchResultFile: Decodable {
        let completedAt: Double
        let results: [String: HelperSyncResponse]
    }

    nonisolated private static func isSyncDaemonRunning() -> Bool {
        let pidPath = (sharedConfigDirPath() as NSString).appendingPathComponent("daemon.pid")
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr), pid > 0 else {
            return false
        }
        return Darwin.kill(pid, 0) == 0
    }

    nonisolated private static func performSyncOnBackgroundQueue(
        pair: SyncedFolderPair
    ) -> (SyncedFolderPair, SyncExecutionReport) {
        var updated = pair
        let script = helperScriptPath()
        let fm = FileManager.default

        // 1. Fast & TCC-safe path via active background daemon (~/.config/drivebar-sync/daemon.pid)
        if isSyncDaemonRunning() {
            let configDir = sharedConfigDirPath()
            let triggerPath = (configDir as NSString).appendingPathComponent("trigger.flag")
            let statusPath = (configDir as NSString).appendingPathComponent("last_sync_result.json")
            let startTime = Date().timeIntervalSince1970
            try? "sync".write(toFile: triggerPath, atomically: true, encoding: .utf8)

            let deadline = Date().addingTimeInterval(25.0)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 0.12)
                if let statusData = try? Data(contentsOf: URL(fileURLWithPath: statusPath)),
                   let batch = try? JSONDecoder().decode(DaemonBatchResultFile.self, from: statusData),
                   batch.completedAt >= startTime - 0.05 {
                    if let pairsData = try? Data(contentsOf: URL(fileURLWithPath: sharedPairsFilePath())),
                       let allPairs = try? makeJSONDecoder().decode([SyncedFolderPair].self, from: pairsData),
                       let matched = allPairs.first(where: {
                           $0.id == pair.id ||
                           ($0.localPath as NSString).standardizingPath == (pair.localPath as NSString).standardizingPath
                       }) {
                        updated = matched
                    }
                    let resp = batch.results[pair.id.uuidString] ?? batch.results[updated.id.uuidString]
                    let report = SyncExecutionReport(
                        pairID: pair.id,
                        copiedToDrive: resp?.copiedToDrive ?? 0,
                        copiedToLocal: resp?.copiedToLocal ?? 0,
                        trashedCount: resp?.trashedCount ?? 0,
                        totalFiles: resp?.totalFiles ?? updated.lastSyncFileCount,
                        totalBytes: resp?.totalBytes ?? updated.lastSyncTotalBytes,
                        errorMessage: resp?.errorMessage ?? updated.lastError
                    )
                    return (updated, report)
                }
            }
        }

        if fm.fileExists(atPath: script) {
            let statePath = "/tmp/drivebar_sync_state_\(pair.id.uuidString).json"
            let statePayload: [String: Any] = [
                "knownRelativeFiles": Array(pair.knownRelativeFiles),
                "lastSyncedAt": pair.lastSyncedAt?.timeIntervalSince1970 ?? 0.0
            ]
            if let stateData = try? JSONSerialization.data(withJSONObject: statePayload) {
                try? stateData.write(to: URL(fileURLWithPath: statePath))
            }
            defer {
                try? fm.removeItem(atPath: statePath)
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: pythonExecutablePath())
            if pair.syncMode == .remoteSharedLink, let remoteURL = pair.remoteSharedURL, !remoteURL.isEmpty {
                proc.arguments = [
                    script,
                    "--sync-shared-url", remoteURL,
                    "--local", pair.localPath,
                    "--drive", pair.driveTargetPath
                ]
            } else {
                proc.arguments = [
                    script,
                    "--local", pair.localPath,
                    "--drive", pair.driveTargetPath,
                    "--mode", pair.syncMode.rawValue,
                    "--state-file", statePath
                ]
            }
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                if let resp = try? JSONDecoder().decode(HelperSyncResponse.self, from: outData) {
                    updated.isRemoteLinkBroken = resp.isBrokenLink ?? false
                    if let owner = resp.ownerName, !owner.isEmpty {
                        updated.remoteOwnerName = owner
                    }
                    if resp.ok {
                        updated.lastSyncedAt = Date()
                        updated.lastSyncFileCount = resp.totalFiles
                        updated.lastSyncTotalBytes = resp.totalBytes
                        updated.lastError = nil
                        updated.knownRelativeFiles = Set(resp.knownRelativeFiles)
                        let report = SyncExecutionReport(
                            pairID: pair.id,
                            copiedToDrive: resp.copiedToDrive,
                            copiedToLocal: resp.copiedToLocal,
                            trashedCount: resp.trashedCount,
                            totalFiles: resp.totalFiles,
                            totalBytes: resp.totalBytes,
                            errorMessage: nil
                        )
                        return (updated, report)
                    } else {
                        let errMsg = resp.errorMessage ?? "Sync helper failed"
                        updated.lastError = errMsg
                        updated.lastSyncFileCount = resp.totalFiles > 0 ? resp.totalFiles : updated.lastSyncFileCount
                        updated.lastSyncTotalBytes = resp.totalBytes > 0 ? resp.totalBytes : updated.lastSyncTotalBytes
                        let report = SyncExecutionReport(
                            pairID: pair.id,
                            copiedToDrive: 0,
                            copiedToLocal: 0,
                            trashedCount: 0,
                            totalFiles: updated.lastSyncFileCount,
                            totalBytes: updated.lastSyncTotalBytes,
                            errorMessage: errMsg
                        )
                        return (updated, report)
                    }
                }
            } catch {
                // Fall through to native Swift engine if subprocess fails to launch
            }
        }

        do {
            // Ensure parent of driveTargetPath exists
            let driveParent = (pair.driveTargetPath as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: driveParent) {
                try fm.createDirectory(atPath: driveParent, withIntermediateDirectories: true)
            }

            if pair.syncMode == .symlinkToDrive {
                return try performSymlinkModeSync(pair: pair)
            }

            // If localPath was previously a symlink (e.g. user switched from symlinkToDrive back to twoWayMirror),
            // materialize it back as a real directory first.
            if isSymbolicLink(atPath: pair.localPath) {
                try fm.removeItem(atPath: pair.localPath)
                if fm.fileExists(atPath: pair.driveTargetPath) {
                    try fm.copyItem(atPath: pair.driveTargetPath, toPath: pair.localPath)
                } else {
                    try fm.createDirectory(atPath: pair.localPath, withIntermediateDirectories: true)
                }
            }

            if !fm.fileExists(atPath: pair.localPath) {
                try fm.createDirectory(atPath: pair.localPath, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: pair.driveTargetPath) {
                try fm.createDirectory(atPath: pair.driveTargetPath, withIntermediateDirectories: true)
            }

            let localScan = scanDirectoryTree(rootPath: pair.localPath, isCloudStorage: false)
            let driveScan = scanDirectoryTree(rootPath: pair.driveTargetPath, isCloudStorage: true)

            let previousKnownFiles = pair.knownRelativeFiles
            let lastSyncDate = pair.lastSyncedAt ?? .distantPast

            var copiedToDrive = 0
            var copiedToLocal = 0
            var trashedCount = 0

            // 1. Sync Directories
            let allDirs = localScan.directories.union(driveScan.directories).sorted()
            for relDir in allDirs {
                let lDir = (pair.localPath as NSString).appendingPathComponent(relDir)
                let dDir = (pair.driveTargetPath as NSString).appendingPathComponent(relDir)
                let inLocal = localScan.directories.contains(relDir)
                let inDrive = driveScan.directories.contains(relDir)

                if inLocal && !inDrive {
                    let hadTrackedFilesBefore = previousKnownFiles.contains { $0.hasPrefix(relDir + "/") }
                    if !hadTrackedFilesBefore {
                        try? fm.createDirectory(atPath: dDir, withIntermediateDirectories: true)
                    }
                } else if inDrive && !inLocal {
                    let hadTrackedFilesBefore = previousKnownFiles.contains { $0.hasPrefix(relDir + "/") }
                    if !hadTrackedFilesBefore {
                        try? fm.createDirectory(atPath: lDir, withIntermediateDirectories: true)
                    }
                }
            }

            // 2. Sync Files (Two-way delta resolution)
            let allRelFiles = Set(localScan.files.keys).union(driveScan.files.keys)
            var currentKnownFiles = Set<String>()

            for relFile in allRelFiles.sorted() {
                let lPath = (pair.localPath as NSString).appendingPathComponent(relFile)
                let dPath = (pair.driveTargetPath as NSString).appendingPathComponent(relFile)
                let lMeta = localScan.files[relFile]
                let dMeta = driveScan.files[relFile]

                switch (lMeta, dMeta) {
                case let (.some(l), .some(d)):
                    let timeDiff = l.mtime.timeIntervalSince(d.mtime)
                    if abs(timeDiff) <= 2.0 && l.size == d.size {
                        // Already identical
                        currentKnownFiles.insert(relFile)
                    } else if timeDiff > 2.0 || (abs(timeDiff) <= 2.0 && l.mtime >= d.mtime) {
                        // Local is newer -> copy to Google Drive
                        if copyFileAtomically(from: lPath, to: dPath, mtime: l.mtime) {
                            copiedToDrive += 1
                        }
                        currentKnownFiles.insert(relFile)
                    } else {
                        // Google Drive is newer -> copy to Local Mac (skip if cloud stub or dataless unmaterialized)
                        if !d.isDataless && !d.isCloudStub {
                            if copyFileAtomically(from: dPath, to: lPath, mtime: d.mtime) {
                                copiedToLocal += 1
                            }
                        }
                        currentKnownFiles.insert(relFile)
                    }

                case let (.some(l), .none):
                    // Exists only on Local Mac
                    let wasKnown = previousKnownFiles.contains(relFile)
                    if wasKnown && l.mtime <= lastSyncDate.addingTimeInterval(2.0) {
                        // File was deleted on Google Drive -> move local copy to Trash safely
                        if (try? fm.trashItem(at: URL(fileURLWithPath: lPath), resultingItemURL: nil)) != nil {
                            trashedCount += 1
                        }
                    } else {
                        // New or newly updated file on Local Mac -> copy to Google Drive
                        if copyFileAtomically(from: lPath, to: dPath, mtime: l.mtime) {
                            copiedToDrive += 1
                            currentKnownFiles.insert(relFile)
                        }
                    }

                case let (.none, .some(d)):
                    // Exists only on Google Drive
                    let wasKnown = previousKnownFiles.contains(relFile)
                    if wasKnown && d.mtime <= lastSyncDate.addingTimeInterval(2.0) {
                        // File was deleted on Local Mac -> move Google Drive copy to Trash safely
                        if (try? fm.trashItem(at: URL(fileURLWithPath: dPath), resultingItemURL: nil)) != nil {
                            trashedCount += 1
                        }
                    } else if !d.isDataless && !d.isCloudStub {
                        // New file added on Google Drive -> copy to Local Mac
                        if copyFileAtomically(from: dPath, to: lPath, mtime: d.mtime) {
                            copiedToLocal += 1
                            currentKnownFiles.insert(relFile)
                        }
                    } else {
                        currentKnownFiles.insert(relFile)
                    }

                case (.none, .none):
                    break
                }
            }

            // Compute final file count & total size from local scan
            let finalScan = scanDirectoryTree(rootPath: pair.localPath, isCloudStorage: false)
            let totalFiles = finalScan.files.count
            let totalBytes = finalScan.files.values.reduce(Int64(0)) { $0 + $1.size }

            updated.lastSyncedAt = Date()
            updated.lastSyncFileCount = totalFiles
            updated.lastSyncTotalBytes = totalBytes
            updated.lastError = nil
            updated.knownRelativeFiles = currentKnownFiles

            let report = SyncExecutionReport(
                pairID: pair.id,
                copiedToDrive: copiedToDrive,
                copiedToLocal: copiedToLocal,
                trashedCount: trashedCount,
                totalFiles: totalFiles,
                totalBytes: totalBytes,
                errorMessage: nil
            )
            return (updated, report)
        } catch {
            updated.lastError = error.localizedDescription
            let report = SyncExecutionReport(
                pairID: pair.id,
                copiedToDrive: 0,
                copiedToLocal: 0,
                trashedCount: 0,
                totalFiles: updated.lastSyncFileCount,
                totalBytes: updated.lastSyncTotalBytes,
                errorMessage: error.localizedDescription
            )
            return (updated, report)
        }
    }

    nonisolated private static func performSymlinkModeSync(
        pair: SyncedFolderPair
    ) throws -> (SyncedFolderPair, SyncExecutionReport) {
        var updated = pair
        let fm = FileManager.default

        if !fm.fileExists(atPath: pair.driveTargetPath) {
            try fm.createDirectory(atPath: pair.driveTargetPath, withIntermediateDirectories: true)
        }

        if !isSymbolicLink(atPath: pair.localPath) {
            // Merge all existing files from localPath into driveTargetPath first
            let localScan = scanDirectoryTree(rootPath: pair.localPath, isCloudStorage: false)
            for relDir in localScan.directories.sorted() {
                let dDir = (pair.driveTargetPath as NSString).appendingPathComponent(relDir)
                try? fm.createDirectory(atPath: dDir, withIntermediateDirectories: true)
            }
            for (relFile, meta) in localScan.files {
                let lPath = (pair.localPath as NSString).appendingPathComponent(relFile)
                let dPath = (pair.driveTargetPath as NSString).appendingPathComponent(relFile)
                _ = copyFileAtomically(from: lPath, to: dPath, mtime: meta.mtime)
            }
            // Move original local folder to Trash for safety, then create symlink at localPath
            try fm.trashItem(at: URL(fileURLWithPath: pair.localPath), resultingItemURL: nil)
            try fm.createSymbolicLink(atPath: pair.localPath, withDestinationPath: pair.driveTargetPath)
        } else {
            // Verify symlink points to driveTargetPath
            let dest = (try? fm.destinationOfSymbolicLink(atPath: pair.localPath)) ?? ""
            if (dest as NSString).standardizingPath != (pair.driveTargetPath as NSString).standardizingPath {
                try? fm.removeItem(atPath: pair.localPath)
                try fm.createSymbolicLink(atPath: pair.localPath, withDestinationPath: pair.driveTargetPath)
            }
        }

        let driveScan = scanDirectoryTree(rootPath: pair.driveTargetPath, isCloudStorage: true)
        let totalFiles = driveScan.files.count
        let totalBytes = driveScan.files.values.reduce(Int64(0)) { $0 + $1.size }

        updated.lastSyncedAt = Date()
        updated.lastSyncFileCount = totalFiles
        updated.lastSyncTotalBytes = totalBytes
        updated.lastError = nil
        updated.knownRelativeFiles = Set(driveScan.files.keys)

        let report = SyncExecutionReport(
            pairID: pair.id,
            copiedToDrive: totalFiles,
            copiedToLocal: 0,
            trashedCount: 0,
            totalFiles: totalFiles,
            totalBytes: totalBytes,
            errorMessage: nil
        )
        return (updated, report)
    }

    // MARK: - Directory Scanner & Atomic File Copy

    private struct ScannedFileMeta: Sendable {
        let mtime: Date
        let size: Int64
        let isDataless: Bool
        let isCloudStub: Bool
    }

    private struct DirectoryScanResult: Sendable {
        var directories: Set<String> = []
        var files: [String: ScannedFileMeta] = [:]
    }

    nonisolated private static func scanDirectoryTree(rootPath: String, isCloudStorage: Bool) -> DirectoryScanResult {
        var result = DirectoryScanResult()
        let fm = FileManager.default
        let stdRoot = (rootPath as NSString).standardizingPath
        guard let enumerator = fm.enumerator(atPath: stdRoot) else { return result }

        while let relObj = enumerator.nextObject() as? String {
            let name = (relObj as NSString).lastPathComponent
            if name.isEmpty { continue }

            // Check ignored directories/files
            if ignoredDirectoryNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if ignoredFileNames.contains(name) || name.hasPrefix("~$") || name.hasPrefix(".~") || name.hasPrefix(".tmp") {
                continue
            }

            let fullPath = (stdRoot as NSString).appendingPathComponent(relObj)
            var st = Darwin.stat()
            guard Darwin.lstat(fullPath, &st) == 0 else { continue }

            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK {
                // Do not traverse nested symlinks inside a synced tree
                continue
            } else if mode == S_IFDIR {
                result.directories.insert(relObj)
            } else if mode == S_IFREG {
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000.0)
                let size = Int64(st.st_size)
                let isDataless = isCloudStorage && ((st.st_flags & UInt32(SF_DATALESS)) != 0)
                let ext = (name as NSString).pathExtension.lowercased()
                let isStub = cloudStubExtensions.contains(ext)
                result.files[relObj] = ScannedFileMeta(
                    mtime: mtime,
                    size: size,
                    isDataless: isDataless,
                    isCloudStub: isStub
                )
            }
        }
        return result
    }

    nonisolated private static func copyFileAtomically(from srcPath: String, to dstPath: String, mtime: Date) -> Bool {
        let fm = FileManager.default
        let dstParent = (dstPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: dstParent) {
            try? fm.createDirectory(atPath: dstParent, withIntermediateDirectories: true)
        }

        let tempPath = dstParent + "/.drivebar_sync_tmp_\(UUID().uuidString)"
        do {
            if fm.fileExists(atPath: tempPath) {
                try? fm.removeItem(atPath: tempPath)
            }
            try fm.copyItem(atPath: srcPath, toPath: tempPath)
            try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: tempPath)

            if fm.fileExists(atPath: dstPath) {
                _ = try fm.replaceItemAt(
                    URL(fileURLWithPath: dstPath),
                    withItemAt: URL(fileURLWithPath: tempPath),
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try fm.moveItem(atPath: tempPath, toPath: dstPath)
            }
            try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: dstPath)
            return true
        } catch {
            try? fm.removeItem(atPath: tempPath)
            return false
        }
    }

    nonisolated static func isSymbolicLink(atPath path: String) -> Bool {
        var st = Darwin.stat()
        guard Darwin.lstat(path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    // MARK: - Real-time FSEvents Monitor & Periodic Timer

    private func startPeriodicTimer() {
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: 6.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadPairsFromSharedFileIfAvailable()
                if !Self.isSyncDaemonRunning() {
                    self.syncAllEnabledPairs(showToast: false)
                }
            }
        }
    }

    private func restartFSEventsMonitor() {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            fsEventStream = nil
        }

        let enabledPairs = syncedPairs.filter { $0.isEnabled && $0.syncMode == .twoWayMirror }
        var watchedPaths: [String] = []
        for pair in enabledPairs {
            if FileManager.default.fileExists(atPath: pair.driveTargetPath) {
                watchedPaths.append(pair.driveTargetPath)
            }
        }
        guard !watchedPaths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
            guard let info = clientCallBackInfo else { return }
            let service = Unmanaged<LocalFolderDriveSyncService>.fromOpaque(info).takeUnretainedValue()
            guard let pathsArray = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
            let changed = Array(pathsArray.prefix(numEvents))
            Task { @MainActor in
                service.handleFSEvents(changedPaths: changed)
            }
        }

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer
        )

        if let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            watchedPaths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            flags
        ) {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
            fsEventStream = stream
        }
    }

    private func handleFSEvents(changedPaths: [String]) {
        let now = Date().timeIntervalSince1970
        var triggeredPairIDs = Set<UUID>()

        for rawPath in changedPaths {
            let name = (rawPath as NSString).lastPathComponent
            if Self.ignoredFileNames.contains(name) ||
               name.hasPrefix(".drivebar_sync_tmp_") ||
               name.hasPrefix("~$") ||
               name.hasPrefix(".tmp") {
                continue
            }
            if let pair = enclosingPair(forPath: rawPath), pair.syncMode == .twoWayMirror {
                if let lastInternal = lastInternalWriteTimestamp[pair.id], now - lastInternal < 2.2 {
                    continue
                }
                triggeredPairIDs.insert(pair.id)
            }
        }

        guard !triggeredPairIDs.isEmpty else { return }

        debounceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for id in triggeredPairIDs {
                    self.syncPairNow(id: id, showToast: false)
                }
            }
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: - Finder Visual Tag Helper

    private func applyFinderSyncTag(to path: String, synced: Bool) {
        let url = URL(fileURLWithPath: path)
        let nsURL = url as NSURL
        var existingTags: [String] = []
        if let vals = try? url.resourceValues(forKeys: [.tagNamesKey]),
           let tags = vals.tagNames {
            existingTags = tags
        }
        if synced {
            if !existingTags.contains(Self.finderSyncTagVI) {
                existingTags.append(Self.finderSyncTagVI)
                try? nsURL.setResourceValue(existingTags, forKey: .tagNamesKey)
            }
        } else {
            let filtered = existingTags.filter { $0 != Self.finderSyncTagVI }
            if filtered.count != existingTags.count {
                try? nsURL.setResourceValue(filtered, forKey: .tagNamesKey)
            }
        }
    }

    // MARK: - Install Finder Right-Click Quick Actions (.workflow in ~/Library/Services)

    func installFinderQuickActionsIfNeeded(force: Bool = false) {
        let servicesDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Services")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: servicesDir, withIntermediateDirectories: true)

        // Remove legacy 2-button workflows so only 1 clean button remains
        let legacyNames = [
            "Đồng bộ với Google Drive (DriveBar).workflow",
            "Đồng bộ nhanh vào Google Drive.workflow"
        ]
        for legacy in legacyNames {
            let legacyPath = (servicesDir as NSString).appendingPathComponent(legacy)
            if fm.fileExists(atPath: legacyPath) {
                try? fm.removeItem(atPath: legacyPath)
            }
        }

        // Single clean Quick Action: "Đồng bộ với Google Drive.workflow"
        let singleWorkflowDir = (servicesDir as NSString).appendingPathComponent("Đồng bộ với Google Drive.workflow")
        installSingleWorkflow(
            at: singleWorkflowDir,
            bundleID: "com.hunglx.DriveBar.FinderQuickAction.SyncFolder",
            menuTitle: "Đồng bộ với Google Drive",
            mode: "instant",
            symbolName: "icloud.and.arrow.up.fill",
            force: force
        )

        // Refresh macOS Services & Quick Actions cache
        Task.detached(priority: .utility) {
            let pbs = Process()
            pbs.executableURL = URL(fileURLWithPath: "/System/Library/CoreServices/pbs")
            pbs.arguments = ["-update"]
            pbs.standardOutput = FileHandle.nullDevice
            pbs.standardError = FileHandle.nullDevice
            try? pbs.run()
            pbs.waitUntilExit()
        }
    }

    private func installSingleWorkflow(
        at workflowDir: String,
        bundleID: String,
        menuTitle: String,
        mode: String,
        symbolName: String,
        force: Bool
    ) {
        let contentsDir = (workflowDir as NSString).appendingPathComponent("Contents")
        let infoPlistPath = (contentsDir as NSString).appendingPathComponent("Info.plist")
        let wflowPath = (contentsDir as NSString).appendingPathComponent("document.wflow")

        if !force && FileManager.default.fileExists(atPath: infoPlistPath) && FileManager.default.fileExists(atPath: wflowPath) {
            return
        }

        try? FileManager.default.createDirectory(atPath: contentsDir, withIntermediateDirectories: true)

        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleDevelopmentRegion</key>
            <string>vi_VN</string>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
            <key>CFBundleName</key>
            <string>\(menuTitle)</string>
            <key>CFBundleShortVersionString</key>
            <string>1.0</string>
            <key>NSServices</key>
            <array>
                <dict>
                    <key>NSIconName</key>
                    <string>\(symbolName)</string>
                    <key>NSMenuItem</key>
                    <dict>
                        <key>default</key>
                        <string>\(menuTitle)</string>
                    </dict>
                    <key>NSMessage</key>
                    <string>runWorkflowAsService</string>
                    <key>NSRequiredContext</key>
                    <dict>
                        <key>NSApplicationIdentifier</key>
                        <array>
                            <string>com.apple.finder</string>
                        </array>
                    </dict>
                    <key>NSSendFileTypes</key>
                    <array>
                        <string>public.folder</string>
                        <string>public.directory</string>
                        <string>public.item</string>
                    </array>
                </dict>
            </array>
        </dict>
        </plist>
        """

        let rawShellCommand = """
        #!/bin/bash
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
        HELPER="$HOME/.config/drivebar-sync/gdrive_folder_sync.py"
        BUNDLED="/Applications/DriveBar.app/Contents/Resources/gdrive_folder_sync.py"
        if [ ! -f "$HELPER" ]; then
            mkdir -p "$HOME/.config/drivebar-sync"
            cp "$BUNDLED" "$HELPER"
            chmod +x "$HELPER"
        fi
        /opt/homebrew/bin/python3.11 "$HELPER" --quick-action "$@"
        """
        let shellCommand = rawShellCommand
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")

        let documentWflow = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>AMApplicationBuild</key>
            <string>521.1</string>
            <key>AMApplicationVersion</key>
            <string>2.10</string>
            <key>AMDocumentVersion</key>
            <string>2</string>
            <key>actions</key>
            <array>
                <dict>
                    <key>action</key>
                    <dict>
                        <key>AMAccepts</key>
                        <dict>
                            <key>Container</key>
                            <string>List</string>
                            <key>Optional</key>
                            <true/>
                            <key>Types</key>
                            <array>
                                <string>com.apple.cocoa.path</string>
                            </array>
                        </dict>
                        <key>AMActionVersion</key>
                        <string>2.0.3</string>
                        <key>AMApplication</key>
                        <array>
                            <string>Automator</string>
                        </array>
                        <key>AMParameterProperties</key>
                        <dict>
                            <key>COMMAND_STRING</key>
                            <dict/>
                            <key>CheckedForUserDefaultShell</key>
                            <dict/>
                            <key>inputMethod</key>
                            <dict/>
                            <key>shell</key>
                            <dict/>
                            <key>source</key>
                            <dict/>
                        </dict>
                        <key>AMProvides</key>
                        <dict>
                            <key>Container</key>
                            <string>List</string>
                            <key>Types</key>
                            <array>
                                <string>com.apple.cocoa.path</string>
                            </array>
                        </dict>
                        <key>ActionBundlePath</key>
                        <string>/System/Library/Automator/Run Shell Script.action</string>
                        <key>ActionName</key>
                        <string>Run Shell Script</string>
                        <key>ActionParameters</key>
                        <dict>
                            <key>COMMAND_STRING</key>
                            <string>\(shellCommand)</string>
                            <key>CheckedForUserDefaultShell</key>
                            <true/>
                            <key>inputMethod</key>
                            <integer>1</integer>
                            <key>shell</key>
                            <string>/bin/bash</string>
                            <key>source</key>
                            <string></string>
                        </dict>
                        <key>BundleIdentifier</key>
                        <string>com.apple.RunShellScript</string>
                        <key>CFBundleVersion</key>
                        <string>2.0.3</string>
                        <key>CanShowSelectedItemsWhenRun</key>
                        <false/>
                        <key>CanShowWhenRun</key>
                        <true/>
                        <key>Category</key>
                        <array>
                            <string>AMCategoryUtilities</string>
                        </array>
                        <key>Class Name</key>
                        <string>RunShellScriptAction</string>
                        <key>InputUUID</key>
                        <string>3F265FDB-9646-44D2-9D39-2ADE717170A1</string>
                        <key>Keywords</key>
                        <array>
                            <string>Shell</string>
                            <string>Script</string>
                        </array>
                        <key>OutputUUID</key>
                        <string>B29A7419-B840-4347-8CA2-BE8EE5D1B8B2</string>
                        <key>UUID</key>
                        <string>C744CDC0-D806-4EC6-AC4C-E934D09810C3</string>
                        <key>UnlocalizedApplications</key>
                        <array>
                            <string>Automator</string>
                        </array>
                        <key>arguments</key>
                        <dict/>
                        <key>isViewVisible</key>
                        <integer>1</integer>
                    </dict>
                    <key>isViewVisible</key>
                    <integer>1</integer>
                </dict>
            </array>
            <key>connectors</key>
            <dict/>
            <key>workflowMetaData</key>
            <dict>
                <key>applicationBundleIDsByPath</key>
                <dict>
                    <key>/System/Library/CoreServices/Finder.app</key>
                    <string>com.apple.finder</string>
                </dict>
                <key>applicationPaths</key>
                <array>
                    <string>/System/Library/CoreServices/Finder.app</string>
                </array>
                <key>inputTypeIdentifier</key>
                <string>com.apple.Automator.fileSystemObject</string>
                <key>outputTypeIdentifier</key>
                <string>com.apple.Automator.nothing</string>
                <key>presentationMode</key>
                <integer>15</integer>
                <key>processesInput</key>
                <integer>0</integer>
                <key>serviceApplicationBundleID</key>
                <string>com.apple.finder</string>
                <key>serviceApplicationPath</key>
                <string>/System/Library/CoreServices/Finder.app</string>
                <key>serviceInputTypeIdentifier</key>
                <string>com.apple.Automator.fileSystemObject</string>
                <key>serviceOutputTypeIdentifier</key>
                <string>com.apple.Automator.nothing</string>
                <key>serviceProcessesInput</key>
                <integer>0</integer>
                <key>systemImageName</key>
                <string>\(symbolName)</string>
                <key>useAutomaticInputType</key>
                <integer>0</integer>
                <key>workflowTypeIdentifier</key>
                <string>com.apple.Automator.servicesMenu</string>
            </dict>
        </dict>
        </plist>
        """

        try? infoPlist.write(toFile: infoPlistPath, atomically: true, encoding: .utf8)
        try? documentWflow.write(toFile: wflowPath, atomically: true, encoding: .utf8)
    }
}
