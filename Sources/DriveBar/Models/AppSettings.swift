import Foundation
import AppKit
import ServiceManagement

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let searchHotKey = "drivebar.searchHotKey"
        static let universalActionHotKey = "drivebar.universalActionHotKey"
        static let disabledActionIDs = "drivebar.disabledActionIDs"
        static let autoCopyMarkdown = "drivebar.autoCopyMarkdown"
        static let saveMarkdownBesideSource = "drivebar.saveMarkdownBesideSource"
        static let enableVisionOCR = "drivebar.enableVisionOCR"
        static let optimizeMarkdownTokens = "drivebar.optimizeMarkdownTokens"
        static let includeMetadataHeader = "drivebar.includeMetadataHeader"
        static let aiToolkitPath = "drivebar.aiToolkitPath"
        static let showDockIcon = "drivebar.showDockIcon"
        static let includeMacAppsInSearch = "drivebar.includeMacAppsInSearch"
        static let hasLaunchedBefore = "drivebar.hasLaunchedBefore"
    }

    @Published var searchHotKey: HotKeyBinding {
        didSet {
            saveCodable(searchHotKey, forKey: Keys.searchHotKey)
            HotKeyService.shared.registerAll()
        }
    }

    @Published var universalActionHotKey: HotKeyBinding {
        didSet {
            saveCodable(universalActionHotKey, forKey: Keys.universalActionHotKey)
            HotKeyService.shared.registerAll()
        }
    }

    @Published var disabledActionIDs: Set<String> {
        didSet {
            defaults.set(Array(disabledActionIDs), forKey: Keys.disabledActionIDs)
        }
    }

    @Published var autoCopyMarkdownToClipboard: Bool {
        didSet { defaults.set(autoCopyMarkdownToClipboard, forKey: Keys.autoCopyMarkdown) }
    }

    @Published var saveMarkdownBesideSource: Bool {
        didSet { defaults.set(saveMarkdownBesideSource, forKey: Keys.saveMarkdownBesideSource) }
    }

    @Published var enableVisionOCR: Bool {
        didSet { defaults.set(enableVisionOCR, forKey: Keys.enableVisionOCR) }
    }

    @Published var optimizeMarkdownTokens: Bool {
        didSet { defaults.set(optimizeMarkdownTokens, forKey: Keys.optimizeMarkdownTokens) }
    }

    @Published var includeMetadataHeader: Bool {
        didSet { defaults.set(includeMetadataHeader, forKey: Keys.includeMetadataHeader) }
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
        didSet { defaults.set(includeMacAppsInSearch, forKey: Keys.includeMacAppsInSearch) }
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
        self.showDockIcon = defaults.object(forKey: Keys.showDockIcon) as? Bool ?? false
        self.includeMacAppsInSearch = defaults.object(forKey: Keys.includeMacAppsInSearch) as? Bool ?? true

        if let customToolkit = defaults.string(forKey: Keys.aiToolkitPath), !customToolkit.isEmpty {
            self.aiToolkitPath = customToolkit
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
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

    private func saveCodable<T: Encodable>(_ value: T, forKey key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }
}
