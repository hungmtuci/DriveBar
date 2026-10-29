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
        static let includeMacAppsInSearch = "drivebar.includeMacAppsInSearch"
        static let enableActionLatching = "drivebar.enableActionLatching"
        static let enableRealtimeFSEvents = "drivebar.enableRealtimeFSEvents"
        static let selectedDriveAccountFilter = "drivebar.selectedDriveAccountFilter"
        static let enableSyncthingSync = "drivebar.enableSyncthingSync"
        static let syncthingFolderPath = "drivebar.syncthingFolderPath"
        static let hasLaunchedBefore = "drivebar.hasLaunchedBefore"
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

    @Published var includeMacAppsInSearch: Bool {
        didSet {
            defaults.set(includeMacAppsInSearch, forKey: Keys.includeMacAppsInSearch)
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
        if let data = defaults.data(forKey: Keys.searchHotKey),
           let decoded = try? JSONDecoder().decode(HotKeyBinding.self, from: data) {
            self.searchHotKey = decoded
        } else {
            self.searchHotKey = .defaultSearch
        }

        if let data = defaults.data(forKey: Keys.universalActionHotKey),
           let decoded = try? JSONDecoder().decode(HotKeyBinding.self, from: data) {
            self.universalActionHotKey = decoded
        } else {
            self.universalActionHotKey = .defaultUniversalAction
        }

        let savedDisabled = defaults.stringArray(forKey: Keys.disabledActionIDs) ?? []
        self.disabledActionIDs = Set(savedDisabled)

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
        self.includeMacAppsInSearch = defaults.object(forKey: Keys.includeMacAppsInSearch) as? Bool ?? true
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

        refreshLaunchAtLoginStatus()
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

    func refreshLaunchAtLoginStatus() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    func toggleLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            statusBannerMessage = "Không thể cập nhật Launch at Login: \(error.localizedDescription)"
            refreshLaunchAtLoginStatus()
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
