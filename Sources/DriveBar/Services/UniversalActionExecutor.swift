import Foundation
import AppKit
import Carbon
import Darwin

@MainActor
final class UniversalActionExecutor {
    static let shared = UniversalActionExecutor()

    private init() {}

    func execute(
        action: UniversalActionDefinition,
        target: ActionTarget,
        modifierFlags: NSEvent.ModifierFlags = [],
        viewModel: LauncherViewModel
    ) {
        let urls = target.fileURLs
        for u in urls {
            GoogleDriveIndexService.shared.recordUsed(u.path)
        }
        SyncAndLatchingService.shared.recordActionUsed(actionID: action.id, target: target)

        switch action.id {
        // MARK: - 1. AI & Markdown Conversion Actions
        case "ai.convert_md":
            let optionHeld = modifierFlags.contains(.option)
            let saveBeside = optionHeld ? false : AppSettings.shared.saveMarkdownBesideSource
            let copyClip = optionHeld ? true : AppSettings.shared.autoCopyMarkdownToClipboard
            LauncherPanelController.shared.hide()
            runMarkdownConversion(urls: urls, saveBeside: saveBeside, copyClipboard: copyClip, forceOCR: false, forceXMLWrap: false)

        case "ai.copy_md":
            LauncherPanelController.shared.hide()
            runMarkdownConversion(urls: urls, saveBeside: false, copyClipboard: true, forceOCR: false, forceXMLWrap: false)

        case "ai.wrap_xml_clipboard":
            LauncherPanelController.shared.hide()
            runMarkdownConversion(urls: urls, saveBeside: false, copyClipboard: true, forceOCR: false, forceXMLWrap: true)

        case "ai.ocr_md":
            LauncherPanelController.shared.hide()
            runMarkdownConversion(
                urls: urls,
                saveBeside: AppSettings.shared.saveMarkdownBesideSource,
                copyClipboard: AppSettings.shared.autoCopyMarkdownToClipboard,
                forceOCR: true,
                forceXMLWrap: false
            )

        case "ai.ocr_clipboard":
            viewModel.runClipboardImageOCR(openPreview: modifierFlags.contains(.option) || modifierFlags.contains(.command))

        case "ai.chunk_md":
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: L("Đang chia nhỏ tài liệu theo Chương/Mục (H1/H2)...", "Splitting document into Sections (H1/H2)..."),
                subtitle: target.primaryTitle
            )
            Task { @MainActor in
                do {
                    let res = try await MarkdownConverterService.shared.convertAndSplitIntoAIChunks(urls: urls)
                    if let first = res.first {
                        let cCount = res.reduce(0) { $0 + $1.chunkCount }
                        FloatingToastController.shared.showSuccess(
                            title: L("Đã tách thành \(cCount) phần trong _Chunks/", "Split into \(cCount) parts in _Chunks/"),
                            subtitle: L("Kèm chỉ mục 00_INDEX.md • Tổng ~\(first.estimatedTokens.formatted()) tokens", "Includes 00_INDEX.md • Total ~\(first.estimatedTokens.formatted()) tokens"),
                            symbol: "rectangle.split.3x1.fill"
                        )
                        if let dir = first.chunkDirectoryURL {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        }
                    }
                } catch {
                    FloatingToastController.shared.showError(
                        title: L("Lỗi chia nhỏ tài liệu", "Failed to split document"),
                        subtitle: error.localizedDescription
                    )
                }
            }

        case "ai.url_to_md", "ai.url_preview_md":
            let webURL: URL? = {
                switch target {
                case .url(let u, _): return u
                case .text(let s, _): return URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines))
                default: return nil
                }
            }()
            guard let webURL else { return }
            let wantPreview = (action.id == "ai.url_preview_md") || modifierFlags.contains(.command)
            let saveDesktop = modifierFlags.contains(.option)
            if !wantPreview {
                LauncherPanelController.shared.hide()
            }
            FloatingToastController.shared.showProgress(
                title: L("Đang trích xuất nội dung Web sang Markdown...", "Extracting web content to Markdown..."),
                subtitle: webURL.host ?? webURL.absoluteString
            )
            Task { @MainActor in
                do {
                    let item = try await MarkdownConverterService.shared.convertWebURLToMarkdown(
                        url: webURL,
                        saveToDownloadsOrDesktop: saveDesktop,
                        copyToClipboard: true
                    )
                    FloatingToastController.shared.showSuccess(
                        title: saveDesktop
                            ? L("Đã lưu .md ra Desktop & Copy vào Clipboard", "Saved .md to Desktop & Copied to Clipboard")
                            : L("Đã Copy Markdown trang Web vào Clipboard", "Copied Web Markdown to Clipboard"),
                        subtitle: "\(item.engineUsed) • ~\(item.estimatedTokens.formatted()) tokens",
                        symbol: "globe.desk.fill"
                    )
                    if wantPreview {
                        viewModel.screenMode = .markdownPreview(
                            title: webURL.host ?? "Web Markdown",
                            sourceURL: webURL,
                            savedMDURL: item.savedMarkdownURL,
                            markdown: item.markdown,
                            estimatedTokens: item.estimatedTokens,
                            engineUsed: item.engineUsed
                        )
                        LauncherPanelController.shared.showAndFocus()
                    }
                } catch {
                    FloatingToastController.shared.showError(
                        title: L("Không đọc được nội dung trang Web", "Failed to read webpage content"),
                        subtitle: error.localizedDescription
                    )
                }
            }

        case "ai.preview_md":
            guard let first = urls.first else { return }
            FloatingToastController.shared.showProgress(
                title: L("Đang chuyển sang Markdown...", "Converting to Markdown..."),
                subtitle: first.lastPathComponent
            )
            Task { @MainActor in
                do {
                    let res = try await MarkdownConverterService.shared.convertFilesToMarkdown(
                        urls: [first],
                        saveBesideSource: AppSettings.shared.saveMarkdownBesideSource,
                        copyToClipboard: AppSettings.shared.autoCopyMarkdownToClipboard,
                        forceOCR: false
                    )
                    if let item = res.first {
                        FloatingToastController.shared.showSuccess(
                            title: L("Đã tối ưu Markdown cho AI (~\(item.estimatedTokens) tokens)", "Optimized Markdown for AI (~\(item.estimatedTokens) tokens)"),
                            subtitle: AppSettings.shared.autoCopyMarkdownToClipboard
                                ? L("Đã chép sẵn vào Clipboard", "Copied to Clipboard")
                                : item.engineUsed,
                            symbol: "doc.text.magnifyingglass"
                        )
                        viewModel.screenMode = .markdownPreview(
                            title: first.lastPathComponent,
                            sourceURL: first,
                            savedMDURL: item.savedMarkdownURL,
                            markdown: item.markdown,
                            estimatedTokens: item.estimatedTokens,
                            engineUsed: item.engineUsed
                        )
                        LauncherPanelController.shared.showAndFocus()
                    }
                } catch {
                    FloatingToastController.shared.showError(
                        title: L("Lỗi Convert sang Markdown", "Markdown conversion failed"),
                        subtitle: error.localizedDescription
                    )
                }
            }

        case "ai.convert_for_ai":
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: L("Đang đóng gói thư mục _AI/...", "Packaging _AI/ bundle..."),
                subtitle: target.primaryTitle
            )
            Task { @MainActor in
                do {
                    let pkgDirs = try await MarkdownConverterService.shared.convertFilesForAIPackage(urls: urls)
                    if let firstPkg = pkgDirs.first {
                        FloatingToastController.shared.showSuccess(
                            title: L("Đã tạo gói AI Package thành công", "Created AI Package successfully"),
                            subtitle: pkgDirs.count == 1 ? firstPkg.lastPathComponent : L("Đã tạo \(pkgDirs.count) thư mục _AI/", "Created \(pkgDirs.count) _AI/ directories"),
                            symbol: "sparkles.rectangle.stack.fill"
                        )
                        if modifierFlags.contains(.command) {
                            NSWorkspace.shared.activateFileViewerSelecting(pkgDirs)
                        }
                    }
                } catch {
                    FloatingToastController.shared.showError(
                        title: L("Lỗi tạo gói Convert for AI", "Failed to package Convert for AI"),
                        subtitle: error.localizedDescription
                    )
                }
            }

        case "ai.merge_folder_md":
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: L("Đang gộp tài liệu thành 1 file AI Context (.md)...", "Merging documents into single AI Context (.md)..."),
                subtitle: target.primaryTitle
            )
            Task { @MainActor in
                do {
                    let merged = try await MarkdownConverterService.shared.mergeIntoSingleContextMarkdown(urls: urls, copyToClipboard: true)
                    let outName = merged.savedMarkdownURL?.lastPathComponent ?? "AI_Context.md"
                    FloatingToastController.shared.showSuccess(
                        title: L("Đã tạo \(outName) & Copy vào Clipboard!", "Created \(outName) & Copied to Clipboard!"),
                        subtitle: L("Tổng ước tính ~\(merged.estimatedTokens.formatted()) tokens cho LLM", "Total ~\(merged.estimatedTokens.formatted()) estimated tokens for LLMs"),
                        symbol: "square.stack.3d.up.badge.a.fill"
                    )
                } catch {
                    FloatingToastController.shared.showError(
                        title: L("Không thể gộp tài liệu", "Failed to merge documents"),
                        subtitle: error.localizedDescription
                    )
                }
            }

        case "ai.convert_pdf":
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: L("Đang chuyển sang PDF...", "Converting to PDF..."),
                subtitle: target.primaryTitle
            )
            Task { @MainActor in
                do {
                    let pdfs = try await MarkdownConverterService.shared.convertFilesToPDF(urls: urls)
                    if let first = pdfs.first {
                        FloatingToastController.shared.showSuccess(
                            title: L("Đã xuất PDF thành công", "Exported PDF successfully"),
                            subtitle: pdfs.count == 1 ? first.lastPathComponent : L("Đã xuất \(pdfs.count) tệp PDF", "Exported \(pdfs.count) PDF files"),
                            symbol: "doc.richtext.fill"
                        )
                    }
                } catch {
                    FloatingToastController.shared.showError(
                        title: L("Lỗi chuyển sang PDF", "Failed to convert to PDF"),
                        subtitle: error.localizedDescription
                    )
                }
            }

        // MARK: - 2. Google Drive Actions
        case "gdrive.open_web":
            LauncherPanelController.shared.hide()
            guard let first = urls.first else { return }
            let path = first.path
            let name = first.lastPathComponent
            Task.detached(priority: .userInitiated) {
                let gd = GoogleDriveIndexService.googleDriveURLs(for: path)
                await MainActor.run {
                    if let gd {
                        NSWorkspace.shared.open(gd.webURL)
                    } else {
                        FloatingToastController.shared.showError(
                            title: L("Không lấy được liên kết Google Drive", "Unable to get Google Drive link"),
                            subtitle: name
                        )
                    }
                }
            }

        case "gdrive.copy_link":
            LauncherPanelController.shared.hide()
            guard let first = urls.first else { return }
            let path = first.path
            let name = first.lastPathComponent
            Task.detached(priority: .userInitiated) {
                let gd = GoogleDriveIndexService.googleDriveURLs(for: path)
                await MainActor.run {
                    if let gd {
                        self.copyString(gd.shareURL.absoluteString)
                        FloatingToastController.shared.showSuccess(
                            title: L("Đã chép liên kết chia sẻ Google Drive", "Copied Google Drive share link"),
                            subtitle: name,
                            symbol: "link"
                        )
                    } else {
                        FloatingToastController.shared.showError(
                            title: L("Không tìm thấy ID Google Drive", "Google Drive ID not found"),
                            subtitle: L("Tệp có thể chưa được đồng bộ lên đám mây", "File may not be synced to the cloud yet")
                        )
                    }
                }
            }

        case "gdrive.share":
            LauncherPanelController.shared.hide()
            guard let first = urls.first else { return }
            let path = first.path
            let name = first.lastPathComponent
            Task.detached(priority: .userInitiated) {
                let gd = GoogleDriveIndexService.googleDriveURLs(for: path)
                await MainActor.run {
                    if let gd {
                        NSWorkspace.shared.open(gd.shareURL)
                    } else {
                        FloatingToastController.shared.showError(
                            title: L("Không mở được trang chia sẻ", "Unable to open sharing settings"),
                            subtitle: name
                        )
                    }
                }
            }

        case "gdrive.offline":
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: L("Đang kích hoạt tải Offline...", "Enabling offline download..."),
                subtitle: target.primaryTitle
            )
            Task.detached(priority: .userInitiated) {
                let count = GoogleDriveIndexService.triggerOfflineDownload(for: urls)
                await MainActor.run {
                    FloatingToastController.shared.showSuccess(
                        title: L("Đã kích hoạt chế độ Offline", "Enabled offline mode"),
                        subtitle: L("Đã đồng bộ \(count) tệp về máy cục bộ", "Synced \(count) files locally"),
                        symbol: "arrow.down.circle.fill"
                    )
                }
            }

        // MARK: - 3. File System Actions
        case "file.extract_archive":
            LauncherPanelController.shared.hide()
            performArchiveExtraction(urls: urls)

        case "file.open":
            LauncherPanelController.shared.hide()
            for u in urls {
                NSWorkspace.shared.open(u)
            }

        case "file.toggle_pin":
            guard !urls.isEmpty else { return }
            let settings = AppSettings.shared
            let allAlreadyPinned = urls.allSatisfy { settings.isPinned($0.path) }
            if allAlreadyPinned {
                for u in urls { _ = settings.togglePin(u.path) }
                LauncherPanelController.shared.hide()
                FloatingToastController.shared.showSuccess(
                    title: urls.count == 1
                        ? L("Đã bỏ ghim khỏi DriveBar", "Unpinned from DriveBar")
                        : L("Đã bỏ ghim \(urls.count) mục", "Unpinned \(urls.count) items"),
                    subtitle: target.primaryTitle,
                    symbol: "pin.slash"
                )
            } else {
                for u in urls where !settings.isPinned(u.path) {
                    _ = settings.togglePin(u.path)
                }
                LauncherPanelController.shared.hide()
                FloatingToastController.shared.showSuccess(
                    title: urls.count == 1
                        ? L("Đã ghim lên đầu thanh tìm kiếm DriveBar", "Pinned to top of DriveBar search")
                        : L("Đã ghim \(urls.count) mục lên đầu DriveBar", "Pinned \(urls.count) items to top of DriveBar"),
                    subtitle: target.primaryTitle,
                    symbol: "pin.fill"
                )
            }
            viewModel.refreshSearchResults()

        case "file.open_with":
            guard let first = urls.first else { return }
            viewModel.enterOpenWithPicker(for: first, previousTarget: target)

        case "file.reveal":
            LauncherPanelController.shared.hide()
            NSWorkspace.shared.activateFileViewerSelecting(urls)

        case "file.browse":
            guard let first = urls.first else { return }
            let isDir = GoogleDriveIndexService.shared.isKnownDirectory(first.path, hasDirectoryHint: first.hasDirectoryPath)
            let browseDir = isDir ? first.path : first.deletingLastPathComponent().path
            viewModel.enterBrowseMode(at: browseDir)

        case "file.toggle_custom_mac_folder":
            LauncherPanelController.shared.hide()
            var addedCount = 0
            var removedCount = 0
            for u in urls {
                let p = u.path
                if AppSettings.shared.isCustomMacFolder(p) {
                    AppSettings.shared.removeCustomMacFolder(p)
                    removedCount += 1
                } else {
                    if AppSettings.shared.addCustomMacFolder(p) {
                        addedCount += 1
                    }
                }
            }
            if addedCount > 0 {
                FloatingToastController.shared.showSuccess(
                    title: L("Đã thêm vào thư mục Mac (m)", "Added to Mac Folders (m)"),
                    subtitle: L("\(addedCount) thư mục đã được bổ sung vào phạm vi tìm kiếm 'm'", "\(addedCount) folders added to 'm' search scope"),
                    symbol: "folder.badge.plus"
                )
            } else if removedCount > 0 {
                FloatingToastController.shared.showSuccess(
                    title: L("Đã xóa khỏi thư mục Mac (m)", "Removed from Mac Folders (m)"),
                    subtitle: L("\(removedCount) thư mục đã được xóa khỏi phạm vi tìm kiếm 'm'", "\(removedCount) folders removed from 'm' search scope"),
                    symbol: "folder.badge.minus"
                )
            }
            viewModel.refreshSearchResults()

        case "file.quicklook":
            QuickLookCoordinator.shared.toggleQuickLook(for: urls)

        case "file.get_info":
            LauncherPanelController.shared.hide()
            openFinderGetInfo(for: urls)

        case "file.batch_rename":
            guard !urls.isEmpty else { return }
            BatchRenameState.shared.configure(for: urls, previousTarget: target)
            viewModel.screenMode = .batchRename(urls: urls, previousTarget: target)

        case "file.copy_to":
            viewModel.enterDestinationPicker(operation: .copy, sources: urls)

        case "file.move_to":
            viewModel.enterDestinationPicker(operation: .move, sources: urls)

        case "file.copy_replace_to":
            viewModel.enterDestinationPicker(operation: .copyReplace, sources: urls)

        case "file.move_replace_to":
            viewModel.enterDestinationPicker(operation: .moveReplace, sources: urls)

        case "file.open_terminal":
            LauncherPanelController.shared.hide()
            guard let first = urls.first else { return }
            let isDir = GoogleDriveIndexService.shared.isKnownDirectory(first.path, hasDirectoryHint: first.hasDirectoryPath)
            let dirURL = isDir ? first : first.deletingLastPathComponent()
            let iTermURL = URL(fileURLWithPath: "/Applications/iTerm.app")
            let termApp = FileManager.default.fileExists(atPath: iTermURL.path)
                ? iTermURL
                : URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([dirURL], withApplicationAt: termApp, configuration: NSWorkspace.OpenConfiguration())

        case "file.show_package":
            LauncherPanelController.shared.hide()
            guard let first = urls.first else { return }
            let contentsURL = first.appendingPathComponent("Contents")
            if FileManager.default.fileExists(atPath: contentsURL.path) {
                NSWorkspace.shared.open(contentsURL)
            } else {
                NSWorkspace.shared.open(first)
            }

        case "file.compress_zip":
            LauncherPanelController.shared.hide()
            performZipCompression(urls: urls, revealInFinder: modifierFlags.contains(.command))

        // MARK: - 4. Clipboard & Buffer
        case "clip.copy_path":
            LauncherPanelController.shared.hide()
            let paths = urls.map(\.path).joined(separator: "\n")
            copyString(paths)
            FloatingToastController.shared.showSuccess(
                title: L("Đã chép đường dẫn vào Clipboard", "Copied path to Clipboard"),
                subtitle: urls.first?.path ?? "",
                symbol: "link"
            )

        case "clip.copy_file":
            LauncherPanelController.shared.hide()
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            FloatingToastController.shared.showSuccess(
                title: L("Đã chép \(urls.count) tệp vào Clipboard", "Copied \(urls.count) files to Clipboard"),
                subtitle: L("Nhấn ⌘V ở bất kỳ đâu để dán tệp", "Press ⌘V anywhere to paste files"),
                symbol: "doc.on.clipboard"
            )

        case "clip.add_buffer":
            FileBufferService.shared.addAll(urls)
            viewModel.returnToSearchMode()
            FloatingToastController.shared.showSuccess(
                title: L("Đã thêm vào File Buffer (\(FileBufferService.shared.items.count) mục)", "Added to File Buffer (\(FileBufferService.shared.items.count) items)"),
                subtitle: L("Nhấn ⌥→ để thực hiện Universal Action hàng loạt", "Press ⌥→ to run Universal Actions in batch"),
                symbol: "tray.and.arrow.down.fill"
            )

        // MARK: - 5. File Visibility (Native POSIX chflags!)
        case "vis.toggle":
            LauncherPanelController.shared.hide()
            applyVisibilityChange(urls: urls, mode: .toggle)

        case "vis.unhide":
            LauncherPanelController.shared.hide()
            applyVisibilityChange(urls: urls, mode: .unhide)

        case "vis.hide":
            LauncherPanelController.shared.hide()
            applyVisibilityChange(urls: urls, mode: .hide)

        // MARK: - 6. Share, Search & Trash
        case "file.share_sheet":
            guard let contentView = LauncherPanelController.shared.panelContentView else { return }
            LauncherPanelController.shared.isSuppressingAutoHide = true
            let picker = NSSharingServicePicker(items: urls)
            picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                LauncherPanelController.shared.isSuppressingAutoHide = false
            }

        case "file.search_finder":
            LauncherPanelController.shared.hide()
            let q: String
            switch target {
            case .files(let u, _): q = u.first?.deletingPathExtension().lastPathComponent ?? ""
            case .text(let t, _): q = t
            case .url(let u, _): q = u.host ?? u.absoluteString
            }
            copyString(q)
            Task.detached(priority: .userInitiated) {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", "tell application \"Finder\" to activate"]
                try? proc.run()
            }
            FloatingToastController.shared.showSuccess(
                title: L("Đã mở Finder & Copy từ khóa tìm kiếm", "Opened Finder & Copied search keyword"),
                subtitle: L("Nhấn ⌘F rồi ⌘V trong Finder để tìm '\(q)'", "Press ⌘F then ⌘V in Finder to find '\(q)'"),
                symbol: "magnifyingglass.circle.fill"
            )

        case "file.trash":
            LauncherPanelController.shared.hide()
            let primaryLabel = target.primaryTitle
            Task.detached(priority: .userInitiated) {
                var trashed = 0
                for u in urls {
                    if (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil {
                        trashed += 1
                    }
                }
                let finalTrashed = trashed
                await MainActor.run {
                    if finalTrashed > 0 {
                        FloatingToastController.shared.showSuccess(
                            title: L("Đã chuyển \(finalTrashed) mục vào Thùng rác", "Moved \(finalTrashed) items to Trash"),
                            subtitle: primaryLabel,
                            symbol: "trash.fill"
                        )
                    } else {
                        FloatingToastController.shared.showError(
                            title: L("Không thể chuyển vào Thùng rác", "Unable to move to Trash"),
                            subtitle: primaryLabel
                        )
                    }
                }
            }

        // MARK: - 7. Text & URL Universal Actions
        case "text.clean_md_ai":
            LauncherPanelController.shared.hide()
            if case .text(let s, _) = target {
                let clean = MarkdownConverterService.optimizeMarkdownText(s)
                let tok = MarkdownConverterService.estimateTokens(clean)
                copyString(clean)
                FloatingToastController.shared.showSuccess(
                    title: L("Đã chuẩn hóa Markdown cho AI (~\(tok) tokens)", "Normalized Markdown for AI (~\(tok) tokens)"),
                    subtitle: L("Đã lưu vào Clipboard sẵn sàng dán (⌘V)", "Saved to Clipboard, ready to paste (⌘V)"),
                    symbol: "wand.and.stars"
                )
            }

        case "url.open":
            LauncherPanelController.shared.hide()
            if case .url(let u, _) = target {
                NSWorkspace.shared.open(u)
            }

        case "url.domain":
            LauncherPanelController.shared.hide()
            if case .url(let u, _) = target, let host = u.host {
                copyString(host)
                FloatingToastController.shared.showSuccess(
                    title: L("Đã sao chép tên miền", "Copied domain"),
                    subtitle: host,
                    symbol: "network"
                )
            }

        case "text.copy_plain":
            LauncherPanelController.shared.hide()
            let plain = rawString(from: target)
            copyString(plain)
            FloatingToastController.shared.showSuccess(
                title: L("Đã sao chép dạng Plain Text", "Copied as Plain Text"),
                subtitle: L("\(plain.count) ký tự", "\(plain.count) characters"),
                symbol: "doc.plaintext.fill"
            )

        case "text.paste_plain":
            let plain = rawString(from: target)
            copyString(plain)
            LauncherPanelController.shared.hide()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                postCommandV()
            }

        case "text.case_upper":
            LauncherPanelController.shared.hide()
            let transformed = rawString(from: target).uppercased()
            copyString(transformed)
            FloatingToastController.shared.showSuccess(
                title: L("Đã chuyển thành IN HOA", "Converted to UPPERCASE"),
                subtitle: String(transformed.prefix(50))
            )

        case "text.case_lower":
            LauncherPanelController.shared.hide()
            let transformed = rawString(from: target).lowercased()
            copyString(transformed)
            FloatingToastController.shared.showSuccess(
                title: L("Đã chuyển thành chữ thường", "Converted to lowercase"),
                subtitle: String(transformed.prefix(50))
            )

        case "text.case_title":
            LauncherPanelController.shared.hide()
            let transformed = rawString(from: target).localizedCapitalized
            copyString(transformed)
            FloatingToastController.shared.showSuccess(
                title: L("Đã chuyển thành Title Case", "Converted to Title Case"),
                subtitle: String(transformed.prefix(50))
            )

        case "text.extract_urls":
            LauncherPanelController.shared.hide()
            let input = rawString(from: target)
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let matches = detector?.matches(in: input, options: [], range: NSRange(input.startIndex..., in: input)) ?? []
            let extracted = matches.compactMap { $0.url?.absoluteString }.joined(separator: "\n")
            if extracted.isEmpty {
                FloatingToastController.shared.showError(
                    title: L("Không tìm thấy URL nào", "No URLs found"),
                    subtitle: L("Đoạn văn bản không chứa liên kết web", "Text does not contain web links")
                )
            } else {
                copyString(extracted)
                FloatingToastController.shared.showSuccess(
                    title: L("Đã tách \(matches.count) URL vào Clipboard", "Extracted \(matches.count) URLs to Clipboard"),
                    subtitle: extracted
                )
            }

        case "text.dictionary":
            LauncherPanelController.shared.hide()
            let word = rawString(from: target).trimmingCharacters(in: .whitespacesAndNewlines)
            if let encoded = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
               let dictURL = URL(string: "dict://\(encoded)") {
                NSWorkspace.shared.open(dictURL)
            }

        case "text.large_type":
            LauncherPanelController.shared.hide()
            LargeTypeOverlayController.shared.show(text: rawString(from: target))

        case "text.web_search":
            LauncherPanelController.shared.hide()
            let q = rawString(from: target)
            if let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
               let searchURL = URL(string: "https://www.google.com/search?q=\(encoded)") {
                NSWorkspace.shared.open(searchURL)
            }

        default:
            break
        }
    }

    // MARK: - Helpers

    func performFileTransfer(
        operation: FileTransferOperation,
        sources: [URL],
        destinationFolder: URL,
        revealInFinder: Bool = false
    ) {
        LauncherPanelController.shared.hide()
        GoogleDriveIndexService.shared.recordUsed(destinationFolder.path)

        FloatingToastController.shared.showProgress(
            title: L("Đang thực hiện \(operation.localizedTitle)", "Performing \(operation.localizedTitle)"),
            subtitle: L("Đích: \(destinationFolder.lastPathComponent)", "Destination: \(destinationFolder.lastPathComponent)")
        )

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var success = 0
            var producedURLs: [URL] = []
            var lastError: String?

            for src in sources {
                let dst = destinationFolder.appendingPathComponent(src.lastPathComponent)
                if src.standardizedFileURL == dst.standardizedFileURL {
                    producedURLs.append(dst)
                    success += 1
                    continue
                }

                // Materialize online-only CloudStorage files before copying/moving
                if src.path.contains("/Library/CloudStorage/") {
                    var st = Darwin.stat()
                    if Darwin.lstat(src.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                        if let fh = try? FileHandle(forReadingFrom: src) {
                            _ = try? fh.read(upToCount: 4096)
                            try? fh.close()
                        }
                    }
                }

                do {
                    switch operation {
                    case .copy:
                        try fm.copyItem(at: src, to: dst)
                    case .move:
                        try fm.moveItem(at: src, to: dst)
                    case .copyReplace:
                        if fm.fileExists(atPath: dst.path) {
                            try fm.removeItem(at: dst)
                        }
                        try fm.copyItem(at: src, to: dst)
                    case .moveReplace:
                        if fm.fileExists(atPath: dst.path) {
                            try fm.removeItem(at: dst)
                        }
                        try fm.moveItem(at: src, to: dst)
                    }
                    producedURLs.append(dst)
                    success += 1
                } catch {
                    lastError = error.localizedDescription
                }
            }

            let finalSuccess = success
            let finalProduced = producedURLs
            let finalError = lastError
            await MainActor.run {
                if finalSuccess > 0 {
                    FloatingToastController.shared.showSuccess(
                        title: L("Đã hoàn tất \(operation.localizedTitle) (\(finalSuccess) mục)", "Completed \(operation.localizedTitle) (\(finalSuccess) items)"),
                        subtitle: L("Đích: \(destinationFolder.lastPathComponent)", "Destination: \(destinationFolder.lastPathComponent)")
                    )
                    if revealInFinder && !finalProduced.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(finalProduced)
                    }
                } else if let finalError {
                    FloatingToastController.shared.showError(
                        title: L("Thao tác tệp thất bại", "File operation failed"),
                        subtitle: finalError
                    )
                }
            }
        }
    }

    private func runMarkdownConversion(
        urls: [URL],
        saveBeside: Bool,
        copyClipboard: Bool,
        forceOCR: Bool,
        forceXMLWrap: Bool
    ) {
        guard !urls.isEmpty else { return }
        let titleLabel = urls.count == 1 ? urls[0].lastPathComponent : L("\(urls.count) tệp tài liệu", "\(urls.count) document files")
        FloatingToastController.shared.showProgress(
            title: forceOCR
                ? L("Đang OCR Tiếng Việt sang Markdown...", "Running OCR to Markdown...")
                : L("Đang Convert sang Markdown cho AI...", "Converting to Markdown for AI..."),
            subtitle: titleLabel
        )

        let hasFolder = urls.contains {
            GoogleDriveIndexService.shared.isKnownDirectory($0.path, hasDirectoryHint: $0.hasDirectoryPath)
        }

        Task { @MainActor in
            do {
                if hasFolder {
                    let merged = try await MarkdownConverterService.shared.mergeIntoSingleContextMarkdown(
                        urls: urls,
                        copyToClipboard: copyClipboard
                    )
                    let outName = merged.savedMarkdownURL?.lastPathComponent ?? "AI_Context.md"
                    FloatingToastController.shared.showSuccess(
                        title: copyClipboard
                            ? L("Đã gộp sang \(outName) & Copy vào Clipboard", "Merged to \(outName) & Copied to Clipboard")
                            : L("Đã xuất \(outName)", "Exported \(outName)"),
                        subtitle: L("Tổng ước tính ~\(merged.estimatedTokens.formatted()) tokens cho AI", "Total ~\(merged.estimatedTokens.formatted()) estimated tokens for AI"),
                        symbol: "doc.text.magnifyingglass"
                    )
                    return
                }

                let results = try await MarkdownConverterService.shared.convertFilesToMarkdown(
                    urls: urls,
                    saveBesideSource: saveBeside,
                    copyToClipboard: copyClipboard,
                    forceOCR: forceOCR,
                    forceXMLWrap: forceXMLWrap
                )
                let totalTokens = results.reduce(0) { $0 + $1.estimatedTokens }
                let totalChunks = results.reduce(0) { $0 + $1.chunkCount }
                let engine = results.first?.engineUsed ?? "AI Engine"

                let mainMsg: String
                if forceXMLWrap {
                    mainMsg = L("Đã Copy cấu trúc XML <documents> vào Clipboard", "Copied XML <documents> structure to Clipboard")
                } else if saveBeside && copyClipboard {
                    let mdName = results.first?.savedMarkdownURL?.lastPathComponent ?? ".md"
                    mainMsg = results.count == 1
                        ? L("Đã tạo \(mdName) & Copy vào Clipboard", "Created \(mdName) & Copied to Clipboard")
                        : L("Đã tạo \(results.count) file .md & Copy vào Clipboard", "Created \(results.count) .md files & Copied to Clipboard")
                } else if copyClipboard {
                    mainMsg = L("Đã Copy Markdown vào Clipboard (Sẵn sàng ⌘V)", "Copied Markdown to Clipboard (Ready to ⌘V)")
                } else {
                    mainMsg = L("Đã xuất \(results.count) file Markdown", "Exported \(results.count) Markdown files")
                }

                let chunkNote = totalChunks > 0 ? L(" • Tách \(totalChunks) phần _Chunks/", " • Split \(totalChunks) parts _Chunks/") : ""
                FloatingToastController.shared.showSuccess(
                    title: mainMsg,
                    subtitle: "\(engine) • ~\(totalTokens.formatted()) tokens\(chunkNote)",
                    symbol: "doc.text.magnifyingglass"
                )
            } catch {
                FloatingToastController.shared.showError(
                    title: L("Convert sang Markdown thất bại", "Markdown conversion failed"),
                    subtitle: error.localizedDescription
                )
            }
        }
    }

    private enum VisibilityMode {
        case hide
        case unhide
        case toggle
    }

    private func applyVisibilityChange(urls: [URL], mode: VisibilityMode) {
        var successCount = 0
        var lastStateHidden = false

        for u in urls {
            var st = stat()
            guard lstat(u.path, &st) == 0 else { continue }
            let currentlyHidden = (st.st_flags & UInt32(UF_HIDDEN)) != 0
            let shouldHide: Bool
            switch mode {
            case .hide: shouldHide = true
            case .unhide: shouldHide = false
            case .toggle: shouldHide = !currentlyHidden
            }

            let newFlags = shouldHide ? (st.st_flags | UInt32(UF_HIDDEN)) : (st.st_flags & ~UInt32(UF_HIDDEN))
            if chflags(u.path, newFlags) == 0 {
                successCount += 1
                lastStateHidden = shouldHide
                refreshFinderItem(at: u.path)
            }
        }

        if successCount > 0 {
            let label = lastStateHidden
                ? L("Đã ẩn (chflags hidden)", "Hidden (chflags hidden)")
                : L("Đã bỏ ẩn (chflags nohidden)", "Unhidden (chflags nohidden)")
            FloatingToastController.shared.showSuccess(
                title: L("\(label) cho \(successCount) mục", "\(label) for \(successCount) items"),
                subtitle: urls.first?.lastPathComponent ?? "",
                symbol: lastStateHidden ? "eye.slash.fill" : "eye.circle.fill"
            )
        } else {
            FloatingToastController.shared.showError(
                title: L("Không thể đổi cờ ẩn/hiện", "Unable to change hidden flag"),
                subtitle: L("Kiểm tra quyền truy cập tệp", "Check file permissions")
            )
        }
    }

    private func refreshFinderItem(at path: String) {
        Task.detached(priority: .utility) {
            let escaped = path.replacingOccurrences(of: "\"", with: "\\\"")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", "tell application \"Finder\" to update (POSIX file \"\(escaped)\")"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
        }
    }

    private func openFinderGetInfo(for urls: [URL]) {
        Task.detached(priority: .userInitiated) {
            for u in urls {
                let escaped = u.path.replacingOccurrences(of: "\"", with: "\\\"")
                let script = """
                tell application "Finder"
                    activate
                    open information window of (POSIX file "\(escaped)" as alias)
                end tell
                """
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                proc.arguments = ["-e", script]
                try? proc.run()
            }
        }
    }

    private func performZipCompression(urls: [URL], revealInFinder: Bool) {
        guard let first = urls.first else { return }
        let parentDir = first.deletingLastPathComponent()
        let firstIsDir = GoogleDriveIndexService.shared.isKnownDirectory(first.path, hasDirectoryHint: first.hasDirectoryPath)

        let baseStem: String
        if urls.count == 1 {
            baseStem = (firstIsDir || first.pathExtension.isEmpty)
                ? first.lastPathComponent
                : first.deletingPathExtension().lastPathComponent
        } else {
            let parentName = parentDir.lastPathComponent
            baseStem = parentName.isEmpty || parentName == "My Drive" ? "Archive_\(urls.count)_items" : "\(parentName)_Archive"
        }

        FloatingToastController.shared.showProgress(
            title: L("Đang nén thành tệp .ZIP...", "Compressing to .ZIP..."),
            subtitle: urls.count == 1 ? first.lastPathComponent : L("\(urls.count) mục đã chọn", "\(urls.count) items selected")
        )

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var zipURL = parentDir.appendingPathComponent("\(baseStem).zip")
            var suffix = 2
            while fm.fileExists(atPath: zipURL.path) {
                zipURL = parentDir.appendingPathComponent("\(baseStem) \(suffix).zip")
                suffix += 1
            }

            // Materialize online-only CloudStorage files before zipping
            _ = GoogleDriveIndexService.triggerOfflineDownload(for: urls)

            var ok = false
            let sameParent = urls.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == parentDir.standardizedFileURL }

            if urls.count == 1 {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = firstIsDir
                    ? ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, zipURL.path]
                    : ["-c", "-k", "--sequesterRsrc", first.path, zipURL.path]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                if (try? proc.run()) != nil {
                    proc.waitUntilExit()
                    ok = (proc.terminationStatus == 0 && fm.fileExists(atPath: zipURL.path))
                }
            } else if sameParent {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
                proc.currentDirectoryURL = parentDir
                proc.arguments = ["-r", "-q", "-y", zipURL.path] + urls.map(\.lastPathComponent) + ["-x", "*.DS_Store", "*__MACOSX*"]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                if (try? proc.run()) != nil {
                    proc.waitUntilExit()
                    ok = (proc.terminationStatus == 0 && fm.fileExists(atPath: zipURL.path))
                }
            } else {
                let stageDir = fm.temporaryDirectory.appendingPathComponent("DriveBarZip_\(UUID().uuidString.prefix(8))", isDirectory: true)
                defer { try? fm.removeItem(at: stageDir) }
                try? fm.createDirectory(at: stageDir, withIntermediateDirectories: true)
                for u in urls {
                    let dst = stageDir.appendingPathComponent(u.lastPathComponent)
                    try? fm.copyItem(at: u, to: dst)
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                proc.arguments = ["-c", "-k", "--sequesterRsrc", stageDir.path, zipURL.path]
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()
                if (try? proc.run()) != nil {
                    proc.waitUntilExit()
                    ok = (proc.terminationStatus == 0 && fm.fileExists(atPath: zipURL.path))
                }
            }

            let finalZipURL = zipURL
            let succeeded = ok
            await MainActor.run {
                if succeeded {
                    GoogleDriveIndexService.shared.rebuildFileCacheInBackground()
                    FloatingToastController.shared.showSuccess(
                        title: L("Đã tạo \(finalZipURL.lastPathComponent)", "Created \(finalZipURL.lastPathComponent)"),
                        subtitle: parentDir.lastPathComponent,
                        symbol: "doc.zipper"
                    )
                    if revealInFinder {
                        NSWorkspace.shared.activateFileViewerSelecting([finalZipURL])
                    }
                } else {
                    FloatingToastController.shared.showError(
                        title: L("Nén tệp .ZIP thất bại", "Failed to compress .ZIP"),
                        subtitle: L("Kiểm tra quyền ghi tại thư mục đích", "Check write permissions at destination")
                    )
                }
            }
        }
    }

    private func performArchiveExtraction(urls: [URL]) {
        guard !urls.isEmpty else { return }
        FloatingToastController.shared.showProgress(
            title: L("Đang giải nén tệp lưu trữ...", "Extracting archive..."),
            subtitle: urls[0].lastPathComponent
        )

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            _ = GoogleDriveIndexService.triggerOfflineDownload(for: urls)
            var extractedDirs: [URL] = []
            var lastError: String?

            for archiveURL in urls {
                let parentDir = archiveURL.deletingLastPathComponent()
                let fileName = archiveURL.lastPathComponent
                let lowerName = fileName.lowercased()
                let stem: String = {
                    for compound in [".tar.gz", ".tar.bz2", ".tar.xz"] where lowerName.hasSuffix(compound) {
                        return String(fileName.dropLast(compound.count))
                    }
                    return archiveURL.deletingPathExtension().lastPathComponent
                }()

                var destDir = parentDir.appendingPathComponent(stem.isEmpty ? "Extracted" : stem, isDirectory: true)
                var suffix = 2
                while fm.fileExists(atPath: destDir.path) {
                    destDir = parentDir.appendingPathComponent("\(stem) \(suffix)", isDirectory: true)
                    suffix += 1
                }

                do {
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                } catch {
                    lastError = error.localizedDescription
                    continue
                }

                let ext = archiveURL.pathExtension.lowercased()
                let proc = Process()
                proc.standardOutput = Pipe()
                proc.standardError = Pipe()

                if ext == "zip" {
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    proc.arguments = ["-x", "-k", archiveURL.path, destDir.path]
                } else if ["tar", "gz", "tgz", "bz2", "tbz2", "xz"].contains(ext) {
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    proc.arguments = ["-xf", archiveURL.path, "-C", destDir.path]
                } else if let unarPath = ["/opt/homebrew/bin/unar", "/usr/local/bin/unar"].first(where: { fm.isExecutableFile(atPath: $0) }) {
                    proc.executableURL = URL(fileURLWithPath: unarPath)
                    proc.arguments = ["-q", "-o", destDir.path, archiveURL.path]
                } else {
                    try? fm.removeItem(at: destDir)
                    lastError = L("Định dạng .\(ext) cần cài thêm công cụ 'unar' (brew install unar)", "Format .\(ext) requires 'unar' (brew install unar)")
                    continue
                }

                if (try? proc.run()) != nil {
                    proc.waitUntilExit()
                    if proc.terminationStatus == 0 {
                        try? fm.removeItem(at: destDir.appendingPathComponent("__MACOSX"))
                        extractedDirs.append(destDir)
                    } else {
                        try? fm.removeItem(at: destDir)
                        lastError = L("Giải nén '\(fileName)' không thành công", "Failed to extract '\(fileName)'")
                    }
                } else {
                    try? fm.removeItem(at: destDir)
                    lastError = L("Không thể khởi chạy trình giải nén", "Unable to launch extractor")
                }
            }

            let finalDirs = extractedDirs
            let finalErr = lastError
            await MainActor.run {
                if !finalDirs.isEmpty {
                    GoogleDriveIndexService.shared.rebuildAllCaches()
                    FloatingToastController.shared.showSuccess(
                        title: finalDirs.count == 1
                            ? L("Đã giải nén vào '\(finalDirs[0].lastPathComponent)'", "Extracted into '\(finalDirs[0].lastPathComponent)'")
                            : L("Đã giải nén \(finalDirs.count) gói lưu trữ", "Extracted \(finalDirs.count) archives"),
                        subtitle: finalDirs[0].deletingLastPathComponent().lastPathComponent,
                        symbol: "archivebox.fill"
                    )
                    NSWorkspace.shared.activateFileViewerSelecting(finalDirs)
                } else {
                    FloatingToastController.shared.showError(
                        title: L("Giải nén thất bại", "Extraction failed"),
                        subtitle: finalErr ?? L("Tệp nén bị lỗi hoặc không được hỗ trợ", "Archive is damaged or unsupported")
                    )
                }
            }
        }
    }

    private func copyString(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    private func rawString(from target: ActionTarget) -> String {
        switch target {
        case .text(let s, _): return s
        case .url(let u, _): return u.absoluteString
        case .files(let u, _): return u.map(\.path).joined(separator: "\n")
        }
    }

    private func postCommandV() {
        guard AXIsProcessTrusted() else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
