import Foundation
import AppKit
import CoreServices
import Darwin
import os

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

struct PendingDeletionPlan: Codable, Equatable, Sendable {
    var localDeletes: [String]
    var driveDeletes: [String]
    var localFileCount: Int
    var driveFileCount: Int
    var baselineFileCount: Int
    var reason: String

    var totalPlannedDeletes: Int {
        localDeletes.count + driveDeletes.count
    }
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
    var status: String?
    var pendingDeletionPlan: PendingDeletionPlan?
    var lastConflicts: [String]?

    enum CodingKeys: String, CodingKey {
        case id, localPath, driveTargetPath, syncMode, isEnabled
        case createdAt, lastSyncedAt, lastSyncFileCount, lastSyncTotalBytes
        case lastError, knownRelativeFiles, shareAccessLevel, shareURLString
        case remoteSharedURL, remoteFolderID, remoteOwnerName, isRemoteLinkBroken
        case status, pendingDeletionPlan, lastConflicts
    }

    init(
        id: UUID,
        localPath: String,
        driveTargetPath: String,
        syncMode: FolderSyncMode,
        isEnabled: Bool,
        createdAt: Date,
        lastSyncedAt: Date?,
        lastSyncFileCount: Int,
        lastSyncTotalBytes: Int64,
        lastError: String?,
        knownRelativeFiles: Set<String> = [],
        shareAccessLevel: DriveShareAccessLevel? = nil,
        shareURLString: String? = nil,
        remoteSharedURL: String? = nil,
        remoteFolderID: String? = nil,
        remoteOwnerName: String? = nil,
        isRemoteLinkBroken: Bool? = nil,
        status: String? = "ok",
        pendingDeletionPlan: PendingDeletionPlan? = nil,
        lastConflicts: [String]? = nil
    ) {
        self.id = id
        self.localPath = localPath
        self.driveTargetPath = driveTargetPath
        self.syncMode = syncMode
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.lastSyncedAt = lastSyncedAt
        self.lastSyncFileCount = lastSyncFileCount
        self.lastSyncTotalBytes = lastSyncTotalBytes
        self.lastError = lastError
        self.knownRelativeFiles = knownRelativeFiles
        self.shareAccessLevel = shareAccessLevel
        self.shareURLString = shareURLString
        self.remoteSharedURL = remoteSharedURL
        self.remoteFolderID = remoteFolderID
        self.remoteOwnerName = remoteOwnerName
        self.isRemoteLinkBroken = isRemoteLinkBroken
        self.status = status
        self.pendingDeletionPlan = pendingDeletionPlan
        self.lastConflicts = lastConflicts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let uuidVal = try? c.decode(UUID.self, forKey: .id) {
            self.id = uuidVal
        } else if let strVal = try? c.decode(String.self, forKey: .id), let parsed = UUID(uuidString: strVal) {
            self.id = parsed
        } else {
            self.id = UUID()
        }
        self.localPath = (try? c.decode(String.self, forKey: .localPath)) ?? ""
        self.driveTargetPath = (try? c.decode(String.self, forKey: .driveTargetPath)) ?? ""
        self.syncMode = (try? c.decode(FolderSyncMode.self, forKey: .syncMode)) ?? .twoWayMirror
        self.isEnabled = (try? c.decode(Bool.self, forKey: .isEnabled)) ?? true
        self.createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        self.lastSyncedAt = try? c.decodeIfPresent(Date.self, forKey: .lastSyncedAt)
        self.lastSyncFileCount = (try? c.decode(Int.self, forKey: .lastSyncFileCount)) ?? 0
        self.lastSyncTotalBytes = (try? c.decode(Int64.self, forKey: .lastSyncTotalBytes)) ?? 0
        self.lastError = try? c.decodeIfPresent(String.self, forKey: .lastError)
        self.knownRelativeFiles = (try? c.decodeIfPresent(Set<String>.self, forKey: .knownRelativeFiles)) ?? []
        self.shareAccessLevel = try? c.decodeIfPresent(DriveShareAccessLevel.self, forKey: .shareAccessLevel)
        self.shareURLString = try? c.decodeIfPresent(String.self, forKey: .shareURLString)
        self.remoteSharedURL = try? c.decodeIfPresent(String.self, forKey: .remoteSharedURL)
        self.remoteFolderID = try? c.decodeIfPresent(String.self, forKey: .remoteFolderID)
        self.remoteOwnerName = try? c.decodeIfPresent(String.self, forKey: .remoteOwnerName)
        self.isRemoteLinkBroken = try? c.decodeIfPresent(Bool.self, forKey: .isRemoteLinkBroken)
        self.status = try? c.decodeIfPresent(String.self, forKey: .status)
        self.pendingDeletionPlan = try? c.decodeIfPresent(PendingDeletionPlan.self, forKey: .pendingDeletionPlan)
        self.lastConflicts = try? c.decodeIfPresent([String].self, forKey: .lastConflicts)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(localPath, forKey: .localPath)
        try c.encode(driveTargetPath, forKey: .driveTargetPath)
        try c.encode(syncMode, forKey: .syncMode)
        try c.encode(isEnabled, forKey: .isEnabled)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(lastSyncedAt, forKey: .lastSyncedAt)
        try c.encode(lastSyncFileCount, forKey: .lastSyncFileCount)
        try c.encode(lastSyncTotalBytes, forKey: .lastSyncTotalBytes)
        try c.encodeIfPresent(lastError, forKey: .lastError)
        // Intentionally omit `knownRelativeFiles` from UserDefaults/config payloads (§3.2 / §3.5)
        try c.encodeIfPresent(shareAccessLevel, forKey: .shareAccessLevel)
        try c.encodeIfPresent(shareURLString, forKey: .shareURLString)
        try c.encodeIfPresent(remoteSharedURL, forKey: .remoteSharedURL)
        try c.encodeIfPresent(remoteFolderID, forKey: .remoteFolderID)
        try c.encodeIfPresent(remoteOwnerName, forKey: .remoteOwnerName)
        try c.encodeIfPresent(isRemoteLinkBroken, forKey: .isRemoteLinkBroken)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(pendingDeletionPlan, forKey: .pendingDeletionPlan)
        try c.encodeIfPresent(lastConflicts, forKey: .lastConflicts)
    }

    var needsConfirmation: Bool {
        status == "needs_confirmation" || pendingDeletionPlan != nil
    }

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

private struct SyncedPairsFileEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let updatedAt: Double?
    let pairs: [SyncedFolderPair]
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

    @Published private(set) var syncedPairs: [SyncedFolderPair] = [] {
        didSet {
            Self.updateMappedPairsSnapshot(from: syncedPairs)
        }
    }
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
    nonisolated private static let expectedHelperVersion = "2.0.0"

    private struct MappedPairEntry: Sendable {
        let localStd: String
        let driveStd: String
    }

    nonisolated private static let mappedPairsLock = OSAllocatedUnfairLock(initialState: [MappedPairEntry]())

    nonisolated private static func updateMappedPairsSnapshot(from pairs: [SyncedFolderPair]) {
        let entries: [MappedPairEntry] = pairs.compactMap { pair in
            guard pair.isEnabled else { return nil }
            let lStd = (pair.localPath as NSString).standardizingPath
            let dStd = (pair.driveTargetPath as NSString).standardizingPath
            guard !lStd.isEmpty, !dStd.isEmpty else { return nil }
            return MappedPairEntry(localStd: lStd, driveStd: dStd)
        }
        mappedPairsLock.withLock { state in
            state = entries
        }
    }

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
        ensureInstalledHelperUpToDate()
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

    // MARK: - Helper Version Verification & Atomic Upgrade (§3.4)

    func ensureInstalledHelperUpToDate() {
        syncQueue.async {
            Self.syncBundledHelperScriptIfNeeded()
        }
    }

    nonisolated private static func bundledHelperCandidatePaths() -> [String] {
        var candidates: [String] = []
        if let bundleRes = Bundle.main.resourcePath {
            candidates.append((bundleRes as NSString).appendingPathComponent("gdrive_folder_sync.py"))
        }
        candidates.append("/Applications/DriveBar.app/Contents/Resources/gdrive_folder_sync.py")
        return candidates
    }

    nonisolated private static func extractHelperVersion(atPath path: String) -> String? {
        guard let fd = fopen(path, "r") else { return nil }
        defer { fclose(fd) }
        var lineBuf = [CChar](repeating: 0, count: 512)
        var linesRead = 0
        while linesRead < 60 && fgets(&lineBuf, Int32(lineBuf.count), fd) != nil {
            linesRead += 1
            let line = String(cString: lineBuf)
            if line.contains("HELPER_VERSION"), let firstQuote = line.firstIndex(of: "\""),
               let lastQuote = line.lastIndex(of: "\""), firstQuote < lastQuote {
                return String(line[line.index(after: firstQuote)..<lastQuote])
            }
        }
        return nil
    }

    nonisolated private static func syncBundledHelperScriptIfNeeded() {
        let fm = FileManager.default
        let dstPath = helperScriptPath()
        let cfgDir = sharedConfigDirPath()
        try? fm.createDirectory(atPath: cfgDir, withIntermediateDirectories: true)

        guard let srcPath = bundledHelperCandidatePaths().first(where: { fm.fileExists(atPath: $0) }) else {
            return
        }
        let srcVersion = extractHelperVersion(atPath: srcPath) ?? expectedHelperVersion
        let dstVersion = extractHelperVersion(atPath: dstPath)

        if !fm.fileExists(atPath: dstPath) || dstVersion != srcVersion {
            let tmpPath = dstPath + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
            try? fm.removeItem(atPath: tmpPath)
            do {
                try fm.copyItem(atPath: srcPath, toPath: tmpPath)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmpPath)
                if fm.fileExists(atPath: dstPath) {
                    _ = try fm.replaceItemAt(URL(fileURLWithPath: dstPath), withItemAt: URL(fileURLWithPath: tmpPath))
                } else {
                    try fm.moveItem(atPath: tmpPath, toPath: dstPath)
                }
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dstPath)
            } catch {
                try? fm.removeItem(atPath: tmpPath)
            }
        }
    }

    // MARK: - Persistence & Single-Writer Command Channel (§3.3)

    nonisolated private static func sharedConfigDirPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/drivebar-sync")
    }

    nonisolated private static func sharedPairsFilePath() -> String {
        (sharedConfigDirPath() as NSString).appendingPathComponent("sync_pairs.json")
    }

    nonisolated private static func commandsDirPath() -> String {
        (sharedConfigDirPath() as NSString).appendingPathComponent("commands")
    }

    nonisolated private static func resultsDirPath() -> String {
        (sharedConfigDirPath() as NSString).appendingPathComponent("results")
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

    nonisolated private static func decodePairsFromSharedData(_ data: Data) -> [SyncedFolderPair]? {
        let dec = makeJSONDecoder()
        if let env = try? dec.decode(SyncedPairsFileEnvelope.self, from: data) {
            return env.pairs
        }
        if let arr = try? dec.decode([SyncedFolderPair].self, from: data) {
            return arr
        }
        return nil
    }

    func reloadPairsFromSharedFileIfAvailable() {
        let path = Self.sharedPairsFilePath()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = Self.decodePairsFromSharedData(data) else {
            return
        }
        if decoded != syncedPairs {
            let oldBrokenIDs = Set(syncedPairs.filter { $0.isRemoteLinkBroken == true }.map(\.id))
            let oldConfirmIDs = Set(syncedPairs.filter { $0.needsConfirmation }.map(\.id))
            syncedPairs = decoded
            savePairsToUserDefaultsOnly()
            for pair in decoded where pair.isRemoteLinkBroken == true && !oldBrokenIDs.contains(pair.id) {
                FloatingToastController.shared.showError(
                    title: L("⚠️ Link Google Drive chia sẻ đã bị khóa!", "⚠️ Shared Google Drive Link Locked!"),
                    subtitle: L(
                        "'\(pair.folderName)' • Đã giữ nguyên toàn bộ \(pair.lastSyncFileCount) tệp trên máy Mac của bạn",
                        "'\(pair.folderName)' • Kept all \(pair.lastSyncFileCount) downloaded files intact on your Mac"
                    )
                )
            }
            for pair in decoded where pair.needsConfirmation && !oldConfirmIDs.contains(pair.id) {
                FloatingToastController.shared.showError(
                    title: L("🛡️ Đã tạm dừng xóa hàng loạt để bảo vệ dữ liệu", "🛡️ Paused Mass Deletion to Protect Files"),
                    subtitle: L(
                        "'\(pair.folderName)' cần bạn xác nhận trong Cài đặt → Google Drive & Đồng bộ",
                        "'\(pair.folderName)' requires confirmation in Settings → Google Drive & Sync"
                    )
                )
            }
        }
    }

    private func loadPairs() {
        let path = Self.sharedPairsFilePath()
        if let fileData = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let decoded = Self.decodePairsFromSharedData(fileData) {
            syncedPairs = decoded
            savePairsToUserDefaultsOnly()
            return
        }
        if let data = UserDefaults.standard.data(forKey: Self.pairsStorageKey),
           let decoded = Self.decodePairsFromSharedData(data) ?? (try? JSONDecoder().decode([SyncedFolderPair].self, from: data)) {
            syncedPairs = decoded
            return
        }
        syncedPairs = []
    }

    /// Saves lightweight pair metadata only to `UserDefaults` for offline display.
    /// `sync_pairs.json` is written exclusively by the Python sync engine under `flock` (§3.3).
    private func savePairsToUserDefaultsOnly() {
        guard let data = try? Self.makeJSONEncoder().encode(syncedPairs) else { return }
        UserDefaults.standard.set(data, forKey: Self.pairsStorageKey)
    }

    private func savePairs() {
        savePairsToUserDefaultsOnly()
    }

    // MARK: - Command Queue Submission & Event-Driven Result Waiting (§3.3)

    private struct CommandChannelResult: Decodable {
        let ok: Bool
        let commandId: String?
        let op: String?
        let completedAt: Double?
        let pair: SyncedFolderPair?
        let report: HelperSyncResponse?
        let shareResult: DriveSharePermissionResult?
        let errorMessage: String?
    }

    nonisolated private static func submitEngineCommandAndWait(
        op: String,
        pairID: UUID?,
        payload: [String: Any],
        timeout: TimeInterval = 60.0
    ) -> CommandChannelResult? {
        let fm = FileManager.default
        let cmdDir = commandsDirPath()
        let resDir = resultsDirPath()
        try? fm.createDirectory(atPath: cmdDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: resDir, withIntermediateDirectories: true)

        let cmdID = UUID().uuidString.uppercased()
        let epochMs = Int64(Date().timeIntervalSince1970 * 1000.0)
        let cmdPath = (cmdDir as NSString).appendingPathComponent("\(epochMs)-\(cmdID).json")
        let tmpPath = (cmdDir as NSString).appendingPathComponent(".tmp.\(cmdID).json")
        let resPath = (resDir as NSString).appendingPathComponent("\(cmdID).json")

        var body: [String: Any] = [
            "v": 1,
            "id": cmdID,
            "op": op,
            "payload": payload,
            "submittedAt": Date().timeIntervalSince1970
        ]
        if let pairID {
            body["pairId"] = pairID.uuidString.uppercased()
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        do {
            try jsonData.write(to: URL(fileURLWithPath: tmpPath), options: .atomic)
            try fm.moveItem(atPath: tmpPath, toPath: cmdPath)
        } catch {
            try? fm.removeItem(atPath: tmpPath)
            return nil
        }

        // If the background daemon is not running, execute `--process-commands` synchronously in helper
        if !isSyncDaemonRunning() {
            let script = helperScriptPath()
            if fm.fileExists(atPath: script) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: pythonExecutablePath())
                proc.arguments = [script, "--process-commands"]
                proc.standardOutput = FileHandle.nullDevice
                proc.standardError = FileHandle.nullDevice
                try? proc.run()
                proc.waitUntilExit()
            }
        } else {
            // Touch trigger.flag as well so legacy or sleeping kqueue wakes immediately
            let triggerPath = (sharedConfigDirPath() as NSString).appendingPathComponent("trigger.flag")
            try? "cmd".write(toFile: triggerPath, atomically: true, encoding: .utf8)
        }

        if let data = try? Data(contentsOf: URL(fileURLWithPath: resPath)),
           let decoded = try? makeJSONDecoder().decode(CommandChannelResult.self, from: data) {
            try? fm.removeItem(atPath: resPath)
            return decoded
        }

        // Wait for `results/<cmdID>.json` using a DispatchSource directory watcher on `results/`
        let sem = DispatchSemaphore(value: 0)
        let dirFD = Darwin.open(resDir, O_EVTONLY)
        var source: DispatchSourceFileSystemObject?
        if dirFD >= 0 {
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: dirFD,
                eventMask: [.write, .extend, .rename],
                queue: DispatchQueue.global(qos: .utility)
            )
            src.setEventHandler {
                if fm.fileExists(atPath: resPath) {
                    sem.signal()
                }
            }
            src.setCancelHandler {
                Darwin.close(dirFD)
            }
            src.resume()
            source = src
        }
        defer {
            source?.cancel()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: resPath)),
               let decoded = try? makeJSONDecoder().decode(CommandChannelResult.self, from: data) {
                try? fm.removeItem(atPath: resPath)
                return decoded
            }
            _ = sem.wait(timeout: .now() + 0.25)
        }
        return nil
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
    /// Reads from in-memory `OSAllocatedUnfairLock` snapshot in O(pairs) without decoding JSON (§3.5).
    nonisolated static func mappedDrivePath(forLocalPath path: String) -> String? {
        let entries = mappedPairsLock.withLock { $0 }
        guard !entries.isEmpty else { return nil }
        let std = (path as NSString).standardizingPath
        for entry in entries {
            if std == entry.localStd {
                return entry.driveStd
            }
            if std.hasPrefix(entry.localStd + "/") {
                let rel = String(std.dropFirst(entry.localStd.count + 1))
                return (entry.driveStd as NSString).appendingPathComponent(rel)
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

    // MARK: - Add / Update / Remove / Confirm Synced Folder Pair

    @discardableResult
    func addOrUpdateSyncPair(
        localPath: String,
        driveTargetPath: String? = nil,
        mode: FolderSyncMode = .twoWayMirror,
        showToast: Bool = true
    ) -> SyncedFolderPair? {
        let stdLocal = (localPath as NSString).standardizingPath
        guard !stdLocal.isEmpty else { return nil }

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
        let opName: String
        if let idx = syncedPairs.firstIndex(where: { ($0.localPath as NSString).standardizingPath == stdLocal }) {
            var existing = syncedPairs[idx]
            existing.driveTargetPath = targetDrive
            existing.syncMode = mode
            existing.isEnabled = true
            existing.lastError = nil
            existing.status = "ok"
            existing.pendingDeletionPlan = nil
            syncedPairs[idx] = existing
            pair = existing
            opName = "update"
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
            opName = "add"
        }

        savePairs()
        restartFSEventsMonitor()
        enqueuePairCommandAndSync(op: opName, pair: pair, showToast: showToast)
        return pair
    }

    func removeSyncPair(id: UUID, restoreRealFolderIfSymlink: Bool = true, showToast: Bool = true) {
        guard let idx = syncedPairs.firstIndex(where: { $0.id == id }) else { return }
        let pair = syncedPairs[idx]
        syncedPairs.remove(at: idx)
        savePairs()
        restartFSEventsMonitor()

        syncQueue.async { [weak self] in
            let cmdRes = Self.submitEngineCommandAndWait(
                op: "remove",
                pairID: pair.id,
                payload: ["restoreSymlink": restoreRealFolderIfSymlink]
            )
            if cmdRes == nil {
                Self.cleanupRemovedPairOnBackgroundQueue(pair: pair, restoreSymlink: restoreRealFolderIfSymlink)
            }
            Task { @MainActor [weak self] in
                self?.reloadPairsFromSharedFileIfAvailable()
            }
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
        let pairSnap = syncedPairs[idx]
        savePairs()
        restartFSEventsMonitor()

        syncQueue.async { [weak self] in
            _ = Self.submitEngineCommandAndWait(
                op: enabled ? "enable" : "disable",
                pairID: pairSnap.id,
                payload: ["isEnabled": enabled, "syncImmediately": false]
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.reloadPairsFromSharedFileIfAvailable()
                if enabled {
                    self.syncPairNow(id: pairSnap.id, showToast: true)
                }
            }
        }
    }

    func resolveMassDeletionConfirmation(id: UUID, applyDeletions: Bool) {
        guard let pair = syncedPairs.first(where: { $0.id == id }) else { return }
        let resolution = applyDeletions ? "apply_deletions" : "restore_from_other"
        guard !activeSyncingIDs.contains(id) else { return }

        activeSyncingIDs.insert(id)
        isGlobalSyncing = !activeSyncingIDs.isEmpty

        FloatingToastController.shared.showProgress(
            title: applyDeletions
                ? L("Đang thực thi xóa các tệp đã xác nhận...", "Applying confirmed file deletions...")
                : L("Đang khôi phục các tệp từ phía đối ứng...", "Restoring files from counterpart folder..."),
            subtitle: pair.folderName
        )

        syncQueue.async { [weak self] in
            let cmdRes = Self.submitEngineCommandAndWait(
                op: "resolve_confirmation",
                pairID: id,
                payload: ["resolution": resolution, "force": true],
                timeout: 120.0
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.activeSyncingIDs.remove(id)
                self.isGlobalSyncing = !self.activeSyncingIDs.isEmpty
                self.reloadPairsFromSharedFileIfAvailable()

                if let cmdRes, cmdRes.ok {
                    FloatingToastController.shared.showSuccess(
                        title: applyDeletions
                            ? L("Đã hoàn tất xóa đồng bộ an toàn", "Completed confirmed deletions")
                            : L("Đã khôi phục đầy đủ tệp cho '\(pair.folderName)'", "Restored all files for '\(pair.folderName)'"),
                        subtitle: pair.prettyDrivePath,
                        symbol: "checkmark.shield.fill"
                    )
                } else {
                    FloatingToastController.shared.showError(
                        title: L("Không thể xử lý xác nhận đồng bộ", "Could not resolve sync confirmation"),
                        subtitle: cmdRes?.errorMessage ?? pair.folderName
                    )
                }
            }
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
        let matchedPair = pair(forLocalOrDrivePath: path)
        let resolvedDrivePath = Self.mappedDrivePath(forLocalPath: path) ?? matchedPair?.driveTargetPath ?? path

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
            let cmdRes = Self.submitEngineCommandAndWait(
                op: "set_share",
                pairID: matchedPair?.id,
                payload: ["path": resolvedDrivePath, "role": level.rawValue],
                timeout: 30.0
            )
            let res = cmdRes?.shareResult ?? Self.runSharePermissionHelper(driveOrLocalPath: resolvedDrivePath, action: level.rawValue)
            Task { @MainActor [weak self] in
                if let self, res.ok {
                    self.updateCachedShareStatus(forPath: path, resolvedDrivePath: resolvedDrivePath, result: res)
                    self.reloadPairsFromSharedFileIfAvailable()
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
        let opName: String
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
            existing.status = "ok"
            existing.isRemoteLinkBroken = false
            syncedPairs[idx] = existing
            pair = existing
            opName = "update"
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
            opName = "add"
        }

        savePairs()
        restartFSEventsMonitor()
        enqueuePairCommandAndSync(op: opName, pair: pair, showToast: showToast)
        return pair
    }

    // MARK: - Sync Execution

    private func enqueuePairCommandAndSync(op: String, pair: SyncedFolderPair, showToast: Bool) {
        let id = pair.id
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

        var cmdPayload: [String: Any] = [
            "localPath": pair.localPath,
            "driveTargetPath": pair.driveTargetPath,
            "syncMode": pair.syncMode.rawValue,
            "syncImmediately": true
        ]
        if let rURL = pair.remoteSharedURL { cmdPayload["remoteSharedURL"] = rURL }
        if let rID = pair.remoteFolderID { cmdPayload["remoteFolderID"] = rID }
        if let rOwner = pair.remoteOwnerName { cmdPayload["remoteOwnerName"] = rOwner }

        syncQueue.async { [weak self] in
            let (updatedPair, report) = Self.performCommandOrFallbackSync(op: op, pair: pair, payload: cmdPayload)
            Task { @MainActor [weak self] in
                self?.finishSyncRun(id: id, updatedPair: updatedPair, report: report, showToast: showToast)
            }
        }
    }

    func syncAllEnabledPairs(showToast: Bool = false) {
        let enabled = syncedPairs.filter { $0.isEnabled && !$0.needsConfirmation }
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
                self?.finishSyncRun(id: id, updatedPair: updatedPair, report: report, showToast: showToast)
            }
        }
    }

    private func finishSyncRun(
        id: UUID,
        updatedPair: SyncedFolderPair,
        report: SyncExecutionReport,
        showToast: Bool
    ) {
        lastInternalWriteTimestamp[id] = Date().timeIntervalSince1970
        activeSyncingIDs.remove(id)
        isGlobalSyncing = !activeSyncingIDs.isEmpty

        if let idx = syncedPairs.firstIndex(where: { $0.id == id }) {
            syncedPairs[idx] = updatedPair
            savePairs()
        }
        reloadPairsFromSharedFileIfAvailable()

        GoogleDriveIndexService.shared.noteExternalDirectoryCreated(at: updatedPair.driveTargetPath)

        if updatedPair.needsConfirmation {
            FloatingToastController.shared.showError(
                title: L("🛡️ Đã chặn xóa hàng loạt để bảo vệ dữ liệu!", "🛡️ Blocked Mass Deletion to Protect Files!"),
                subtitle: L(
                    "'\(updatedPair.folderName)' • Mở Cài đặt → Google Drive & Đồng bộ để xác nhận",
                    "'\(updatedPair.folderName)' • Open Settings → Google Drive & Sync to confirm"
                )
            )
        } else if updatedPair.isRemoteLinkBroken == true {
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

    // MARK: - Core Background Sync Engine

    private struct HelperSyncResponse: Decodable {
        let ok: Bool
        let status: String?
        let isBrokenLink: Bool?
        let copiedToDrive: Int
        let copiedToLocal: Int
        let trashedCount: Int
        let conflicts: [String]?
        let pendingDeletionPlan: PendingDeletionPlan?
        let totalFiles: Int
        let totalBytes: Int64
        let knownRelativeFiles: [String]?
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

    nonisolated private static func isSyncDaemonRunning() -> Bool {
        let pidPath = (sharedConfigDirPath() as NSString).appendingPathComponent("daemon.pid")
        guard let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr), pid > 0 else {
            return false
        }
        return Darwin.kill(pid, 0) == 0
    }

    nonisolated private static func performCommandOrFallbackSync(
        op: String,
        pair: SyncedFolderPair,
        payload: [String: Any]
    ) -> (SyncedFolderPair, SyncExecutionReport) {
        if let cmdRes = submitEngineCommandAndWait(op: op, pairID: pair.id, payload: payload, timeout: 60.0) {
            let resolvedPair = cmdRes.pair ?? pair
            let rep = cmdRes.report
            let report = SyncExecutionReport(
                pairID: resolvedPair.id,
                copiedToDrive: rep?.copiedToDrive ?? 0,
                copiedToLocal: rep?.copiedToLocal ?? 0,
                trashedCount: rep?.trashedCount ?? 0,
                totalFiles: rep?.totalFiles ?? resolvedPair.lastSyncFileCount,
                totalBytes: rep?.totalBytes ?? resolvedPair.lastSyncTotalBytes,
                errorMessage: cmdRes.errorMessage ?? rep?.errorMessage
            )
            return (resolvedPair, report)
        }
        return performSyncOnBackgroundQueue(pair: pair)
    }

    nonisolated private static func performSyncOnBackgroundQueue(
        pair: SyncedFolderPair
    ) -> (SyncedFolderPair, SyncExecutionReport) {
        // 1. Primary path: Single-writer command channel (`commands/` -> `results/`)
        if let cmdRes = submitEngineCommandAndWait(
            op: "sync",
            pairID: pair.id,
            payload: ["force": true],
            timeout: 60.0
        ), cmdRes.pair != nil || cmdRes.report != nil {
            var updated = cmdRes.pair ?? pair
            if let rep = cmdRes.report {
                updated.status = rep.status ?? (rep.ok ? "ok" : "error")
                updated.pendingDeletionPlan = rep.pendingDeletionPlan
                updated.lastConflicts = rep.conflicts
                updated.isRemoteLinkBroken = rep.isBrokenLink ?? false
                if rep.ok {
                    updated.lastSyncedAt = Date()
                    updated.lastSyncFileCount = rep.totalFiles
                    updated.lastSyncTotalBytes = rep.totalBytes
                    updated.lastError = nil
                } else {
                    updated.lastError = rep.errorMessage ?? cmdRes.errorMessage
                }
                let execReport = SyncExecutionReport(
                    pairID: pair.id,
                    copiedToDrive: rep.copiedToDrive,
                    copiedToLocal: rep.copiedToLocal,
                    trashedCount: rep.trashedCount,
                    totalFiles: rep.totalFiles,
                    totalBytes: rep.totalBytes,
                    errorMessage: rep.ok ? nil : (rep.errorMessage ?? cmdRes.errorMessage)
                )
                return (updated, execReport)
            }
        }

        // 2. Secondary fallback: direct CLI invocation of `gdrive_folder_sync.py`
        var updated = pair
        let script = helperScriptPath()
        let fm = FileManager.default

        if fm.fileExists(atPath: script) {
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
                    "--mode", pair.syncMode.rawValue
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
                    updated.status = resp.status ?? (resp.ok ? "ok" : "error")
                    updated.pendingDeletionPlan = resp.pendingDeletionPlan
                    updated.lastConflicts = resp.conflicts
                    if let owner = resp.ownerName, !owner.isEmpty {
                        updated.remoteOwnerName = owner
                    }
                    if resp.ok {
                        updated.lastSyncedAt = Date()
                        updated.lastSyncFileCount = resp.totalFiles
                        updated.lastSyncTotalBytes = resp.totalBytes
                        updated.lastError = nil
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
                // Fall through to native Swift fallback if subprocess fails to launch
            }
        }

        // 3. Hardened Native Swift Fallback (with Mount Health & Mass-Deletion Guard §3.1)
        do {
            let hadPriorSync = pair.lastSyncedAt != nil || pair.lastSyncFileCount > 0
            if hadPriorSync {
                if !fm.fileExists(atPath: pair.driveTargetPath) {
                    throw NSError(
                        domain: "DriveBarSync",
                        code: 4001,
                        userInfo: [NSLocalizedDescriptionKey: "Drive target folder is missing or unmounted (aborted to prevent data loss)"]
                    )
                }
                if !fm.fileExists(atPath: pair.localPath) && !isSymbolicLink(atPath: pair.localPath) {
                    throw NSError(
                        domain: "DriveBarSync",
                        code: 4002,
                        userInfo: [NSLocalizedDescriptionKey: "Local synced folder is missing (aborted to prevent data loss)"]
                    )
                }
            }

            let driveParent = (pair.driveTargetPath as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: driveParent) {
                try fm.createDirectory(atPath: driveParent, withIntermediateDirectories: true)
            }

            if pair.syncMode == .symlinkToDrive {
                return try performSymlinkModeSync(pair: pair)
            }

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

            if hadPriorSync && pair.lastSyncFileCount > 0 && (localScan.files.isEmpty || driveScan.files.isEmpty) {
                let msg = "One side scanned 0 files while baseline had \(pair.lastSyncFileCount) files (mass-deletion guard)."
                updated.status = "needs_confirmation"
                updated.lastError = msg
                return (updated, SyncExecutionReport(
                    pairID: pair.id,
                    copiedToDrive: 0,
                    copiedToLocal: 0,
                    trashedCount: 0,
                    totalFiles: localScan.files.count,
                    totalBytes: updated.lastSyncTotalBytes,
                    errorMessage: msg
                ))
            }

            var copiedToDrive = 0
            var copiedToLocal = 0

            for relDir in localScan.directories.union(driveScan.directories).sorted() {
                let lDir = (pair.localPath as NSString).appendingPathComponent(relDir)
                let dDir = (pair.driveTargetPath as NSString).appendingPathComponent(relDir)
                if localScan.directories.contains(relDir) && !driveScan.directories.contains(relDir) {
                    try? fm.createDirectory(atPath: dDir, withIntermediateDirectories: true)
                } else if driveScan.directories.contains(relDir) && !localScan.directories.contains(relDir) {
                    try? fm.createDirectory(atPath: lDir, withIntermediateDirectories: true)
                }
            }

            let allRelFiles = Set(localScan.files.keys).union(driveScan.files.keys)
            for relFile in allRelFiles.sorted() {
                let lPath = (pair.localPath as NSString).appendingPathComponent(relFile)
                let dPath = (pair.driveTargetPath as NSString).appendingPathComponent(relFile)
                let lMeta = localScan.files[relFile]
                let dMeta = driveScan.files[relFile]

                switch (lMeta, dMeta) {
                case let (.some(l), .some(d)):
                    let timeDiff = l.mtime.timeIntervalSince(d.mtime)
                    if abs(timeDiff) <= 2.0 && l.size == d.size {
                        break
                    } else if timeDiff > 2.0 {
                        if copyFileAtomically(from: lPath, to: dPath, mtime: l.mtime) { copiedToDrive += 1 }
                    } else if !d.isDataless && !d.isCloudStub {
                        if copyFileAtomically(from: dPath, to: lPath, mtime: d.mtime) { copiedToLocal += 1 }
                    }
                case let (.some(l), .none):
                    if copyFileAtomically(from: lPath, to: dPath, mtime: l.mtime) { copiedToDrive += 1 }
                case let (.none, .some(d)):
                    if !d.isDataless && !d.isCloudStub {
                        if copyFileAtomically(from: dPath, to: lPath, mtime: d.mtime) { copiedToLocal += 1 }
                    }
                case (.none, .none):
                    break
                }
            }

            let totalFiles = allRelFiles.count
            let totalBytes = localScan.files.values.reduce(Int64(0)) { $0 + $1.size }
            updated.lastSyncedAt = Date()
            updated.lastSyncFileCount = totalFiles
            updated.lastSyncTotalBytes = totalBytes
            updated.lastError = nil
            updated.status = "ok"

            let report = SyncExecutionReport(
                pairID: pair.id,
                copiedToDrive: copiedToDrive,
                copiedToLocal: copiedToLocal,
                trashedCount: 0,
                totalFiles: totalFiles,
                totalBytes: totalBytes,
                errorMessage: nil
            )
            return (updated, report)
        } catch {
            updated.lastError = error.localizedDescription
            updated.status = "error"
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
            try fm.trashItem(at: URL(fileURLWithPath: pair.localPath), resultingItemURL: nil)
            try fm.createSymbolicLink(atPath: pair.localPath, withDestinationPath: pair.driveTargetPath)
        } else {
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
        updated.status = "ok"

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

            if ignoredDirectoryNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if ignoredFileNames.contains(name) || name.hasPrefix("~$") || name.hasPrefix(".~") || name.hasPrefix(".tmp") || name.hasPrefix(".drivebar_sync_tmp_") {
                continue
            }

            let fullPath = (stdRoot as NSString).appendingPathComponent(relObj)
            var st = Darwin.stat()
            guard Darwin.lstat(fullPath, &st) == 0 else { continue }

            let mode = st.st_mode & S_IFMT
            if mode == S_IFLNK {
                continue
            } else if mode == S_IFDIR {
                result.directories.insert(relObj)
            } else if mode == S_IFREG {
                let ext = (name as NSString).pathExtension.lowercased()
                if cloudStubExtensions.contains(ext) {
                    continue
                }
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000.0)
                let size = Int64(st.st_size)
                let isDataless = isCloudStorage && ((st.st_flags & UInt32(SF_DATALESS)) != 0)
                result.files[relObj] = ScannedFileMeta(
                    mtime: mtime,
                    size: size,
                    isDataless: isDataless,
                    isCloudStub: false
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
            if let pair = enclosingPair(forPath: rawPath), pair.syncMode == .twoWayMirror, !pair.needsConfirmation {
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

    // MARK: - Install Finder Right-Click Quick Actions (.workflow in ~/Library/Services, §3.4)

    func installFinderQuickActionsIfNeeded(force: Bool = false) {
        let servicesDir = (NSHomeDirectory() as NSString).appendingPathComponent("Library/Services")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: servicesDir, withIntermediateDirectories: true)

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

        // 1. Quick Action: "Đồng bộ với Google Drive.workflow"
        let singleWorkflowDir = (servicesDir as NSString).appendingPathComponent("Đồng bộ với Google Drive.workflow")
        installSingleWorkflow(
            at: singleWorkflowDir,
            bundleID: "com.hunglx.DriveBar.FinderQuickAction.SyncFolder",
            menuTitle: "Đồng bộ với Google Drive",
            cliFlag: "--quick-action",
            symbolName: "icloud.and.arrow.up.fill",
            force: force
        )

        // 2. Quick Action: "Dán Link Copy.workflow"
        let pasteLinkWorkflowDir = (servicesDir as NSString).appendingPathComponent("Dán Link Copy.workflow")
        installSingleWorkflow(
            at: pasteLinkWorkflowDir,
            bundleID: "com.hunglx.DriveBar.FinderQuickAction.PasteLinkCopy",
            menuTitle: "Dán Link Copy",
            cliFlag: "--quick-action-paste-link",
            symbolName: "icloud.and.arrow.down.fill",
            force: force
        )

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
        cliFlag: String,
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
            <string>2.0</string>
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
        if [ -f "$BUNDLED" ]; then
            B_VER=$(grep -m1 '^HELPER_VERSION' "$BUNDLED" 2>/dev/null | cut -d'"' -f2)
            H_VER=$(grep -m1 '^HELPER_VERSION' "$HELPER" 2>/dev/null | cut -d'"' -f2)
            if [ ! -f "$HELPER" ] || [ "$B_VER" != "$H_VER" ]; then
                mkdir -p "$HOME/.config/drivebar-sync"
                TMP_H="$HELPER.tmp.$$"
                cp "$BUNDLED" "$TMP_H" && chmod 755 "$TMP_H" && mv -f "$TMP_H" "$HELPER"
            fi
        fi
        PY_BIN=""
        for candidate in /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
            if [ -x "$candidate" ]; then
                PY_BIN="$candidate"
                break
            fi
        done
        if [ -z "$PY_BIN" ] || [ ! -f "$HELPER" ]; then
            osascript -e 'display notification "Không tìm thấy Python 3 hoặc bộ đồng bộ DriveBar." with title "DriveBar Sync"' >/dev/null 2>&1
            exit 1
        fi
        "$PY_BIN" "$HELPER" \(cliFlag) "$@"
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
