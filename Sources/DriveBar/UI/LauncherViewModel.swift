import Foundation
import SwiftUI
import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers
import Darwin

@MainActor
final class LauncherViewModel: ObservableObject {
    static let shared = LauncherViewModel()

    @Published var screenMode: LauncherScreenMode = .search {
        didSet {
            selectedIndex = 0
            updatePreviewThumbnailIfNeeded()
            if LauncherPanelController.shared.isVisible {
                LauncherPanelController.shared.isSuppressingAutoHide = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    LauncherPanelController.shared.isSuppressingAutoHide = false
                }
            }
        }
    }

    @Published var searchText: String = "" {
        didSet {
            if searchText.isEmpty {
                activeBrowseDirectory = nil
            }
            refreshSearchResults()
        }
    }

    @Published var actionFilterText: String = "" {
        didSet {
            refreshFilteredActions()
        }
    }

    @Published var destinationSearchText: String = "" {
        didSet {
            if destinationSearchText.isEmpty {
                activeDestinationBrowseDirectory = nil
            }
            refreshDestinationFolders()
        }
    }

    /// Full canonical directory path currently being browsed in search mode.
    @Published var activeBrowseDirectory: String? = nil
    /// Full canonical directory path currently being browsed in destination picker mode.
    @Published var activeDestinationBrowseDirectory: String? = nil

    // MARK: - Breadcrumb / Path Shortening Helpers

    /// Formats a directory path for display in browse mode, hiding the long common root
    /// (e.g. `~/Library/CloudStorage/GoogleDrive-account`) and showing starting from at most
    /// the 3 nearest folders leading to the selected directory.
    func formatBrowseDisplayPath(_ path: String) -> String {
        let clean = path.hasSuffix("/") ? String(path.dropLast()) : path
        let drive = GoogleDriveIndexService.shared

        // 1. Inside a Google Drive account:
        if let acc = drive.accountForPath(clean) {
            let root = acc.rootPath
            if clean.hasPrefix(root) {
                let rel = String(clean.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                let parts = rel.split(separator: "/").map(String.init)
                if parts.count > 3 {
                    let lastThree = parts.suffix(3).joined(separator: "/")
                    return "…/\(lastThree)/"
                } else if !parts.isEmpty {
                    return "…/\(parts.joined(separator: "/"))/"
                } else {
                    return "…/Google Drive/"
                }
            }
        }

        // 2. Inside user home directory:
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if clean.hasPrefix(home) {
            let rel = String(clean.dropFirst(home.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = rel.split(separator: "/").map(String.init)
            if parts.count > 3 {
                let lastThree = parts.suffix(3).joined(separator: "/")
                return "…/\(lastThree)/"
            } else if !parts.isEmpty {
                return "…/\(parts.joined(separator: "/"))/"
            }
        }

        // 3. Fallback for any other path:
        let parts = clean.split(separator: "/").map(String.init)
        if parts.count > 3 {
            let lastThree = parts.suffix(3).joined(separator: "/")
            return "…/\(lastThree)/"
        } else if !parts.isEmpty {
            return "…/\(parts.joined(separator: "/"))/"
        } else {
            return "/"
        }
    }

    @Published var contactDetailFilterText: String = "" {
        didSet {
            refreshFilteredContactDetailFields()
        }
    }

    @Published private(set) var searchResults: [SearchResultItem] = []
    @Published private(set) var filteredActions: [UniversalActionDefinition] = []
    @Published private(set) var openWithApps: [(name: String, url: URL)] = []
    @Published private(set) var destinationFolders: [SearchResultItem] = []
    @Published private(set) var filteredContactDetailFields: [ContactDetailField] = []

    @Published var selectedIndex: Int = 0
    @Published var activeModifiers: NSEvent.ModifierFlags = []
    @Published private(set) var openedDirectlyInUniversalActions: Bool = false

    // Focus coordination for NativeSearchInputField
    @Published var focusTrigger: Int = 0
    @Published var selectAllOnFocus: Bool = false
    @Published private(set) var isLoadingBrowseFiles: Bool = false

    // Preview card state for Universal Actions right pane (Screenshot 2 style!)
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewFileSizeText: String = ""
    @Published private(set) var previewCreatedText: String = ""
    @Published private(set) var previewModifiedText: String = ""
    @Published private(set) var previewRouteHint: String = ""

    private var searchGeneration: UInt64 = 0
    private var destinationGeneration: UInt64 = 0
    private var previewGeneration: UInt64 = 0
    private static let searchQueue = DispatchQueue(label: "com.hunglx.DriveBar.fastSearch", qos: .userInteractive)

    private init() {
        refreshSearchResults()
    }

    // MARK: - Focus & Keyboard Helpers

    func triggerInputFocus(selectAll: Bool) {
        selectAllOnFocus = selectAll
        focusTrigger &+= 1
    }

    func syncImmediateTextBeforeSubmit(_ live: String) {
        switch screenMode {
        case .search:
            guard searchText != live else { return }
            searchText = live
            let trimmed = live.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowerTrimmed = trimmed.lowercased()
            let lowerLive = live.lowercased()

            // Synchronous modes (`c`, `cb`, `clip`, `s`, `ai`, `ocr`, `http`, `//`) are already populated by `searchText = live`.
            if lowerTrimmed == "c" || lowerLive.hasPrefix("c ") ||
               lowerTrimmed == "cb" || lowerLive.hasPrefix("cb ") ||
               lowerTrimmed == "clip" || lowerLive.hasPrefix("clip ") ||
               lowerTrimmed == "s" || lowerLive.hasPrefix("s ") ||
               lowerTrimmed == "ai" || lowerLive.hasPrefix("ai ") ||
               lowerTrimmed == "ocr" ||
               lowerTrimmed.hasPrefix("http://") || lowerTrimmed.hasPrefix("https://") ||
               lowerTrimmed.hasPrefix("//") {
                selectedIndex = 0
                return
            }

            if lowerTrimmed == "a" || lowerLive.hasPrefix("a ") {
                let appQuery = lowerTrimmed == "a" ? "" : String(live.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                searchGeneration &+= 1
                let drive = GoogleDriveIndexService.shared
                if appQuery.isEmpty {
                    searchResults = drive.defaultInstalledAppResultItems(limit: 80)
                } else {
                    let appTokens = appQuery.split(separator: " ").map(String.init)
                    let matched = GoogleDriveIndexService.searchInstalledApps(
                        queryTokens: appTokens,
                        apps: drive.installedApps,
                        historySnapshot: drive.history,
                        isAppOnlyMode: true,
                        maxResults: 60
                    )
                    searchResults = matched.isEmpty ? Self.emptyAppSearchBanner(for: appQuery) : matched
                }
                selectedIndex = 0
            } else if lowerTrimmed == "ff" || lowerLive.hasPrefix("ff ") {
                let fileQuery = lowerTrimmed == "ff" ? "" : String(live.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                searchGeneration &+= 1
                let drive = GoogleDriveIndexService.shared
                if fileQuery.isEmpty {
                    searchResults = drive.defaultFileModeResultItems(limit: 40)
                } else {
                    let fileTokens = fileQuery.split(separator: " ").map(String.init)
                    let hits = GoogleDriveIndexService.evaluateFileSearchHits(
                        tokens: fileTokens,
                        fastIndex: drive.fastFileIndex,
                        historySnapshot: drive.history,
                        pinnedSet: Set(AppSettings.shared.pinnedPaths),
                        maxResults: 45
                    )
                    searchResults = drive.buildFileSearchResultItems(from: hits, maxResults: 45)
                }
                selectedIndex = 0
            } else if !trimmed.isEmpty && !live.hasPrefix("/") && !live.hasPrefix("~/") {
                let isShared = (lowerTrimmed == "fs" || lowerLive.hasPrefix("fs "))
                var effective = trimmed
                if lowerLive.hasPrefix("fs ") {
                    effective = String(live.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                } else if lowerLive.hasPrefix("f ") {
                    effective = String(live.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                let tokens = effective.split(separator: " ").map(String.init)
                if !tokens.isEmpty {
                    searchGeneration &+= 1
                    let drive = GoogleDriveIndexService.shared
                    var built: [SearchResultItem]
                    if isShared {
                        let hits = GoogleDriveIndexService.evaluateSharedSearchHits(
                            tokens: tokens,
                            fastIndex: drive.fastSharedIndex,
                            historySnapshot: drive.history,
                            maxResults: 45
                        )
                        built = drive.buildSharedSearchResultItems(from: hits, maxResults: 45)
                    } else {
                        built = drive.searchMyDriveFolders(
                            tokens: tokens,
                            includeApps: AppSettings.shared.includeMacAppsInSearch
                        )
                        if GoogleDriveIndexService.hasExplicitFileExtensionToken(tokens) || built.count < 5 {
                            let fHits = GoogleDriveIndexService.evaluateFileSearchHits(
                                tokens: tokens,
                                fastIndex: drive.fastFileIndex,
                                historySnapshot: drive.history,
                                pinnedSet: Set(AppSettings.shared.pinnedPaths),
                                maxResults: 15
                            )
                            let fItems = drive.buildFileSearchResultItems(from: fHits, maxResults: 15)
                            if GoogleDriveIndexService.hasExplicitFileExtensionToken(tokens) {
                                built.insert(contentsOf: fItems, at: 0)
                            } else {
                                built.append(contentsOf: fItems)
                            }
                        }
                    }
                    applyInlineCommandsAndEmptyFallback(to: &built, effectiveQuery: effective, isSharedMode: isShared)
                    searchResults = built
                    selectedIndex = 0
                }
            }
        case .universalActions:
            if actionFilterText != live { actionFilterText = live }
        case .contactDetail:
            if contactDetailFilterText != live { contactDetailFilterText = live }
        case .destinationPicker:
            guard destinationSearchText != live else { return }
            destinationSearchText = live
            let trimmed = live.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !live.hasPrefix("/") && !live.hasPrefix("~/") {
                let tokens = trimmed.split(separator: " ").map(String.init)
                let cleanTokens = tokens.map(GoogleDriveIndexService.cleanString).filter { !$0.isEmpty }
                if !cleanTokens.isEmpty {
                    destinationGeneration &+= 1
                    let drive = GoogleDriveIndexService.shared
                    let hits = GoogleDriveIndexService.evaluateMyDriveSearchHits(
                        tokens: tokens,
                        fastIndex: drive.fastFolderIndex,
                        historySnapshot: drive.history,
                        maxResults: 30
                    )
                    destinationFolders = drive.buildMyDriveSearchResultItems(
                        from: hits,
                        cleanTokens: cleanTokens,
                        includeApps: false,
                        maxResults: 30
                    )
                    selectedIndex = 0
                }
            }
        default:
            break
        }
    }

    func handleEscapeKey() {
        switch screenMode {
        case .search:
            if !searchText.isEmpty {
                searchText = ""
                triggerInputFocus(selectAll: false)
            } else {
                LauncherPanelController.shared.hide()
            }
        case .universalActions:
            if !actionFilterText.isEmpty {
                actionFilterText = ""
                triggerInputFocus(selectAll: false)
            } else if openedDirectlyInUniversalActions {
                LauncherPanelController.shared.hide()
            } else {
                returnToSearchMode()
            }
        case .openWithPicker(_, let prevTarget):
            openUniversalActions(for: prevTarget, directExternalTrigger: openedDirectlyInUniversalActions)
        case .destinationPicker(_, let sources):
            if !destinationSearchText.isEmpty {
                destinationSearchText = ""
                triggerInputFocus(selectAll: false)
            } else {
                openUniversalActions(for: .files(sources), directExternalTrigger: openedDirectlyInUniversalActions)
            }
        case .batchRename(_, let prevTarget):
            openUniversalActions(for: prevTarget, directExternalTrigger: openedDirectlyInUniversalActions)
        case .markdownPreview(_, let src, _, _, _, _):
            openUniversalActions(for: .files([src]), directExternalTrigger: openedDirectlyInUniversalActions)
        case .contactDetail:
            if !contactDetailFilterText.isEmpty {
                contactDetailFilterText = ""
                triggerInputFocus(selectAll: false)
            } else {
                returnFromContactDetail()
            }
        }
    }

    func handleTabKey() {
        switch screenMode {
        case .search:
            openUniversalActionsForSelectedSearchItem()
        case .universalActions:
            if !openedDirectlyInUniversalActions {
                returnToSearchMode()
            }
        case .destinationPicker:
            _ = drillIntoSelectedDestinationFolder()
        case .contactDetail:
            returnFromContactDetail()
        default:
            break
        }
    }

    func popParentFolderIfAtSlashBoundary() -> Bool {
        switch screenMode {
        case .search:
            if let activeDir = activeBrowseDirectory {
                let trimmedSlash = activeDir.hasSuffix("/") ? String(activeDir.dropLast()) : activeDir
                let parent = (trimmedSlash as NSString).deletingLastPathComponent
                let myDrive = GoogleDriveIndexService.shared.myDrivePath
                let driveRoot = GoogleDriveIndexService.shared.accountForPath(trimmedSlash)?.rootPath
                if parent == "/" || parent.isEmpty || (myDrive != nil && trimmedSlash == myDrive) || (driveRoot != nil && trimmedSlash == driveRoot) {
                    activeBrowseDirectory = nil
                    searchText = ""
                } else {
                    enterBrowseMode(at: parent)
                }
                triggerInputFocus(selectAll: false)
                return true
            }
            let s = searchText
            if (s.hasPrefix("/") || s.hasPrefix("…") || s.hasPrefix("...")), s.hasSuffix("/"), s.count > 1 {
                let trimmedSlash = String(s.dropLast())
                let parent = (trimmedSlash as NSString).deletingLastPathComponent
                let myDrive = GoogleDriveIndexService.shared.myDrivePath
                if parent == "/" || (myDrive != nil && trimmedSlash == myDrive) {
                    searchText = ""
                } else {
                    searchText = parent.hasSuffix("/") ? parent : parent + "/"
                }
                triggerInputFocus(selectAll: false)
                return true
            }
            return false

        case .destinationPicker:
            if let activeDir = activeDestinationBrowseDirectory {
                let trimmedSlash = activeDir.hasSuffix("/") ? String(activeDir.dropLast()) : activeDir
                let parent = (trimmedSlash as NSString).deletingLastPathComponent
                let myDrive = GoogleDriveIndexService.shared.myDrivePath
                let driveRoot = GoogleDriveIndexService.shared.accountForPath(trimmedSlash)?.rootPath
                if parent == "/" || parent.isEmpty || (myDrive != nil && trimmedSlash == myDrive) || (driveRoot != nil && trimmedSlash == driveRoot) {
                    activeDestinationBrowseDirectory = nil
                    destinationSearchText = ""
                } else {
                    let clean = parent.hasSuffix("/") ? parent : parent + "/"
                    activeDestinationBrowseDirectory = clean
                    destinationSearchText = formatBrowseDisplayPath(clean)
                }
                triggerInputFocus(selectAll: false)
                return true
            }
            let s = destinationSearchText
            if (s.hasPrefix("/") || s.hasPrefix("…") || s.hasPrefix("...")), s.hasSuffix("/"), s.count > 1 {
                let trimmedSlash = String(s.dropLast())
                let parent = (trimmedSlash as NSString).deletingLastPathComponent
                let myDrive = GoogleDriveIndexService.shared.myDrivePath
                if parent == "/" || (myDrive != nil && trimmedSlash == myDrive) {
                    destinationSearchText = ""
                } else {
                    destinationSearchText = parent.hasSuffix("/") ? parent : parent + "/"
                }
                triggerInputFocus(selectAll: false)
                return true
            }
            return false

        default:
            return false
        }
    }

    @discardableResult
    func drillIntoSelectedDestinationFolder() -> Bool {
        guard case .destinationPicker = screenMode,
              selectedIndex >= 0 && selectedIndex < destinationFolders.count,
              let path = destinationFolders[selectedIndex].path else {
            return false
        }
        let clean = path.hasSuffix("/") ? path : path + "/"
        activeDestinationBrowseDirectory = clean
        destinationSearchText = formatBrowseDisplayPath(clean)
        triggerInputFocus(selectAll: false)
        return true
    }

    // MARK: - Mode Transitions

    func prepareForSearchLaunch() {
        openedDirectlyInUniversalActions = false
        screenMode = .search
        actionFilterText = ""
        selectedIndex = 0
        GoogleDriveIndexService.shared.refreshInstalledAppsIfNeeded()
        refreshSearchResults()
    }

    func openUniversalActions(for target: ActionTarget, directExternalTrigger: Bool) {
        openedDirectlyInUniversalActions = directExternalTrigger
        actionFilterText = ""
        screenMode = .universalActions(target: target)
        refreshFilteredActions()
        updatePreviewThumbnailIfNeeded()
        triggerInputFocus(selectAll: false)
        if LauncherPanelController.shared.isVisible {
            DispatchQueue.main.async {
                LauncherPanelController.shared.restoreFocusFromAuxiliaryPanel()
            }
        }
    }

    func enterBrowseMode(at folderPath: String) {
        openedDirectlyInUniversalActions = false
        screenMode = .search
        let clean = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        GoogleDriveIndexService.shared.recordUsed(folderPath)
        activeBrowseDirectory = clean
        searchText = formatBrowseDisplayPath(clean)
        triggerInputFocus(selectAll: false)
        if LauncherPanelController.shared.isVisible {
            DispatchQueue.main.async {
                LauncherPanelController.shared.restoreFocusFromAuxiliaryPanel()
            }
        }
    }

    func returnToSearchMode() {
        screenMode = .search
        actionFilterText = ""
        activeBrowseDirectory = nil
        refreshSearchResults()
        triggerInputFocus(selectAll: false)
        if LauncherPanelController.shared.isVisible {
            DispatchQueue.main.async {
                LauncherPanelController.shared.restoreFocusFromAuxiliaryPanel()
            }
        }
    }

    func enterOpenWithPicker(for fileURL: URL, previousTarget: ActionTarget) {
        let appURLs: [URL]
        if fileURL.path.contains("/Library/CloudStorage/"),
           let ut = UTType(filenameExtension: fileURL.pathExtension.lowercased()) {
            let byType = NSWorkspace.shared.urlsForApplications(toOpen: ut)
            appURLs = byType.isEmpty ? NSWorkspace.shared.urlsForApplications(toOpen: fileURL) : byType
        } else {
            appURLs = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        }
        openWithApps = appURLs.map { u in
            (u.deletingPathExtension().lastPathComponent, u)
        }
        screenMode = .openWithPicker(fileURL: fileURL, previousTarget: previousTarget)
    }

    func enterDestinationPicker(operation: FileTransferOperation, sources: [URL]) {
        destinationSearchText = ""
        screenMode = .destinationPicker(operation: operation, sources: sources)
        refreshDestinationFolders()
        triggerInputFocus(selectAll: false)
        if LauncherPanelController.shared.isVisible {
            DispatchQueue.main.async {
                LauncherPanelController.shared.restoreFocusFromAuxiliaryPanel()
            }
        }
    }

    func openContactDetail(contactID: String) {
        let prevQuery = searchText
        let prevIdx = selectedIndex
        ContactsSearchService.shared.recordContactOpened(contactID)
        ContactsSearchService.shared.lastCopiedFieldID = nil
        contactDetailFilterText = ""
        screenMode = .contactDetail(contactID: contactID, previousQuery: prevQuery, previousSelectedIndex: prevIdx)
        refreshFilteredContactDetailFields()
        triggerInputFocus(selectAll: false)
        if LauncherPanelController.shared.isVisible {
            DispatchQueue.main.async {
                LauncherPanelController.shared.restoreFocusFromAuxiliaryPanel()
            }
        }
    }

    func returnFromContactDetail() {
        guard case .contactDetail(_, let prevQuery, let prevIdx) = screenMode else {
            returnToSearchMode()
            return
        }
        screenMode = .search
        if searchText != prevQuery {
            searchText = prevQuery
        } else {
            refreshSearchResults()
        }
        selectedIndex = min(max(0, prevIdx), max(0, searchResults.count - 1))
        triggerInputFocus(selectAll: false)
        if LauncherPanelController.shared.isVisible {
            DispatchQueue.main.async {
                LauncherPanelController.shared.restoreFocusFromAuxiliaryPanel()
            }
        }
    }

    func refreshFilteredContactDetailFields() {
        guard case .contactDetail(let contactID, _, _) = screenMode,
              let rec = ContactsSearchService.shared.contact(withID: contactID) else {
            filteredContactDetailFields = []
            return
        }
        let qNorm = GoogleDriveIndexService.removeAccents(contactDetailFilterText)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !qNorm.isEmpty else {
            filteredContactDetailFields = rec.fields
            selectedIndex = 0
            return
        }
        let tokens = qNorm.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        filteredContactDetailFields = rec.fields.filter { f in
            var alias = ""
            if f.id.hasPrefix("phone:") { alias = "sdt phone dien thoai mobile so" }
            else if f.id.hasPrefix("email:") { alias = "email mail thu" }
            else if f.id.hasPrefix("addr:") { alias = "dia chi address map" }
            else if f.id.hasPrefix("org:") { alias = "co quan cong ty chuc vu org company" }
            else if f.id.hasPrefix("name:") { alias = "ho ten name" }
            let hay = GoogleDriveIndexService.removeAccents("\(f.categoryLabel) \(f.displayValue) \(alias)").lowercased()
            return tokens.allSatisfy { hay.contains($0) }
        }
        selectedIndex = 0
    }

    func refreshContactsResultsIfNeeded() {
        switch screenMode {
        case .search:
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed == "c" || searchText.lowercased().hasPrefix("c ") {
                refreshSearchResults()
            }
        case .contactDetail:
            refreshFilteredContactDetailFields()
        default:
            break
        }
    }

    // MARK: - Active Search Mode Pill Label

    var currentSearchModeBadge: (label: String, color: Color) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowerTrimmed = trimmed.lowercased()
        let lowerRaw = searchText.lowercased()
        if lowerTrimmed.hasPrefix("http://") || lowerTrimmed.hasPrefix("https://") {
            return ("Web → AI MD", .secondary)
        }
        if activeBrowseDirectory != nil || searchText.hasPrefix("/") || searchText.hasPrefix("~/") || searchText.hasPrefix("…") || searchText.hasPrefix("...") {
            return ("Duyệt thư mục", .secondary)
        }
        if lowerTrimmed == "a" || lowerRaw.hasPrefix("a ") {
            return ("Ứng dụng", .secondary)
        }
        if lowerTrimmed == "ff" || lowerRaw.hasPrefix("ff ") {
            return ("Tệp tin", .secondary)
        }
        if lowerTrimmed == "c" || lowerRaw.hasPrefix("c ") {
            return ("Danh bạ", .secondary)
        }
        if lowerTrimmed == "cb" || lowerRaw.hasPrefix("cb ") || lowerTrimmed == "clip" || lowerRaw.hasPrefix("clip ") {
            return ("Clipboard", .secondary)
        }
        if lowerTrimmed == "s" || lowerRaw.hasPrefix("s ") {
            return ("Hệ thống", .secondary)
        }
        if lowerTrimmed == "fs" || lowerRaw.hasPrefix("fs ") {
            return ("Shared Drives", .secondary)
        }
        if lowerTrimmed == "ai" || lowerRaw.hasPrefix("ai ") || lowerTrimmed == "ocr" {
            return ("AI Toolkit", .secondary)
        }
        if trimmed.hasPrefix("//") {
            return ("Lệnh hệ thống", .secondary)
        }
        if InstantUtilityService.evaluateMathExpression(trimmed) != nil {
            return ("Máy tính", .secondary)
        }
        return ("Google Drive", .secondary)
    }

    // MARK: - Search Engine Evaluation (Zero Main-Thread Blocking!)

    func refreshSearchResults() {
        searchGeneration &+= 1
        let gen = searchGeneration
        isLoadingBrowseFiles = false

        let drive = GoogleDriveIndexService.shared
        let raw = searchText
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 0. Direct Web URL pasted/typed into Search Bar -> Instant Convert Web URL to Markdown!
        if (trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://")),
           !trimmed.contains(" "),
           let webURL = URL(string: trimmed) {
            searchResults = [
                SearchResultItem(
                    id: "urlmd:copy:\(trimmed)",
                    title: "Convert Web URL to Markdown (Copy vào Clipboard)",
                    subtitle: "Lọc sạch bài viết / Google Docs / GitHub từ \(webURL.host ?? "URL") → Chuẩn AI (⌥↩ lưu file .md ra Desktop)",
                    path: nil,
                    isDirectory: false,
                    kind: .webURLQuickConvert(url: webURL, preview: false),
                    badge: "AI • URL",
                    sfSymbolFallback: "globe.desk.fill"
                ),
                SearchResultItem(
                    id: "urlmd:preview:\(trimmed)",
                    title: "Convert Web URL & Xem trước trong AI Inspector",
                    subtitle: "Đếm số Token ước tính và xem trực tiếp văn bản Markdown đã làm sạch",
                    path: nil,
                    isDirectory: false,
                    kind: .webURLQuickConvert(url: webURL, preview: true),
                    badge: "Preview",
                    sfSymbolFallback: "doc.viewfinder.fill"
                )
            ]
            selectedIndex = 0
            return
        }

        // 1. Check `gda <path>` (avoid blocking syscall on CloudStorage paths)
        if raw.lowercased().hasPrefix("gda ") {
            let p = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if !p.isEmpty && (p.contains("/Library/CloudStorage/") || FileManager.default.fileExists(atPath: p)) {
                let isDir = drive.isKnownDirectory(p)
                openUniversalActions(for: .files([URL(fileURLWithPath: p, isDirectory: isDir)]), directExternalTrigger: false)
                return
            }
        }

        // 2. Check `ai` / `ai <filter>` or `ocr` quick list (Finder selection + Clipboard Image OCR)
        if trimmed.lowercased() == "ocr" {
            searchResults = [
                SearchResultItem(
                    id: "aicmd:ocr_clip",
                    title: "OCR Ảnh trong Clipboard sang Markdown (Tiếng Việt + Anh)",
                    subtitle: "Nhận diện chữ chuẩn từ ảnh chụp màn hình vừa lưu trong Clipboard • ↩ Copy Markdown • ⌥↩ Xem trong AI Inspector",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "sys.ocr_clipboard"),
                    badge: "AI • OCR",
                    sfSymbolFallback: "camera.viewfinder"
                ),
                SearchResultItem(
                    id: "aicmd:ocr_finder",
                    title: "OCR Tệp PDF Scan / Ảnh đang chọn trong Finder sang Markdown",
                    subtitle: "Dùng Apple Vision OCR trên tệp đang chọn trong Finder",
                    path: nil,
                    isDirectory: false,
                    kind: .aiQuickCommand(action: "ai.ocr_md"),
                    badge: "Finder",
                    sfSymbolFallback: "text.viewfinder"
                )
            ]
            selectedIndex = 0
            return
        }

        if trimmed.lowercased() == "ai" || raw.lowercased().hasPrefix("ai ") {
            let sub = raw.count > 3 ? String(raw.dropFirst(3)).lowercased().trimmingCharacters(in: .whitespaces) : ""
            let items: [SearchResultItem] = [
                SearchResultItem(
                    id: "aicmd:ocr_clip",
                    title: "OCR Ảnh chụp màn hình từ Clipboard → Markdown",
                    subtitle: "Trích xuất chữ Tiếng Việt & Tiếng Anh từ ảnh đang lưu trong Clipboard (⌥↩ xem trước)",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "sys.ocr_clipboard"),
                    badge: "OCR",
                    sfSymbolFallback: "camera.viewfinder"
                ),
                SearchResultItem(
                    id: "aicmd:md",
                    title: "Convert to Markdown (Mục đang chọn trong Finder)",
                    subtitle: "Xuất file .md cạnh file gốc & Copy thẳng Markdown vào Clipboard cho AI",
                    path: nil,
                    isDirectory: false,
                    kind: .aiQuickCommand(action: "ai.convert_md"),
                    badge: "AI • MD",
                    sfSymbolFallback: "doc.text.magnifyingglass"
                ),
                SearchResultItem(
                    id: "aicmd:copymd",
                    title: "Convert to Markdown → Copy Only",
                    subtitle: "Chỉ chuyển sang Markdown trong bộ nhớ và chép vào Clipboard (⌘V ngay)",
                    path: nil,
                    isDirectory: false,
                    kind: .aiQuickCommand(action: "ai.copy_md"),
                    badge: "Clipboard",
                    sfSymbolFallback: "doc.on.clipboard.fill"
                ),
                SearchResultItem(
                    id: "aicmd:pkg",
                    title: "Convert for AI (Gói đầy đủ _AI/)",
                    subtitle: "Tạo thư mục _AI/ chứa .md, .txt, .json, .html, manifest cho các tệp Finder",
                    path: nil,
                    isDirectory: false,
                    kind: .aiQuickCommand(action: "ai.convert_for_ai"),
                    badge: "_AI/",
                    sfSymbolFallback: "sparkles.rectangle.stack.fill"
                ),
                SearchResultItem(
                    id: "aicmd:pdf",
                    title: "Convert to PDF",
                    subtitle: "Chuyển các tệp đang chọn trong Finder sang PDF chuẩn qua LibreOffice",
                    path: nil,
                    isDirectory: false,
                    kind: .aiQuickCommand(action: "ai.convert_pdf"),
                    badge: "PDF",
                    sfSymbolFallback: "doc.richtext.fill"
                )
            ]
            searchResults = sub.isEmpty ? items : items.filter {
                $0.title.lowercased().contains(sub) || $0.subtitle.lowercased().contains(sub)
            }
            selectedIndex = 0
            return
        }

        // 3. Browse Mode (`/path/...`, `~/...`, or `…/...`) — 0ms RAM folders + async background POSIX readdir!
        if activeBrowseDirectory != nil || raw.hasPrefix("/") || raw.hasPrefix("~/") || raw.hasPrefix("…") || raw.hasPrefix("...") {
            let currentDir: String
            let filterPart: String
            if let activeDir = activeBrowseDirectory {
                currentDir = activeDir.hasSuffix("/") ? String(activeDir.dropLast()) : activeDir
                let displayPrefix = formatBrowseDisplayPath(activeDir)
                if raw.hasPrefix(displayPrefix) {
                    filterPart = String(raw.dropFirst(displayPrefix.count))
                } else if let lastSlash = raw.lastIndex(of: "/") {
                    filterPart = String(raw[raw.index(after: lastSlash)...])
                } else {
                    filterPart = ""
                }
            } else {
                let expanded = raw.hasPrefix("~/")
                    ? FileManager.default.homeDirectoryForCurrentUser.path + String(raw.dropFirst(1))
                    : raw
                if let lastSlash = expanded.lastIndex(of: "/") {
                    let dirPart = String(expanded[..<lastSlash])
                    currentDir = dirPart.isEmpty ? "/" : dirPart
                    filterPart = String(expanded[expanded.index(after: lastSlash)...])
                } else {
                    currentDir = expanded
                    filterPart = ""
                }
            }

            let words = filterPart.split(separator: " ").map(String.init)
            let ramChildren = drive.cachedChildrenInMemory(parentPath: currentDir, queryWords: words)
            searchResults = buildBrowseResultItems(
                currentDir: currentDir,
                words: words,
                filterPart: filterPart,
                children: ramChildren,
                isInitialRAMOnly: true
            )
            selectedIndex = 0
            isLoadingBrowseFiles = true

            Task.detached(priority: .userInitiated) {
                let diskChildren = GoogleDriveIndexService.listDirectoryFastPOSIX(
                    parentPath: currentDir,
                    queryWords: words
                )
                await MainActor.run {
                    let vm = LauncherViewModel.shared
                    guard vm.searchGeneration == gen else { return }
                    vm.isLoadingBrowseFiles = false

                    var merged: [(path: String, isDir: Bool)] = []
                    var seen = Set<String>()
                    for item in diskChildren where seen.insert(item.path).inserted {
                        merged.append(item)
                    }
                    for item in ramChildren where seen.insert(item.path).inserted {
                        merged.append(item)
                    }
                    merged.sort { a, b in
                        if a.isDir != b.isDir { return a.isDir && !b.isDir }
                        return (a.path as NSString).lastPathComponent.localizedStandardCompare((b.path as NSString).lastPathComponent) == .orderedAscending
                    }

                    let prevSelectedID: String? = (vm.selectedIndex >= 0 && vm.selectedIndex < vm.searchResults.count)
                        ? vm.searchResults[vm.selectedIndex].id
                        : nil
                    let finalItems = vm.buildBrowseResultItems(
                        currentDir: currentDir,
                        words: words,
                        filterPart: filterPart,
                        children: merged,
                        isInitialRAMOnly: false
                    )
                    vm.searchResults = finalItems
                    if let prevSelectedID, let matchIdx = finalItems.firstIndex(where: { $0.id == prevSelectedID }) {
                        vm.selectedIndex = matchIdx
                    } else {
                        vm.selectedIndex = min(vm.selectedIndex, max(0, finalItems.count - 1))
                    }
                }
            }
            return
        }

        // 3.2. Contacts Lookup Mode (`c` or `c <từ khóa>`) — Vietnamese accent-insensitive!
        if trimmed.lowercased() == "c" || raw.lowercased().hasPrefix("c ") {
            let contactQuery = trimmed.lowercased() == "c"
                ? ""
                : String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            searchResults = ContactsSearchService.shared.searchResultItems(query: contactQuery, limit: 60)
            selectedIndex = 0
            return
        }

        // 3.3. Clipboard History Mode (`cb` / `cb <từ khóa>` or `clip` / `clip <từ khóa>`)
        if trimmed.lowercased() == "cb" || raw.lowercased().hasPrefix("cb ") ||
           trimmed.lowercased() == "clip" || raw.lowercased().hasPrefix("clip ") {
            let clipQuery: String
            if raw.lowercased().hasPrefix("clip ") {
                clipQuery = String(raw.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if raw.lowercased().hasPrefix("cb ") {
                clipQuery = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else {
                clipQuery = ""
            }
            searchResults = ClipboardHistoryService.shared.searchResultItems(query: clipQuery, limit: 60)
            selectedIndex = 0
            return
        }

        // 3.4. System Commands Mode (`s` or `s <từ khóa>`)
        if trimmed.lowercased() == "s" || raw.lowercased().hasPrefix("s ") {
            let sysQuery = trimmed.lowercased() == "s"
                ? ""
                : String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            searchResults = InstantUtilityService.searchSystemCommands(query: sysQuery, isExplicitSystemMode: true)
            selectedIndex = 0
            return
        }

        // 3.5. App-Only Mode (`a` or `a <từ khóa>`) — Filter exclusively installed macOS applications!
        if trimmed.lowercased() == "a" || raw.lowercased().hasPrefix("a ") {
            let appQuery = trimmed.lowercased() == "a"
                ? ""
                : String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if appQuery.isEmpty {
                searchResults = drive.defaultInstalledAppResultItems(limit: 80)
            } else {
                let appTokens = appQuery.split(separator: " ").map(String.init)
                let matched = GoogleDriveIndexService.searchInstalledApps(
                    queryTokens: appTokens,
                    apps: drive.installedApps,
                    historySnapshot: drive.history,
                    isAppOnlyMode: true,
                    maxResults: 60
                )
                searchResults = matched.isEmpty ? Self.emptyAppSearchBanner(for: appQuery) : matched
            }
            selectedIndex = 0
            return
        }

        // 3.6. Direct File-Only Search Mode (`ff` or `ff <từ khóa>`) — Fast RAM index + Spotlight fallback!
        if trimmed.lowercased() == "ff" || raw.lowercased().hasPrefix("ff ") {
            let fileQuery = trimmed.lowercased() == "ff"
                ? ""
                : String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            if fileQuery.isEmpty {
                searchResults = drive.defaultFileModeResultItems(limit: 40)
                selectedIndex = 0
                return
            }
            let fileTokens = fileQuery.split(separator: " ").map(String.init)
            let fastFiles = drive.fastFileIndex
            let histSnap = drive.history
            let pinSet = Set(AppSettings.shared.pinnedPaths)
            let scopeDirs: [String] = {
                var dirs = drive.activeAccounts.map(\.rootPath)
                let home = FileManager.default.homeDirectoryForCurrentUser.path
                for sub in ["Desktop", "Downloads", "Documents"] {
                    let p = "\(home)/\(sub)"
                    if FileManager.default.fileExists(atPath: p) { dirs.append(p) }
                }
                return dirs
            }()

            Self.searchQueue.async {
                let hits = GoogleDriveIndexService.evaluateFileSearchHits(
                    tokens: fileTokens,
                    fastIndex: fastFiles,
                    historySnapshot: histSnap,
                    pinnedSet: pinSet,
                    maxResults: 45
                )
                Task { @MainActor in
                    let vm = LauncherViewModel.shared
                    guard vm.searchGeneration == gen else { return }
                    let built = GoogleDriveIndexService.shared.buildFileSearchResultItems(from: hits, maxResults: 45)
                    if !built.isEmpty {
                        vm.searchResults = built
                    } else {
                        vm.searchResults = [
                            SearchResultItem(
                                id: "ffile:searching:\(fileQuery)",
                                title: "Đang tìm tệp '\(fileQuery)'...",
                                subtitle: "Đang mở rộng tìm kiếm qua Spotlight macOS",
                                path: nil,
                                isDirectory: false,
                                kind: .infoBanner,
                                badge: "Tệp tin",
                                sfSymbolFallback: "magnifyingglass"
                            )
                        ]
                    }
                    vm.selectedIndex = 0
                }

                if hits.count < 6 && fileQuery.count >= 2 && !scopeDirs.isEmpty {
                    let spotPaths = GoogleDriveIndexService.spotlightFallbackFilePaths(
                        query: fileQuery,
                        scopeDirs: scopeDirs,
                        limit: 25
                    )
                    Task { @MainActor in
                        let vm = LauncherViewModel.shared
                        guard vm.searchGeneration == gen else { return }
                        let driveSvc = GoogleDriveIndexService.shared
                        var combined = driveSvc.buildFileSearchResultItems(from: hits, maxResults: 45)
                        var seen = Set(combined.compactMap(\.path))
                        for sp in spotPaths where seen.insert(sp).inserted {
                            let ext = (sp as NSString).pathExtension.uppercased()
                            combined.append(SearchResultItem(
                                id: "ffile:spot:\(sp)",
                                title: (sp as NSString).lastPathComponent,
                                subtitle: driveSvc.formatHierarchicalSubtitle(sp, maxLevels: 3),
                                path: sp,
                                isDirectory: false,
                                kind: .driveFile(path: sp),
                                badge: ext.isEmpty ? "Tệp" : ext,
                                sfSymbolFallback: "doc.fill"
                            ))
                            if combined.count >= 45 { break }
                        }
                        if combined.isEmpty {
                            combined = [
                                SearchResultItem(
                                    id: "ffile:nomatch:\(fileQuery)",
                                    title: "Không tìm thấy tệp tin nào khớp '\(fileQuery)'",
                                    subtitle: "Gõ '//rebuild' nếu tệp vừa được tải lên Google Drive",
                                    path: nil,
                                    isDirectory: false,
                                    kind: .infoBanner,
                                    badge: "Tệp tin",
                                    sfSymbolFallback: "doc.questionmark"
                                )
                            ]
                        }
                        vm.searchResults = combined
                        vm.selectedIndex = min(vm.selectedIndex, max(0, combined.count - 1))
                    }
                }
            }
            return
        }

        // 4. Parse optional prefixes `f ` or `fs `
        var isSharedMode = false
        var effectiveQuery = trimmed

        if trimmed.lowercased() == "fs" {
            isSharedMode = true
            effectiveQuery = ""
        } else if raw.lowercased().hasPrefix("fs ") {
            isSharedMode = true
            effectiveQuery = String(raw.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        } else if trimmed.lowercased() == "f" {
            effectiveQuery = ""
        } else if raw.lowercased().hasPrefix("f ") {
            effectiveQuery = String(raw.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        }

        // 5. System slash commands (`//rebuild`, `//clean`, `//hotkey`)
        if effectiveQuery == "//rebuild" {
            searchResults = [
                SearchResultItem(
                    id: "cmd:rebuild",
                    title: drive.isRebuildingFolders ? "Đang quét lại dữ liệu Google Drive ở nền..." : "Quét lại toàn bộ Cache Google Drive (Background Rebuild)",
                    subtitle: "Nhấn Enter để cập nhật danh mục thư mục My Drive & Shared Drives mà không gây đơ máy",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "rebuild"),
                    badge: "Rebuild",
                    sfSymbolFallback: "arrow.clockwise.circle"
                )
            ]
            selectedIndex = 0
            return
        }

        if ["//clean", "//clear", "//clear-history"].contains(effectiveQuery) {
            searchResults = [
                SearchResultItem(
                    id: "cmd:clean",
                    title: "Xóa toàn bộ lịch sử thư mục mở gần đây",
                    subtitle: "Nhấn Enter để làm sạch danh sách mở gần đây",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "clean-history"),
                    badge: "Clean",
                    sfSymbolFallback: "trash"
                )
            ]
            selectedIndex = 0
            return
        }

        if ["//win", "//windows", "//tab", "//preview"].contains(effectiveQuery.lowercased()) {
            let curWin = AppSettings.shared.windowSwitcherHotKey.readableDisplay
            searchResults = [
                SearchResultItem(
                    id: "cmd:open-win-switcher",
                    title: "Mở Windows Preview — Chuyển đổi & phóng to cửa sổ đang chạy (\(curWin))",
                    subtitle: "Hiển thị tất cả cửa sổ các ứng dụng đang mở trên mọi Desktop & Màn hình",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "open-window-switcher"),
                    badge: curWin,
                    sfSymbolFallback: "macwindow.on.rectangle"
                ),
                SearchResultItem(
                    id: "cmd:record-win-hotkey",
                    title: "Thiết lập phím tắt & chế độ hiển thị Windows Preview...",
                    subtitle: "Đổi phím tắt (\(curWin) / ⌥⇥ / tùy chọn), bật/tắt cửa sổ Minimize và phạm vi màn hình",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "record-win-hotkey"),
                    badge: "Cài đặt",
                    sfSymbolFallback: "slider.horizontal.3"
                )
            ]
            selectedIndex = 0
            return
        }

        if ["//hotkey", "//shortcut", "//phimtat"].contains(effectiveQuery.lowercased()) {
            searchResults = Self.hotkeyQuickItems()
            selectedIndex = 0
            return
        }

        // 6. Check Google Drive availability (still allow Math Calculator, System Commands & Installed Apps!)
        if drive.accountRoot == nil {
            var offlineResults: [SearchResultItem] = []
            if let math = InstantUtilityService.evaluateMathExpression(effectiveQuery) {
                offlineResults.append(Self.makeCalculatorResultItem(math))
            }
            offlineResults.append(contentsOf: InstantUtilityService.searchSystemCommands(query: effectiveQuery, isExplicitSystemMode: false))

            let fallbackTokens = effectiveQuery.split(separator: " ").map(String.init)
            if AppSettings.shared.includeMacAppsInSearch && !fallbackTokens.isEmpty {
                let appMatches = GoogleDriveIndexService.searchInstalledApps(
                    queryTokens: fallbackTokens,
                    apps: drive.installedApps,
                    historySnapshot: drive.history,
                    isAppOnlyMode: true,
                    maxResults: 30
                )
                offlineResults.append(contentsOf: appMatches)
            }
            if !offlineResults.isEmpty {
                searchResults = offlineResults
                selectedIndex = 0
                return
            }
            searchResults = [
                SearchResultItem(
                    id: "no-gdrive",
                    title: "Không tìm thấy thư mục Google Drive trong ~/Library/CloudStorage",
                    subtitle: "Gõ 'c ' tìm Danh bạ, 'cb ' lịch sử Clipboard, 'a ' ứng dụng, 's ' lệnh hệ thống, hoặc dùng Universal Actions (\(AppSettings.shared.universalActionHotKey.readableDisplay))",
                    path: nil,
                    isDirectory: false,
                    kind: .infoBanner,
                    badge: nil,
                    sfSymbolFallback: "exclamationmark.icloud.fill"
                )
            ]
            selectedIndex = 0
            return
        }

        let tokens = effectiveQuery.split(separator: " ").map(String.init)
        if tokens.isEmpty {
            searchResults = isSharedMode ? drive.recentSharedItems(limit: 9) : drive.recentMyDriveFolders(limit: 9)
            selectedIndex = 0
            return
        }

        // Instant 0ms Math Calculator & Alfred System Commands feedback while background search queue evaluates folders/files
        let instantSysItems = InstantUtilityService.searchSystemCommands(query: effectiveQuery, isExplicitSystemMode: false)
        let liveMath = InstantUtilityService.evaluateMathExpression(effectiveQuery)
        if !instantSysItems.isEmpty || liveMath != nil {
            var current = searchResults.filter {
                if case .calculatorResult = $0.kind { return false }
                if case .systemCommand = $0.kind { return false }
                if case .infoBanner = $0.kind { return false }
                return true
            }
            if !instantSysItems.isEmpty {
                current.insert(contentsOf: instantSysItems, at: 0)
            }
            if let liveMath {
                current.insert(Self.makeCalculatorResultItem(liveMath), at: 0)
            }
            searchResults = current
            selectedIndex = 0
        }

        let cleanTokens = tokens.map(GoogleDriveIndexService.cleanString).filter { !$0.isEmpty }
        if cleanTokens.isEmpty {
            if let liveMath = InstantUtilityService.evaluateMathExpression(effectiveQuery) {
                searchResults = [Self.makeCalculatorResultItem(liveMath)]
            } else {
                searchResults = isSharedMode ? drive.recentSharedItems(limit: 9) : drive.recentMyDriveFolders(limit: 9)
            }
            selectedIndex = 0
            return
        }

        let fastFolders = drive.fastFolderIndex
        let fastShared = drive.fastSharedIndex
        let fastFiles = drive.fastFileIndex
        let histSnap = drive.history
        let pinSet = Set(AppSettings.shared.pinnedPaths)
        let includeApps = AppSettings.shared.includeMacAppsInSearch
        let querySnap = effectiveQuery
        let sharedSnap = isSharedMode
        let hasExtToken = GoogleDriveIndexService.hasExplicitFileExtensionToken(tokens)

        Self.searchQueue.async {
            if sharedSnap {
                let hits = GoogleDriveIndexService.evaluateSharedSearchHits(
                    tokens: tokens,
                    fastIndex: fastShared,
                    historySnapshot: histSnap,
                    maxResults: 45
                )
                Task { @MainActor in
                    let vm = LauncherViewModel.shared
                    guard vm.searchGeneration == gen else { return }
                    var built = GoogleDriveIndexService.shared.buildSharedSearchResultItems(from: hits, maxResults: 45)
                    vm.applyInlineCommandsAndEmptyFallback(to: &built, effectiveQuery: querySnap, isSharedMode: true)
                    vm.searchResults = built
                    vm.selectedIndex = 0
                }
            } else {
                let hits = GoogleDriveIndexService.evaluateMyDriveSearchHits(
                    tokens: tokens,
                    fastIndex: fastFolders,
                    historySnapshot: histSnap,
                    maxResults: 45
                )
                let shouldIncludeFiles = hasExtToken || (hits.count < 5 && querySnap.count >= 3)
                let fileHits: [(entry: DriveFileEntry, historyCount: Int, isPinned: Bool)]
                if shouldIncludeFiles {
                    fileHits = GoogleDriveIndexService.evaluateFileSearchHits(
                        tokens: tokens,
                        fastIndex: fastFiles,
                        historySnapshot: histSnap,
                        pinnedSet: pinSet,
                        maxResults: hasExtToken ? 25 : 12
                    )
                } else {
                    fileHits = []
                }

                Task { @MainActor in
                    let vm = LauncherViewModel.shared
                    guard vm.searchGeneration == gen else { return }
                    let driveSvc = GoogleDriveIndexService.shared
                    var built = driveSvc.buildMyDriveSearchResultItems(
                        from: hits,
                        cleanTokens: cleanTokens,
                        includeApps: includeApps,
                        maxResults: 45
                    )
                    if !fileHits.isEmpty {
                        let fileItems = driveSvc.buildFileSearchResultItems(from: fileHits, maxResults: hasExtToken ? 25 : 12)
                        if hasExtToken {
                            built.insert(contentsOf: fileItems, at: 0)
                        } else {
                            built.append(contentsOf: fileItems)
                        }
                    }
                    vm.applyInlineCommandsAndEmptyFallback(to: &built, effectiveQuery: querySnap, isSharedMode: false)
                    vm.searchResults = built
                    vm.selectedIndex = 0
                }
            }
        }
    }

    private func buildBrowseResultItems(
        currentDir: String,
        words: [String],
        filterPart: String,
        children: [(path: String, isDir: Bool)],
        isInitialRAMOnly: Bool
    ) -> [SearchResultItem] {
        let drive = GoogleDriveIndexService.shared
        var items: [SearchResultItem] = []
        items.reserveCapacity(min(children.count + 2, 84))

        if words.isEmpty {
            let folderName = currentDir == "/" ? "/" : (currentDir as NSString).lastPathComponent
            items.append(SearchResultItem(
                id: "open-finder:\(currentDir)",
                title: "Mở thư mục '\(folderName)' trong Finder",
                subtitle: "Nhấn Enter (hoặc click chuột) để mở trong Finder • Phím ↓ chọn mục con bên dưới • ⇥ Actions",
                path: currentDir,
                isDirectory: true,
                kind: .openInFinder(path: currentDir),
                badge: "Finder",
                sfSymbolFallback: "folder"
            ))
        }

        for child in children.prefix(80) {
            let ext = URL(fileURLWithPath: child.path).pathExtension.uppercased()
            items.append(SearchResultItem(
                id: "browse:\(child.path)",
                title: (child.path as NSString).lastPathComponent,
                subtitle: drive.formatHierarchicalSubtitle(child.path, maxLevels: 3),
                path: child.path,
                isDirectory: child.isDir,
                kind: child.isDir ? .driveFolder(path: child.path) : .driveFile(path: child.path),
                badge: child.isDir ? nil : (ext.isEmpty ? nil : ext),
                sfSymbolFallback: child.isDir ? "folder.fill" : "doc.fill"
            ))
        }

        if words.isEmpty && currentDir != "/" && currentDir != drive.myDrivePath {
            let parent = (currentDir as NSString).deletingLastPathComponent
            items.append(SearchResultItem(
                id: "parent:\(parent)",
                title: ".. (Quay lại thư mục cha)",
                subtitle: parent,
                path: parent,
                isDirectory: true,
                kind: .parentFolder(path: parent),
                badge: "⌫",
                sfSymbolFallback: "arrow.turn.left.up"
            ))
        }

        if items.isEmpty {
            items.append(SearchResultItem(
                id: "empty-browse",
                title: isInitialRAMOnly ? "Đang đọc danh sách tệp trong thư mục..." : "Không có tệp hoặc thư mục con khớp '\(filterPart)'",
                subtitle: currentDir,
                path: nil,
                isDirectory: false,
                kind: .infoBanner,
                badge: nil,
                sfSymbolFallback: "folder"
            ))
        }

        return items
    }

    private func applyInlineCommandsAndEmptyFallback(
        to results: inout [SearchResultItem],
        effectiveQuery: String,
        isSharedMode: Bool
    ) {
        let normQ = GoogleDriveIndexService.removeAccents(effectiveQuery).lowercased()
        if normQ.contains("windows preview") || normQ.contains("chuyen cua so") || normQ == "cmd tab" {
            let curWin = AppSettings.shared.windowSwitcherHotKey.readableDisplay
            results.insert(
                SearchResultItem(
                    id: "cmd:open-win-inline",
                    title: "Mở Windows Preview — Xem & chuyển nhanh mọi cửa sổ (\(curWin))",
                    subtitle: "Hỗ trợ đa cửa sổ cùng ứng dụng, đa Desktop/Màn hình & phóng to nội dung trực tiếp",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "open-window-switcher"),
                    badge: curWin,
                    sfSymbolFallback: "macwindow.on.rectangle"
                ),
                at: 0
            )
        }
        if normQ.contains("phim tat") || normQ == "hotkey" || normQ == "shortcut" {
            results.insert(contentsOf: Self.hotkeyQuickItems(), at: 0)
        }
        if normQ.contains("clean") || normQ.contains("clear") {
            results.insert(
                SearchResultItem(
                    id: "cmd:clean-inline",
                    title: "Xóa lịch sử thư mục gần đây (Clean History)",
                    subtitle: "Nhấn Enter để làm sạch lịch sử mở gần đây",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "clean-history"),
                    badge: "History",
                    sfSymbolFallback: "trash"
                ),
                at: 0
            )
        }

        let inlineUtilities = InstantUtilityService.searchSystemCommands(query: effectiveQuery, isExplicitSystemMode: false)
        if !inlineUtilities.isEmpty {
            results.insert(contentsOf: inlineUtilities, at: 0)
        }

        if let math = InstantUtilityService.evaluateMathExpression(effectiveQuery) {
            results.insert(Self.makeCalculatorResultItem(math), at: 0)
        }

        if results.isEmpty {
            results = [
                SearchResultItem(
                    id: "no-match",
                    title: isSharedMode ? "Không tìm thấy mục chia sẻ phù hợp" : "Không tìm thấy thư mục hoặc tệp phù hợp",
                    subtitle: "Từ khóa: '\(effectiveQuery)'  •  Gõ 'ff \(effectiveQuery)' để tìm mở rộng qua Spotlight hoặc '//rebuild' quét lại",
                    path: nil,
                    isDirectory: false,
                    kind: .infoBanner,
                    badge: nil,
                    sfSymbolFallback: "magnifyingglass"
                )
            ]
        }
    }

    private static func makeCalculatorResultItem(_ math: MathEvaluationResult) -> SearchResultItem {
        SearchResultItem(
            id: "calc:\(math.expression)",
            title: "= \(math.formattedDisplay)",
            subtitle: "Biểu thức: \(math.expression)  •  ↩ Copy kết quả (\(math.rawCopyString))  •  ⌥↩ Copy cả phép tính",
            path: nil,
            isDirectory: false,
            kind: .calculatorResult(
                expression: math.expression,
                rawValue: math.rawCopyString,
                formattedValue: math.formattedDisplay
            ),
            badge: "Máy tính",
            sfSymbolFallback: "function"
        )
    }

    // MARK: - Universal Actions Filtering

    func refreshFilteredActions() {
        guard case .universalActions(let target) = screenMode else {
            filteredActions = []
            return
        }

        let settings = AppSettings.shared
        let drive = GoogleDriveIndexService.shared
        let inGDrive = target.fileURLs.first.map { drive.isPathInGoogleDrive($0.path) } ?? false

        let candidates = UniversalActionCatalog.all.filter { def in
            guard settings.isActionEnabled(def.id) else { return false }
            return def.matches(target: target, isInsideGoogleDrive: inGDrive)
        }

        let latcher = SyncAndLatchingService.shared
        let q = GoogleDriveIndexService.removeAccents(actionFilterText)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if q.isEmpty {
            filteredActions = candidates.sorted { a, b in
                let scoreA = a.priority + latcher.latchBoost(for: a.id, target: target)
                let scoreB = b.priority + latcher.latchBoost(for: b.id, target: target)
                return scoreA > scoreB
            }
        } else {
            let tokens = q.split(separator: " ").map(String.init)
            var scored: [(score: Int, def: UniversalActionDefinition)] = []
            for def in candidates {
                let titleNorm = GoogleDriveIndexService.removeAccents(def.title).lowercased()
                let subNorm = GoogleDriveIndexService.removeAccents(def.subtitle).lowercased()
                let kwNorm = def.keywords.lowercased()

                let allMatched = tokens.allSatisfy { tok in
                    titleNorm.contains(tok) || kwNorm.contains(tok) || subNorm.contains(tok)
                }
                guard allMatched else { continue }

                var sc = (def.priority / 10) + (latcher.latchBoost(for: def.id, target: target) / 3)
                if titleNorm.hasPrefix(q) { sc += 500 }
                else if titleNorm.contains(q) { sc += 300 }
                else if kwNorm.contains(q) { sc += 150 }
                scored.append((sc, def))
            }
            scored.sort { $0.score > $1.score }
            filteredActions = scored.map(\.def)
        }

        selectedIndex = 0
    }

    func refreshDestinationFolders() {
        destinationGeneration &+= 1
        let gen = destinationGeneration

        let drive = GoogleDriveIndexService.shared
        let raw = destinationSearchText
        let q = raw.trimmingCharacters(in: .whitespaces)

        if activeDestinationBrowseDirectory != nil || raw.hasPrefix("/") || raw.hasPrefix("~/") || raw.hasPrefix("…") || raw.hasPrefix("...") {
            let currentDir: String
            let filterPart: String
            if let activeDir = activeDestinationBrowseDirectory {
                currentDir = activeDir.hasSuffix("/") ? String(activeDir.dropLast()) : activeDir
                let displayPrefix = formatBrowseDisplayPath(activeDir)
                if raw.hasPrefix(displayPrefix) {
                    filterPart = String(raw.dropFirst(displayPrefix.count))
                } else if let lastSlash = raw.lastIndex(of: "/") {
                    filterPart = String(raw[raw.index(after: lastSlash)...])
                } else {
                    filterPart = ""
                }
            } else {
                let expanded = raw.hasPrefix("~/")
                    ? FileManager.default.homeDirectoryForCurrentUser.path + String(raw.dropFirst(1))
                    : raw
                if let lastSlash = expanded.lastIndex(of: "/") {
                    let dirPart = String(expanded[..<lastSlash])
                    currentDir = dirPart.isEmpty ? "/" : dirPart
                    filterPart = String(expanded[expanded.index(after: lastSlash)...])
                } else {
                    currentDir = expanded
                    filterPart = ""
                }
            }

            let words = filterPart.split(separator: " ").map(String.init)
            let ramDirs = drive.cachedChildrenInMemory(parentPath: currentDir, queryWords: words).filter(\.isDir)
            var items: [SearchResultItem] = []
            if words.isEmpty {
                let folderName = currentDir == "/" ? "/" : (currentDir as NSString).lastPathComponent
                items.append(SearchResultItem(
                    id: "dest-here:\(currentDir)",
                    title: "Chọn chính thư mục này: '\(folderName)'",
                    subtitle: currentDir,
                    path: currentDir,
                    isDirectory: true,
                    kind: .driveFolder(path: currentDir),
                    badge: "Đích",
                    sfSymbolFallback: "checkmark.circle.fill"
                ))
            }
            for child in ramDirs.prefix(60) {
                items.append(SearchResultItem(
                    id: "dest-sub:\(child.path)",
                    title: (child.path as NSString).lastPathComponent,
                    subtitle: drive.formatHierarchicalSubtitle(child.path, maxLevels: 3),
                    path: child.path,
                    isDirectory: true,
                    kind: .driveFolder(path: child.path),
                    badge: nil,
                    sfSymbolFallback: "folder.fill"
                ))
            }
            destinationFolders = items
            selectedIndex = 0

            Task.detached(priority: .userInitiated) {
                let diskDirs = GoogleDriveIndexService.listDirectoryFastPOSIX(parentPath: currentDir, queryWords: words).filter(\.isDir)
                await MainActor.run {
                    let vm = LauncherViewModel.shared
                    guard vm.destinationGeneration == gen else { return }
                    var seen = Set<String>()
                    var merged: [String] = []
                    for d in diskDirs where seen.insert(d.path).inserted { merged.append(d.path) }
                    for d in ramDirs where seen.insert(d.path).inserted { merged.append(d.path) }
                    merged.sort { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }

                    var built: [SearchResultItem] = []
                    if words.isEmpty {
                        let folderName = currentDir == "/" ? "/" : (currentDir as NSString).lastPathComponent
                        built.append(SearchResultItem(
                            id: "dest-here:\(currentDir)",
                            title: "Chọn chính thư mục này: '\(folderName)'",
                            subtitle: currentDir,
                            path: currentDir,
                            isDirectory: true,
                            kind: .driveFolder(path: currentDir),
                            badge: "Đích",
                            sfSymbolFallback: "checkmark.circle.fill"
                        ))
                    }
                    for p in merged.prefix(60) {
                        built.append(SearchResultItem(
                            id: "dest-sub:\(p)",
                            title: (p as NSString).lastPathComponent,
                            subtitle: drive.formatHierarchicalSubtitle(p, maxLevels: 3),
                            path: p,
                            isDirectory: true,
                            kind: .driveFolder(path: p),
                            badge: nil,
                            sfSymbolFallback: "folder.fill"
                        ))
                    }
                    vm.destinationFolders = built
                    vm.selectedIndex = min(vm.selectedIndex, max(0, built.count - 1))
                }
            }
            return
        }

        if q.isEmpty {
            var list = drive.recentMyDriveFolders(limit: 8)
            let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop").path
            let downloads = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
            list.insert(SearchResultItem(
                id: "dest:desktop",
                title: "Desktop",
                subtitle: "~/Desktop",
                path: desktop,
                isDirectory: true,
                kind: .driveFolder(path: desktop),
                badge: "Local",
                sfSymbolFallback: "menubar.dock.rectangle"
            ), at: 0)
            list.insert(SearchResultItem(
                id: "dest:downloads",
                title: "Downloads",
                subtitle: "~/Downloads",
                path: downloads,
                isDirectory: true,
                kind: .driveFolder(path: downloads),
                badge: "Local",
                sfSymbolFallback: "arrow.down.circle"
            ), at: 1)
            destinationFolders = list
            selectedIndex = 0
        } else {
            let tokens = q.split(separator: " ").map(String.init)
            let cleanTokens = tokens.map(GoogleDriveIndexService.cleanString).filter { !$0.isEmpty }
            guard !cleanTokens.isEmpty else { return }
            let fastFolders = drive.fastFolderIndex
            let histSnap = drive.history

            Self.searchQueue.async {
                let hits = GoogleDriveIndexService.evaluateMyDriveSearchHits(
                    tokens: tokens,
                    fastIndex: fastFolders,
                    historySnapshot: histSnap,
                    maxResults: 30
                )
                Task { @MainActor in
                    let vm = LauncherViewModel.shared
                    guard vm.destinationGeneration == gen else { return }
                    vm.destinationFolders = GoogleDriveIndexService.shared.buildMyDriveSearchResultItems(
                        from: hits,
                        cleanTokens: cleanTokens,
                        includeApps: false,
                        maxResults: 30
                    )
                    vm.selectedIndex = 0
                }
            }
        }
    }

    // MARK: - Thumbnail & File Metadata Preview (Screenshot 2 Right Pane — Non-Blocking!)

    func updatePreviewThumbnailIfNeeded() {
        previewGeneration &+= 1
        let gen = previewGeneration

        previewImage = nil
        previewFileSizeText = ""
        previewCreatedText = ""
        previewModifiedText = ""
        previewRouteHint = ""

        guard case .universalActions(let target) = screenMode,
              let firstURL = target.fileURLs.first else {
            return
        }

        let path = firstURL.path
        let isDir = GoogleDriveIndexService.shared.isKnownDirectory(path, hasDirectoryHint: firstURL.hasDirectoryPath)
        if isDir {
            previewRouteHint = "Thư mục • Convert sang Markdown (gộp ngữ cảnh AI)"
        }

        // Instant zero-blocking fallback icon
        if isDir {
            previewImage = NSWorkspace.shared.icon(for: .folder)
        } else if path.contains("/Library/CloudStorage/") {
            let ext = firstURL.pathExtension.lowercased()
            if !ext.isEmpty, let ut = UTType(filenameExtension: ext) {
                previewImage = NSWorkspace.shared.icon(for: ut)
            } else {
                previewImage = NSWorkspace.shared.icon(for: .data)
            }
        } else {
            previewImage = NSWorkspace.shared.icon(forFile: path)
        }

        // Read stat metadata + route hint on background thread so CloudStorage never blocks UI
        Task.detached(priority: .utility) {
            var sizeStr = ""
            var createdStr = ""
            var modStr = ""
            var stBuf = Darwin.stat()
            if Darwin.lstat(path, &stBuf) == 0 {
                if (stBuf.st_mode & S_IFMT) != S_IFDIR {
                    sizeStr = ByteCountFormatter.string(fromByteCount: Int64(stBuf.st_size), countStyle: .file)
                }
                let df = DateFormatter()
                df.dateFormat = "dd/MM/yyyy HH:mm"
                if stBuf.st_birthtimespec.tv_sec > 0 {
                    let birth = Date(timeIntervalSince1970: TimeInterval(stBuf.st_birthtimespec.tv_sec))
                    createdStr = df.string(from: birth)
                }
                let mod = Date(timeIntervalSince1970: TimeInterval(stBuf.st_mtimespec.tv_sec))
                modStr = df.string(from: mod)
            }
            let computedRoute = isDir
                ? "Thư mục • Convert sang Markdown (gộp ngữ cảnh AI)"
                : MarkdownConverterService.routeDescription(for: firstURL)
            let finalSize = sizeStr
            let finalCreated = createdStr
            let finalMod = modStr
            await MainActor.run {
                let vm = LauncherViewModel.shared
                guard vm.previewGeneration == gen else { return }
                vm.previewFileSizeText = finalSize
                vm.previewCreatedText = finalCreated
                vm.previewModifiedText = finalMod
                vm.previewRouteHint = computedRoute
            }
        }

        let req = QLThumbnailGenerator.Request(
            fileAt: firstURL,
            size: CGSize(width: 340, height: 420),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let nsImg = rep?.nsImage else { return }
            Task { @MainActor in
                guard let self, self.previewGeneration == gen else { return }
                self.previewImage = nsImg
            }
        }
    }

    // MARK: - Keyboard Selection & Execution

    var activeListCount: Int {
        switch screenMode {
        case .search: return searchResults.count
        case .universalActions: return filteredActions.count
        case .openWithPicker: return openWithApps.count
        case .destinationPicker: return destinationFolders.count
        case .contactDetail: return filteredContactDetailFields.count
        case .batchRename: return 0
        case .markdownPreview: return 0
        }
    }

    func moveSelection(delta: Int) {
        let count = activeListCount
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
        syncQuickLookPreviewIfVisible()
    }

    func toggleQuickLookForCurrentContext() {
        if LargeTypeOverlayController.shared.isVisible {
            LargeTypeOverlayController.shared.dismiss(restoreFocus: true)
            return
        }
        if case .contactDetail(let contactID, _, _) = screenMode {
            guard selectedIndex >= 0 && selectedIndex < filteredContactDetailFields.count else {
                NSSound.beep()
                return
            }
            let field = filteredContactDetailFields[selectedIndex]
            let contactName = ContactsSearchService.shared.contact(withID: contactID)?.displayName ?? ""
            let header = contactName.isEmpty ? field.categoryLabel : "\(contactName) — \(field.categoryLabel)"
            LargeTypeOverlayController.shared.show(
                text: "\(header)\n\(field.displayValue)",
                restoreLauncherFocusOnClose: true
            )
            return
        }
        if case .search = screenMode,
           selectedIndex >= 0 && selectedIndex < searchResults.count,
           case .contactItem(let contactID) = searchResults[selectedIndex].kind,
           let rec = ContactsSearchService.shared.contact(withID: contactID) {
            LargeTypeOverlayController.shared.show(
                text: "\(rec.displayName)\n\(rec.primaryQuickCopyValue)",
                restoreLauncherFocusOnClose: true
            )
            return
        }

        let urls = currentQuickLookURLs()
        guard !urls.isEmpty else {
            if QuickLookCoordinator.shared.isQuickLookVisible {
                QuickLookCoordinator.shared.closeQuickLook(restoreLauncherFocus: true)
            } else {
                NSSound.beep()
            }
            return
        }
        QuickLookCoordinator.shared.toggleQuickLook(for: urls)
    }

    func syncQuickLookPreviewIfVisible() {
        guard QuickLookCoordinator.shared.isQuickLookVisible else { return }
        let urls = currentQuickLookURLs()
        if !urls.isEmpty {
            QuickLookCoordinator.shared.updateIfVisible(for: urls)
        }
    }

    private func currentQuickLookURLs() -> [URL] {
        switch screenMode {
        case .search:
            guard selectedIndex >= 0 && selectedIndex < searchResults.count else { return [] }
            let item = searchResults[selectedIndex]
            if case .clipboardItem(let clipID) = item.kind,
               let entry = ClipboardHistoryService.shared.entry(withID: clipID) {
                return ClipboardHistoryService.shared.previewURLs(for: entry)
            }
            guard let u = item.fileURL else { return [] }
            return [u]
        case .universalActions(let target):
            return target.fileURLs
        case .destinationPicker:
            guard selectedIndex >= 0 && selectedIndex < destinationFolders.count,
                  let u = destinationFolders[selectedIndex].fileURL else { return [] }
            return [u]
        case .openWithPicker(let fileURL, _):
            return [fileURL]
        case .batchRename(let urls, _):
            return urls
        case .markdownPreview(_, let srcURL, let savedMDURL, _, _, _):
            return [savedMDURL ?? srcURL]
        case .contactDetail:
            return []
        }
    }

    func executeAtIndex(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        guard index >= 0 && index < activeListCount else { return }
        selectedIndex = index
        executeCurrentSelection(modifiers: modifiers.cleanShortcutModifiers)
    }

    func executeCurrentSelection(modifiers: NSEvent.ModifierFlags) {
        let cleanMods = modifiers.cleanShortcutModifiers
        switch screenMode {
        case .search:
            guard selectedIndex >= 0 && selectedIndex < searchResults.count else { return }
            let item = searchResults[selectedIndex]
            handleSearchItemExecution(item, modifiers: cleanMods)

        case .universalActions(let target):
            guard selectedIndex >= 0 && selectedIndex < filteredActions.count else { return }
            let action = filteredActions[selectedIndex]
            UniversalActionExecutor.shared.execute(
                action: action,
                target: target,
                modifierFlags: cleanMods,
                viewModel: self
            )

        case .openWithPicker(let fileURL, _):
            guard selectedIndex >= 0 && selectedIndex < openWithApps.count else { return }
            let app = openWithApps[selectedIndex]
            LauncherPanelController.shared.hide()
            NSWorkspace.shared.open([fileURL], withApplicationAt: app.url, configuration: NSWorkspace.OpenConfiguration())

        case .destinationPicker(let op, let sources):
            guard selectedIndex >= 0 && selectedIndex < destinationFolders.count else { return }
            guard let folderPath = destinationFolders[selectedIndex].path else { return }
            UniversalActionExecutor.shared.performFileTransfer(
                operation: op,
                sources: sources,
                destinationFolder: URL(fileURLWithPath: folderPath, isDirectory: true),
                revealInFinder: cleanMods.contains(.command)
            )

        case .batchRename:
            BatchRenameState.shared.executeCommit(revealInFinder: cleanMods.contains(.command))

        case .markdownPreview(_, _, _, let markdown, _, _):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(markdown, forType: .string)
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showSuccess(
                title: "Đã sao chép Markdown vào Clipboard",
                subtitle: "Sẵn sàng nhấn ⌘V vào AI"
            )

        case .contactDetail(let contactID, _, _):
            guard selectedIndex >= 0 && selectedIndex < filteredContactDetailFields.count else { return }
            let field = filteredContactDetailFields[selectedIndex]
            let contactName = ContactsSearchService.shared.contact(withID: contactID)?.displayName ?? ""
            if cleanMods.contains(.command), let actionURL = field.actionURL {
                LauncherPanelController.shared.hide()
                _ = NSWorkspace.shared.open(actionURL)
                return
            }
            ContactsSearchService.shared.copyField(
                field,
                contactName: contactName,
                closeLauncher: true,
                autoPaste: cleanMods.contains(.option),
                previousApp: LauncherPanelController.shared.previousFrontApp
            )
        }
    }

    @discardableResult
    func copySelectedContactDetailFieldKeepOpen() -> Bool {
        guard case .contactDetail(let contactID, _, _) = screenMode,
              selectedIndex >= 0 && selectedIndex < filteredContactDetailFields.count else {
            return false
        }
        let field = filteredContactDetailFields[selectedIndex]
        let contactName = ContactsSearchService.shared.contact(withID: contactID)?.displayName ?? ""
        ContactsSearchService.shared.copyField(
            field,
            contactName: contactName,
            closeLauncher: false,
            autoPaste: false,
            previousApp: LauncherPanelController.shared.previousFrontApp
        )
        return true
    }

    @discardableResult
    func openUniversalActionsForSelectedSearchItem() -> Bool {
        guard case .search = screenMode,
              selectedIndex >= 0 && selectedIndex < searchResults.count else { return false }
        let item = searchResults[selectedIndex]
        if case .clipboardItem(let clipID) = item.kind,
           let entry = ClipboardHistoryService.shared.entry(withID: clipID) {
            switch entry.kind {
            case .files, .image:
                let urls = entry.filePaths
                    .filter { $0.contains("/Library/CloudStorage/") || FileManager.default.fileExists(atPath: $0) }
                    .map { URL(fileURLWithPath: $0) }
                guard !urls.isEmpty else { return false }
                openUniversalActions(for: .files(urls, sourceNote: "Lịch sử Clipboard"), directExternalTrigger: false)
                return true
            case .url:
                if let u = URL(string: entry.textContent.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    openUniversalActions(for: .url(u, sourceNote: "Lịch sử Clipboard"), directExternalTrigger: false)
                    return true
                }
                openUniversalActions(for: .text(entry.textContent, sourceNote: "Lịch sử Clipboard"), directExternalTrigger: false)
                return true
            case .text:
                openUniversalActions(for: .text(entry.textContent, sourceNote: "Lịch sử Clipboard"), directExternalTrigger: false)
                return true
            }
        }
        if case .contactItem(let contactID) = item.kind {
            openContactDetail(contactID: contactID)
            return true
        }
        if case .systemCommand = item.kind {
            return false
        }
        if let path = item.path {
            openUniversalActions(
                for: .files([URL(fileURLWithPath: path, isDirectory: item.isDirectory)]),
                directExternalTrigger: false
            )
            return true
        }
        if case .webURLQuickConvert(let webURL, _) = item.kind {
            openUniversalActions(
                for: .url(webURL, sourceNote: "Thanh tìm kiếm"),
                directExternalTrigger: false
            )
            return true
        }
        return false
    }

    @discardableResult
    func togglePinForSelectedItem() -> Bool {
        guard case .search = screenMode,
              selectedIndex >= 0 && selectedIndex < searchResults.count else { return false }
        let item = searchResults[selectedIndex]
        if case .clipboardItem = item.kind { return false }
        if case .systemCommand = item.kind { return false }
        guard let path = item.path else { return false }

        let nowPinned = AppSettings.shared.togglePin(path)
        let name = (path as NSString).lastPathComponent
        FloatingToastController.shared.showSuccess(
            title: nowPinned ? "Đã ghim '\(name)'" : "Đã bỏ ghim '\(name)'",
            subtitle: nowPinned ? "Luôn hiện đầu tiên khi mở DriveBar" : "Đã gỡ khỏi danh sách ghim",
            symbol: nowPinned ? "pin.fill" : "pin.slash"
        )
        refreshSearchResults()
        if let idx = searchResults.firstIndex(where: { $0.path == path }) {
            selectedIndex = idx
        }
        return true
    }

    func runClipboardImageOCR(openPreview: Bool) {
        guard let imgURL = ClipboardHistoryService.shared.materializeCurrentClipboardImageURL() else {
            FloatingToastController.shared.showError(
                title: "Không có hình ảnh trong Clipboard",
                subtitle: "Hãy chụp màn hình (⌘⌃⇧4) hoặc Copy một hình ảnh trước khi chạy OCR"
            )
            return
        }

        if !openPreview {
            LauncherPanelController.shared.hide()
        }
        FloatingToastController.shared.showProgress(
            title: "Đang OCR ảnh trong Clipboard (Tiếng Việt + Anh)...",
            subtitle: imgURL.lastPathComponent
        )

        Task { @MainActor in
            do {
                let results = try await MarkdownConverterService.shared.convertFilesToMarkdown(
                    urls: [imgURL],
                    saveBesideSource: false,
                    copyToClipboard: true,
                    forceOCR: true
                )
                guard let first = results.first else { return }
                FloatingToastController.shared.showSuccess(
                    title: "Đã OCR ảnh & Copy Markdown vào Clipboard!",
                    subtitle: "Apple Vision • ~\(first.estimatedTokens.formatted()) tokens • Sẵn sàng ⌘V",
                    symbol: "camera.viewfinder"
                )
                if openPreview {
                    self.screenMode = .markdownPreview(
                        title: "OCR Clipboard Image",
                        sourceURL: imgURL,
                        savedMDURL: nil,
                        markdown: first.markdown,
                        estimatedTokens: first.estimatedTokens,
                        engineUsed: first.engineUsed
                    )
                    LauncherPanelController.shared.showAndFocus()
                }
            } catch {
                FloatingToastController.shared.showError(
                    title: "Không nhận diện được văn bản trong ảnh",
                    subtitle: error.localizedDescription
                )
            }
        }
    }

    private func handleSearchItemExecution(_ item: SearchResultItem, modifiers: NSEvent.ModifierFlags) {
        switch item.kind {
        case .infoBanner:
            return

        case .calculatorResult(let expr, let rawVal, let prettyVal):
            let textToCopy = modifiers.contains(.option) ? "\(expr) = \(prettyVal)" : rawVal
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(textToCopy, forType: .string)
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showSuccess(
                title: "Đã Copy kết quả: \(textToCopy)",
                subtitle: "\(expr) = \(prettyVal)",
                symbol: "function"
            )

        case .contactItem(let contactID):
            if modifiers.contains(.command) {
                ContactsSearchService.shared.openInContactsApp(contactID: contactID)
                return
            }
            if modifiers.contains(.option),
               let rec = ContactsSearchService.shared.contact(withID: contactID),
               let primaryField = rec.fields.first {
                ContactsSearchService.shared.copyField(
                    primaryField,
                    contactName: rec.displayName,
                    closeLauncher: true,
                    autoPaste: false,
                    previousApp: LauncherPanelController.shared.previousFrontApp
                )
                return
            }
            openContactDetail(contactID: contactID)

        case .clipboardItem(let clipID):
            guard let entry = ClipboardHistoryService.shared.entry(withID: clipID) else { return }
            if modifiers.contains(.shift) {
                _ = openUniversalActionsForSelectedSearchItem()
                return
            }
            if modifiers.contains(.command) {
                switch entry.kind {
                case .url:
                    if let u = URL(string: entry.textContent.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        LauncherPanelController.shared.hide()
                        NSWorkspace.shared.open(u)
                        return
                    }
                case .files, .image:
                    let urls = entry.filePaths
                        .filter { $0.contains("/Library/CloudStorage/") || FileManager.default.fileExists(atPath: $0) }
                        .map { URL(fileURLWithPath: $0) }
                    if !urls.isEmpty {
                        LauncherPanelController.shared.hide()
                        NSWorkspace.shared.activateFileViewerSelecting(urls)
                        return
                    }
                case .text:
                    break
                }
            }
            ClipboardHistoryService.shared.activateEntry(
                entry,
                autoPaste: !modifiers.contains(.option),
                previousApp: LauncherPanelController.shared.previousFrontApp
            )

        case .webURLQuickConvert(let webURL, let preview):
            let actID = preview ? "ai.url_preview_md" : "ai.url_to_md"
            if let def = UniversalActionCatalog.all.first(where: { $0.id == actID }) {
                UniversalActionExecutor.shared.execute(
                    action: def,
                    target: .url(webURL, sourceNote: "Thanh tìm kiếm"),
                    modifierFlags: modifiers,
                    viewModel: self
                )
            }

        case .systemCommand(let cmd):
            if InstantUtilityService.executeSystemUtility(id: cmd, viewModel: self, modifiers: modifiers) {
                return
            }
            if cmd == "rebuild" {
                GoogleDriveIndexService.shared.rebuildAllCaches()
                FloatingToastController.shared.showProgress(
                    title: "Đang quét lại Google Drive ở nền...",
                    subtitle: "Bạn vẫn có thể tìm kiếm bình thường"
                )
                LauncherPanelController.shared.hide()
            } else if cmd == "clean-history" {
                GoogleDriveIndexService.shared.clearAllHistory()
                refreshSearchResults()
                FloatingToastController.shared.showSuccess(
                    title: "Đã làm sạch lịch sử gần đây",
                    subtitle: "Google Drive Search"
                )
            } else if cmd == "open-window-switcher" {
                LauncherPanelController.shared.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    WindowSwitcherController.shared.openPinnedFromMenuOrSearch()
                }
            } else if cmd == "record-win-hotkey" {
                LauncherPanelController.shared.hide()
                HotKeyService.shared.openSettingsAndRecord(.windowSwitcher)
            } else if cmd == "record-hotkey" {
                LauncherPanelController.shared.hide()
                HotKeyService.shared.openSettingsAndRecord(.search)
            } else if cmd == "record-ua-hotkey" {
                LauncherPanelController.shared.hide()
                HotKeyService.shared.openSettingsAndRecord(.universalAction)
            } else if cmd == "set-cmd-space" {
                LauncherPanelController.shared.hide()
                HotKeyService.shared.applyRecordedBinding(.commandSpace, for: .search)
            } else if cmd == "set-cmd-slash" {
                LauncherPanelController.shared.hide()
                HotKeyService.shared.applyRecordedBinding(.commandSlash, for: .universalAction)
            } else if cmd == "set-opt-space" {
                LauncherPanelController.shared.hide()
                HotKeyService.shared.applyRecordedBinding(.optionSpace, for: .search)
            }

        case .aiQuickCommand(let actionID):
            let finderURLs = SelectionCaptureService.fetchFinderSelectionURLs()
            guard !finderURLs.isEmpty else {
                FloatingToastController.shared.showError(
                    title: "Chưa chọn tệp nào trong Finder",
                    subtitle: "Hãy chọn ít nhất 1 tệp trong Finder hoặc duyệt tệp rồi nhấn Tab"
                )
                return
            }
            if let def = UniversalActionCatalog.all.first(where: { $0.id == actionID }) {
                UniversalActionExecutor.shared.execute(
                    action: def,
                    target: .files(finderURLs, sourceNote: "Finder"),
                    modifierFlags: modifiers,
                    viewModel: self
                )
            }

        case .parentFolder(let parentPath):
            enterBrowseMode(at: parentPath)

        case .openInFinder(let folderPath):
            let folderURL = URL(fileURLWithPath: folderPath, isDirectory: true)
            GoogleDriveIndexService.shared.recordUsed(folderPath)
            if modifiers.contains(.shift) {
                openUniversalActions(for: .files([folderURL]), directExternalTrigger: false)
                return
            }
            if modifiers.contains(.option) {
                copyDriveOrLocalLinkAsync(path: folderPath, isDirectory: true)
                return
            }
            if modifiers.contains(.control) {
                openDriveWebOrLocalAsync(path: folderPath, isDirectory: true)
                return
            }
            LauncherPanelController.shared.hide()
            NSWorkspace.shared.open(folderURL)

        case .localApp(let appPath):
            let appURL = URL(fileURLWithPath: appPath)
            GoogleDriveIndexService.shared.recordUsed(appPath)
            if modifiers.contains(.shift) {
                openUniversalActions(for: .files([appURL]), directExternalTrigger: false)
                return
            }
            if modifiers.contains(.option) {
                copyDriveOrLocalLinkAsync(path: appPath, isDirectory: false)
                return
            }
            LauncherPanelController.shared.hide()
            if modifiers.contains(.command) {
                NSWorkspace.shared.activateFileViewerSelecting([appURL])
            } else {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: appURL, configuration: cfg) { _, error in
                    if error != nil {
                        DispatchQueue.main.async {
                            NSWorkspace.shared.open(appURL)
                        }
                    }
                }
            }

        case .driveFolder(let path), .driveFile(let path):
            let fileURL = URL(fileURLWithPath: path, isDirectory: item.isDirectory)
            GoogleDriveIndexService.shared.recordUsed(path)

            if modifiers.contains(.shift) {
                openUniversalActions(for: .files([fileURL]), directExternalTrigger: false)
                return
            }
            if modifiers.contains(.command) {
                LauncherPanelController.shared.hide()
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                return
            }
            if modifiers.contains(.option) {
                copyDriveOrLocalLinkAsync(path: path, isDirectory: item.isDirectory)
                return
            }
            if modifiers.contains(.control) {
                openDriveWebOrLocalAsync(path: path, isDirectory: item.isDirectory)
                return
            }

            // Default Enter / Click (no modifier):
            if item.isDirectory {
                enterBrowseMode(at: path)
            } else {
                LauncherPanelController.shared.hide()
                NSWorkspace.shared.open(fileURL)
            }
        }
    }

    private func copyDriveOrLocalLinkAsync(path: String, isDirectory: Bool) {
        LauncherPanelController.shared.hide()
        let lastComponent = (path as NSString).lastPathComponent
        Task.detached(priority: .userInitiated) {
            let gd = GoogleDriveIndexService.googleDriveURLs(for: path, isDirectoryHint: isDirectory)
            await MainActor.run {
                let pb = NSPasteboard.general
                pb.clearContents()
                if let gd {
                    pb.setString(gd.shareURL.absoluteString, forType: .string)
                    FloatingToastController.shared.showSuccess(
                        title: "Đã sao chép liên kết chia sẻ Google Drive",
                        subtitle: lastComponent,
                        symbol: "link"
                    )
                } else {
                    pb.setString(path, forType: .string)
                    FloatingToastController.shared.showSuccess(
                        title: "Đã sao chép đường dẫn cục bộ",
                        subtitle: path,
                        symbol: "link"
                    )
                }
            }
        }
    }

    private func openDriveWebOrLocalAsync(path: String, isDirectory: Bool) {
        LauncherPanelController.shared.hide()
        Task.detached(priority: .userInitiated) {
            let gd = GoogleDriveIndexService.googleDriveURLs(for: path, isDirectoryHint: isDirectory)
            await MainActor.run {
                if let gd {
                    _ = NSWorkspace.shared.open(gd.webURL)
                } else {
                    _ = NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: isDirectory))
                }
            }
        }
    }

    private static func hotkeyQuickItems() -> [SearchResultItem] {
        let curSearch = AppSettings.shared.searchHotKey.readableDisplay
        let curUA = AppSettings.shared.universalActionHotKey.readableDisplay
        let curWin = AppSettings.shared.windowSwitcherHotKey.readableDisplay
        return [
            SearchResultItem(
                id: "cmd:record-win-hotkey",
                title: "Tự thiết lập Phím tắt Windows Preview — Chuyển cửa sổ (Đang dùng: \(curWin))",
                subtitle: "Mặc định: ⌘⇥ (Command + Tab) • Phóng to nội dung & chuyển nhanh mọi cửa sổ đang chạy",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "record-win-hotkey"),
                badge: "Windows Preview",
                sfSymbolFallback: "macwindow.on.rectangle"
            ),
            SearchResultItem(
                id: "cmd:record-ua-hotkey",
                title: "Tự thiết lập Phím tắt mở Universal Actions trên Finder (Đang dùng: \(curUA))",
                subtitle: "Mặc định: ⌘/ (Command + /) • Nhấn Enter để tự bấm tổ hợp phím bất kỳ bạn muốn",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "record-ua-hotkey"),
                badge: "Finder Action",
                sfSymbolFallback: "bolt.horizontal"
            ),
            SearchResultItem(
                id: "cmd:set-cmd-slash",
                title: "Đặt phím tắt Universal Actions mặc định Command + / (⌘/)",
                subtitle: "Chọn file/thư mục trong Finder rồi nhấn ⌘/ để mở ngay Universal Actions & Convert sang Markdown",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "set-cmd-slash"),
                badge: "Mặc định",
                sfSymbolFallback: "command"
            ),
            SearchResultItem(
                id: "cmd:record-hotkey",
                title: "Tự thiết lập Phím tắt mở Thanh Tìm Kiếm (Đang dùng: \(curSearch))",
                subtitle: "Mặc định: ⌘Space • Nhấn Enter để mở bộ thu phím tắt bất kỳ theo ý muốn của bạn",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "record-hotkey"),
                badge: "Tùy chỉnh",
                sfSymbolFallback: "keyboard"
            ),
            SearchResultItem(
                id: "cmd:set-cmd-space",
                title: "Đặt phím tắt Tìm kiếm mặc định Command + Space (⌘Space)",
                subtitle: "Áp dụng ngay tổ hợp phím mặc định ⌘Space để mở DriveBar",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "set-cmd-space"),
                badge: "Mặc định",
                sfSymbolFallback: "command"
            ),
            SearchResultItem(
                id: "cmd:set-opt-space",
                title: "Đặt phím tắt Tìm kiếm Option + Space (⌥Space)",
                subtitle: "Áp dụng ngay tổ hợp phím ⌥Space để mở DriveBar",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "set-opt-space"),
                badge: "Preset",
                sfSymbolFallback: "option"
            )
        ]
    }

    private static func emptyAppSearchBanner(for query: String) -> [SearchResultItem] {
        [
            SearchResultItem(
                id: "empty-apps:\(query)",
                title: "Không tìm thấy ứng dụng nào khớp '\(query)'",
                subtitle: "Chỉ đang lọc trong /Applications & ứng dụng hệ thống macOS • Xóa bớt từ khóa để xem toàn bộ ứng dụng",
                path: nil,
                isDirectory: false,
                kind: .infoBanner,
                badge: "Ứng dụng",
                sfSymbolFallback: "app.dashed"
            )
        ]
    }
}
