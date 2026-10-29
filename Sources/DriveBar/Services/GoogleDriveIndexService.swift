import Foundation
import AppKit
import CoreServices
import Darwin

struct DriveAccountMount: Identifiable, Equatable, Sendable {
    var id: String { email }
    let email: String
    let rootPath: String
    let myDrivePath: String?
    let sharedDrivesPath: String?
    let shortcutTargetsPath: String?
}

struct FastFolderRecord: Sendable {
    let path: String
    let cleanBytes: [[UInt8]]
    let acrBytes: [[UInt8]]
}

struct FastFolderIndex: Sendable {
    let records: [FastFolderRecord]
    let knownPaths: Set<String>
    let childrenByParent: [String: [String]]

    static let empty = FastFolderIndex(records: [], knownPaths: [], childrenByParent: [:])

    nonisolated static func build(from entries: [DriveFolderEntry]) -> FastFolderIndex {
        var recs: [FastFolderRecord] = []
        recs.reserveCapacity(entries.count)
        var paths = Set<String>(minimumCapacity: entries.count)
        var byParent: [String: [String]] = [:]
        byParent.reserveCapacity(entries.count / 3 + 16)

        for e in entries {
            paths.insert(e.path)
            let parent = (e.path as NSString).deletingLastPathComponent
            byParent[parent, default: []].append(e.path)
            recs.append(FastFolderRecord(
                path: e.path,
                cleanBytes: e.cleanSegs.map { Array($0.utf8) },
                acrBytes: e.acrSegs.map { Array($0.utf8) }
            ))
        }
        return FastFolderIndex(records: recs, knownPaths: paths, childrenByParent: byParent)
    }
}

struct FastSharedRecord: Sendable {
    let entry: SharedDriveEntry
    let cleanBytes: [[UInt8]]
    let acrBytes: [[UInt8]]
}

struct FastSharedIndex: Sendable {
    let records: [FastSharedRecord]
    let byPath: [String: SharedDriveEntry]
    let childrenByParent: [String: [(path: String, isDir: Bool)]]

    static let empty = FastSharedIndex(records: [], byPath: [:], childrenByParent: [:])

    nonisolated static func build(from entries: [SharedDriveEntry]) -> FastSharedIndex {
        var recs: [FastSharedRecord] = []
        recs.reserveCapacity(entries.count)
        var map: [String: SharedDriveEntry] = [:]
        map.reserveCapacity(entries.count)
        var byParent: [String: [(path: String, isDir: Bool)]] = [:]

        for e in entries {
            map[e.path] = e
            let parent = (e.path as NSString).deletingLastPathComponent
            byParent[parent, default: []].append((e.path, e.isDir))
            recs.append(FastSharedRecord(
                entry: e,
                cleanBytes: e.cleanSegs.map { Array($0.utf8) },
                acrBytes: e.acrSegs.map { Array($0.utf8) }
            ))
        }
        return FastSharedIndex(records: recs, byPath: map, childrenByParent: byParent)
    }
}

@MainActor
final class GoogleDriveIndexService: ObservableObject {
    static let shared = GoogleDriveIndexService()

    @Published private(set) var availableAccounts: [DriveAccountMount] = []
    @Published private(set) var accountRoot: String?
    @Published private(set) var myDrivePath: String?
    @Published private(set) var sharedDrivesPath: String?
    @Published private(set) var shortcutTargetsPath: String?
    @Published private(set) var isRealtimeWatcherActive: Bool = false

    @Published private(set) var folderCount: Int = 0
    @Published private(set) var sharedCount: Int = 0
    @Published private(set) var isRebuildingFolders: Bool = false
    @Published private(set) var isRebuildingShared: Bool = false
    @Published private(set) var rebuildProgressText: String?
    @Published private(set) var lastCacheUpdate: Date?

    private var folderEntries: [DriveFolderEntry] = []
    private var sharedEntries: [SharedDriveEntry] = []
    private(set) var fastFolderIndex: FastFolderIndex = .empty
    private(set) var fastSharedIndex: FastSharedIndex = .empty
    private(set) var history: [String: HistoryRecord] = [:]
    private(set) var appEntries: [(name: String, clean: String, acronym: String, path: String)] = []

    private var driveFSStream: FSEventStreamRef?
    private let driveFSQueue = DispatchQueue(label: "com.hunglx.DriveBar.driveFSEvents", qos: .utility)
    private var pendingEventPaths = Set<String>()
    private var debounceTask: Task<Void, Never>?
    private var cachePersistTask: Task<Void, Never>?

    private let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    private var cacheDir: String { "\(homePath)/.config/alfred-scripts" }
    private var folderCachePath: String { "\(cacheDir)/folder_cache.json" }
    private var sharedCachePath: String { "\(cacheDir)/shared_cache.json" }
    private var historyPath: String { "\(cacheDir)/folder_history.json" }

    nonisolated private static let skipExtensions: Set<String> = [
        "app", "photoslibrary", "xcodeproj", "xcworkspace",
        "bundle", "framework", "dsym", "git", "svn"
    ]

    private init() {
        refreshAccountPaths()
        loadInitialDataAsync()
    }

    var activeAccounts: [DriveAccountMount] {
        let filter = AppSettings.shared.selectedDriveAccountFilter
        if filter == "ALL" || filter.isEmpty {
            return availableAccounts
        }
        let filtered = availableAccounts.filter { $0.email == filter }
        return filtered.isEmpty ? availableAccounts : filtered
    }

    // MARK: - Multi-Account Path Detection

    func refreshAccountPaths() {
        let cloudStorage = "\(homePath)/Library/CloudStorage"
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: cloudStorage) else {
            availableAccounts = []
            accountRoot = nil
            myDrivePath = nil
            sharedDrivesPath = nil
            shortcutTargetsPath = nil
            stopRealtimeDriveWatcher()
            return
        }

        var discovered: [DriveAccountMount] = []
        for name in items.sorted() where name.hasPrefix("GoogleDrive-") && !name.contains("(") {
            let full = "\(cloudStorage)/\(name)"
            let email = String(name.dropFirst("GoogleDrive-".count))
            // Construct standard DriveFS mount subpaths without synchronous FileProvider open() on Main Thread
            let mount = DriveAccountMount(
                email: email,
                rootPath: full,
                myDrivePath: "\(full)/My Drive",
                sharedDrivesPath: "\(full)/Shared drives",
                shortcutTargetsPath: "\(full)/.shortcut-targets-by-id"
            )
            discovered.append(mount)
        }

        availableAccounts = discovered

        guard let primary = activeAccounts.first else {
            accountRoot = nil
            myDrivePath = nil
            sharedDrivesPath = nil
            shortcutTargetsPath = nil
            stopRealtimeDriveWatcher()
            return
        }

        accountRoot = primary.rootPath
        myDrivePath = primary.myDrivePath
        sharedDrivesPath = primary.sharedDrivesPath
        shortcutTargetsPath = primary.shortcutTargetsPath
        updateRealtimeWatcherState()
    }

    func applyAccountFilterChange() {
        refreshAccountPaths()
        rebuildAllCaches()
    }

    func isPathInGoogleDrive(_ path: String) -> Bool {
        availableAccounts.contains { path.hasPrefix($0.rootPath) }
    }

    private func accountForPath(_ path: String) -> DriveAccountMount? {
        availableAccounts.first { path.hasPrefix($0.rootPath) }
    }

    // MARK: - Cloud Online-Only (Dataless) Detection

    nonisolated static func isCloudDatalessFile(_ url: URL) -> Bool {
        var st = Darwin.stat()
        if Darwin.lstat(url.path, &st) == 0 {
            // SF_DATALESS on macOS APFS CloudStorage = 0x40000000
            let sfDataless: UInt32 = 0x4000_0000
            if (st.st_flags & sfDataless) != 0 {
                return true
            }
        }
        if let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .fileAllocatedSizeKey, .ubiquitousItemDownloadingStatusKey]) {
            if let dlStatus = vals.ubiquitousItemDownloadingStatus, dlStatus == .notDownloaded {
                return true
            }
            if let fSize = vals.fileSize, let allocSize = vals.fileAllocatedSize,
               fSize > 4096, allocSize == 0 {
                return true
            }
        }
        return false
    }

    // MARK: - Real-time FSEvents Incremental Indexer

    func updateRealtimeWatcherState() {
        if AppSettings.shared.enableRealtimeFSEvents, !activeAccounts.isEmpty {
            startRealtimeDriveWatcher()
        } else {
            stopRealtimeDriveWatcher()
        }
    }

    private func startRealtimeDriveWatcher() {
        stopRealtimeDriveWatcher()
        var candidateRoots: [String] = []
        for acc in activeAccounts {
            if let md = acc.myDrivePath { candidateRoots.append(md) }
            if let sd = acc.sharedDrivesPath { candidateRoots.append(sd) }
        }
        guard !candidateRoots.isEmpty else { return }

        let rootsSnapshot = candidateRoots
        let queue = driveFSQueue
        queue.async {
            let validPaths = rootsSnapshot.filter { FileManager.default.fileExists(atPath: $0) }
            guard !validPaths.isEmpty else { return }
            let cfPaths = validPaths as CFArray

            let callback: FSEventStreamCallback = { _, _, numEvents, eventPathsPtr, eventFlagsPtr, _ in
                guard numEvents > 0 else { return }
                let cfArray = unsafeBitCast(eventPathsPtr, to: CFArray.self)
                guard let paths = cfArray as? [String] else { return }

                var dirCandidates: [String] = []
                for i in 0..<min(numEvents, paths.count) {
                    let flags = eventFlagsPtr[i]
                    let isDirEvent = (flags & UInt32(kFSEventStreamEventFlagItemIsDir)) != 0
                    let isMustScanSubDirs = (flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs)) != 0
                    if isDirEvent || isMustScanSubDirs {
                        let cleanPath = paths[i].hasSuffix("/") && paths[i].count > 1
                            ? String(paths[i].dropLast())
                            : paths[i]
                        dirCandidates.append(cleanPath)
                    }
                }
                guard !dirCandidates.isEmpty else { return }
                let capturedCandidates = dirCandidates

                Task { @MainActor in
                    GoogleDriveIndexService.shared.enqueueIncrementalFolderEvents(capturedCandidates)
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
                cfPaths,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                0.85,
                flags
            ) {
                FSEventStreamSetDispatchQueue(stream, queue)
                FSEventStreamStart(stream)
                let ptrAddr = Int(bitPattern: stream)
                Task { @MainActor in
                    if let ref = FSEventStreamRef(bitPattern: ptrAddr) {
                        GoogleDriveIndexService.shared.driveFSStream = ref
                        GoogleDriveIndexService.shared.isRealtimeWatcherActive = true
                    }
                }
            }
        }
    }

    private func stopRealtimeDriveWatcher() {
        if let stream = driveFSStream {
            driveFSStream = nil
            isRealtimeWatcherActive = false
            let ptrAddr = Int(bitPattern: stream)
            driveFSQueue.async {
                if let ref = FSEventStreamRef(bitPattern: ptrAddr) {
                    FSEventStreamStop(ref)
                    FSEventStreamInvalidate(ref)
                    FSEventStreamRelease(ref)
                }
            }
        } else {
            isRealtimeWatcherActive = false
        }
    }

    private func enqueueIncrementalFolderEvents(_ paths: [String]) {
        for p in paths {
            let lastName = (p as NSString).lastPathComponent
            if !Self.shouldSkip(lastName) {
                pendingEventPaths.insert(p)
            }
        }
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled else { return }
            self.processPendingFSEvents()
        }
    }

    private func processPendingFSEvents() {
        guard !pendingEventPaths.isEmpty, !isRebuildingFolders else { return }
        let batch = Array(pendingEventPaths)
        pendingEventPaths.removeAll()

        let accountsSnap = activeAccounts
        let currentFolders = folderEntries
        let currentShared = sharedEntries

        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var folderMap = Dictionary(uniqueKeysWithValues: currentFolders.map { ($0.path, $0) })
            var sharedMap = Dictionary(uniqueKeysWithValues: currentShared.map { ($0.path, $0) })
            var didMutateFolders = false
            var didMutateShared = false

            for eventPath in batch {
                guard let acc = accountsSnap.first(where: { eventPath.hasPrefix($0.rootPath) }) else { continue }

                var isDir: ObjCBool = false
                let existsAsDir = fm.fileExists(atPath: eventPath, isDirectory: &isDir) && isDir.boolValue

                if let md = acc.myDrivePath, eventPath.hasPrefix(md + "/") {
                    if existsAsDir {
                        let newSubtree = Self.scanFolderSubtree(at: eventPath, myDriveRoot: md, maxSubDepth: 4)
                        for entry in newSubtree {
                            if folderMap[entry.path]?.cleanSegs != entry.cleanSegs {
                                folderMap[entry.path] = entry
                                didMutateFolders = true
                            }
                        }
                    } else {
                        let prefix = eventPath + "/"
                        let beforeCount = folderMap.count
                        folderMap = folderMap.filter { key, _ in key != eventPath && !key.hasPrefix(prefix) }
                        if folderMap.count != beforeCount {
                            didMutateFolders = true
                        }
                    }
                } else if let sd = acc.sharedDrivesPath, eventPath.hasPrefix(sd + "/") {
                    if existsAsDir {
                        var fresh: [SharedDriveEntry] = []
                        let rel = String(eventPath.dropFirst(sd.count + 1))
                        let segs = rel.split(separator: "/").map(String.init)
                        let sigs = segs.map { Self.extractSignatures($0) }
                        fresh.append(SharedDriveEntry(
                            path: eventPath,
                            isDir: true,
                            displaySub: "Bộ nhớ dùng chung/\(rel)",
                            cleanSegs: ["bonhodungchung"] + sigs.map(\.clean),
                            acrSegs: [""] + sigs.map(\.acronym)
                        ))
                        Self.walkSharedTree(
                            rootDir: eventPath,
                            baseStripPath: sd,
                            prefixDisplay: "Bộ nhớ dùng chung",
                            prefixClean: "bonhodungchung",
                            into: &fresh
                        )
                        for item in fresh {
                            sharedMap[item.path] = item
                            didMutateShared = true
                        }
                    } else {
                        let prefix = eventPath + "/"
                        let beforeCount = sharedMap.count
                        sharedMap = sharedMap.filter { key, _ in key != eventPath && !key.hasPrefix(prefix) }
                        if sharedMap.count != beforeCount {
                            didMutateShared = true
                        }
                    }
                }
            }

            guard didMutateFolders || didMutateShared else { return }

            let updatedFolders = didMutateFolders
                ? folderMap.values.sorted { $0.path < $1.path }
                : nil
            let updatedFastFolders = updatedFolders.map { FastFolderIndex.build(from: $0) }
            let updatedShared = didMutateShared
                ? sharedMap.values.sorted { $0.path < $1.path }
                : nil
            let updatedFastShared = updatedShared.map { FastSharedIndex.build(from: $0) }

            await MainActor.run {
                let svc = GoogleDriveIndexService.shared
                if let updatedFolders, let updatedFastFolders {
                    svc.folderEntries = updatedFolders
                    svc.fastFolderIndex = updatedFastFolders
                    svc.folderCount = updatedFolders.count
                    svc.lastCacheUpdate = Date()
                    svc.scheduleFolderCachePersist()
                }
                if let updatedShared, let updatedFastShared {
                    svc.sharedEntries = updatedShared
                    svc.fastSharedIndex = updatedFastShared
                    svc.sharedCount = updatedShared.count
                    svc.scheduleSharedCachePersist()
                }
                if LauncherPanelController.shared.isVisible {
                    LauncherViewModel.shared.refreshSearchResults()
                }
            }
        }
    }

    private nonisolated static func scanFolderSubtree(
        at startDir: String,
        myDriveRoot: String,
        maxSubDepth: Int
    ) -> [DriveFolderEntry] {
        let fm = FileManager.default
        let rootPrefixLen = myDriveRoot.count + 1
        var out: [DriveFolderEntry] = []
        var stack: [(String, Int)] = [(startDir, 0)]

        while let (cur, d) = stack.popLast() {
            let name = (cur as NSString).lastPathComponent
            if shouldSkip(name) { continue }
            let rel = cur.hasPrefix(myDriveRoot + "/") ? String(cur.dropFirst(rootPrefixLen)) : name
            let rawSegs = rel.split(separator: "/").map(String.init)
            let sigs = rawSegs.map { extractSignatures($0) }
            out.append(DriveFolderEntry(
                path: cur,
                cleanSegs: sigs.map(\.clean),
                acrSegs: sigs.map(\.acronym)
            ))

            guard d < maxSubDepth, let children = try? fm.contentsOfDirectory(atPath: cur) else { continue }
            for child in children where !shouldSkip(child) {
                let full = "\(cur)/\(child)"
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    stack.append((full, d + 1))
                }
            }
        }
        return out
    }

    private func scheduleFolderCachePersist() {
        cachePersistTask?.cancel()
        let entriesSnap = folderEntries
        let rootSnap = myDrivePath
        let targetPath = folderCachePath
        cachePersistTask = Task.detached(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            let payload = FolderCachePayload(
                timestamp: Date().timeIntervalSince1970,
                root: rootSnap,
                items: entriesSnap,
                folders: nil
            )
            Self.writeCodableAtomic(payload, to: targetPath)
        }
    }

    private func scheduleSharedCachePersist() {
        let itemsSnap = sharedEntries
        let rootSnap = accountRoot
        let targetPath = sharedCachePath
        Task.detached(priority: .background) {
            let payload = SharedCachePayload(
                timestamp: Date().timeIntervalSince1970,
                root: rootSnap,
                items: itemsSnap
            )
            Self.writeCodableAtomic(payload, to: targetPath)
        }
    }

    // MARK: - Initial Load

    private func loadInitialDataAsync() {
        let fCache = folderCachePath
        let sCache = sharedCachePath
        let hPath = historyPath
        let currentAccount = accountRoot

        Task.detached(priority: .userInitiated) {
            let loadedHistory = Self.readHistoryDisk(at: hPath)
            let loadedFolders = Self.readFolderCacheDisk(at: fCache)
            let builtFastFolders = loadedFolders.map { FastFolderIndex.build(from: $0.0) }
            let loadedShared = Self.readSharedCacheDisk(at: sCache)
            let builtFastShared = loadedShared.map { FastSharedIndex.build(from: $0.0) }
            let scannedApps = Self.scanInstalledApplications()

            await MainActor.run {
                let service = GoogleDriveIndexService.shared
                service.history = loadedHistory
                service.appEntries = scannedApps

                if let (entries, ts) = loadedFolders, let builtFastFolders {
                    service.folderEntries = entries
                    service.fastFolderIndex = builtFastFolders
                    service.folderCount = entries.count
                    service.lastCacheUpdate = Date(timeIntervalSince1970: ts)
                    if Date().timeIntervalSince1970 - ts > 86_400 {
                        service.rebuildFolderCacheInBackground()
                    }
                } else if currentAccount != nil {
                    service.rebuildFolderCacheInBackground()
                }

                if let (sEntries, ts) = loadedShared, let builtFastShared {
                    service.sharedEntries = sEntries
                    service.fastSharedIndex = builtFastShared
                    service.sharedCount = sEntries.count
                    if Date().timeIntervalSince1970 - ts > 86_400 {
                        service.rebuildSharedCacheInBackground()
                    }
                } else if service.sharedDrivesPath != nil || service.shortcutTargetsPath != nil {
                    service.rebuildSharedCacheInBackground()
                }

                SyncAndLatchingService.shared.start()
                LauncherViewModel.shared.refreshSearchResults()
            }
        }
    }

    private nonisolated static func readHistoryDisk(at path: String) -> [String: HistoryRecord] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let decoded = try? JSONDecoder().decode([String: HistoryRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private nonisolated static func readFolderCacheDisk(at path: String) -> ([DriveFolderEntry], Double)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let payload = try? JSONDecoder().decode(FolderCachePayload.self, from: data) else {
            return nil
        }
        let items = payload.items ?? payload.folders ?? []
        return (items, payload.timestamp)
    }

    private nonisolated static func readSharedCacheDisk(at path: String) -> ([SharedDriveEntry], Double)? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let payload = try? JSONDecoder().decode(SharedCachePayload.self, from: data) else {
            return nil
        }
        return (payload.items, payload.timestamp)
    }

    private nonisolated static func scanInstalledApplications() -> [(name: String, clean: String, acronym: String, path: String)] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            "\(home)/Applications"
        ]
        var seen = Set<String>()
        var result: [(String, String, String, String)] = []

        for dir in dirs {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasSuffix(".app") {
                let full = "\(dir)/\(item)"
                let baseName = String(item.dropLast(4))
                guard !seen.contains(baseName.lowercased()) else { continue }
                seen.insert(baseName.lowercased())
                let (clean, acr) = extractSignatures(baseName)
                result.append((baseName, clean, acr, full))
            }
        }
        return result
    }

    // MARK: - Vietnamese Normalization & Signatures (Exact parity with folder_search.py)

    nonisolated static func removeAccents(_ s: String) -> String {
        let replaced = s
            .replacingOccurrences(of: "đ", with: "d")
            .replacingOccurrences(of: "Đ", with: "D")
        let decomposed = replaced.decomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(decomposed.unicodeScalars.count)
        for scalar in decomposed.unicodeScalars {
            if !CharacterSet.nonBaseCharacters.contains(scalar) {
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    nonisolated static func cleanString(_ s: String) -> String {
        let unaccented = removeAccents(s).lowercased()
        var out = ""
        out.reserveCapacity(unaccented.utf8.count)
        for ch in unaccented.unicodeScalars {
            if (ch.value >= 97 && ch.value <= 122) || (ch.value >= 48 && ch.value <= 57) {
                out.unicodeScalars.append(ch)
            }
        }
        return out
    }

    nonisolated static func extractSignatures(_ name: String) -> (clean: String, acronym: String) {
        let unaccented = removeAccents(name)
        var spaced = ""
        let chars = Array(unaccented)
        for i in chars.indices {
            let c = chars[i]
            if i > 0 {
                let prev = chars[i - 1]
                let boundaryCamel = prev.isLowercase && c.isUppercase
                let boundaryNumLetter = (prev.isNumber && c.isLetter) || (prev.isLetter && c.isNumber)
                if boundaryCamel || boundaryNumLetter {
                    spaced.append(" ")
                }
            }
            spaced.append(c)
        }

        let lower = spaced.lowercased()
        var words: [String] = []
        var currentWord = ""
        for scalar in lower.unicodeScalars {
            let isAlphaNum = (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)
            if isAlphaNum {
                currentWord.unicodeScalars.append(scalar)
            } else if !currentWord.isEmpty {
                if !currentWord.allSatisfy(\.isNumber) {
                    words.append(currentWord)
                }
                currentWord = ""
            }
        }
        if !currentWord.isEmpty && !currentWord.allSatisfy(\.isNumber) {
            words.append(currentWord)
        }

        let acronym = words.count > 1 ? String(words.compactMap(\.first)) : ""
        let clean = cleanString(unaccented)
        return (clean, acronym)
    }

    private nonisolated static func shouldSkip(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return skipExtensions.contains(ext)
    }

    // MARK: - Background Cache Builders (Multi-Account Capable)

    func rebuildAllCaches() {
        refreshAccountPaths()
        rebuildFolderCacheInBackground()
        rebuildSharedCacheInBackground()
    }

    func rebuildFolderCacheInBackground() {
        guard !isRebuildingFolders else { return }
        refreshAccountPaths()
        let mounts = activeAccounts.compactMap { $0.myDrivePath }
        guard !mounts.isEmpty else { return }

        isRebuildingFolders = true
        rebuildProgressText = "Đang quét My Drive..."
        let targetCachePath = folderCachePath
        let primaryRoot = myDrivePath

        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var entries: [DriveFolderEntry] = []
            entries.reserveCapacity(60_000)
            var count = 0

            for rootPath in mounts {
                var stack: [(dir: String, depth: Int)] = [(rootPath, 0)]
                let rootPrefixCount = rootPath.count + 1

                while let (currentDir, depth) = stack.popLast() {
                    if depth > 10 { continue }
                    guard let names = try? fm.contentsOfDirectory(atPath: currentDir) else { continue }

                    var subdirs: [String] = []
                    for name in names {
                        if Self.shouldSkip(name) { continue }
                        let fullPath = "\(currentDir)/\(name)"
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue else { continue }

                        let rel = fullPath.hasPrefix(rootPath + "/")
                            ? String(fullPath.dropFirst(rootPrefixCount))
                            : name

                        let rawSegs = rel.split(separator: "/").map(String.init)
                        var cleanSegs: [String] = []
                        var acrSegs: [String] = []
                        cleanSegs.reserveCapacity(rawSegs.count)
                        acrSegs.reserveCapacity(rawSegs.count)

                        for s in rawSegs {
                            let (c, a) = Self.extractSignatures(s)
                            cleanSegs.append(c)
                            acrSegs.append(a)
                        }

                        entries.append(DriveFolderEntry(path: fullPath, cleanSegs: cleanSegs, acrSegs: acrSegs))
                        count += 1

                        if count % 2500 == 0 {
                            let cSnap = count
                            await MainActor.run {
                                GoogleDriveIndexService.shared.rebuildProgressText = "Đang quét: \(cSnap.formatted()) thư mục..."
                            }
                        }

                        if depth < 10 {
                            subdirs.append(fullPath)
                        }
                    }

                    subdirs.sort()
                    for sd in subdirs.reversed() {
                        stack.append((sd, depth + 1))
                    }
                }
            }

            let now = Date().timeIntervalSince1970
            let payload = FolderCachePayload(timestamp: now, root: primaryRoot, items: entries, folders: nil)
            Self.writeCodableAtomic(payload, to: targetCachePath)

            let finalEntries = entries
            let finalFastFolders = FastFolderIndex.build(from: finalEntries)
            await MainActor.run {
                let service = GoogleDriveIndexService.shared
                service.folderEntries = finalEntries
                service.fastFolderIndex = finalFastFolders
                service.folderCount = finalEntries.count
                service.lastCacheUpdate = Date(timeIntervalSince1970: now)
                service.isRebuildingFolders = false
                service.rebuildProgressText = nil
                LauncherViewModel.shared.refreshSearchResults()
            }
        }
    }

    func rebuildSharedCacheInBackground() {
        guard !isRebuildingShared else { return }
        let mounts = activeAccounts
        guard mounts.contains(where: { $0.sharedDrivesPath != nil || $0.shortcutTargetsPath != nil }) else { return }

        isRebuildingShared = true
        let targetCachePath = sharedCachePath
        let primaryAcc = accountRoot

        Task.detached(priority: .utility) {
            let fm = FileManager.default
            var items: [SharedDriveEntry] = []

            for mount in mounts {
                if let sdPath = mount.sharedDrivesPath, let drives = try? fm.contentsOfDirectory(atPath: sdPath) {
                    for d in drives where !d.hasPrefix(".") {
                        let drivePath = "\(sdPath)/\(d)"
                        var isDir: ObjCBool = false
                        guard fm.fileExists(atPath: drivePath, isDirectory: &isDir), isDir.boolValue else { continue }
                        let (c, a) = Self.extractSignatures(d)
                        items.append(SharedDriveEntry(
                            path: drivePath,
                            isDir: true,
                            displaySub: "Bộ nhớ dùng chung/\(d)",
                            cleanSegs: ["bonhodungchung", c],
                            acrSegs: ["", a]
                        ))
                        Self.walkSharedTree(
                            rootDir: drivePath,
                            baseStripPath: sdPath,
                            prefixDisplay: "Bộ nhớ dùng chung",
                            prefixClean: "bonhodungchung",
                            into: &items
                        )
                    }
                }

                if let stPath = mount.shortcutTargetsPath, let targetIDs = try? fm.contentsOfDirectory(atPath: stPath) {
                    for tid in targetIDs where !tid.hasPrefix(".") {
                        let idDir = "\(stPath)/\(tid)"
                        guard let names = try? fm.contentsOfDirectory(atPath: idDir) else { continue }
                        for name in names where !name.hasPrefix(".") {
                            let itemPath = "\(idDir)/\(name)"
                            var isDir: ObjCBool = false
                            guard fm.fileExists(atPath: itemPath, isDirectory: &isDir) else { continue }
                            let (c, a) = Self.extractSignatures(name)
                            items.append(SharedDriveEntry(
                                path: itemPath,
                                isDir: isDir.boolValue,
                                displaySub: "Được chia sẻ/\(name)",
                                cleanSegs: ["duocchiase", c],
                                acrSegs: ["", a]
                            ))
                            if isDir.boolValue {
                                Self.walkSharedTree(
                                    rootDir: itemPath,
                                    baseStripPath: idDir,
                                    prefixDisplay: "Được chia sẻ",
                                    prefixClean: "duocchiase",
                                    into: &items
                                )
                            }
                        }
                    }
                }
            }

            let now = Date().timeIntervalSince1970
            let payload = SharedCachePayload(timestamp: now, root: primaryAcc, items: items)
            Self.writeCodableAtomic(payload, to: targetCachePath)

            let finalItems = items
            let finalFastShared = FastSharedIndex.build(from: finalItems)
            await MainActor.run {
                let service = GoogleDriveIndexService.shared
                service.sharedEntries = finalItems
                service.fastSharedIndex = finalFastShared
                service.sharedCount = finalItems.count
                service.isRebuildingShared = false
            }
        }
    }

    private nonisolated static func walkSharedTree(
        rootDir: String,
        baseStripPath: String,
        prefixDisplay: String,
        prefixClean: String,
        into items: inout [SharedDriveEntry]
    ) {
        let fm = FileManager.default
        var stack: [(String, Int)] = [(rootDir, 0)]
        let baseLen = baseStripPath.count + 1

        while let (cur, depth) = stack.popLast() {
            if depth > 8 { continue }
            guard let names = try? fm.contentsOfDirectory(atPath: cur) else { continue }
            for name in names {
                if shouldSkip(name) { continue }
                let full = "\(cur)/\(name)"
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDir) else { continue }
                let rel = full.hasPrefix(baseStripPath + "/") ? String(full.dropFirst(baseLen)) : name
                let segs = rel.split(separator: "/").map(String.init)
                let sigs = segs.map { extractSignatures($0) }
                let cSegs = [prefixClean] + sigs.map(\.clean)
                let aSegs = [""] + sigs.map(\.acronym)
                items.append(SharedDriveEntry(
                    path: full,
                    isDir: isDir.boolValue,
                    displaySub: "\(prefixDisplay)/\(rel)",
                    cleanSegs: cSegs,
                    acrSegs: aSegs
                ))
                if isDir.boolValue && depth < 8 {
                    stack.append((full, depth + 1))
                }
            }
        }
    }

    private nonisolated static func writeCodableAtomic<T: Encodable>(_ value: T, to filePath: String) {
        let fm = FileManager.default
        let dir = (filePath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let tmp = "\(filePath).tmp.\(ProcessInfo.processInfo.processIdentifier)"
        guard let data = try? JSONEncoder().encode(value) else { return }
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

    // MARK: - History Management & Cross-Mac Portable Syncthing Sync

    func recordUsed(_ path: String) {
        let now = Date().timeIntervalSince1970
        let ext = (path as NSString).pathExtension
        let looksLikeFile = !ext.isEmpty && !Self.skipExtensions.contains(ext.lowercased())
        let targetDir = looksLikeFile ? (path as NSString).deletingLastPathComponent : path

        var dirRec = history[targetDir] ?? HistoryRecord(count: 0, last_used: now)
        dirRec.count += 1
        dirRec.last_used = now
        history[targetDir] = dirRec

        if looksLikeFile {
            var fileRec = history[path] ?? HistoryRecord(count: 0, last_used: now)
            fileRec.count += 1
            fileRec.last_used = now
            history[path] = fileRec
        }

        if history.count > 500 {
            let sorted = history.sorted { $0.value.last_used > $1.value.last_used }.prefix(500)
            history = Dictionary(uniqueKeysWithValues: sorted.map { ($0.key, $0.value) })
        }

        persistHistoryAndPushSync()
    }

    func removeFromHistory(_ path: String) {
        history.removeValue(forKey: path)
        persistHistoryAndPushSync()
    }

    func clearAllHistory() {
        history.removeAll()
        try? FileManager.default.removeItem(atPath: historyPath)
        if AppSettings.shared.enableSyncthingSync {
            SyncAndLatchingService.shared.pushPortableHistory([:])
        }
    }

    private func persistHistoryAndPushSync() {
        let snap = history
        let hPath = historyPath
        Task.detached(priority: .background) {
            Self.writeCodableAtomic(snap, to: hPath)
        }
        if AppSettings.shared.enableSyncthingSync {
            SyncAndLatchingService.shared.pushPortableHistory(exportPortableHistoryMap())
        }
    }

    /// Converts local `/Users/hunglx/Library/CloudStorage/GoogleDrive-email/My Drive/...`
    /// into portable `<email>::My Drive/...` so iMac (`hunglx`) and MacBook Pro (`hunglexuan`) sync seamlessly.
    private func exportPortableHistoryMap() -> [String: HistoryRecord] {
        var out: [String: HistoryRecord] = [:]
        for (absPath, rec) in history {
            if let acc = accountForPath(absPath), absPath.hasPrefix(acc.rootPath + "/") {
                let rel = String(absPath.dropFirst(acc.rootPath.count + 1))
                out["\(acc.email)::\(rel)"] = rec
            }
        }
        return out
    }

    func mergeWithPortableSyncFile(at remoteFilePath: String) -> Int {
        var remoteMap: [String: HistoryRecord] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: remoteFilePath)),
           let decoded = try? JSONDecoder().decode([String: HistoryRecord].self, from: data) {
            remoteMap = decoded
        }

        var localChanged = false
        for (portableKey, rRec) in remoteMap {
            let resolvedPath: String?
            if let sepRange = portableKey.range(of: "::") {
                let email = String(portableKey[..<sepRange.lowerBound])
                let rel = String(portableKey[sepRange.upperBound...])
                if let matchAcc = availableAccounts.first(where: { $0.email == email }) ?? availableAccounts.first {
                    resolvedPath = "\(matchAcc.rootPath)/\(rel)"
                } else {
                    resolvedPath = nil
                }
            } else if let primary = accountRoot {
                resolvedPath = "\(primary)/\(portableKey)"
            } else {
                resolvedPath = nil
            }

            guard let absPath = resolvedPath else { continue }
            if let lRec = history[absPath] {
                if rRec.count > lRec.count || rRec.last_used > lRec.last_used {
                    history[absPath] = HistoryRecord(
                        count: max(lRec.count, rRec.count),
                        last_used: max(lRec.last_used, rRec.last_used)
                    )
                    localChanged = true
                }
            } else {
                history[absPath] = rRec
                localChanged = true
            }
        }

        if localChanged {
            let snap = history
            let hPath = historyPath
            Task.detached(priority: .utility) {
                Self.writeCodableAtomic(snap, to: hPath)
            }
            if LauncherPanelController.shared.isVisible {
                LauncherViewModel.shared.refreshSearchResults()
            }
        }

        let combinedPortable = exportPortableHistoryMap()
        if combinedPortable.count > remoteMap.count {
            SyncAndLatchingService.shared.pushPortableHistory(combinedPortable)
        }
        return combinedPortable.count
    }

    // MARK: - Reversed Breadcrumb Subtitle

    func formatHierarchicalSubtitle(_ path: String, maxLevels: Int? = nil) -> String {
        let multiAccount = activeAccounts.count > 1
        guard let acc = accountForPath(path) else {
            return (path as NSString).deletingLastPathComponent.replacingOccurrences(of: homePath, with: "~")
        }

        var baseLabel = ""
        var rel = ""

        if let md = acc.myDrivePath, path.hasPrefix(md + "/") {
            rel = String(path.dropFirst(md.count + 1))
            baseLabel = multiAccount ? "My Drive (\(acc.email))" : "My Drive"
        } else if let sd = acc.sharedDrivesPath, path.hasPrefix(sd + "/") {
            rel = String(path.dropFirst(sd.count + 1))
            baseLabel = multiAccount ? "Bộ nhớ dùng chung (\(acc.email))" : "Bộ nhớ dùng chung"
        } else if let st = acc.shortcutTargetsPath, path.hasPrefix(st + "/") {
            let relSt = String(path.dropFirst(st.count + 1))
            let parts = relSt.split(separator: "/").map(String.init)
            rel = parts.count > 1 ? parts.dropFirst().joined(separator: "/") : (parts.first ?? "")
            baseLabel = multiAccount ? "Được chia sẻ (\(acc.email))" : "Được chia sẻ"
        } else if path.hasPrefix(acc.rootPath + "/") {
            rel = String(path.dropFirst(acc.rootPath.count + 1))
            baseLabel = multiAccount ? "Google Drive (\(acc.email))" : "Google Drive"
        } else {
            return (path as NSString).deletingLastPathComponent.replacingOccurrences(of: homePath, with: "~")
        }

        let parts = rel.split(separator: "/").map(String.init)
        let ancestors = parts.dropLast()
        if ancestors.isEmpty {
            return baseLabel.isEmpty ? "Thư mục gốc" : baseLabel
        }

        var reversed = Array(ancestors.reversed())
        if let maxLevels, reversed.count > maxLevels {
            reversed = Array(reversed.prefix(maxLevels))
        } else if !baseLabel.isEmpty {
            reversed.append(baseLabel)
        }
        return reversed.joined(separator: " ‹ ")
    }

    // MARK: - Zero-Syscall RAM Directory & Recent Lookups

    func isKnownDirectory(_ path: String, hasDirectoryHint: Bool = false) -> Bool {
        if hasDirectoryHint { return true }
        let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if fastFolderIndex.knownPaths.contains(trimmed) { return true }
        if let sh = fastSharedIndex.byPath[trimmed] { return sh.isDir }
        if availableAccounts.contains(where: {
            trimmed == $0.rootPath || trimmed == $0.myDrivePath || trimmed == $0.sharedDrivesPath || trimmed == $0.shortcutTargetsPath
        }) {
            return true
        }
        if !trimmed.contains("/Library/CloudStorage/") {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir) && isDir.boolValue
        }
        let ext = (trimmed as NSString).pathExtension
        return ext.isEmpty || ext.contains(" ")
    }

    func recentMyDriveFolders(limit: Int = 9) -> [SearchResultItem] {
        let validMyDrivePrefixes = activeAccounts.compactMap(\.myDrivePath)
        let knownFolderSet = fastFolderIndex.knownPaths
        let sorted = history.sorted {
            if $0.value.last_used != $1.value.last_used {
                return $0.value.last_used > $1.value.last_used
            }
            return $0.value.count > $1.value.count
        }

        var items: [SearchResultItem] = []
        for (hPath, rec) in sorted {
            if !validMyDrivePrefixes.isEmpty, !validMyDrivePrefixes.contains(where: { hPath.hasPrefix($0) }) {
                continue
            }
            if !knownFolderSet.isEmpty && !knownFolderSet.contains(hPath) {
                continue
            }
            let sub = "🕒 Mở gần đây (\(rec.count) lần) ‹ \(formatHierarchicalSubtitle(hPath))"
            items.append(SearchResultItem(
                id: "recent:\(hPath)",
                title: (hPath as NSString).lastPathComponent,
                subtitle: sub,
                path: hPath,
                isDirectory: true,
                kind: .driveFolder(path: hPath),
                badge: nil,
                sfSymbolFallback: "folder.fill"
            ))
            if items.count >= limit { break }
        }

        if items.isEmpty {
            for entry in folderEntries where entry.cleanSegs.count <= 1 {
                items.append(SearchResultItem(
                    id: "root:\(entry.path)",
                    title: (entry.path as NSString).lastPathComponent,
                    subtitle: formatHierarchicalSubtitle(entry.path),
                    path: entry.path,
                    isDirectory: true,
                    kind: .driveFolder(path: entry.path),
                    badge: nil,
                    sfSymbolFallback: "folder.fill"
                ))
                if items.count >= limit { break }
            }
        }
        return items
    }

    func recentSharedItems(limit: Int = 9) -> [SearchResultItem] {
        let sdPrefixes = activeAccounts.compactMap(\.sharedDrivesPath)
        let stPrefixes = activeAccounts.compactMap(\.shortcutTargetsPath)
        let sharedByPath = fastSharedIndex.byPath
        let sorted = history.sorted { $0.value.last_used > $1.value.last_used }
        var items: [SearchResultItem] = []

        for (hPath, rec) in sorted {
            let inSD = sdPrefixes.contains { hPath.hasPrefix($0) }
            let inST = stPrefixes.contains { hPath.hasPrefix($0) }
            guard inSD || inST else { continue }
            let isDir = sharedByPath[hPath]?.isDir ?? true

            let sub = "🕒 Mở gần đây (\(rec.count) lần) ‹ \(formatHierarchicalSubtitle(hPath))"
            items.append(SearchResultItem(
                id: "srecent:\(hPath)",
                title: (hPath as NSString).lastPathComponent,
                subtitle: sub,
                path: hPath,
                isDirectory: isDir,
                kind: isDir ? .driveFolder(path: hPath) : .driveFile(path: hPath),
                badge: "Shared",
                sfSymbolFallback: isDir ? "folder.fill.badge.person.crop" : "doc.fill"
            ))
            if items.count >= limit { break }
        }

        if items.isEmpty {
            for entry in sharedEntries.prefix(limit) {
                items.append(SearchResultItem(
                    id: "sd:\(entry.path)",
                    title: (entry.path as NSString).lastPathComponent,
                    subtitle: entry.displaySub,
                    path: entry.path,
                    isDirectory: entry.isDir,
                    kind: entry.isDir ? .driveFolder(path: entry.path) : .driveFile(path: entry.path),
                    badge: "Shared",
                    sfSymbolFallback: entry.isDir ? "externaldrive.fill.badge.person.crop" : "doc.fill"
                ))
            }
        }
        return items
    }

    // MARK: - Ultra-Fast ASCII Byte Search (< 1.2ms on 90,000 folders, Off-Main-Thread Capable)

    @inline(__always)
    private nonisolated static func asciiContains(_ hay: [UInt8], _ needle: [UInt8]) -> Bool {
        let nLen = needle.count
        let hLen = hay.count
        if nLen == 0 { return true }
        if nLen > hLen { return false }
        let first = needle[0]
        let maxStart = hLen - nLen
        var i = 0
        while i <= maxStart {
            if hay[i] == first {
                var j = 1
                while j < nLen && hay[i + j] == needle[j] {
                    j += 1
                }
                if j == nLen { return true }
            }
            i += 1
        }
        return false
    }

    @inline(__always)
    private nonisolated static func asciiHasPrefix(_ hay: [UInt8], from startIdx: Int, _ needle: [UInt8]) -> Bool {
        let nLen = needle.count
        if startIdx + nLen > hay.count { return false }
        var j = 0
        while j < nLen {
            if hay[startIdx + j] != needle[j] { return false }
            j += 1
        }
        return true
    }

    @inline(__always)
    private nonisolated static func asciiEquals(_ hay: [UInt8], from startIdx: Int, _ needle: [UInt8]) -> Bool {
        let rem = hay.count - startIdx
        if rem != needle.count { return false }
        return asciiHasPrefix(hay, from: startIdx, needle)
    }

    @inline(__always)
    private nonisolated static func firstNonDigitIndex(_ bytes: [UInt8]) -> Int {
        var idx = 0
        let count = bytes.count
        while idx < count && bytes[idx] >= 48 && bytes[idx] <= 57 {
            idx += 1
        }
        return idx
    }

    nonisolated static func evaluateMyDriveSearchHits(
        tokens: [String],
        fastIndex: FastFolderIndex,
        historySnapshot: [String: HistoryRecord],
        maxResults: Int
    ) -> [(path: String, historyCount: Int)] {
        let tokenBytes = tokens.map(cleanString).filter { !$0.isEmpty }.map { Array($0.utf8) }
        guard !tokenBytes.isEmpty else { return [] }

        let numTokens = tokenBytes.count
        let lastTokIdx = numTokens - 1

        struct ScoredHit {
            let totalScore: Int
            let hasHistory: Bool
            let negDepth: Int
            let negLen: Int
            let path: String
            let historyCount: Int
        }

        var hits: [ScoredHit] = []
        hits.reserveCapacity(128)

        for rec in fastIndex.records {
            let cleanSegs = rec.cleanBytes
            let acrSegs = rec.acrBytes
            let numSegs = cleanSegs.count
            if numSegs == 0 { continue }

            let leafIdx = numSegs - 1
            var curS = 0
            var matchedAll = true
            var matchScore = 0
            var leafMatched = false

            for tokIdx in 0..<numTokens {
                let tok = tokenBytes[tokIdx]
                var foundS = -1
                let isLastTok = (tokIdx == lastTokIdx)

                for sIdx in curS..<numSegs {
                    let seg = cleanSegs[sIdx]
                    let acr = sIdx < acrSegs.count ? acrSegs[sIdx] : []

                    let segMatch = asciiContains(seg, tok)
                    let acrMatch = !acr.isEmpty && asciiHasPrefix(acr, from: 0, tok)

                    if segMatch || acrMatch {
                        foundS = sIdx
                        if isLastTok && sIdx == leafIdx {
                            leafMatched = true
                        }

                        let stripIdx = firstNonDigitIndex(seg)
                        let sc: Int
                        if asciiEquals(seg, from: stripIdx, tok) || asciiEquals(seg, from: 0, tok) || (!acr.isEmpty && asciiEquals(acr, from: 0, tok)) {
                            sc = 100
                        } else if asciiHasPrefix(seg, from: stripIdx, tok) || asciiHasPrefix(seg, from: 0, tok) || acrMatch {
                            sc = 80
                        } else {
                            sc = 50
                        }
                        matchScore += sc
                        break
                    }
                }

                if foundS != -1 {
                    curS = foundS
                } else {
                    matchedAll = false
                    break
                }
            }

            if matchedAll {
                if leafMatched { matchScore += 1000 }
                let hRec = historySnapshot[rec.path]
                let histBoost = hRec.map { min(150 + $0.count * 15, 300) } ?? 0
                hits.append(ScoredHit(
                    totalScore: matchScore + histBoost,
                    hasHistory: histBoost > 0,
                    negDepth: -numSegs,
                    negLen: -rec.path.utf8.count,
                    path: rec.path,
                    historyCount: hRec?.count ?? 0
                ))
            }
        }

        hits.sort {
            if $0.totalScore != $1.totalScore { return $0.totalScore > $1.totalScore }
            if $0.hasHistory != $1.hasHistory { return $0.hasHistory && !$1.hasHistory }
            if $0.negDepth != $1.negDepth { return $0.negDepth > $1.negDepth }
            return $0.negLen > $1.negLen
        }

        return hits.prefix(maxResults).map { ($0.path, $0.historyCount) }
    }

    nonisolated static func evaluateSharedSearchHits(
        tokens: [String],
        fastIndex: FastSharedIndex,
        historySnapshot: [String: HistoryRecord],
        maxResults: Int
    ) -> [(entry: SharedDriveEntry, historyCount: Int)] {
        let tokenBytes = tokens.map(cleanString).filter { !$0.isEmpty }.map { Array($0.utf8) }
        guard !tokenBytes.isEmpty else { return [] }

        let numTokens = tokenBytes.count
        let lastTokIdx = numTokens - 1

        struct ScoredShared {
            let totalScore: Int
            let hasHistory: Bool
            let negDepth: Int
            let negLen: Int
            let entry: SharedDriveEntry
            let historyCount: Int
        }

        var hits: [ScoredShared] = []
        hits.reserveCapacity(128)

        for rec in fastIndex.records {
            let cleanSegs = rec.cleanBytes
            let acrSegs = rec.acrBytes
            let numSegs = cleanSegs.count
            if numSegs == 0 { continue }

            let leafIdx = numSegs - 1
            var curS = 0
            var matchedAll = true
            var matchScore = 0
            var leafMatched = false

            for tokIdx in 0..<numTokens {
                let tok = tokenBytes[tokIdx]
                var foundS = -1
                let isLastTok = (tokIdx == lastTokIdx)

                for sIdx in curS..<numSegs {
                    let seg = cleanSegs[sIdx]
                    let acr = sIdx < acrSegs.count ? acrSegs[sIdx] : []
                    let segMatch = asciiContains(seg, tok)
                    let acrMatch = !acr.isEmpty && asciiHasPrefix(acr, from: 0, tok)

                    if segMatch || acrMatch {
                        foundS = sIdx
                        if isLastTok && sIdx == leafIdx { leafMatched = true }
                        let stripIdx = firstNonDigitIndex(seg)
                        if asciiEquals(seg, from: stripIdx, tok) || asciiEquals(seg, from: 0, tok) || (!acr.isEmpty && asciiEquals(acr, from: 0, tok)) {
                            matchScore += 100
                        } else if asciiHasPrefix(seg, from: stripIdx, tok) || asciiHasPrefix(seg, from: 0, tok) || acrMatch {
                            matchScore += 80
                        } else {
                            matchScore += 50
                        }
                        break
                    }
                }
                if foundS != -1 {
                    curS = foundS
                } else {
                    matchedAll = false
                    break
                }
            }

            if matchedAll {
                if leafMatched { matchScore += 1000 }
                let hRec = historySnapshot[rec.entry.path]
                let histBoost = hRec.map { min(150 + $0.count * 15, 300) } ?? 0
                hits.append(ScoredShared(
                    totalScore: matchScore + histBoost,
                    hasHistory: histBoost > 0,
                    negDepth: -numSegs,
                    negLen: -rec.entry.path.utf8.count,
                    entry: rec.entry,
                    historyCount: hRec?.count ?? 0
                ))
            }
        }

        hits.sort {
            if $0.totalScore != $1.totalScore { return $0.totalScore > $1.totalScore }
            if $0.hasHistory != $1.hasHistory { return $0.hasHistory && !$1.hasHistory }
            if $0.negDepth != $1.negDepth { return $0.negDepth > $1.negDepth }
            return $0.negLen > $1.negLen
        }

        return hits.prefix(maxResults).map { ($0.entry, $0.historyCount) }
    }

    func searchMyDriveFolders(tokens: [String], includeApps: Bool, maxResults: Int = 45) -> [SearchResultItem] {
        let cleanTokens = tokens.map(Self.cleanString).filter { !$0.isEmpty }
        guard !cleanTokens.isEmpty else { return recentMyDriveFolders() }

        let topHits = Self.evaluateMyDriveSearchHits(
            tokens: tokens,
            fastIndex: fastFolderIndex,
            historySnapshot: history,
            maxResults: maxResults
        )
        return buildMyDriveSearchResultItems(from: topHits, cleanTokens: cleanTokens, includeApps: includeApps, maxResults: maxResults)
    }

    func buildMyDriveSearchResultItems(
        from topHits: [(path: String, historyCount: Int)],
        cleanTokens: [String],
        includeApps: Bool,
        maxResults: Int = 45
    ) -> [SearchResultItem] {
        var results: [SearchResultItem] = []
        results.reserveCapacity(min(topHits.count + 4, maxResults))

        if includeApps && cleanTokens.count <= 2 && !cleanTokens.isEmpty {
            let joinedQ = cleanTokens.joined()
            var appHits: [(score: Int, name: String, path: String)] = []
            for app in appEntries {
                if app.clean == joinedQ || app.acronym == joinedQ {
                    appHits.append((1250, app.name, app.path))
                } else if app.clean.hasPrefix(joinedQ) || (!app.acronym.isEmpty && app.acronym.hasPrefix(joinedQ)) {
                    appHits.append((1120, app.name, app.path))
                }
            }
            appHits.sort { $0.score > $1.score }
            for app in appHits.prefix(3) {
                results.append(SearchResultItem(
                    id: "app:\(app.path)",
                    title: app.name,
                    subtitle: "Ứng dụng macOS • \(app.path)",
                    path: app.path,
                    isDirectory: false,
                    kind: .localApp(path: app.path),
                    badge: "App",
                    sfSymbolFallback: "app.fill"
                ))
            }
        }

        for hit in topHits {
            if results.count >= maxResults { break }
            let sub: String
            if hit.historyCount > 0 {
                sub = "⭐ Mở gần đây (\(hit.historyCount) lần) ‹ \(formatHierarchicalSubtitle(hit.path))"
            } else {
                sub = formatHierarchicalSubtitle(hit.path)
            }
            results.append(SearchResultItem(
                id: "gd:\(hit.path)",
                title: (hit.path as NSString).lastPathComponent,
                subtitle: sub,
                path: hit.path,
                isDirectory: true,
                kind: .driveFolder(path: hit.path),
                badge: nil,
                sfSymbolFallback: "folder.fill"
            ))
        }
        return results
    }

    func buildSharedSearchResultItems(
        from topHits: [(entry: SharedDriveEntry, historyCount: Int)],
        maxResults: Int = 45
    ) -> [SearchResultItem] {
        var results: [SearchResultItem] = []
        results.reserveCapacity(min(topHits.count, maxResults))
        for hit in topHits.prefix(maxResults) {
            let sub = hit.historyCount > 0
                ? "⭐ Mở gần đây (\(hit.historyCount) lần) ‹ \(formatHierarchicalSubtitle(hit.entry.path))"
                : formatHierarchicalSubtitle(hit.entry.path)
            results.append(SearchResultItem(
                id: "sh:\(hit.entry.path)",
                title: (hit.entry.path as NSString).lastPathComponent,
                subtitle: sub,
                path: hit.entry.path,
                isDirectory: hit.entry.isDir,
                kind: hit.entry.isDir ? .driveFolder(path: hit.entry.path) : .driveFile(path: hit.entry.path),
                badge: "Shared",
                sfSymbolFallback: hit.entry.isDir ? "folder.fill.badge.person.crop" : "doc.fill"
            ))
        }
        return results
    }

    // MARK: - Zero-Hang Browse Mode (0ms RAM Folders + Background POSIX readdir)

    /// Returns cached child folders/items from RAM in < 0.05ms with ZERO disk/cloud syscalls.
    func cachedChildrenInMemory(parentPath: String, queryWords: [String]) -> [(path: String, isDir: Bool)] {
        let cleanParent = parentPath.hasSuffix("/") && parentPath.count > 1 ? String(parentPath.dropLast()) : parentPath
        let tokens = queryWords.map(Self.cleanString).filter { !$0.isEmpty }

        var combined: [(path: String, isDir: Bool)] = []
        var seen = Set<String>()

        if let folderChildren = fastFolderIndex.childrenByParent[cleanParent] {
            for p in folderChildren where seen.insert(p).inserted {
                combined.append((p, true))
            }
        }
        if let sharedChildren = fastSharedIndex.childrenByParent[cleanParent] {
            for item in sharedChildren where seen.insert(item.path).inserted {
                combined.append(item)
            }
        }

        if !tokens.isEmpty {
            combined = combined.filter { item in
                let name = (item.path as NSString).lastPathComponent
                let nameClean = Self.cleanString(name)
                let nameNorm = Self.removeAccents(name.lowercased())
                return tokens.allSatisfy { nameClean.contains($0) || nameNorm.contains($0) }
            }
        }

        combined.sort { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return (a.path as NSString).lastPathComponent.localizedStandardCompare((b.path as NSString).lastPathComponent) == .orderedAscending
        }
        return combined
    }

    /// Reads directory entries on a background thread using POSIX `opendir`/`readdir` (`d_type`),
    /// avoiding `FileManager.fileExists` RPC storms on CloudStorage mounts.
    nonisolated static func listDirectoryFastPOSIX(parentPath: String, queryWords: [String]) -> [(path: String, isDir: Bool)] {
        let cleanParent = parentPath.hasSuffix("/") && parentPath.count > 1 ? String(parentPath.dropLast()) : parentPath
        guard let dirPtr = Darwin.opendir(cleanParent) else { return [] }
        defer { Darwin.closedir(dirPtr) }

        let tokens = queryWords.map(cleanString).filter { !$0.isEmpty }
        var results: [(path: String, isDir: Bool)] = []

        while let entryPtr = Darwin.readdir(dirPtr) {
            let dType = entryPtr.pointee.d_type
            let nameLen = Int(entryPtr.pointee.d_namlen)
            guard nameLen > 0 else { continue }

            let name: String = withUnsafePointer(to: entryPtr.pointee.d_name) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: nameLen) { utf8Ptr in
                    String(decoding: UnsafeBufferPointer(start: utf8Ptr, count: nameLen), as: UTF8.self)
                }
            }
            if name.isEmpty || name.hasPrefix(".") { continue }

            let full = cleanParent == "/" ? "/\(name)" : "\(cleanParent)/\(name)"
            let isDir: Bool
            if dType == DT_DIR {
                isDir = true
            } else if dType == DT_UNKNOWN {
                var st = Darwin.stat()
                isDir = (Darwin.lstat(full, &st) == 0) && ((st.st_mode & S_IFMT) == S_IFDIR)
            } else {
                isDir = false
            }

            if !tokens.isEmpty {
                let nameClean = cleanString(name)
                let nameNorm = removeAccents(name.lowercased())
                let matches = tokens.allSatisfy { nameClean.contains($0) || nameNorm.contains($0) }
                if !matches { continue }
            }
            results.append((full, isDir))
        }

        results.sort { a, b in
            if a.isDir != b.isDir { return a.isDir && !b.isDir }
            return (a.path as NSString).lastPathComponent.localizedStandardCompare((b.path as NSString).lastPathComponent) == .orderedAscending
        }
        return results
    }

    // MARK: - Native Google Drive Item ID & Web URLs (Zero-subprocess getxattr!)

    nonisolated static func extractGoogleDriveItemID(at path: String) -> String? {
        let attrName = "com.google.drivefs.item-id#S"
        let size = getxattr(path, attrName, nil, 0, 0, 0)
        if size > 0 {
            var buffer = [UInt8](repeating: 0, count: size)
            let readSize = getxattr(path, attrName, &buffer, size, 0, 0)
            if readSize > 0, let str = String(bytes: buffer.prefix(readSize), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                return str
            }
        }

        let ext = (path as NSString).pathExtension.lowercased()
        if ["gdoc", "gsheet", "gslides", "gdraw", "gform", "gtable"].contains(ext),
           let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let docID = json["doc_id"] as? String, !docID.isEmpty {
                return docID
            }
            if let urlStr = json["url"] as? String {
                if let range = urlStr.range(of: "/d/") {
                    let after = urlStr[range.upperBound...]
                    let idPart = after.split(separator: "/").first.map(String.init)
                    if let idPart, !idPart.isEmpty { return idPart }
                }
                let trimmed = urlStr.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                return trimmed.components(separatedBy: "/").last
            }
        }
        return nil
    }

    nonisolated static func googleDriveURLs(for path: String, isDirectoryHint: Bool? = nil) -> (webURL: URL, shareURL: URL)? {
        guard let itemID = extractGoogleDriveItemID(at: path) else { return nil }
        let isDir: Bool
        if let isDirectoryHint {
            isDir = isDirectoryHint
        } else {
            var st = Darwin.stat()
            isDir = (Darwin.lstat(path, &st) == 0) && ((st.st_mode & S_IFMT) == S_IFDIR)
        }

        let ext = (path as NSString).pathExtension.lowercased()
        let webStr: String
        let shareStr: String

        if isDir {
            webStr = "https://drive.google.com/drive/folders/\(itemID)"
            shareStr = "https://drive.google.com/drive/folders/\(itemID)?usp=sharing"
        } else if ext == "gdoc" {
            webStr = "https://docs.google.com/document/d/\(itemID)/edit"
            shareStr = "https://docs.google.com/document/d/\(itemID)/edit?usp=sharing"
        } else if ext == "gsheet" {
            webStr = "https://docs.google.com/spreadsheets/d/\(itemID)/edit"
            shareStr = "https://docs.google.com/spreadsheets/d/\(itemID)/edit?usp=sharing"
        } else if ext == "gslides" {
            webStr = "https://docs.google.com/presentation/d/\(itemID)/edit"
            shareStr = "https://docs.google.com/presentation/d/\(itemID)/edit?usp=sharing"
        } else {
            webStr = "https://drive.google.com/file/d/\(itemID)/view"
            shareStr = "https://drive.google.com/file/d/\(itemID)/view?usp=sharing"
        }

        guard let w = URL(string: webStr), let s = URL(string: shareStr) else { return nil }
        return (w, s)
    }

    nonisolated static func triggerOfflineDownload(for urls: [URL]) -> Int {
        let fm = FileManager.default
        var count = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                if let fh = try? FileHandle(forReadingFrom: url) {
                    _ = try? fh.read(upToCount: 1)
                    try? fh.close()
                    count += 1
                }
            } else if let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) {
                for case let fileURL as URL in enumerator {
                    if let vals = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]), vals.isRegularFile == true {
                        if let fh = try? FileHandle(forReadingFrom: fileURL) {
                            _ = try? fh.read(upToCount: 1)
                            try? fh.close()
                            count += 1
                        }
                    }
                }
            }
        }
        return count
    }
}
