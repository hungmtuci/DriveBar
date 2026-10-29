import Foundation
import SwiftUI
import AppKit
import QuickLookThumbnailing
import Darwin

@MainActor
final class LauncherViewModel: ObservableObject {
    static let shared = LauncherViewModel()

    @Published var screenMode: LauncherScreenMode = .search {
        didSet {
            selectedIndex = 0
            updatePreviewThumbnailIfNeeded()
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

    // Preview card state for Universal Actions right pane (Screenshot 2 style!)
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var previewFileSizeText: String = ""
    @Published private(set) var previewModifiedText: String = ""
    @Published private(set) var previewRouteHint: String = ""

    private init() {
        refreshSearchResults()
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
    }

    func enterBrowseMode(at folderPath: String) {
        openedDirectlyInUniversalActions = false
        screenMode = .search
        let clean = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        GoogleDriveIndexService.shared.recordUsed(folderPath)
        searchText = clean
    }

    func returnToSearchMode() {
        screenMode = .search
        actionFilterText = ""
        refreshSearchResults()
    }

    func enterOpenWithPicker(for fileURL: URL, previousTarget: ActionTarget) {
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: fileURL)
        openWithApps = appURLs.map { u in
            (u.deletingPathExtension().lastPathComponent, u)
        }
        screenMode = .openWithPicker(fileURL: fileURL, previousTarget: previousTarget)
    }

    func enterDestinationPicker(operation: FileTransferOperation, sources: [URL]) {
        destinationSearchText = ""
        screenMode = .destinationPicker(operation: operation, sources: sources)
        refreshDestinationFolders()
    }

    // MARK: - Active Search Mode Pill Label

    var currentSearchModeBadge: (label: String, color: Color) {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return ("Web → AI MD", .purple)
        }
        if searchText.hasPrefix("/") || searchText.hasPrefix("~/") {
            return ("Duyệt thư mục", .blue)
        }
        if trimmed == "fs" || searchText.lowercased().hasPrefix("fs ") {
            return ("Shared Drives", .teal)
        }
        if trimmed == "ai" || searchText.lowercased().hasPrefix("ai ") {
            return ("AI Toolkit", .purple)
        }
        if trimmed.hasPrefix("//") {
            return ("Lệnh hệ thống", .orange)
        }
        return ("Google Drive", .indigo)
    }

    // MARK: - Search Engine Evaluation

    func refreshSearchResults() {
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

        // 1. Check `gda <path>`
        if raw.lowercased().hasPrefix("gda ") {
            let p = String(raw.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            if FileManager.default.fileExists(atPath: p) {
                openUniversalActions(for: .files([URL(fileURLWithPath: p)]), directExternalTrigger: false)
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

        // 3. Browse Mode (`/path/...` or `~/...`)
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

            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: currentDir, isDirectory: &isDir), isDir.boolValue {
                let words = filterPart.split(separator: " ").map(String.init)
                let children = drive.listChildren(parentPath: currentDir, queryWords: words)
                var items: [SearchResultItem] = children.prefix(80).map { child in
                    SearchResultItem(
                        id: "browse:\(child.path)",
                        title: (child.path as NSString).lastPathComponent,
                        subtitle: drive.formatHierarchicalSubtitle(child.path, maxLevels: 3),
                        path: child.path,
                        isDirectory: child.isDir,
                        kind: child.isDir ? .driveFolder(path: child.path) : .driveFile(path: child.path),
                        badge: child.isDir ? nil : URL(fileURLWithPath: child.path).pathExtension.uppercased(),
                        sfSymbolFallback: child.isDir ? "folder.fill" : "doc.fill"
                    )
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
                        title: "Thư mục trống hoặc không khớp từ khóa",
                        subtitle: currentDir,
                        path: nil,
                        isDirectory: false,
                        kind: .infoBanner,
                        badge: nil,
                        sfSymbolFallback: "folder"
                    ))
                }
                searchResults = items
                selectedIndex = 0
                return
            }
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

        // 5. System slash commands (`//rebuild`, `//clean`)
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

        // 6. Check Google Drive availability
        if drive.accountRoot == nil {
            searchResults = [
                SearchResultItem(
                    id: "no-gdrive",
                    title: "Không tìm thấy thư mục Google Drive trong ~/Library/CloudStorage",
                    subtitle: "Bạn vẫn dùng được mọi Universal Actions (⌘⇧A) & Convert sang Markdown trên file cục bộ!",
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
        var results: [SearchResultItem]

        if isSharedMode {
            results = tokens.isEmpty
                ? drive.recentSharedItems(limit: 9)
                : drive.searchSharedItems(tokens: tokens)
        } else {
            results = tokens.isEmpty
                ? drive.recentMyDriveFolders(limit: 9)
                : drive.searchMyDriveFolders(tokens: tokens, includeApps: AppSettings.shared.includeMacAppsInSearch)
        }

        let normQ = GoogleDriveIndexService.removeAccents(effectiveQuery).lowercased()
        if !tokens.isEmpty && (normQ.contains("clean") || normQ.contains("clear")) {
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

        searchResults = results
        selectedIndex = 0
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
        let drive = GoogleDriveIndexService.shared
        let q = destinationSearchText.trimmingCharacters(in: .whitespaces)
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
        } else {
            let tokens = q.split(separator: " ").map(String.init)
            destinationFolders = drive.searchMyDriveFolders(tokens: tokens, includeApps: false, maxResults: 30)
        }
        selectedIndex = 0
    }

    // MARK: - Thumbnail & File Metadata Preview (Screenshot 2 Right Pane!)

    func updatePreviewThumbnailIfNeeded() {
        previewImage = nil
        previewFileSizeText = ""
        previewModifiedText = ""
        previewRouteHint = ""

        guard case .universalActions(let target) = screenMode,
              let firstURL = target.fileURLs.first else {
            return
        }

        let fm = FileManager.default
        var stBuf = Darwin.stat()
        if Darwin.lstat(firstURL.path, &stBuf) == 0 {
            if (stBuf.st_mode & S_IFMT) != S_IFDIR {
                previewFileSizeText = ByteCountFormatter.string(fromByteCount: Int64(stBuf.st_size), countStyle: .file)
            }
            let mod = Date(timeIntervalSince1970: TimeInterval(stBuf.st_mtimespec.tv_sec))
            let df = DateFormatter()
            df.dateFormat = "dd/MM/yyyy HH:mm"
            previewModifiedText = df.string(from: mod)
        }

        var isDir: ObjCBool = false
        fm.fileExists(atPath: firstURL.path, isDirectory: &isDir)
        if !isDir.boolValue {
            previewRouteHint = MarkdownConverterService.routeDescription(for: firstURL)
        } else {
            previewRouteHint = "Thư mục • Hỗ trợ gộp sang 1 file AI .md"
        }

        // Fallback immediate icon while QuickLook renders high-DPI preview
        previewImage = NSWorkspace.shared.icon(forFile: firstURL.path)

        let req = QLThumbnailGenerator.Request(
            fileAt: firstURL,
            size: CGSize(width: 340, height: 420),
            scale: NSScreen.main?.backingScaleFactor ?? 2.0,
            representationTypes: .all
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let nsImg = rep?.nsImage else { return }
            Task { @MainActor in
                self?.previewImage = nsImg
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
    }

    func executeAtIndex(_ index: Int, modifiers: NSEvent.ModifierFlags) {
        guard index >= 0 && index < activeListCount else { return }
        selectedIndex = index
        executeCurrentSelection(modifiers: modifiers)
    }

    func executeCurrentSelection(modifiers: NSEvent.ModifierFlags) {
        switch screenMode {
        case .search:
            guard selectedIndex >= 0 && selectedIndex < searchResults.count else { return }
            let item = searchResults[selectedIndex]
            handleSearchItemExecution(item, modifiers: modifiers)

        case .universalActions(let target):
            guard selectedIndex >= 0 && selectedIndex < filteredActions.count else { return }
            let action = filteredActions[selectedIndex]
            UniversalActionExecutor.shared.execute(
                action: action,
                target: target,
                modifierFlags: modifiers,
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
                destinationFolder: URL(fileURLWithPath: folderPath)
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

    func openUniversalActionsForSelectedSearchItem() {
        guard case .search = screenMode,
              selectedIndex >= 0 && selectedIndex < searchResults.count,
              let path = searchResults[selectedIndex].path else { return }
        openUniversalActions(for: .files([URL(fileURLWithPath: path)]), directExternalTrigger: false)
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

        case .localApp(let appPath):
            LauncherPanelController.shared.hide()
            if modifiers.contains(.command) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: appPath)])
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
            }

        case .driveFolder(let path), .driveFile(let path):
            let fileURL = URL(fileURLWithPath: path)
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
                LauncherPanelController.shared.hide()
                if let gd = GoogleDriveIndexService.googleDriveURLs(for: path) {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(gd.shareURL.absoluteString, forType: .string)
                    FloatingToastController.shared.showSuccess(
                        title: "Đã sao chép liên kết chia sẻ Google Drive",
                        subtitle: fileURL.lastPathComponent,
                        symbol: "link"
                    )
                } else {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(path, forType: .string)
                    FloatingToastController.shared.showSuccess(
                        title: "Đã sao chép đường dẫn cục bộ",
                        subtitle: path,
                        symbol: "link"
                    )
                }
                return
            }
            if modifiers.contains(.control) {
                LauncherPanelController.shared.hide()
                if let gd = GoogleDriveIndexService.googleDriveURLs(for: path) {
                    NSWorkspace.shared.open(gd.webURL)
                } else {
                    NSWorkspace.shared.open(fileURL)
                }
                return
            }

            // Default Enter (no modifier):
            if item.isDirectory {
                enterBrowseMode(at: path)
            } else {
                LauncherPanelController.shared.hide()
                NSWorkspace.shared.open(fileURL)
            }
        }
    }
}
