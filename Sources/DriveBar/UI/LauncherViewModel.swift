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
            refreshDestinationFolders()
        }
    }

    @Published private(set) var searchResults: [SearchResultItem] = []
    @Published private(set) var filteredActions: [UniversalActionDefinition] = []
    @Published private(set) var openWithApps: [(name: String, url: URL)] = []
    @Published private(set) var destinationFolders: [SearchResultItem] = []

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
            if !trimmed.isEmpty && !live.hasPrefix("/") && !live.hasPrefix("~/") {
                let tokens = trimmed.split(separator: " ").map(String.init)
                if !tokens.isEmpty {
                    searchGeneration &+= 1
                    searchResults = GoogleDriveIndexService.shared.searchMyDriveFolders(
                        tokens: tokens,
                        includeApps: AppSettings.shared.includeMacAppsInSearch
                    )
                    selectedIndex = 0
                }
            }
        case .universalActions:
            if actionFilterText != live { actionFilterText = live }
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
        case .markdownPreview(_, let src, _, _, _, _):
            openUniversalActions(for: .files([src]), directExternalTrigger: openedDirectlyInUniversalActions)
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
        default:
            break
        }
    }

    func popParentFolderIfAtSlashBoundary() -> Bool {
        switch screenMode {
        case .search:
            let s = searchText
            if s.hasPrefix("/"), s.hasSuffix("/"), s.count > 1 {
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
            let s = destinationSearchText
            if s.hasPrefix("/"), s.hasSuffix("/"), s.count > 1 {
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
        destinationSearchText = path.hasSuffix("/") ? path : path + "/"
        triggerInputFocus(selectAll: false)
        return true
    }

    // MARK: - Mode Transitions

    func prepareForSearchLaunch() {
        openedDirectlyInUniversalActions = false
        screenMode = .search
        actionFilterText = ""
        selectedIndex = 0
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
        searchText = clean
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

    // MARK: - Active Search Mode Pill Label

    var currentSearchModeBadge: (label: String, color: Color) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return ("Web → AI MD", .secondary)
        }
        if searchText.hasPrefix("/") || searchText.hasPrefix("~/") {
            return ("Duyệt thư mục", .secondary)
        }
        if trimmed == "fs" || searchText.lowercased().hasPrefix("fs ") {
            return ("Shared Drives", .secondary)
        }
        if trimmed == "ai" || searchText.lowercased().hasPrefix("ai ") {
            return ("AI Toolkit", .secondary)
        }
        if trimmed.hasPrefix("//") {
            return ("Lệnh hệ thống", .secondary)
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

        // 2. Check `ai` / `ai <filter>` quick list (Finder selection)
        if trimmed.lowercased() == "ai" || raw.lowercased().hasPrefix("ai ") {
            let sub = raw.count > 3 ? String(raw.dropFirst(3)).lowercased().trimmingCharacters(in: .whitespaces) : ""
            let items: [SearchResultItem] = [
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

        // 3. Browse Mode (`/path/...` or `~/...`) — 0ms RAM folders + async background POSIX readdir!
        if raw.hasPrefix("/") || raw.hasPrefix("~/") {
            let expanded = raw.hasPrefix("~/")
                ? FileManager.default.homeDirectoryForCurrentUser.path + String(raw.dropFirst(1))
                : raw

            let currentDir: String
            let filterPart: String
            if let lastSlash = expanded.lastIndex(of: "/") {
                let dirPart = String(expanded[..<lastSlash])
                currentDir = dirPart.isEmpty ? "/" : dirPart
                filterPart = String(expanded[expanded.index(after: lastSlash)...])
            } else {
                currentDir = expanded
                filterPart = ""
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
                    title: drive.isRebuildingFolders ? "⏳ Đang quét lại dữ liệu Google Drive ở nền..." : "🔄 Quét lại toàn bộ Cache Google Drive (Background Rebuild)",
                    subtitle: "Nhấn Enter để cập nhật danh mục thư mục My Drive & Shared Drives mà không gây đơ máy",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "rebuild"),
                    badge: "Rebuild",
                    sfSymbolFallback: "arrow.clockwise.circle.fill"
                )
            ]
            selectedIndex = 0
            return
        }

        if ["//clean", "//clear", "//clear-history"].contains(effectiveQuery) {
            searchResults = [
                SearchResultItem(
                    id: "cmd:clean",
                    title: "🗑️ Xóa toàn bộ lịch sử thư mục mở gần đây",
                    subtitle: "Nhấn Enter để làm sạch danh sách mở gần đây",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "clean-history"),
                    badge: "Clean",
                    sfSymbolFallback: "trash.circle.fill"
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

        // 6. Check Google Drive availability
        if drive.accountRoot == nil {
            searchResults = [
                SearchResultItem(
                    id: "no-gdrive",
                    title: "Không tìm thấy thư mục Google Drive trong ~/Library/CloudStorage",
                    subtitle: "Bạn vẫn dùng được mọi Universal Actions (\(AppSettings.shared.universalActionHotKey.readableDisplay)) & Convert sang Markdown trên file cục bộ!",
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

        let cleanTokens = tokens.map(GoogleDriveIndexService.cleanString).filter { !$0.isEmpty }
        if cleanTokens.isEmpty {
            searchResults = isSharedMode ? drive.recentSharedItems(limit: 9) : drive.recentMyDriveFolders(limit: 9)
            selectedIndex = 0
            return
        }

        let fastFolders = drive.fastFolderIndex
        let fastShared = drive.fastSharedIndex
        let histSnap = drive.history
        let includeApps = AppSettings.shared.includeMacAppsInSearch
        let querySnap = effectiveQuery
        let sharedSnap = isSharedMode

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
                Task { @MainActor in
                    let vm = LauncherViewModel.shared
                    guard vm.searchGeneration == gen else { return }
                    var built = GoogleDriveIndexService.shared.buildMyDriveSearchResultItems(
                        from: hits,
                        cleanTokens: cleanTokens,
                        includeApps: includeApps,
                        maxResults: 45
                    )
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
                title: "📂 Mở thư mục '\(folderName)' trong Finder",
                subtitle: "Nhấn Enter (hoặc click chuột) để mở trong Finder • Phím ↓ chọn mục con bên dưới • ⇥ Actions",
                path: currentDir,
                isDirectory: true,
                kind: .openInFinder(path: currentDir),
                badge: "Finder",
                sfSymbolFallback: "folder.badge.gearshape"
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
                title: isInitialRAMOnly ? "⏳ Đang đọc danh sách tệp trong thư mục..." : "Không có tệp hoặc thư mục con khớp '\(filterPart)'",
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
        if normQ.contains("phim tat") || normQ == "hotkey" || normQ == "shortcut" {
            results.insert(contentsOf: Self.hotkeyQuickItems(), at: 0)
        }
        if normQ.contains("clean") || normQ.contains("clear") {
            results.insert(
                SearchResultItem(
                    id: "cmd:clean-inline",
                    title: "🗑️ Xóa lịch sử thư mục gần đây (Clean History)",
                    subtitle: "Nhấn Enter để làm sạch lịch sử mở gần đây",
                    path: nil,
                    isDirectory: false,
                    kind: .systemCommand(id: "clean-history"),
                    badge: "History",
                    sfSymbolFallback: "trash.fill"
                ),
                at: 0
            )
        }

        if results.isEmpty {
            results = [
                SearchResultItem(
                    id: "no-match",
                    title: isSharedMode ? "Không tìm thấy mục chia sẻ phù hợp" : "Không tìm thấy thư mục Google Drive phù hợp",
                    subtitle: "Từ khóa: '\(effectiveQuery)'  •  Gõ '//rebuild' để quét lại dữ liệu mới",
                    path: nil,
                    isDirectory: false,
                    kind: .infoBanner,
                    badge: nil,
                    sfSymbolFallback: "magnifyingglass"
                )
            ]
        }
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

        if raw.hasPrefix("/") || raw.hasPrefix("~/") {
            let expanded = raw.hasPrefix("~/")
                ? FileManager.default.homeDirectoryForCurrentUser.path + String(raw.dropFirst(1))
                : raw
            let currentDir: String
            let filterPart: String
            if let lastSlash = expanded.lastIndex(of: "/") {
                let dirPart = String(expanded[..<lastSlash])
                currentDir = dirPart.isEmpty ? "/" : dirPart
                filterPart = String(expanded[expanded.index(after: lastSlash)...])
            } else {
                currentDir = expanded
                filterPart = ""
            }

            let words = filterPart.split(separator: " ").map(String.init)
            let ramDirs = drive.cachedChildrenInMemory(parentPath: currentDir, queryWords: words).filter(\.isDir)
            var items: [SearchResultItem] = []
            if words.isEmpty {
                let folderName = currentDir == "/" ? "/" : (currentDir as NSString).lastPathComponent
                items.append(SearchResultItem(
                    id: "dest-here:\(currentDir)",
                    title: "📥 Chọn chính thư mục này: '\(folderName)'",
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
                            title: "📥 Chọn chính thư mục này: '\(folderName)'",
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
            guard selectedIndex >= 0 && selectedIndex < searchResults.count,
                  let u = searchResults[selectedIndex].fileURL else { return [] }
            return [u]
        case .universalActions(let target):
            return target.fileURLs
        case .destinationPicker:
            guard selectedIndex >= 0 && selectedIndex < destinationFolders.count,
                  let u = destinationFolders[selectedIndex].fileURL else { return [] }
            return [u]
        case .openWithPicker(let fileURL, _):
            return [fileURL]
        case .markdownPreview(_, let srcURL, let savedMDURL, _, _, _):
            return [savedMDURL ?? srcURL]
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

        case .markdownPreview(_, _, _, let markdown, _, _):
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(markdown, forType: .string)
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showSuccess(
                title: "Đã sao chép Markdown vào Clipboard ✓",
                subtitle: "Sẵn sàng nhấn ⌘V vào AI"
            )
        }
    }

    @discardableResult
    func openUniversalActionsForSelectedSearchItem() -> Bool {
        guard case .search = screenMode,
              selectedIndex >= 0 && selectedIndex < searchResults.count else { return false }
        let item = searchResults[selectedIndex]
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

    private func handleSearchItemExecution(_ item: SearchResultItem, modifiers: NSEvent.ModifierFlags) {
        switch item.kind {
        case .infoBanner:
            return

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
            LauncherPanelController.shared.hide()
            if modifiers.contains(.command) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
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
                    NSWorkspace.shared.open(gd.webURL)
                } else {
                    NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: isDirectory))
                }
            }
        }
    }

    private static func hotkeyQuickItems() -> [SearchResultItem] {
        let curSearch = AppSettings.shared.searchHotKey.readableDisplay
        let curUA = AppSettings.shared.universalActionHotKey.readableDisplay
        return [
            SearchResultItem(
                id: "cmd:record-ua-hotkey",
                title: "⚡ Tự thiết lập Phím tắt mở Universal Actions trên Finder (Đang dùng: \(curUA))",
                subtitle: "Mặc định: ⌘/ (Command + /) • Nhấn Enter để tự bấm tổ hợp phím bất kỳ bạn muốn",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "record-ua-hotkey"),
                badge: "Finder Action",
                sfSymbolFallback: "bolt.horizontal.circle.fill"
            ),
            SearchResultItem(
                id: "cmd:set-cmd-slash",
                title: "⚡ Đặt phím tắt Universal Actions mặc định Command + / (⌘/)",
                subtitle: "Chọn file/thư mục trong Finder rồi nhấn ⌘/ để mở ngay Universal Actions & Convert sang Markdown",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "set-cmd-slash"),
                badge: "Mặc định",
                sfSymbolFallback: "command.square.fill"
            ),
            SearchResultItem(
                id: "cmd:record-hotkey",
                title: "⌨️ Tự thiết lập Phím tắt mở Thanh Tìm Kiếm (Đang dùng: \(curSearch))",
                subtitle: "Mặc định: ⌘Space • Nhấn Enter để mở bộ thu phím tắt bất kỳ theo ý muốn của bạn",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "record-hotkey"),
                badge: "Tùy chỉnh",
                sfSymbolFallback: "keyboard.fill"
            ),
            SearchResultItem(
                id: "cmd:set-cmd-space",
                title: "⚡ Đặt phím tắt Tìm kiếm mặc định Command + Space (⌘Space)",
                subtitle: "Áp dụng ngay tổ hợp phím mặc định ⌘Space để mở DriveBar",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "set-cmd-space"),
                badge: "Mặc định",
                sfSymbolFallback: "command.square.fill"
            ),
            SearchResultItem(
                id: "cmd:set-opt-space",
                title: "⚡ Đặt phím tắt Tìm kiếm Option + Space (⌥Space)",
                subtitle: "Áp dụng ngay tổ hợp phím ⌥Space để mở DriveBar",
                path: nil,
                isDirectory: false,
                kind: .systemCommand(id: "set-opt-space"),
                badge: "Preset",
                sfSymbolFallback: "option"
            )
        ]
    }
}
