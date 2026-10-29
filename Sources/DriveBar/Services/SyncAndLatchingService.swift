import Foundation
import AppKit
import CoreServices

struct ActionLatchEntry: Codable, Sendable {
    var count: Int
    var lastUsed: Double
}

struct PortableSyncSettingsPayload: Codable, Sendable {
    var updatedAt: Double
    var searchHotKey: HotKeyBinding
    var universalActionHotKey: HotKeyBinding
    var disabledActionIDs: [String]
    var autoCopyMarkdownToClipboard: Bool
    var saveMarkdownBesideSource: Bool
    var enableVisionOCR: Bool
    var optimizeMarkdownTokens: Bool
    var includeMetadataHeader: Bool
    var wrapMultiFilesInXMLTags: Bool
    var enableSmartChunking: Bool
    var smartChunkMaxTokens: Int
    var includeMacAppsInSearch: Bool
    var enableActionLatching: Bool
}

@MainActor
final class SyncAndLatchingService: ObservableObject {
    static let shared = SyncAndLatchingService()

    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var syncedRecordCount: Int = 0
    @Published private(set) var learnedActionCount: Int = 0

    private var latchMap: [String: ActionLatchEntry] = [:]
    private var localSettingsTimestamp: Double = 0
    private var syncEventStream: FSEventStreamRef?
    private let fseventQueue = DispatchQueue(label: "com.hunglx.DriveBar.syncthingWatcher", qos: .utility)
    private var isWritingSyncFiles: Bool = false

    private let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    private var localLatchPath: String { "\(homePath)/.config/alfred-scripts/drivebar_latching.json" }

    private init() {
        loadLocalLatching()
    }

    func start() {
        configureSyncthingWatcher()
        if AppSettings.shared.enableSyncthingSync {
            syncNow()
        }
    }

    // MARK: - 1. Action Latching (Smart Universal Actions Ranking)

    func contextKey(for target: ActionTarget) -> String {
        switch target {
        case .files(let urls, _):
            guard let first = urls.first else { return "file:any" }
            if urls.count > 1 { return "files:multi" }
            if GoogleDriveIndexService.shared.isKnownDirectory(first.path, hasDirectoryHint: first.hasDirectoryPath) {
                return "folder"
            }
            let ext = first.pathExtension.lowercased()
            return ext.isEmpty ? "file:noext" : "ext:\(ext)"
        case .url:
            return "url"
        case .text:
            return "text"
        }
    }

    func recordActionUsed(actionID: String, target: ActionTarget) {
        guard AppSettings.shared.enableActionLatching else { return }
        let key = "\(contextKey(for: target))::\(actionID)"
        let now = Date().timeIntervalSince1970
        var rec = latchMap[key] ?? ActionLatchEntry(count: 0, lastUsed: now)
        rec.count += 1
        rec.lastUsed = now
        latchMap[key] = rec
        learnedActionCount = latchMap.count

        persistLocalLatching()
        if AppSettings.shared.enableSyncthingSync {
            pushLatchingToSyncFolder()
        }
    }

    func latchBoost(for actionID: String, target: ActionTarget) -> Int {
        guard AppSettings.shared.enableActionLatching else { return 0 }
        let key = "\(contextKey(for: target))::\(actionID)"
        guard let rec = latchMap[key], rec.count > 0 else { return 0 }
        // Strong enough boost so user's preferred action rises above siblings cleanly
        let countBonus = min(rec.count * 45, 360)
        let ageHours = max(0, (Date().timeIntervalSince1970 - rec.lastUsed) / 3600.0)
        let recencyBonus = ageHours < 72 ? 120 : 40
        return 180 + countBonus + recencyBonus
    }

    func isFrequentlyUsed(actionID: String, target: ActionTarget) -> Bool {
        guard AppSettings.shared.enableActionLatching else { return false }
        let key = "\(contextKey(for: target))::\(actionID)"
        return (latchMap[key]?.count ?? 0) >= 2
    }

    func resetActionLatching() {
        latchMap.removeAll()
        learnedActionCount = 0
        try? FileManager.default.removeItem(atPath: localLatchPath)
        if AppSettings.shared.enableSyncthingSync {
            let remoteLatch = "\(expandedSyncDir)/action_latching.json"
            try? FileManager.default.removeItem(atPath: remoteLatch)
        }
    }

    private func loadLocalLatching() {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: localLatchPath)),
           let decoded = try? JSONDecoder().decode([String: ActionLatchEntry].self, from: data) {
            latchMap = decoded
            learnedActionCount = decoded.count
        }
    }

    private func persistLocalLatching() {
        let snap = latchMap
        let path = localLatchPath
        Task.detached(priority: .utility) {
            Self.writeAtomicJSON(snap, to: path)
        }
    }

    // MARK: - 2. Bi-directional P2P Sync via ~/Sync/ (Syncthing iMac <-> MacBook Pro)

    var expandedSyncDir: String {
        (AppSettings.shared.syncthingFolderPath as NSString).expandingTildeInPath
    }

    func syncNow() {
        guard AppSettings.shared.enableSyncthingSync else { return }
        let dir = expandedSyncDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // 1. Merge Action Latching
        let remoteLatchFile = "\(dir)/action_latching.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: remoteLatchFile)),
           let remoteMap = try? JSONDecoder().decode([String: ActionLatchEntry].self, from: data) {
            var changed = false
            for (k, rVal) in remoteMap {
                if let lVal = latchMap[k] {
                    if rVal.count > lVal.count || rVal.lastUsed > lVal.lastUsed {
                        latchMap[k] = ActionLatchEntry(
                            count: max(lVal.count, rVal.count),
                            lastUsed: max(lVal.lastUsed, rVal.lastUsed)
                        )
                        changed = true
                    }
                } else {
                    latchMap[k] = rVal
                    changed = true
                }
            }
            if changed {
                learnedActionCount = latchMap.count
                persistLocalLatching()
            }
        }
        pushLatchingToSyncFolder()

        // 2. Merge Portable Settings
        let remoteSettingsFile = "\(dir)/portable_settings.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: remoteSettingsFile)),
           let remote = try? JSONDecoder().decode(PortableSyncSettingsPayload.self, from: data) {
            let currentLocalTS = max(localSettingsTimestamp, AppSettings.shared.localSettingsUpdatedAt)
            if remote.updatedAt > currentLocalTS + 0.5 {
                applyRemoteSettings(remote)
            } else if currentLocalTS > remote.updatedAt + 0.5 {
                pushPortableSettings()
            }
        } else {
            pushPortableSettings()
        }

        // 3. Merge Portable Google Drive History (cross-user hunglx <-> hunglexuan!)
        let remoteHistFile = "\(dir)/portable_history.json"
        let mergedCount = GoogleDriveIndexService.shared.mergeWithPortableSyncFile(at: remoteHistFile)
        syncedRecordCount = mergedCount
        lastSyncDate = Date()
    }

    func pushPortableSettings() {
        guard AppSettings.shared.enableSyncthingSync else { return }
        let s = AppSettings.shared
        let now = Date().timeIntervalSince1970
        localSettingsTimestamp = now
        AppSettings.shared.localSettingsUpdatedAt = now
        let payload = PortableSyncSettingsPayload(
            updatedAt: now,
            searchHotKey: s.searchHotKey,
            universalActionHotKey: s.universalActionHotKey,
            disabledActionIDs: Array(s.disabledActionIDs).sorted(),
            autoCopyMarkdownToClipboard: s.autoCopyMarkdownToClipboard,
            saveMarkdownBesideSource: s.saveMarkdownBesideSource,
            enableVisionOCR: s.enableVisionOCR,
            optimizeMarkdownTokens: s.optimizeMarkdownTokens,
            includeMetadataHeader: s.includeMetadataHeader,
            wrapMultiFilesInXMLTags: s.wrapMultiFilesInXMLTags,
            enableSmartChunking: s.enableSmartChunking,
            smartChunkMaxTokens: s.smartChunkMaxTokens,
            includeMacAppsInSearch: s.includeMacAppsInSearch,
            enableActionLatching: s.enableActionLatching
        )
        let targetFile = "\(expandedSyncDir)/portable_settings.json"
        isWritingSyncFiles = true
        Task.detached(priority: .utility) {
            Self.writeAtomicJSON(payload, to: targetFile)
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                SyncAndLatchingService.shared.isWritingSyncFiles = false
                SyncAndLatchingService.shared.lastSyncDate = Date()
            }
        }
    }

    func pushPortableHistory(_ portableMap: [String: HistoryRecord]) {
        guard AppSettings.shared.enableSyncthingSync else { return }
        let targetFile = "\(expandedSyncDir)/portable_history.json"
        syncedRecordCount = portableMap.count
        isWritingSyncFiles = true
        Task.detached(priority: .utility) {
            Self.writeAtomicJSON(portableMap, to: targetFile)
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                SyncAndLatchingService.shared.isWritingSyncFiles = false
                SyncAndLatchingService.shared.lastSyncDate = Date()
            }
        }
    }

    private func pushLatchingToSyncFolder() {
        let snap = latchMap
        let targetFile = "\(expandedSyncDir)/action_latching.json"
        isWritingSyncFiles = true
        Task.detached(priority: .utility) {
            Self.writeAtomicJSON(snap, to: targetFile)
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                SyncAndLatchingService.shared.isWritingSyncFiles = false
            }
        }
    }

    private func applyRemoteSettings(_ remote: PortableSyncSettingsPayload) {
        let s = AppSettings.shared
        s.isApplyingRemoteSync = true
        defer { s.isApplyingRemoteSync = false }

        localSettingsTimestamp = remote.updatedAt
        s.localSettingsUpdatedAt = remote.updatedAt
        if s.searchHotKey != remote.searchHotKey { s.searchHotKey = remote.searchHotKey }
        if s.universalActionHotKey != remote.universalActionHotKey { s.universalActionHotKey = remote.universalActionHotKey }
        let newDisabled = Set(remote.disabledActionIDs)
        if s.disabledActionIDs != newDisabled { s.disabledActionIDs = newDisabled }
        s.autoCopyMarkdownToClipboard = remote.autoCopyMarkdownToClipboard
        s.saveMarkdownBesideSource = remote.saveMarkdownBesideSource
        s.enableVisionOCR = remote.enableVisionOCR
        s.optimizeMarkdownTokens = remote.optimizeMarkdownTokens
        s.includeMetadataHeader = remote.includeMetadataHeader
        s.wrapMultiFilesInXMLTags = remote.wrapMultiFilesInXMLTags
        s.enableSmartChunking = remote.enableSmartChunking
        s.smartChunkMaxTokens = remote.smartChunkMaxTokens
        s.includeMacAppsInSearch = remote.includeMacAppsInSearch
        s.enableActionLatching = remote.enableActionLatching
    }

    // MARK: - Live FSEventStream Watcher for Incoming Syncthing Updates

    func configureSyncthingWatcher() {
        stopSyncthingWatcher()
        guard AppSettings.shared.enableSyncthingSync else { return }

        let dir = expandedSyncDir
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let pathsToWatch = [dir] as CFArray
        let callback: FSEventStreamCallback = { _, _, numEvents, eventPathsPtr, _, _ in
            guard numEvents > 0 else { return }
            let cfArray = unsafeBitCast(eventPathsPtr, to: CFArray.self)
            guard let paths = cfArray as? [String] else { return }
            let relevant = paths.contains { p in
                p.hasSuffix(".json") && !p.contains(".tmp.")
            }
            guard relevant else { return }

            Task { @MainActor in
                guard !SyncAndLatchingService.shared.isWritingSyncFiles else { return }
                SyncAndLatchingService.shared.syncNow()
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
            nil,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.2,
            flags
        ) {
            FSEventStreamSetDispatchQueue(stream, fseventQueue)
            FSEventStreamStart(stream)
            syncEventStream = stream
        }
    }

    private func stopSyncthingWatcher() {
        if let stream = syncEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            syncEventStream = nil
        }
    }

    nonisolated static func writeAtomicJSON<T: Encodable>(_ value: T, to filePath: String) {
        let fm = FileManager.default
        let dir = (filePath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = "\(filePath).tmp.\(ProcessInfo.processInfo.processIdentifier)"
        guard let encoder: JSONEncoder = {
            let e = JSONEncoder()
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            return e
        }(), let data = try? encoder.encode(value) else { return }

        do {
            try data.write(to: URL(fileURLWithPath: tmp), options: .atomic)
            if fm.fileExists(atPath: filePath) {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: filePath), withItemAt: URL(fileURLWithPath: tmp))
            } else {
                try fm.moveItem(atPath: tmp, toPath: filePath)
            }
        } catch {
            try? fm.removeItem(atPath: tmp)
        }
    }
}
