import Foundation
import AppKit
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    var isApplyingRemoteSync: Bool = false

    private enum Keys {
        static let searchHotKey = "drivebar.searchHotKey"
        static let universalActionHotKey = "drivebar.universalActionHotKey"
        static let disabledActionIDs = "drivebar.disabledActionIDs"
        static let autoCopyMarkdown = "drivebar.autoCopyMarkdown"
        static let saveMarkdownBesideSource = "drivebar.saveMarkdownBesideSource"
        static let enableVisionOCR = "drivebar.enableVisionOCR"
        static let optimizeMarkdownTokens = "drivebar.optimizeMarkdownTokens"
        static let includeMetadataHeader = "drivebar.includeMetadataHeader"
        static let wrapMultiFilesInXMLTags = "drivebar.wrapMultiFilesInXMLTags"
        static let enableSmartChunking = "drivebar.enableSmartChunking"
        static let smartChunkMaxTokens = "drivebar.smartChunkMaxTokens"
        static let aiToolkitPath = "drivebar.aiToolkitPath"
        static let showDockIcon = "drivebar.showDockIcon"
        static let showLauncherOnStartup = "drivebar.showLauncherOnStartup"
        static let includeMacAppsInSearch = "drivebar.includeMacAppsInSearch"
        static let enableActionLatching = "drivebar.enableActionLatching"
        static let enableRealtimeFSEvents = "drivebar.enableRealtimeFSEvents"
        static let selectedDriveAccountFilter = "drivebar.selectedDriveAccountFilter"
        static let enableSyncthingSync = "drivebar.enableSyncthingSync"
        static let syncthingFolderPath = "drivebar.syncthingFolderPath"
        static let hasLaunchedBefore = "drivebar.hasLaunchedBefore"
        static let didMigrateCmdSpaceV121 = "drivebar.didMigrateCmdSpaceV121"
        static let didMigrateCmdSlashV123 = "drivebar.didMigrateCmdSlashV123"
        static let localSettingsUpdatedAt = "drivebar.localSettingsUpdatedAt"
        static let enableWindowSwitcher = "drivebar.enableWindowSwitcher"
        static let windowSwitcherHotKey = "drivebar.windowSwitcherHotKey"
        static let enableSameAppSwitcher = "drivebar.enableSameAppSwitcher"
        static let sameAppSwitcherHotKey = "drivebar.sameAppSwitcherHotKey"
        static let windowSwitcherShowMinimized = "drivebar.windowSwitcherShowMinimized"
        static let windowSwitcherShowHiddenApps = "drivebar.windowSwitcherShowHiddenApps"
        static let windowSwitcherShowWindowlessApps = "drivebar.windowSwitcherShowWindowlessApps"
        static let windowSwitcherShowZoomPreview = "drivebar.windowSwitcherShowZoomPreview"
        static let windowSwitcherScope = "drivebar.windowSwitcherScope"
        static let windowSwitcherReleaseToActivate = "drivebar.windowSwitcherReleaseToActivate"
        static let pinnedPaths = "drivebar.pinnedPaths"
        static let enableClipboardHistory = "drivebar.enableClipboardHistory"
        static let disabledSystemCommandIDs = "drivebar.disabledSystemCommandIDs"
        static let confirmSystemCommandIDs = "drivebar.confirmSystemCommandIDs"
    }

    static let defaultConfirmSystemCommandIDs: Set<String> = [
        "sys.empty_trash",
        "sys.logout",
        "sys.restart",
        "sys.shutdown",
        "sys.quit_all",
        "sys.force_quit"
    ]

    @Published var enableWindowSwitcher: Bool {
        didSet {
            defaults.set(enableWindowSwitcher, forKey: Keys.enableWindowSwitcher)
            WindowSwitcherController.shared.refreshEventTapState()
            HotKeyService.shared.registerAll()
        }
    }

    @Published var windowSwitcherHotKey: HotKeyBinding {
        didSet {
            saveCodable(windowSwitcherHotKey, forKey: Keys.windowSwitcherHotKey)
            WindowSwitcherController.shared.refreshEventTapState()
            HotKeyService.shared.registerAll()
        }
    }

    @Published var enableSameAppSwitcher: Bool {
        didSet {
            defaults.set(enableSameAppSwitcher, forKey: Keys.enableSameAppSwitcher)
            WindowSwitcherController.shared.refreshEventTapState()
            HotKeyService.shared.registerAll()
        }
    }

    @Published var sameAppSwitcherHotKey: HotKeyBinding {
        didSet {
            saveCodable(sameAppSwitcherHotKey, forKey: Keys.sameAppSwitcherHotKey)
            WindowSwitcherController.shared.refreshEventTapState()
            HotKeyService.shared.registerAll()
        }
    }

    @Published var windowSwitcherShowMinimized: Bool {
        didSet {
            defaults.set(windowSwitcherShowMinimized, forKey: Keys.windowSwitcherShowMinimized)
        }
    }

    @Published var windowSwitcherShowHiddenApps: Bool {
        didSet {
            defaults.set(windowSwitcherShowHiddenApps, forKey: Keys.windowSwitcherShowHiddenApps)
        }
    }

    @Published var windowSwitcherShowWindowlessApps: Bool {
        didSet {
            defaults.set(windowSwitcherShowWindowlessApps, forKey: Keys.windowSwitcherShowWindowlessApps)
        }
    }

    @Published var windowSwitcherShowZoomPreview: Bool {
        didSet {
            defaults.set(windowSwitcherShowZoomPreview, forKey: Keys.windowSwitcherShowZoomPreview)
        }
    }

    @Published var windowSwitcherScope: WindowSwitcherScope {
        didSet {
            defaults.set(windowSwitcherScope.rawValue, forKey: Keys.windowSwitcherScope)
        }
    }

    /// When false (default), releasing ⌘ after pressing ⌘Tab keeps Windows Preview open so user can navigate with arrows or type keywords, then press Enter/Click to jump.
    @Published var windowSwitcherReleaseToActivate: Bool {
        didSet {
            defaults.set(windowSwitcherReleaseToActivate, forKey: Keys.windowSwitcherReleaseToActivate)
            WindowSwitcherController.shared.syncSharedTapConfiguration()
        }
    }

    @Published var searchHotKey: HotKeyBinding {
        didSet {
            saveCodable(searchHotKey, forKey: Keys.searchHotKey)
            HotKeyService.shared.registerAll()
            notifyPortableSettingsChanged()
        }
    }

    @Published var universalActionHotKey: HotKeyBinding {
        didSet {
            saveCodable(universalActionHotKey, forKey: Keys.universalActionHotKey)
            HotKeyService.shared.registerAll()
            notifyPortableSettingsChanged()
        }
    }

    @Published var disabledActionIDs: Set<String> {
        didSet {
            defaults.set(Array(disabledActionIDs), forKey: Keys.disabledActionIDs)
            notifyPortableSettingsChanged()
        }
    }

    @Published var disabledSystemCommandIDs: Set<String> {
        didSet {
            defaults.set(Array(disabledSystemCommandIDs), forKey: Keys.disabledSystemCommandIDs)
            notifyPortableSettingsChanged()
        }
    }

    @Published var confirmSystemCommandIDs: Set<String> {
        didSet {
            defaults.set(Array(confirmSystemCommandIDs), forKey: Keys.confirmSystemCommandIDs)
            notifyPortableSettingsChanged()
        }
    }

    @Published var autoCopyMarkdownToClipboard: Bool {
        didSet {
            defaults.set(autoCopyMarkdownToClipboard, forKey: Keys.autoCopyMarkdown)
            notifyPortableSettingsChanged()
        }
    }

    @Published var saveMarkdownBesideSource: Bool {
        didSet {
            defaults.set(saveMarkdownBesideSource, forKey: Keys.saveMarkdownBesideSource)
            notifyPortableSettingsChanged()
        }
    }

    @Published var enableVisionOCR: Bool {
        didSet {
            defaults.set(enableVisionOCR, forKey: Keys.enableVisionOCR)
            notifyPortableSettingsChanged()
        }
    }

    @Published var optimizeMarkdownTokens: Bool {
        didSet {
            defaults.set(optimizeMarkdownTokens, forKey: Keys.optimizeMarkdownTokens)
            notifyPortableSettingsChanged()
        }
    }

    @Published var includeMetadataHeader: Bool {
        didSet {
            defaults.set(includeMetadataHeader, forKey: Keys.includeMetadataHeader)
            notifyPortableSettingsChanged()
        }
    }

    @Published var wrapMultiFilesInXMLTags: Bool {
        didSet {
            defaults.set(wrapMultiFilesInXMLTags, forKey: Keys.wrapMultiFilesInXMLTags)
            notifyPortableSettingsChanged()
        }
    }

    @Published var enableSmartChunking: Bool {
        didSet {
            defaults.set(enableSmartChunking, forKey: Keys.enableSmartChunking)
            notifyPortableSettingsChanged()
        }
    }

    @Published var smartChunkMaxTokens: Int {
        didSet {
            defaults.set(smartChunkMaxTokens, forKey: Keys.smartChunkMaxTokens)
            notifyPortableSettingsChanged()
        }
    }

    @Published var aiToolkitPath: String {
        didSet { defaults.set(aiToolkitPath, forKey: Keys.aiToolkitPath) }
    }

    @Published var showDockIcon: Bool {
        didSet {
            defaults.set(showDockIcon, forKey: Keys.showDockIcon)
            applyDockPolicy()
        }
    }

    @Published var showLauncherOnStartup: Bool {
        didSet {
            defaults.set(showLauncherOnStartup, forKey: Keys.showLauncherOnStartup)
        }
    }

    @Published var includeMacAppsInSearch: Bool {
        didSet {
            defaults.set(includeMacAppsInSearch, forKey: Keys.includeMacAppsInSearch)
            notifyPortableSettingsChanged()
        }
    }

    @Published var pinnedPaths: [String] {
        didSet {
            defaults.set(pinnedPaths, forKey: Keys.pinnedPaths)
            notifyPortableSettingsChanged()
        }
    }

    @Published var enableClipboardHistory: Bool {
        didSet {
            defaults.set(enableClipboardHistory, forKey: Keys.enableClipboardHistory)
            ClipboardHistoryService.shared.updatePollingState()
            notifyPortableSettingsChanged()
        }
    }

    @Published var enableActionLatching: Bool {
        didSet {
            defaults.set(enableActionLatching, forKey: Keys.enableActionLatching)
            notifyPortableSettingsChanged()
        }
    }

    @Published var enableRealtimeFSEvents: Bool {
        didSet {
            defaults.set(enableRealtimeFSEvents, forKey: Keys.enableRealtimeFSEvents)
            GoogleDriveIndexService.shared.updateRealtimeWatcherState()
        }
    }

    @Published var selectedDriveAccountFilter: String {
        didSet {
            defaults.set(selectedDriveAccountFilter, forKey: Keys.selectedDriveAccountFilter)
            GoogleDriveIndexService.shared.applyAccountFilterChange()
        }
    }

    @Published var enableSyncthingSync: Bool {
        didSet {
            defaults.set(enableSyncthingSync, forKey: Keys.enableSyncthingSync)
            SyncAndLatchingService.shared.configureSyncthingWatcher()
            if enableSyncthingSync {
                SyncAndLatchingService.shared.syncNow()
            }
        }
    }

    @Published var syncthingFolderPath: String {
        didSet {
            defaults.set(syncthingFolderPath, forKey: Keys.syncthingFolderPath)
            SyncAndLatchingService.shared.configureSyncthingWatcher()
        }
    }

    @Published var launchAtLogin: Bool = false
    @Published var statusBannerMessage: String?

    private init() {
        let didMigrateCmdSpace = defaults.bool(forKey: Keys.didMigrateCmdSpaceV121)
        let didMigrateCmdSlash = defaults.bool(forKey: Keys.didMigrateCmdSlashV123)
        var didPerformDefaultMigration = false

        if let data = defaults.data(forKey: Keys.searchHotKey),
           let decoded = try? JSONDecoder().decode(HotKeyBinding.self, from: data) {
            if !didMigrateCmdSpace && decoded == .optionSpace {
                self.searchHotKey = .defaultSearch
                didPerformDefaultMigration = true
            } else {
                self.searchHotKey = decoded
            }
        } else {
            self.searchHotKey = .defaultSearch
            if !didMigrateCmdSpace {
                didPerformDefaultMigration = true
            }
        }

        if let data = defaults.data(forKey: Keys.universalActionHotKey),
           let decoded = try? JSONDecoder().decode(HotKeyBinding.self, from: data) {
            if !didMigrateCmdSlash && decoded == .commandShiftA {
                self.universalActionHotKey = .defaultUniversalAction
                didPerformDefaultMigration = true
            } else {
                self.universalActionHotKey = decoded
            }
        } else {
            self.universalActionHotKey = .defaultUniversalAction
            if !didMigrateCmdSlash {
                didPerformDefaultMigration = true
            }
        }

        self.enableWindowSwitcher = defaults.object(forKey: Keys.enableWindowSwitcher) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.windowSwitcherHotKey),
           let decoded = try? JSONDecoder().decode(HotKeyBinding.self, from: data) {
            self.windowSwitcherHotKey = decoded
        } else {
            self.windowSwitcherHotKey = .defaultWindowSwitcher
        }
        self.enableSameAppSwitcher = defaults.object(forKey: Keys.enableSameAppSwitcher) as? Bool ?? true
        if let data = defaults.data(forKey: Keys.sameAppSwitcherHotKey),
           let decoded = try? JSONDecoder().decode(HotKeyBinding.self, from: data) {
            self.sameAppSwitcherHotKey = decoded
        } else {
            self.sameAppSwitcherHotKey = .defaultSameAppSwitcher
        }
        self.windowSwitcherShowMinimized = defaults.object(forKey: Keys.windowSwitcherShowMinimized) as? Bool ?? true
        self.windowSwitcherShowHiddenApps = defaults.object(forKey: Keys.windowSwitcherShowHiddenApps) as? Bool ?? true
        self.windowSwitcherShowWindowlessApps = defaults.object(forKey: Keys.windowSwitcherShowWindowlessApps) as? Bool ?? false
        self.windowSwitcherShowZoomPreview = defaults.object(forKey: Keys.windowSwitcherShowZoomPreview) as? Bool ?? true
        if let rawScope = defaults.string(forKey: Keys.windowSwitcherScope),
           let parsedScope = WindowSwitcherScope(rawValue: rawScope) {
            self.windowSwitcherScope = parsedScope
        } else {
            self.windowSwitcherScope = .allSpacesAndDisplays
        }
        self.windowSwitcherReleaseToActivate = defaults.object(forKey: Keys.windowSwitcherReleaseToActivate) as? Bool ?? false

        let savedDisabled = defaults.stringArray(forKey: Keys.disabledActionIDs) ?? []
        self.disabledActionIDs = Set(savedDisabled)

        let savedDisabledSys = defaults.stringArray(forKey: Keys.disabledSystemCommandIDs) ?? []
        self.disabledSystemCommandIDs = Set(savedDisabledSys)

        if let savedConfirmSys = defaults.stringArray(forKey: Keys.confirmSystemCommandIDs) {
            self.confirmSystemCommandIDs = Set(savedConfirmSys)
        } else {
            self.confirmSystemCommandIDs = Self.defaultConfirmSystemCommandIDs
        }

        self.autoCopyMarkdownToClipboard = defaults.object(forKey: Keys.autoCopyMarkdown) as? Bool ?? true
        self.saveMarkdownBesideSource = defaults.object(forKey: Keys.saveMarkdownBesideSource) as? Bool ?? true
        self.enableVisionOCR = defaults.object(forKey: Keys.enableVisionOCR) as? Bool ?? true
        self.optimizeMarkdownTokens = defaults.object(forKey: Keys.optimizeMarkdownTokens) as? Bool ?? true
        self.includeMetadataHeader = defaults.object(forKey: Keys.includeMetadataHeader) as? Bool ?? false
        self.wrapMultiFilesInXMLTags = defaults.object(forKey: Keys.wrapMultiFilesInXMLTags) as? Bool ?? true
        self.enableSmartChunking = defaults.object(forKey: Keys.enableSmartChunking) as? Bool ?? false
        let savedChunkMax = defaults.integer(forKey: Keys.smartChunkMaxTokens)
        self.smartChunkMaxTokens = savedChunkMax > 2000 ? savedChunkMax : 25_000

        self.showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? false
        self.showLauncherOnStartup = defaults.object(forKey: Keys.showLauncherOnStartup) as? Bool ?? false
        self.includeMacAppsInSearch = defaults.object(forKey: Keys.includeMacAppsInSearch) as? Bool ?? true
        self.pinnedPaths = defaults.stringArray(forKey: Keys.pinnedPaths) ?? []
        self.enableClipboardHistory = defaults.object(forKey: Keys.enableClipboardHistory) as? Bool ?? true
        self.enableActionLatching = defaults.object(forKey: Keys.enableActionLatching) as? Bool ?? true
        self.enableRealtimeFSEvents = defaults.object(forKey: Keys.enableRealtimeFSEvents) as? Bool ?? true
        self.selectedDriveAccountFilter = defaults.string(forKey: Keys.selectedDriveAccountFilter) ?? "ALL"

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let syncRootExists = FileManager.default.fileExists(atPath: "\(home)/Sync")
        self.enableSyncthingSync = defaults.object(forKey: Keys.enableSyncthingSync) as? Bool ?? syncRootExists

        if let customSync = defaults.string(forKey: Keys.syncthingFolderPath), !customSync.isEmpty {
            self.syncthingFolderPath = customSync
        } else if FileManager.default.fileExists(atPath: "\(home)/Sync/Alfred") {
            self.syncthingFolderPath = "\(home)/Sync/Alfred/DriveBar"
        } else {
            self.syncthingFolderPath = "\(home)/Sync/DriveBar"
        }

        if let customToolkit = defaults.string(forKey: Keys.aiToolkitPath), !customToolkit.isEmpty {
            self.aiToolkitPath = customToolkit
        } else {
            let candidates = [
                "\(home)/Developer/AI/ai-document-toolkit",
                "/Users/hunglx/Developer/AI/ai-document-toolkit",
                "/Users/hunglexuan/Developer/AI/ai-document-toolkit"
            ]
            self.aiToolkitPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
                ?? "\(home)/Developer/AI/ai-document-toolkit"
        }

        if !didMigrateCmdSpace {
            defaults.set(true, forKey: Keys.didMigrateCmdSpaceV121)
        }
        if !didMigrateCmdSlash {
            defaults.set(true, forKey: Keys.didMigrateCmdSlashV123)
        }
        if didPerformDefaultMigration {
            saveCodable(self.searchHotKey, forKey: Keys.searchHotKey)
            saveCodable(self.universalActionHotKey, forKey: Keys.universalActionHotKey)
            defaults.set(Date().timeIntervalSince1970 + 2.0, forKey: Keys.localSettingsUpdatedAt)
            DispatchQueue.main.async {
                SyncAndLatchingService.shared.pushPortableSettings()
            }
        }

        refreshLaunchAtLoginStatus()
    }

    var localSettingsUpdatedAt: Double {
        get { defaults.double(forKey: Keys.localSettingsUpdatedAt) }
        set { defaults.set(newValue, forKey: Keys.localSettingsUpdatedAt) }
    }

    func resetShortcutsToDefault() {
        searchHotKey = .defaultSearch
        universalActionHotKey = .defaultUniversalAction
        windowSwitcherHotKey = .defaultWindowSwitcher
        sameAppSwitcherHotKey = .defaultSameAppSwitcher
        statusBannerMessage = "Đã khôi phục phím tắt mặc định: Tìm kiếm \(searchHotKey.readableDisplay) • Finder \(universalActionHotKey.readableDisplay) • Windows \(windowSwitcherHotKey.readableDisplay)"
    }

    var isFirstLaunch: Bool {
        if !defaults.bool(forKey: Keys.hasLaunchedBefore) {
            defaults.set(true, forKey: Keys.hasLaunchedBefore)
            return true
        }
        return false
    }

    func isActionEnabled(_ id: String) -> Bool {
        !disabledActionIDs.contains(id)
    }

    func setActionEnabled(_ id: String, enabled: Bool) {
        if enabled {
            disabledActionIDs.remove(id)
        } else {
            disabledActionIDs.insert(id)
        }
    }

    func isSystemCommandEnabled(_ id: String) -> Bool {
        !disabledSystemCommandIDs.contains(id)
    }

    func setSystemCommandEnabled(_ id: String, enabled: Bool) {
        if enabled {
            disabledSystemCommandIDs.remove(id)
        } else {
            disabledSystemCommandIDs.insert(id)
        }
    }

    func requiresSystemCommandConfirmation(_ id: String) -> Bool {
        confirmSystemCommandIDs.contains(id)
    }

    func setSystemCommandConfirmation(_ id: String, confirm: Bool) {
        if confirm {
            confirmSystemCommandIDs.insert(id)
        } else {
            confirmSystemCommandIDs.remove(id)
        }
    }

    func resetSystemCommandsToDefault() {
        disabledSystemCommandIDs.removeAll()
        confirmSystemCommandIDs = Self.defaultConfirmSystemCommandIDs
    }

    func isPinned(_ path: String) -> Bool {
        let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        return pinnedPaths.contains(normalized)
    }

    @discardableResult
    func togglePin(_ path: String) -> Bool {
        let normalized = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
        if let idx = pinnedPaths.firstIndex(of: normalized) {
            pinnedPaths.remove(at: idx)
            return false
        } else {
            pinnedPaths.insert(normalized, at: 0)
            return true
        }
    }

    func applyDockPolicy() {
        let wasSettingsVisible = AppDelegate.shared?.isSettingsWindowVisible ?? false
        let wasLauncherVisible = LauncherPanelController.shared.isVisible

        NSApp.setActivationPolicy(showDockIcon ? .regular : .accessory)

        DispatchQueue.main.async {
            LauncherPanelController.shared.reapplySpaceCollectionBehavior()
            if wasLauncherVisible {
                LauncherPanelController.shared.showAndFocus()
            }
            if wasSettingsVisible {
                AppDelegate.shared?.bringSettingsWindowToFront()
            }
        }
    }

    private var launchAgentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.hunglx.DriveBar.plist")
    }

    func refreshLaunchAtLoginStatus() {
        let smEnabled = (SMAppService.mainApp.status == .enabled)
        let plistExists = FileManager.default.fileExists(atPath: launchAgentPlistURL.path)
        launchAtLogin = smEnabled || plistExists
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        if enabled {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try? SMAppService.mainApp.unregister()
                }
                try SMAppService.mainApp.register()
                let status = SMAppService.mainApp.status
                if status == .enabled {
                    try? FileManager.default.removeItem(at: launchAgentPlistURL)
                    refreshLaunchAtLoginStatus()
                    return
                } else if status == .requiresApproval {
                    writeFallbackLaunchAgentPlist()
                    refreshLaunchAtLoginStatus()
                    SMAppService.openSystemSettingsLoginItems()
                    statusBannerMessage = "Nếu macOS yêu cầu xác nhận, hãy bật công tắc DriveBar trong mục Login Items."
                    return
                }
            } catch {
                // Ad-hoc signed rebuilds or non-/Applications paths can be rejected by smd;
                // fall back cleanly to standard per-user ~/Library/LaunchAgents plist.
            }
            writeFallbackLaunchAgentPlist()
            refreshLaunchAtLoginStatus()
        } else {
            try? SMAppService.mainApp.unregister()
            try? FileManager.default.removeItem(at: launchAgentPlistURL)
            refreshLaunchAtLoginStatus()
        }
    }

    private func writeFallbackLaunchAgentPlist() {
        let installedExec = "/Applications/DriveBar.app/Contents/MacOS/DriveBar"
        let execPath: String
        if FileManager.default.isExecutableFile(atPath: installedExec) {
            execPath = installedExec
        } else if let bundleExec = Bundle.main.executablePath {
            execPath = bundleExec
        } else {
            return
        }

        let dir = launchAgentPlistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plistDict: [String: Any] = [
            "Label": "com.hunglx.DriveBar",
            "ProgramArguments": [execPath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plistDict, format: .xml, options: 0) {
            try? data.write(to: launchAgentPlistURL, options: .atomic)
        }
    }

    private func notifyPortableSettingsChanged() {
        guard !isApplyingRemoteSync else { return }
        SyncAndLatchingService.shared.pushPortableSettings()
    }

    private func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
