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

        case "ai.chunk_md":
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: "Đang chia nhỏ tài liệu theo Chương/Mục (H1/H2)...",
                subtitle: target.primaryTitle
            )
            Task { @MainActor in
                do {
                    let res = try await MarkdownConverterService.shared.convertAndSplitIntoAIChunks(urls: urls)
                    if let first = res.first {
                        let cCount = res.reduce(0) { $0 + $1.chunkCount }
                        FloatingToastController.shared.showSuccess(
                            title: "Đã tách thành \(cCount) phần trong _Chunks/",
                            subtitle: "Kèm chỉ mục 00_INDEX.md • Tổng ~\(first.estimatedTokens.formatted()) tokens",
                            symbol: "rectangle.split.3x1.fill"
                        )
                        if let dir = first.chunkDirectoryURL {
                            NSWorkspace.shared.activateFileViewerSelecting([dir])
                        }
                    }
                } catch {
                    FloatingToastController.shared.showError(
                        title: "Lỗi chia nhỏ tài liệu",
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
                title: "Đang trích xuất nội dung Web sang Markdown...",
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
                        title: saveDesktop ? "Đã lưu .md ra Desktop & Copy vào Clipboard" : "Đã Copy Markdown trang Web vào Clipboard",
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
                        title: "Không đọc được nội dung trang Web",
                        subtitle: error.localizedDescription
                    )
                }
            }

        case "ai.preview_md":
            guard let first = urls.first else { return }
            FloatingToastController.shared.showProgress(
                title: "Đang chuyển sang Markdown...",
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
                            title: "Đã tối ưu Markdown cho AI (~\(item.estimatedTokens) tokens)",
                            subtitle: AppSettings.shared.autoCopyMarkdownToClipboard ? "Đã chép sẵn vào Clipboard" : item.engineUsed,
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
                        title: "Lỗi Convert sang Markdown",
                        subtitle: error.localizedDescription
                    )
                }
            }

        case "ai.convert_for_ai":
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: "Đang đóng gói thư mục _AI/...",
                subtitle: target.primaryTitle
            )
            Task { @MainActor in
                do {
                    let pkgDirs = try await MarkdownConverterService.shared.convertFilesForAIPackage(urls: urls)
                    if let firstPkg = pkgDirs.first {
                        FloatingToastController.shared.showSuccess(
                            title: "Đã tạo gói AI Package thành công",
                            subtitle: pkgDirs.count == 1 ? firstPkg.lastPathComponent : "Đã tạo \(pkgDirs.count) thư mục _AI/",
                            symbol: "sparkles.rectangle.stack.fill"
                        )
                        if modifierFlags.contains(.command) {
                            NSWorkspace.shared.activateFileViewerSelecting(pkgDirs)
                        }
                    }
                } catch {
                    FloatingToastController.shared.showError(
                        title: "Lỗi tạo gói Convert for AI",
                        subtitle: error.localizedDescription
                    )
                }
            }

        case "ai.merge_folder_md":
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: "Đang gộp tài liệu thành 1 file AI Context (.md)...",
                subtitle: target.primaryTitle
            )
            Task { @MainActor in
                do {
                    let merged = try await MarkdownConverterService.shared.mergeIntoSingleContextMarkdown(urls: urls, copyToClipboard: true)
                    let outName = merged.savedMarkdownURL?.lastPathComponent ?? "AI_Context.md"
                    FloatingToastController.shared.showSuccess(
                        title: "Đã tạo \(outName) & Copy vào Clipboard!",
                        subtitle: "Tổng ước tính ~\(merged.estimatedTokens.formatted()) tokens cho LLM",
                        symbol: "square.stack.3d.up.badge.a.fill"
                    )
                } catch {
                    FloatingToastController.shared.showError(
                        title: "Không thể gộp tài liệu",
                        subtitle: error.localizedDescription
                    )
                }
            }

        case "ai.convert_pdf":
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: "Đang chuyển sang PDF...",
                subtitle: target.primaryTitle
            )
            Task { @MainActor in
                do {
                    let pdfs = try await MarkdownConverterService.shared.convertFilesToPDF(urls: urls)
                    if let first = pdfs.first {
                        FloatingToastController.shared.showSuccess(
                            title: "Đã xuất PDF thành công",
                            subtitle: pdfs.count == 1 ? first.lastPathComponent : "Đã xuất \(pdfs.count) tệp PDF",
                            symbol: "doc.richtext.fill"
                        )
                    }
                } catch {
                    FloatingToastController.shared.showError(
                        title: "Lỗi chuyển sang PDF",
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
                            title: "Không lấy được liên kết Google Drive",
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
                            title: "Đã chép liên kết chia sẻ Google Drive",
                            subtitle: name,
                            symbol: "link"
                        )
                    } else {
                        FloatingToastController.shared.showError(
                            title: "Không tìm thấy ID Google Drive",
                            subtitle: "Tệp có thể chưa được đồng bộ lên đám mây"
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
                            title: "Không mở được trang chia sẻ",
                            subtitle: name
                        )
                    }
                }
            }

        case "gdrive.offline":
            LauncherPanelController.shared.hide()
            FloatingToastController.shared.showProgress(
                title: "Đang kích hoạt tải Offline...",
                subtitle: target.primaryTitle
            )
            Task.detached(priority: .userInitiated) {
                let count = GoogleDriveIndexService.triggerOfflineDownload(for: urls)
                await MainActor.run {
                    FloatingToastController.shared.showSuccess(
                        title: "Đã kích hoạt chế độ Offline",
                        subtitle: "Đã đồng bộ \(count) tệp về máy cục bộ",
                        symbol: "arrow.down.circle.fill"
                    )
                }
            }

        // MARK: - 3. File System Actions
        case "file.open":
            LauncherPanelController.shared.hide()
            for u in urls {
                NSWorkspace.shared.open(u)
            }

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

        case "file.quicklook":
            QuickLookCoordinator.shared.toggleQuickLook(for: urls)

        case "file.get_info":
            LauncherPanelController.shared.hide()
            openFinderGetInfo(for: urls)

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

        // MARK: - 4. Clipboard & Buffer
        case "clip.copy_path":
            LauncherPanelController.shared.hide()
            let paths = urls.map(\.path).joined(separator: "\n")
            copyString(paths)
            FloatingToastController.shared.showSuccess(
                title: "Đã chép đường dẫn vào Clipboard",
                subtitle: urls.first?.path ?? "",
                symbol: "link"
            )

        case "clip.copy_file":
            LauncherPanelController.shared.hide()
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects(urls as [NSURL])
            FloatingToastController.shared.showSuccess(
                title: "Đã chép \(urls.count) tệp vào Clipboard",
                subtitle: "Nhấn ⌘V ở bất kỳ đâu để dán tệp",
                symbol: "doc.on.clipboard"
            )

        case "clip.add_buffer":
            FileBufferService.shared.addAll(urls)
            viewModel.returnToSearchMode()
            FloatingToastController.shared.showSuccess(
                title: "Đã thêm vào File Buffer (\(FileBufferService.shared.items.count) mục)",
                subtitle: "Nhấn ⌥→ để thực hiện Universal Action hàng loạt",
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
                title: "Đã mở Finder & Copy từ khóa tìm kiếm",
                subtitle: "Nhấn ⌘F rồi ⌘V trong Finder để tìm '\(q)'",
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
                            title: "Đã chuyển \(finalTrashed) mục vào Thùng rác",
                            subtitle: primaryLabel,
                            symbol: "trash.fill"
                        )
                    } else {
                        FloatingToastController.shared.showError(
                            title: "Không thể chuyển vào Thùng rác",
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
                    title: "Đã chuẩn hóa Markdown cho AI (~\(tok) tokens)",
                    subtitle: "Đã lưu vào Clipboard sẵn sàng dán (⌘V)",
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
                    title: "Đã sao chép tên miền",
                    subtitle: host,
                    symbol: "network"
                )
            }

        case "text.copy_plain":
            LauncherPanelController.shared.hide()
            let plain = rawString(from: target)
            copyString(plain)
            FloatingToastController.shared.showSuccess(
                title: "Đã sao chép dạng Plain Text",
                subtitle: "\(plain.count) ký tự",
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
            FloatingToastController.shared.showSuccess(title: "Đã chuyển thành IN HOA", subtitle: String(transformed.prefix(50)))

        case "text.case_lower":
            LauncherPanelController.shared.hide()
            let transformed = rawString(from: target).lowercased()
            copyString(transformed)
            FloatingToastController.shared.showSuccess(title: "Đã chuyển thành chữ thường", subtitle: String(transformed.prefix(50)))

        case "text.case_title":
            LauncherPanelController.shared.hide()
            let transformed = rawString(from: target).localizedCapitalized
            copyString(transformed)
            FloatingToastController.shared.showSuccess(title: "Đã chuyển thành Title Case", subtitle: String(transformed.prefix(50)))

        case "text.extract_urls":
            LauncherPanelController.shared.hide()
            let input = rawString(from: target)
            let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            let matches = detector?.matches(in: input, options: [], range: NSRange(input.startIndex..., in: input)) ?? []
            let extracted = matches.compactMap { $0.url?.absoluteString }.joined(separator: "\n")
            if extracted.isEmpty {
                FloatingToastController.shared.showError(title: "Không tìm thấy URL nào", subtitle: "Đoạn văn bản không chứa liên kết web")
            } else {
                copyString(extracted)
                FloatingToastController.shared.showSuccess(title: "Đã tách \(matches.count) URL vào Clipboard", subtitle: extracted)
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
            title: "Đang thực hiện \(operation.rawValue)",
            subtitle: "Đích: \(destinationFolder.lastPathComponent)"
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
                        title: "Đã hoàn tất \(operation.rawValue) (\(finalSuccess) mục)",
                        subtitle: "Đích: \(destinationFolder.lastPathComponent)"
                    )
                    if revealInFinder && !finalProduced.isEmpty {
                        NSWorkspace.shared.activateFileViewerSelecting(finalProduced)
                    }
                } else if let finalError {
                    FloatingToastController.shared.showError(
                        title: "Thao tác tệp thất bại",
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
        let titleLabel = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) tệp tài liệu"
        FloatingToastController.shared.showProgress(
            title: forceOCR ? "Đang OCR Tiếng Việt sang Markdown..." : "Đang Convert sang Markdown cho AI...",
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
                        title: copyClipboard ? "Đã gộp sang \(outName) & Copy vào Clipboard" : "Đã xuất \(outName)",
                        subtitle: "Tổng ước tính ~\(merged.estimatedTokens.formatted()) tokens cho AI",
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
                    mainMsg = "Đã Copy cấu trúc XML <documents> vào Clipboard"
                } else if saveBeside && copyClipboard {
                    let mdName = results.first?.savedMarkdownURL?.lastPathComponent ?? ".md"
                    mainMsg = results.count == 1
                        ? "Đã tạo \(mdName) & Copy vào Clipboard"
                        : "Đã tạo \(results.count) file .md & Copy vào Clipboard"
                } else if copyClipboard {
                    mainMsg = "Đã Copy Markdown vào Clipboard (Sẵn sàng ⌘V)"
                } else {
                    mainMsg = "Đã xuất \(results.count) file Markdown"
                }

                let chunkNote = totalChunks > 0 ? " • Tách \(totalChunks) phần _Chunks/" : ""
                FloatingToastController.shared.showSuccess(
                    title: mainMsg,
                    subtitle: "\(engine) • ~\(totalTokens.formatted()) tokens\(chunkNote)",
                    symbol: "doc.text.magnifyingglass"
                )
            } catch {
                FloatingToastController.shared.showError(
                    title: "Convert sang Markdown thất bại",
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
            let label = lastStateHidden ? "Đã ẩn (chflags hidden)" : "Đã bỏ ẩn (chflags nohidden)"
            FloatingToastController.shared.showSuccess(
                title: "\(label) cho \(successCount) mục",
                subtitle: urls.first?.lastPathComponent ?? "",
                symbol: lastStateHidden ? "eye.slash.fill" : "eye.circle.fill"
            )
        } else {
            FloatingToastController.shared.showError(title: "Không thể đổi cờ ẩn/hiện", subtitle: "Kiểm tra quyền truy cập tệp")
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
