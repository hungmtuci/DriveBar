import Foundation
import AppKit
import PDFKit
import Vision

struct MarkdownConversionResult: Sendable {
    let sourceURL: URL
    let savedMarkdownURL: URL?
    let chunkDirectoryURL: URL?
    let chunkCount: Int
    let markdown: String
    let estimatedTokens: Int
    let engineUsed: String

    init(
        sourceURL: URL,
        savedMarkdownURL: URL?,
        chunkDirectoryURL: URL? = nil,
        chunkCount: Int = 0,
        markdown: String,
        estimatedTokens: Int,
        engineUsed: String
    ) {
        self.sourceURL = sourceURL
        self.savedMarkdownURL = savedMarkdownURL
        self.chunkDirectoryURL = chunkDirectoryURL
        self.chunkCount = chunkCount
        self.markdown = markdown
        self.estimatedTokens = estimatedTokens
        self.engineUsed = engineUsed
    }
}

enum MarkdownConversionError: LocalizedError {
    case fileNotFound(String)
    case unsupportedFormat(String)
    case libreOfficeMissing
    case conversionFailed(String)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let name):
            return "Không tìm thấy tệp: \(name)"
        case .unsupportedFormat(let ext):
            return "Định dạng '\(ext)' chưa được hỗ trợ chuyển đổi."
        case .libreOfficeMissing:
            return "Chưa cài đặt LibreOffice (/Applications/LibreOffice.app) để chuyển định dạng này sang PDF."
        case .conversionFailed(let detail):
            return detail
        }
    }
}

@MainActor
final class MarkdownConverterService: ObservableObject {
    static let shared = MarkdownConverterService()

    @Published private(set) var isConverting: Bool = false

    nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "webp", "bmp"
    ]
    nonisolated static let markItDownExtensions: Set<String> = [
        "docx", "pptx", "xlsx", "html", "htm", "csv", "json", "xml"
    ]
    nonisolated static let libreOfficeLegacyExtensions: Set<String> = [
        "doc", "rtf", "xls", "ppt", "odt", "ods", "odp"
    ]
    nonisolated static let codeAndPlainExtensions: Set<String> = [
        "txt", "md", "tsv", "yaml", "yml", "py", "swift", "js", "ts", "tsx", "jsx",
        "sh", "zsh", "sql", "css", "c", "cpp", "h", "java", "go", "rs", "php", "rb", "ini", "toml", "log"
    ]
    nonisolated static let googleWorkspaceExtensions: Set<String> = [
        "gdoc", "gsheet", "gslides"
    ]

    private init() {}

    // MARK: - Engine Status Diagnostics

    nonisolated static func findLibreOffice() -> String? {
        let candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return nil
    }

    nonisolated static func findToolkitPython(toolkitDir: String) -> String? {
        let py = "\(toolkitDir)/.venv/bin/python3"
        return FileManager.default.isExecutableFile(atPath: py) ? py : nil
    }

    func engineDiagnostics() -> (toolkitReady: Bool, libreOfficeReady: Bool, pythonPath: String?, sofficePath: String?) {
        let py = Self.findToolkitPython(toolkitDir: AppSettings.shared.aiToolkitPath)
        let lo = Self.findLibreOffice()
        return (py != nil, lo != nil, py, lo)
    }

    nonisolated static func routeDescription(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let cloudTag = GoogleDriveIndexService.isCloudDatalessFile(url) ? "☁️ Online-Only → " : ""
        if googleWorkspaceExtensions.contains(ext) {
            return "\(cloudTag)Google Workspace Cloud Export → .md"
        } else if ext == "pdf" {
            return "\(cloudTag)PyMuPDF4LLM / PDFKit + Vision OCR (vi-VN) → .md"
        } else if markItDownExtensions.contains(ext) {
            return "\(cloudTag)MarkItDown / Native AST → .md"
        } else if libreOfficeLegacyExtensions.contains(ext) {
            return "\(cloudTag)LibreOffice / textutil → PyMuPDF4LLM → .md"
        } else if imageExtensions.contains(ext) {
            return "\(cloudTag)Apple Vision Neural OCR (vi-VN + en-US) → .md"
        } else {
            return "\(cloudTag)UTF-8 Text & Token Optimizer → .md"
        }
    }

    // MARK: - Primary API: Convert 1 or Multiple Files to Markdown

    func convertFilesToMarkdown(
        urls: [URL],
        saveBesideSource: Bool,
        copyToClipboard: Bool,
        forceOCR: Bool = false,
        forceXMLWrap: Bool = false
    ) async throws -> [MarkdownConversionResult] {
        isConverting = true
        defer { isConverting = false }

        let toolkitDir = AppSettings.shared.aiToolkitPath
        let enableOCR = forceOCR || AppSettings.shared.enableVisionOCR
        let optimizeTokens = AppSettings.shared.optimizeMarkdownTokens
        let includeMeta = AppSettings.shared.includeMetadataHeader
        let wrapXML = forceXMLWrap || (urls.count > 1 && AppSettings.shared.wrapMultiFilesInXMLTags)
        let autoChunk = AppSettings.shared.enableSmartChunking
        let chunkMaxTokens = AppSettings.shared.smartChunkMaxTokens

        var outputs: [MarkdownConversionResult] = []

        for url in urls {
            await ensureCloudFileMaterializedWithFeedback(url)
            let res = try await Task.detached(priority: .userInitiated) {
                try Self.convertSingleFileWorker(
                    url: url,
                    toolkitDir: toolkitDir,
                    saveBesideSource: saveBesideSource,
                    enableOCR: enableOCR,
                    forceOCR: forceOCR,
                    optimizeTokens: optimizeTokens,
                    includeMetadataHeader: includeMeta,
                    autoChunkIfExceedsTokens: autoChunk ? chunkMaxTokens : nil
                )
            }.value
            outputs.append(res)
        }

        if copyToClipboard, !outputs.isEmpty {
            let combined: String
            if wrapXML {
                combined = Self.wrapDocumentsInXML(outputs.map {
                    (source: $0.sourceURL.lastPathComponent, tokens: $0.estimatedTokens, markdown: $0.markdown)
                })
            } else if outputs.count == 1 {
                combined = outputs[0].markdown
            } else {
                combined = outputs.map { item in
                    "<!-- FILE: \(item.sourceURL.lastPathComponent) -->\n\(item.markdown)"
                }.joined(separator: "\n\n---\n\n")
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(combined, forType: .string)
        }

        return outputs
    }

    // MARK: - Explicit Smart Chunking Action (`ai.chunk_md`)

    func convertAndSplitIntoAIChunks(urls: [URL], maxTokensPerChunk: Int? = nil) async throws -> [MarkdownConversionResult] {
        isConverting = true
        defer { isConverting = false }

        let toolkitDir = AppSettings.shared.aiToolkitPath
        let enableOCR = AppSettings.shared.enableVisionOCR
        let optimizeTokens = AppSettings.shared.optimizeMarkdownTokens
        let limit = maxTokensPerChunk ?? AppSettings.shared.smartChunkMaxTokens

        var results: [MarkdownConversionResult] = []
        for url in urls {
            await ensureCloudFileMaterializedWithFeedback(url)
            let item = try await Task.detached(priority: .userInitiated) { () -> MarkdownConversionResult in
                let single = try Self.convertSingleFileWorker(
                    url: url,
                    toolkitDir: toolkitDir,
                    saveBesideSource: true,
                    enableOCR: enableOCR,
                    forceOCR: false,
                    optimizeTokens: optimizeTokens,
                    includeMetadataHeader: false,
                    autoChunkIfExceedsTokens: nil
                )
                let stem = Self.safeNFCStem(for: url)
                let parentDir = url.deletingLastPathComponent()
                // Force chunking at a practical threshold even for medium docs when explicitly invoked
                let effectiveMax = min(limit, max(2500, single.estimatedTokens / 2))
                let (chunkDir, count) = try Self.writeSmartChunks(
                    markdown: single.markdown,
                    stem: stem,
                    sourceFilename: url.lastPathComponent,
                    parentDir: parentDir,
                    maxTokensPerChunk: effectiveMax
                )
                return MarkdownConversionResult(
                    sourceURL: url,
                    savedMarkdownURL: single.savedMarkdownURL,
                    chunkDirectoryURL: chunkDir,
                    chunkCount: count,
                    markdown: single.markdown,
                    estimatedTokens: single.estimatedTokens,
                    engineUsed: "\(single.engineUsed) + Smart Chunker"
                )
            }.value
            results.append(item)
        }
        return results
    }

    // MARK: - Web URL -> Clean AI Markdown (`ai.url_to_md`)

    func convertWebURLToMarkdown(
        url: URL,
        saveToDownloadsOrDesktop: Bool = false,
        copyToClipboard: Bool = true
    ) async throws -> MarkdownConversionResult {
        isConverting = true
        defer { isConverting = false }

        let optimizeTokens = AppSettings.shared.optimizeMarkdownTokens
        let includeMeta = AppSettings.shared.includeMetadataHeader

        let res = try await Task.detached(priority: .userInitiated) { () -> MarkdownConversionResult in
            let (rawMD, title, engine) = try Self.fetchWebURLAsMarkdownWorker(url: url)
            var finalMD = rawMD.precomposedStringWithCanonicalMapping
            let trimmed = finalMD.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.hasPrefix("#") {
                finalMD = "# \(title)\n\n> Nguồn: \(url.absoluteString)\n\n\(trimmed)"
            } else {
                finalMD = trimmed
            }
            if optimizeTokens {
                finalMD = Self.optimizeMarkdownText(finalMD)
            }
            if includeMeta {
                let meta = """
                ---
                source_url: "\(url.absoluteString)"
                converted_at: "\(Self.isoTimestamp())"
                engine: "\(engine)"
                ---

                """
                finalMD = meta + finalMD
            }

            var savedFile: URL?
            if saveToDownloadsOrDesktop {
                let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop")
                let safeName = Self.slugifyFilename(title)
                let outURL = desktop.appendingPathComponent("\(safeName).md")
                try? finalMD.write(to: outURL, atomically: true, encoding: .utf8)
                savedFile = outURL
            }

            return MarkdownConversionResult(
                sourceURL: url,
                savedMarkdownURL: savedFile,
                markdown: finalMD,
                estimatedTokens: Self.estimateTokens(finalMD),
                engineUsed: engine
            )
        }.value

        if copyToClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(res.markdown, forType: .string)
        }

        return res
    }

    // MARK: - Cloud Online-Only Materialization with Toast Progress

    private func ensureCloudFileMaterializedWithFeedback(_ url: URL) async {
        let ext = url.pathExtension.lowercased()
        guard !Self.googleWorkspaceExtensions.contains(ext) else { return }
        guard GoogleDriveIndexService.isCloudDatalessFile(url) else { return }

        FloatingToastController.shared.showProgress(
            title: "☁️ Đang tải từ Google Drive về máy...",
            subtitle: "\(url.lastPathComponent) (Tệp Online-only)"
        )

        await Task.detached(priority: .userInitiated) {
            Self.materializeCloudFileBlocking(url)
        }.value

        FloatingToastController.shared.showProgress(
            title: "Đang chuyển đổi sang Markdown...",
            subtitle: url.lastPathComponent
        )
    }

    // MARK: - Convert for AI (_AI/ Full Package)

    func convertFilesForAIPackage(urls: [URL]) async throws -> [URL] {
        isConverting = true
        defer { isConverting = false }

        let toolkitDir = AppSettings.shared.aiToolkitPath
        let enableOCR = AppSettings.shared.enableVisionOCR
        let optimizeTokens = AppSettings.shared.optimizeMarkdownTokens

        var createdDirs: [URL] = []

        for url in urls {
            await ensureCloudFileMaterializedWithFeedback(url)
            let pkgDir = try await Task.detached(priority: .userInitiated) {
                try Self.buildAIPackageWorker(
                    url: url,
                    toolkitDir: toolkitDir,
                    enableOCR: enableOCR,
                    optimizeTokens: optimizeTokens
                )
            }.value
            createdDirs.append(pkgDir)
        }

        return createdDirs
    }

    // MARK: - Merge Multiple Files / Folder into 1 Unified AI Context .md

    func mergeIntoSingleContextMarkdown(urls: [URL], copyToClipboard: Bool = true) async throws -> MarkdownConversionResult {
        isConverting = true
        defer { isConverting = false }

        let toolkitDir = AppSettings.shared.aiToolkitPath
        let enableOCR = AppSettings.shared.enableVisionOCR
        let useXMLTags = AppSettings.shared.wrapMultiFilesInXMLTags

        let expandedFiles = await Task.detached(priority: .userInitiated) {
            Self.collectConvertibleFiles(from: urls)
        }.value

        guard !expandedFiles.isEmpty else {
            throw MarkdownConversionError.conversionFailed("Không tìm thấy tệp tài liệu hợp lệ để gộp.")
        }

        for f in expandedFiles {
            await ensureCloudFileMaterializedWithFeedback(f)
        }

        let result = try await Task.detached(priority: .userInitiated) { () -> MarkdownConversionResult in
            var docPayloads: [(source: String, tokens: Int, markdown: String)] = []
            var toc: [String] = []
            var engines = Set<String>()

            for (idx, fileURL) in expandedFiles.enumerated() {
                if let single = try? Self.convertSingleFileWorker(
                    url: fileURL,
                    toolkitDir: toolkitDir,
                    saveBesideSource: false,
                    enableOCR: enableOCR,
                    forceOCR: false,
                    optimizeTokens: true,
                    includeMetadataHeader: false,
                    autoChunkIfExceedsTokens: nil
                ) {
                    engines.insert(single.engineUsed)
                    toc.append("- [\(idx + 1). \(fileURL.lastPathComponent)] (`~\(single.estimatedTokens) tokens`)")
                    docPayloads.append((fileURL.lastPathComponent, single.estimatedTokens, single.markdown))
                }
            }

            guard !docPayloads.isEmpty else {
                throw MarkdownConversionError.conversionFailed("Không trích xuất được nội dung từ các tệp đã chọn.")
            }

            let first = urls[0]
            let baseName = Self.safeNFCStem(for: first)
            let outputDir = first.deletingLastPathComponent()
            let outURL = outputDir.appendingPathComponent("\(baseName)_AI_Context.md")

            let header = """
            # Gói Ngữ Cảnh Tài Liệu AI: \(baseName)

            - **Số lượng tài liệu:** \(docPayloads.count)
            - **Định dạng cấu trúc:** \(useXMLTags ? "Claude / Gemini XML `<documents>`" : "Markdown Sections")
            - **Thời gian trích xuất:** \(Self.isoTimestamp())

            ## Mục lục tài liệu
            \(toc.joined(separator: "\n"))

            ---

            """

            let body: String
            if useXMLTags {
                body = Self.wrapDocumentsInXML(docPayloads)
            } else {
                body = docPayloads.enumerated().map { idx, item in
                    "## Tài liệu [\(idx + 1)/\(docPayloads.count)]: `\(item.source)`\n\n\(item.markdown)"
                }.joined(separator: "\n\n---\n\n")
            }

            let fullMD = Self.optimizeMarkdownText(header + body)
            try fullMD.write(to: outURL, atomically: true, encoding: .utf8)

            let tokens = Self.estimateTokens(fullMD)
            return MarkdownConversionResult(
                sourceURL: first,
                savedMarkdownURL: outURL,
                markdown: fullMD,
                estimatedTokens: tokens,
                engineUsed: engines.sorted().joined(separator: " + ")
            )
        }.value

        if copyToClipboard {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(result.markdown, forType: .string)
        }

        return result
    }

    // MARK: - Convert to PDF

    func convertFilesToPDF(urls: [URL]) async throws -> [URL] {
        isConverting = true
        defer { isConverting = false }

        for u in urls {
            await ensureCloudFileMaterializedWithFeedback(u)
        }

        return try await Task.detached(priority: .userInitiated) {
            var created: [URL] = []
            for url in urls {
                Self.materializeCloudFileBlocking(url)
                let ext = url.pathExtension.lowercased()
                if ext == "pdf" {
                    created.append(url)
                    continue
                }
                let outDir = url.deletingLastPathComponent()
                let stem = Self.safeNFCStem(for: url)
                let targetPDF = outDir.appendingPathComponent("\(stem).pdf")

                if Self.imageExtensions.contains(ext), let img = NSImage(contentsOf: url) {
                    let pdfDoc = PDFDocument()
                    if let page = PDFPage(image: img) {
                        pdfDoc.insert(page, at: 0)
                        pdfDoc.write(to: targetPDF)
                        created.append(targetPDF)
                        continue
                    }
                }

                guard let soffice = Self.findLibreOffice() else {
                    throw MarkdownConversionError.libreOfficeMissing
                }
                let produced = try Self.runLibreOfficeToPDF(soffice: soffice, inputURL: url, outputDir: outDir)
                created.append(produced)
            }
            return created
        }.value
    }

    // MARK: - Core Background Worker

    private nonisolated static func convertSingleFileWorker(
        url: URL,
        toolkitDir: String,
        saveBesideSource: Bool,
        enableOCR: Bool,
        forceOCR: Bool,
        optimizeTokens: Bool,
        includeMetadataHeader: Bool,
        autoChunkIfExceedsTokens: Int?
    ) throws -> MarkdownConversionResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MarkdownConversionError.fileNotFound(url.lastPathComponent)
        }

        let ext = url.pathExtension.lowercased()
        if !googleWorkspaceExtensions.contains(ext) {
            materializeCloudFileBlocking(url)
        }

        let stem = safeNFCStem(for: url)
        var rawMarkdown = ""
        var engineName = "Native Swift"

        // 1. Google Workspace Cloud Shortcut files (.gdoc, .gsheet, .gslides)
        if googleWorkspaceExtensions.contains(ext) {
            let exported = exportGoogleWorkspaceFile(url: url, ext: ext, stem: stem)
            rawMarkdown = exported.markdown
            engineName = exported.engine
        }
        // 2. Image files -> Apple Vision Neural OCR (vi-VN + en-US)
        else if imageExtensions.contains(ext) {
            rawMarkdown = try performVisionOCROnImage(url: url)
            engineName = "Apple Vision OCR (vi-VN)"
        }
        // 3. Forced OCR on PDF
        else if forceOCR && ext == "pdf" {
            rawMarkdown = try performPDFExtraction(url: url, enableVisionOCR: true, forceAllPagesOCR: true)
            engineName = "PDFKit + Vision OCR (vi-VN)"
        }
        // 4. Plain Text / Code / Markdown
        else if ext == "md" || ext == "txt" || codeAndPlainExtensions.contains(ext) {
            let content = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
                ?? ""
            if ext == "md" || ext == "txt" {
                rawMarkdown = content
            } else {
                rawMarkdown = "```\(ext)\n\(content)\n```"
            }
            engineName = "UTF-8 Direct"
        }
        // 5. PDF Documents -> PyMuPDF4LLM + Automatic Vision OCR Rescue for scanned pages
        else if ext == "pdf" {
            if let py = findToolkitPython(toolkitDir: toolkitDir),
               let pyMD = try? runPythonPyMuPDF(pythonPath: py, pdfURL: url),
               hasMeaningfulText(pyMD, minChars: 60) {
                rawMarkdown = pyMD
                engineName = "PyMuPDF4LLM"
            } else {
                rawMarkdown = try performPDFExtraction(url: url, enableVisionOCR: enableOCR, forceAllPagesOCR: false)
                engineName = enableOCR ? "PDFKit + Vision OCR" : "PDFKit"
            }
        }
        // 6. Modern Office & Structured Docs (.docx, .pptx, .xlsx, .html, .csv...)
        else if markItDownExtensions.contains(ext) {
            if let py = findToolkitPython(toolkitDir: toolkitDir),
               let mdText = try? runPythonMarkItDown(pythonPath: py, fileURL: url),
               !mdText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawMarkdown = mdText
                engineName = "MarkItDown"
            } else {
                rawMarkdown = try fallbackNativeStructuredConversion(url: url, ext: ext)
                engineName = "Native Swift AST"
            }
        }
        // 7. Legacy Office (.doc, .xls, .ppt, .rtf, .odt, .ods, .odp)
        else if libreOfficeLegacyExtensions.contains(ext) {
            if let soffice = findLibreOffice() {
                let tmpDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("drivebar_lo_\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: tmpDir) }
                if let pdfURL = try? runLibreOfficeToPDF(soffice: soffice, inputURL: url, outputDir: tmpDir) {
                    if let py = findToolkitPython(toolkitDir: toolkitDir),
                       let pyMD = try? runPythonPyMuPDF(pythonPath: py, pdfURL: pdfURL),
                       hasMeaningfulText(pyMD, minChars: 40) {
                        rawMarkdown = pyMD
                        engineName = "LibreOffice + PyMuPDF4LLM"
                    } else {
                        rawMarkdown = try performPDFExtraction(url: pdfURL, enableVisionOCR: enableOCR, forceAllPagesOCR: false)
                        engineName = "LibreOffice + Vision OCR"
                    }
                }
            }

            if rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawMarkdown = try fallbackNativeStructuredConversion(url: url, ext: ext)
                engineName = "macOS textutil AST"
            }
        }
        // 8. Any other text-readable file fallback
        else {
            if let txt = try? String(contentsOf: url, encoding: .utf8), !txt.isEmpty {
                rawMarkdown = txt
                engineName = "UTF-8 Fallback"
            } else {
                throw MarkdownConversionError.unsupportedFormat(".\(ext)")
            }
        }

        // Ensure heading & NFC normalization
        var finalMD = rawMarkdown.precomposedStringWithCanonicalMapping
        let trimmedLead = finalMD.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLead.hasPrefix("#") {
            finalMD = "# \(stem)\n\n\(trimmedLead)"
        } else {
            finalMD = trimmedLead
        }

        if optimizeTokens {
            finalMD = optimizeMarkdownText(finalMD)
        }

        if includeMetadataHeader {
            let meta = """
            ---
            source: "\(url.lastPathComponent)"
            format: ".\(ext)"
            converted_at: "\(isoTimestamp())"
            engine: "\(engineName)"
            ---

            """
            finalMD = meta + finalMD
        }

        let estTokens = estimateTokens(finalMD)
        var savedURL: URL?
        var createdChunkDir: URL?
        var createdChunkCount = 0

        if saveBesideSource {
            let parentDir = url.deletingLastPathComponent()
            let targetURL = parentDir.appendingPathComponent("\(stem).md")
            try finalMD.write(to: targetURL, atomically: true, encoding: .utf8)
            savedURL = targetURL

            if let threshold = autoChunkIfExceedsTokens, estTokens > threshold {
                if let (cDir, cCount) = try? writeSmartChunks(
                    markdown: finalMD,
                    stem: stem,
                    sourceFilename: url.lastPathComponent,
                    parentDir: parentDir,
                    maxTokensPerChunk: threshold
                ) {
                    createdChunkDir = cDir
                    createdChunkCount = cCount
                }
            }
        }

        return MarkdownConversionResult(
            sourceURL: url,
            savedMarkdownURL: savedURL,
            chunkDirectoryURL: createdChunkDir,
            chunkCount: createdChunkCount,
            markdown: finalMD,
            estimatedTokens: estTokens,
            engineUsed: engineName
        )
    }

    // MARK: - Direct Google Workspace (.gdoc / .gsheet / .gslides) Cloud Export

    private nonisolated static func exportGoogleWorkspaceFile(
        url: URL,
        ext: String,
        stem: String
    ) -> (markdown: String, engine: String) {
        guard let docID = GoogleDriveIndexService.extractGoogleDriveItemID(at: url.path) else {
            return ("# \(stem)\n\n> Không đọc được `doc_id` từ tệp Google Workspace `\(url.lastPathComponent)`.", "Google Workspace")
        }

        if ext == "gdoc" {
            let mdExport = "https://docs.google.com/document/d/\(docID)/export?format=md"
            if let text = fetchGoogleExportText(from: mdExport), hasMeaningfulText(text, minChars: 12) {
                return (text, "Google Docs Cloud Export (.md)")
            }
            let txtExport = "https://docs.google.com/document/d/\(docID)/export?format=txt"
            if let text = fetchGoogleExportText(from: txtExport), hasMeaningfulText(text, minChars: 12) {
                return ("# \(stem)\n\n\(text)", "Google Docs Cloud Export (.txt)")
            }
            return (
                """
                # \(stem)

                > **Lưu ý:** Tệp Google Docs (`.gdoc`) này đang khóa quyền truy cập riêng tư (yêu cầu phiên đăng nhập trình duyệt).
                - **Tải trực tiếp bản Markdown trên trình duyệt:** https://docs.google.com/document/d/\(docID)/export?format=md
                - **Mở chỉnh sửa trên Google Docs:** https://docs.google.com/document/d/\(docID)/edit
                """,
                "Google Docs Link"
            )
        } else if ext == "gsheet" {
            let csvExport = "https://docs.google.com/spreadsheets/d/\(docID)/export?format=csv"
            if let csvText = fetchGoogleExportText(from: csvExport), !csvText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let tableMD = convertRFC4180CSVToMarkdownTable(csvText)
                return ("# \(stem)\n\n\(tableMD)", "Google Sheets Cloud Export (CSV → Table)")
            }
            return (
                """
                # \(stem)

                > **Lưu ý:** Bảng tính Google Sheets (`.gsheet`) này yêu cầu xác thực trình duyệt để xuất dữ liệu trực tiếp.
                - **Tải trực tiếp CSV trên trình duyệt:** https://docs.google.com/spreadsheets/d/\(docID)/export?format=csv
                - **Mở trên Google Sheets:** https://docs.google.com/spreadsheets/d/\(docID)/edit
                """,
                "Google Sheets Link"
            )
        } else {
            let txtExport = "https://docs.google.com/presentation/d/\(docID)/export/txt"
            if let slideTxt = fetchGoogleExportText(from: txtExport), hasMeaningfulText(slideTxt, minChars: 12) {
                return ("# \(stem)\n\n\(slideTxt)", "Google Slides Cloud Export")
            }
            return (
                """
                # \(stem)

                > **Lưu ý:** Bản trình chiếu Google Slides (`.gslides`) này yêu cầu xác thực trình duyệt để xuất văn bản.
                - **Tải trực tiếp nội dung Slide:** https://docs.google.com/presentation/d/\(docID)/export/txt
                - **Mở trên Google Slides:** https://docs.google.com/presentation/d/\(docID)/edit
                """,
                "Google Slides Link"
            )
        }
    }

    private nonisolated static func fetchGoogleExportText(from urlString: String) -> String? {
        guard let reqURL = URL(string: urlString) else { return nil }
        var req = URLRequest(url: reqURL, timeoutInterval: 10)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) DriveBar/1.2", forHTTPHeaderField: "User-Agent")

        let sem = DispatchSemaphore(value: 0)
        var fetchedText: String?

        let task = URLSession.shared.dataTask(with: req) { data, response, _ in
            defer { sem.signal() }
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let finalHost = http.url?.host?.lowercased(),
                  !finalHost.contains("accounts.google.com"),
                  let data,
                  let str = String(data: data, encoding: .utf8) else {
                return
            }
            let lowerPrefix = String(str.prefix(300)).lowercased()
            if lowerPrefix.contains("<!doctype html") || lowerPrefix.contains("<html") {
                return
            }
            fetchedText = str
        }
        task.resume()
        _ = sem.wait(timeout: .now() + 11)
        return fetchedText
    }

    // MARK: - Web URL -> Clean AI Markdown Worker

    private nonisolated static func fetchWebURLAsMarkdownWorker(url: URL) throws -> (markdown: String, title: String, engine: String) {
        let abs = url.absoluteString
        let host = url.host?.lowercased() ?? ""

        // 1. Direct Google Docs / Sheets / Slides URLs
        if host.contains("docs.google.com"), let range = abs.range(of: "/d/") {
            let after = abs[range.upperBound...]
            if let docID = after.split(separator: "/").first.map(String.init), !docID.isEmpty {
                if abs.contains("/document/") {
                    if let md = fetchGoogleExportText(from: "https://docs.google.com/document/d/\(docID)/export?format=md") {
                        return (md, "Google Document (\(docID.prefix(8)))", "Google Docs Export")
                    }
                } else if abs.contains("/spreadsheets/") {
                    if let csv = fetchGoogleExportText(from: "https://docs.google.com/spreadsheets/d/\(docID)/export?format=csv") {
                        return (convertRFC4180CSVToMarkdownTable(csv), "Google Sheet (\(docID.prefix(8)))", "Google Sheets CSV → MD")
                    }
                } else if abs.contains("/presentation/") {
                    if let txt = fetchGoogleExportText(from: "https://docs.google.com/presentation/d/\(docID)/export/txt") {
                        return (txt, "Google Slides (\(docID.prefix(8)))", "Google Slides Export")
                    }
                }
            }
        }

        // 2. GitHub File Blob URL -> Raw File Content
        if host == "github.com" && abs.contains("/blob/") {
            let rawStr = abs
                .replacingOccurrences(of: "https://github.com/", with: "https://raw.githubusercontent.com/")
                .replacingOccurrences(of: "/blob/", with: "/")
            if let rawURL = URL(string: rawStr),
               let (rawData, code) = synchronousHTTPGet(url: rawURL, headers: [:], timeout: 10),
               (200...299).contains(code),
               let content = String(data: rawData, encoding: .utf8) {
                let fname = url.lastPathComponent
                let ext = url.pathExtension.lowercased()
                let md = (ext == "md" || ext.isEmpty) ? content : "# \(fname)\n\n```\(ext)\n\(content)\n```"
                return (md, fname, "GitHub Raw Reader")
            }
        }

        // 3. Tier A: Jina AI Clean Reader (if reachable, ultra-clean article extraction)
        if let jinaURL = URL(string: "https://r.jina.ai/\(abs)"),
           let (jData, jCode) = synchronousHTTPGet(
               url: jinaURL,
               headers: ["X-Return-Format": "markdown"],
               timeout: 7.5
           ),
           (200...299).contains(jCode),
           let jText = String(data: jData, encoding: .utf8),
           hasMeaningfulText(jText, minChars: 80) {
            let guessedTitle = extractFirstHeadingOrHost(from: jText, fallbackURL: url)
            return (jText, guessedTitle, "Jina AI Reader")
        }

        // 4. Tier B: 100% Native Swift Article DOM Cleaner (Offline / Corporate / Direct)
        guard let (htmlData, statusCode) = synchronousHTTPGet(url: url, headers: [:], timeout: 14),
              (200...399).contains(statusCode) else {
            throw MarkdownConversionError.conversionFailed("Không thể tải nội dung từ địa chỉ: \(abs)")
        }

        let html = String(data: htmlData, encoding: .utf8)
            ?? String(data: htmlData, encoding: .isoLatin1)
            ?? ""
        guard !html.isEmpty else {
            throw MarkdownConversionError.conversionFailed("Trang web trả về dữ liệu rỗng.")
        }

        let pageTitle = extractHTMLTitle(from: html) ?? (url.host ?? "Trang Web")
        let articleHTML = extractPrimaryArticleBody(from: html)
        let cleanedMD = richWebHTMLToMarkdown(articleHTML, baseURL: url)

        guard hasMeaningfulText(cleanedMD, minChars: 20) else {
            throw MarkdownConversionError.conversionFailed("Trang web sử dụng JavaScript động hoàn toàn hoặc chặn trình đọc tự động.")
        }

        return (cleanedMD, pageTitle, "Native Swift Web Reader")
    }

    private nonisolated static func synchronousHTTPGet(
        url: URL,
        headers: [String: String],
        timeout: TimeInterval
    ) -> (Data, Int)? {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, Int)?
        let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
            defer { sem.signal() }
            if let data, let http = resp as? HTTPURLResponse {
                result = (data, http.statusCode)
            }
        }
        task.resume()
        _ = sem.wait(timeout: .now() + timeout + 1.0)
        return result
    }

    private nonisolated static func extractHTMLTitle(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "(?is)<title[^>]*>(.*?)</title>"),
              let m = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let r = Range(m.range(at: 1), in: html) else {
            return nil
        }
        let raw = decodeHTMLEntities(String(html[r]))
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return raw.isEmpty ? nil : raw
    }

    private nonisolated static func extractPrimaryArticleBody(from html: String) -> String {
        var cleaned = html
        let noisePatterns = [
            "(?is)<head[^>]*>.*?</head>",
            "(?is)<script[^>]*>.*?</script>",
            "(?is)<style[^>]*>.*?</style>",
            "(?is)<noscript[^>]*>.*?</noscript>",
            "(?is)<svg[^>]*>.*?</svg>",
            "(?is)<iframe[^>]*>.*?</iframe>",
            "(?is)<nav[^>]*>.*?</nav>",
            "(?is)<footer[^>]*>.*?</footer>",
            "(?is)<aside[^>]*>.*?</aside>",
            "(?is)<!--.*?-->"
        ]
        for pat in noisePatterns {
            cleaned = cleaned.replacingOccurrences(of: pat, with: "", options: .regularExpression)
        }

        // Prefer <article> or <main> if substantial
        for tag in ["article", "main"] {
            if let rx = try? NSRegularExpression(pattern: "(?is)<\(tag)[^>]*>(.*?)</\(tag)>"),
               let m = rx.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
               let r = Range(m.range(at: 1), in: cleaned) {
                let candidate = String(cleaned[r])
                if candidate.count > 400 {
                    return candidate
                }
            }
        }
        return cleaned
    }

    private nonisolated static func richWebHTMLToMarkdown(_ html: String, baseURL: URL) -> String {
        var s = html

        // Pre/Code blocks
        if let preRx = try? NSRegularExpression(pattern: "(?is)<pre[^>]*>(.*?)</pre>") {
            for m in preRx.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let full = Range(m.range, in: s), let inner = Range(m.range(at: 1), in: s) else { continue }
                let codeRaw = String(s[inner]).replacingOccurrences(of: "(?is)<[^>]+>", with: "", options: .regularExpression)
                let decoded = decodeHTMLEntities(codeRaw).trimmingCharacters(in: .newlines)
                s.replaceSubrange(full, with: "\n\n```\n\(decoded)\n```\n\n")
            }
        }

        // Links <a href="...">text</a>
        if let linkRx = try? NSRegularExpression(pattern: "(?is)<a\\s+[^>]*href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>") {
            for m in linkRx.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
                guard let full = Range(m.range, in: s),
                      let hrefR = Range(m.range(at: 1), in: s),
                      let textR = Range(m.range(at: 2), in: s) else { continue }
                let rawHref = String(s[hrefR]).trimmingCharacters(in: .whitespacesAndNewlines)
                let label = decodeHTMLEntities(
                    String(s[textR]).replacingOccurrences(of: "(?is)<[^>]+>", with: "", options: .regularExpression)
                ).trimmingCharacters(in: .whitespacesAndNewlines)

                if label.isEmpty || rawHref.hasPrefix("javascript:") || rawHref.hasPrefix("#") {
                    s.replaceSubrange(full, with: label)
                } else {
                    let resolved = URL(string: rawHref, relativeTo: baseURL)?.absoluteURL.absoluteString ?? rawHref
                    s.replaceSubrange(full, with: "[\(label)](\(resolved))")
                }
            }
        }

        s = s.replacingOccurrences(of: "(?is)<code[^>]*>(.*?)</code>", with: "`$1`", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<blockquote[^>]*>(.*?)</blockquote>", with: "\n\n> $1\n\n", options: .regularExpression)

        return simpleHTMLToMarkdown(s)
    }

    private nonisolated static func extractFirstHeadingOrHost(from md: String, fallbackURL: URL) -> String {
        for line in md.components(separatedBy: .newlines).prefix(12) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Title: ") {
                return String(t.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            }
            if t.hasPrefix("# ") {
                return String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return fallbackURL.host ?? "Web Article"
    }

    private nonisolated static func slugifyFilename(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: "[/\\\\:?%*|\"<>]", with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let short = String(cleaned.prefix(70)).trimmingCharacters(in: .whitespacesAndNewlines)
        return short.isEmpty ? "Web_Article_AI" : short
    }

    // MARK: - XML `<documents>` Wrapper & Smart Chunking Engine

    nonisolated static func wrapDocumentsInXML(
        _ docs: [(source: String, tokens: Int, markdown: String)]
    ) -> String {
        var lines: [String] = ["<documents>"]
        for (idx, doc) in docs.enumerated() {
            let escapedName = doc.source.replacingOccurrences(of: "\"", with: "&quot;")
            lines.append("<document index=\"\(idx + 1)\" source=\"\(escapedName)\" estimated_tokens=\"\(doc.tokens)\">")
            lines.append(doc.markdown.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("</document>")
        }
        lines.append("</documents>\n")
        return lines.joined(separator: "\n")
    }

    nonisolated static func writeSmartChunks(
        markdown: String,
        stem: String,
        sourceFilename: String,
        parentDir: URL,
        maxTokensPerChunk: Int
    ) throws -> (URL, Int) {
        let chunks = splitMarkdownIntoSmartChunks(markdown, maxTokensPerChunk: max(1500, maxTokensPerChunk))
        let chunkDir = parentDir.appendingPathComponent("\(stem)_Chunks", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: chunkDir.path) {
            try? fm.removeItem(at: chunkDir)
        }
        try fm.createDirectory(at: chunkDir, withIntermediateDirectories: true)

        var indexRows: [String] = []
        for (i, chunk) in chunks.enumerated() {
            let numStr = String(format: "%02d", i + 1)
            let slug = slugifyFilename(chunk.heading)
            let fileName = "Part_\(numStr)_\(slug).md"
            let fileURL = chunkDir.appendingPathComponent(fileName)
            let header = """
            <!-- AI CHUNK [\(i + 1)/\(chunks.count)] • Source: \(sourceFilename) • ~\(chunk.tokens) tokens -->

            """
            try (header + chunk.body).write(to: fileURL, atomically: true, encoding: .utf8)
            indexRows.append("- **Phần \(numStr):** `\(fileName)` — *\(chunk.heading)* (`~\(chunk.tokens.formatted()) tokens`)")
        }

        let indexMD = """
        # Chỉ Mục Các Phần (Smart Chunks): \(stem)

        - **Tài liệu gốc:** `\(sourceFilename)`
        - **Tổng số phần đã chia:** `\(chunks.count)` phần (tối ưu ngữ cảnh đọc cho Claude / ChatGPT / Gemini)
        - **Ngưỡng mỗi phần:** `~\(maxTokensPerChunk.formatted()) tokens`

        ## Danh sách các phần
        \(indexRows.joined(separator: "\n"))
        """
        try indexMD.write(to: chunkDir.appendingPathComponent("00_INDEX.md"), atomically: true, encoding: .utf8)
        return (chunkDir, chunks.count)
    }

    nonisolated static func splitMarkdownIntoSmartChunks(
        _ markdown: String,
        maxTokensPerChunk: Int
    ) -> [(heading: String, body: String, tokens: Int)] {
        let maxChars = max(4000, Int(Double(maxTokensPerChunk) * 3.6))
        let lines = markdown.components(separatedBy: "\n")

        // Group lines into logical H1/H2 sections first
        var sections: [(heading: String, text: String)] = []
        var curHeading = "Mở đầu"
        var curLines: [String] = []

        for line in lines {
            if line.hasPrefix("# ") || line.hasPrefix("## ") {
                if !curLines.isEmpty {
                    sections.append((curHeading, curLines.joined(separator: "\n")))
                    curLines.removeAll(keepingCapacity: true)
                }
                curHeading = line.replacingOccurrences(of: "^#+\\s*", with: "", options: .regularExpression)
            }
            curLines.append(line)
        }
        if !curLines.isEmpty {
            sections.append((curHeading, curLines.joined(separator: "\n")))
        }

        // Pack logical sections into chunks <= maxChars (splitting oversized sections on paragraph breaks)
        var chunks: [(heading: String, body: String, tokens: Int)] = []
        var accHeading = sections.first?.heading ?? "Phần 1"
        var accText = ""

        func flushAcc() {
            let trimmed = accText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            chunks.append((accHeading, trimmed + "\n", estimateTokens(trimmed)))
            accText = ""
        }

        for sec in sections {
            if sec.text.count > maxChars {
                flushAcc()
                let paragraphs = sec.text.components(separatedBy: "\n\n")
                var subAcc = ""
                var partIdx = 1
                for p in paragraphs {
                    if !subAcc.isEmpty && (subAcc.count + p.count + 2) > maxChars {
                        let body = subAcc.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                        chunks.append(("\(sec.heading) (Đoạn \(partIdx))", body, estimateTokens(body)))
                        partIdx += 1
                        subAcc = p
                    } else {
                        subAcc = subAcc.isEmpty ? p : "\(subAcc)\n\n\(p)"
                    }
                }
                if !subAcc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let body = subAcc.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
                    let title = partIdx > 1 ? "\(sec.heading) (Đoạn \(partIdx))" : sec.heading
                    chunks.append((title, body, estimateTokens(body)))
                }
            } else if !accText.isEmpty && (accText.count + sec.text.count + 2) > maxChars {
                flushAcc()
                accHeading = sec.heading
                accText = sec.text
            } else {
                if accText.isEmpty { accHeading = sec.heading }
                accText = accText.isEmpty ? sec.text : "\(accText)\n\n\(sec.text)"
            }
        }
        flushAcc()

        return chunks.isEmpty ? [("Toàn văn", markdown, estimateTokens(markdown))] : chunks
    }

    // MARK: - AI Package Builder (_AI/)

    private nonisolated static func buildAIPackageWorker(
        url: URL,
        toolkitDir: String,
        enableOCR: Bool,
        optimizeTokens: Bool
    ) throws -> URL {
        let single = try convertSingleFileWorker(
            url: url,
            toolkitDir: toolkitDir,
            saveBesideSource: false,
            enableOCR: enableOCR,
            forceOCR: false,
            optimizeTokens: optimizeTokens,
            includeMetadataHeader: false,
            autoChunkIfExceedsTokens: nil
        )

        let stem = safeNFCStem(for: url)
        let ext = ".\(url.pathExtension.lowercased())"
        let pkgDir = url.deletingLastPathComponent().appendingPathComponent("\(stem)_AI", isDirectory: true)
        let logsDir = pkgDir.appendingPathComponent("logs", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let mdURL = pkgDir.appendingPathComponent("\(stem).md")
        let xmlURL = pkgDir.appendingPathComponent("\(stem)_claude.xml")
        let txtURL = pkgDir.appendingPathComponent("\(stem).txt")
        let htmlURL = pkgDir.appendingPathComponent("\(stem).html")
        let jsonURL = pkgDir.appendingPathComponent("\(stem).json")
        let readmeURL = pkgDir.appendingPathComponent("README.md")
        let manifestURL = pkgDir.appendingPathComponent("manifest.json")
        let logURL = logsDir.appendingPathComponent("convert.log")

        try single.markdown.write(to: mdURL, atomically: true, encoding: .utf8)
        try single.markdown.write(to: txtURL, atomically: true, encoding: .utf8)
        let xmlWrapped = wrapDocumentsInXML([(url.lastPathComponent, single.estimatedTokens, single.markdown)])
        try xmlWrapped.write(to: xmlURL, atomically: true, encoding: .utf8)

        let escapedHTML = single.markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let htmlDoc = """
        <!DOCTYPE html>
        <html lang="vi">
        <head><meta charset="utf-8"><title>\(stem)</title></head>
        <body><pre style="white-space: pre-wrap; font-family: system-ui, sans-serif;">\(escapedHTML)</pre></body>
        </html>
        """
        try htmlDoc.write(to: htmlURL, atomically: true, encoding: .utf8)

        let jsonPayload: [String: Any] = [
            "source": url.lastPathComponent,
            "format": "md",
            "engine": single.engineUsed,
            "estimated_tokens": single.estimatedTokens,
            "content": single.markdown,
            "metadata": ["title": stem, "original_extension": ext]
        ]
        if let jData = try? JSONSerialization.data(withJSONObject: jsonPayload, options: [.prettyPrinted, .sortedKeys]) {
            try jData.write(to: jsonURL, options: .atomic)
        }

        let ts = isoTimestamp()
        let readme = """
        # AI Package: \(stem)

        ## Source Document
        - **Filename:** `\(url.lastPathComponent)`
        - **Format:** `\(ext)`
        - **Engine:** `\(single.engineUsed)`
        - **Estimated AI Tokens:** `~\(single.estimatedTokens)`
        - **Generated:** `\(ts)`

        ## Contents
        - `\(stem).md`: Optimized Markdown for Claude / ChatGPT / Gemini / NotebookLM (Primary)
        - `\(stem)_claude.xml`: Structured `<documents><document>` XML context wrapper
        - `\(stem).txt`: Plain text fallback
        - `\(stem).json`: Structured JSON payload for API ingestion
        - `\(stem).html`: HTML preview
        """
        try readme.write(to: readmeURL, atomically: true, encoding: .utf8)

        let manifest: [String: Any] = [
            "source_file": url.lastPathComponent,
            "original_format": ext,
            "generated_at": ts,
            "engine": single.engineUsed,
            "estimated_tokens": single.estimatedTokens,
            "status": "success",
            "files": ["\(stem).md", "\(stem)_claude.xml", "\(stem).txt", "\(stem).html", "\(stem).json", "README.md"]
        ]
        if let mData = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try mData.write(to: manifestURL, options: .atomic)
        }

        let logContent = """
        DriveBar AI Document Engine
        Timestamp : \(ts)
        Source    : \(url.path)
        Engine    : \(single.engineUsed)
        Tokens    : ~\(single.estimatedTokens)
        Status    : SUCCESS
        """
        try logContent.write(to: logURL, atomically: true, encoding: .utf8)

        return pkgDir
    }

    // MARK: - Python Subprocess Helpers (PyMuPDF4LLM & MarkItDown)

    private nonisolated static func runPythonPyMuPDF(pythonPath: String, pdfURL: URL) throws -> String {
        let code = "import sys, pymupdf4llm; sys.stdout.write(pymupdf4llm.to_markdown(sys.argv[1]))"
        return try runProcess(executable: pythonPath, arguments: ["-c", code, pdfURL.path], timeout: 90)
    }

    private nonisolated static func runPythonMarkItDown(pythonPath: String, fileURL: URL) throws -> String {
        let code = "import sys; from markitdown import MarkItDown; sys.stdout.write(MarkItDown().convert(sys.argv[1]).text_content)"
        return try runProcess(executable: pythonPath, arguments: ["-c", code, fileURL.path], timeout: 90)
    }

    private nonisolated static func runLibreOfficeToPDF(soffice: String, inputURL: URL, outputDir: URL) throws -> URL {
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        _ = try runProcess(
            executable: soffice,
            arguments: ["--headless", "--convert-to", "pdf", "--outdir", outputDir.path, inputURL.path],
            timeout: 120
        )
        let expected = outputDir.appendingPathComponent(inputURL.deletingPathExtension().lastPathComponent + ".pdf")
        if FileManager.default.fileExists(atPath: expected.path) {
            return expected
        }
        if let items = try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil),
           let firstPDF = items.first(where: { $0.pathExtension.lowercased() == "pdf" }) {
            return firstPDF
        }
        throw MarkdownConversionError.conversionFailed("LibreOffice không xuất được tệp PDF.")
    }

    // MARK: - Native PDFKit + Apple Vision Vietnamese OCR

    private nonisolated static func performPDFExtraction(
        url: URL,
        enableVisionOCR: Bool,
        forceAllPagesOCR: Bool
    ) throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw MarkdownConversionError.conversionFailed("Không thể đọc tệp PDF: \(url.lastPathComponent)")
        }

        let pageCount = pdf.pageCount
        guard pageCount > 0 else { return "" }

        var pageSections: [String] = []
        pageSections.reserveCapacity(pageCount)

        for i in 0..<pageCount {
            guard let page = pdf.page(at: i) else { continue }
            let directText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            let pageBody: String
            if !forceAllPagesOCR && directText.count >= 45 {
                pageBody = directText
            } else if enableVisionOCR, let cgImg = renderPDFPageToCGImage(page: page, dpiScale: 2.5) {
                let ocrText = (try? recognizeTextInCGImage(cgImg)) ?? directText
                pageBody = ocrText.isEmpty ? directText : ocrText
            } else {
                pageBody = directText
            }

            if !pageBody.isEmpty {
                if pageCount > 1 {
                    pageSections.append("## Trang \(i + 1)\n\n\(pageBody)")
                } else {
                    pageSections.append(pageBody)
                }
            }
        }

        return pageSections.joined(separator: "\n\n")
    }

    private nonisolated static func renderPDFPageToCGImage(page: PDFPage, dpiScale: CGFloat) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let width = max(Int(bounds.width * dpiScale), 600)
        let height = max(Int(bounds.height * dpiScale), 800)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }

        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.saveGState()
        ctx.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        return ctx.makeImage()
    }

    private nonisolated static func performVisionOCROnImage(url: URL) throws -> String {
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw MarkdownConversionError.conversionFailed("Không thể mở tệp hình ảnh: \(url.lastPathComponent)")
        }
        return try recognizeTextInCGImage(cgImage)
    }

    private nonisolated static func recognizeTextInCGImage(_ cgImage: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["vi-VN", "en-US"]

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        guard let observations = request.results, !observations.isEmpty else {
            return ""
        }

        let sorted = observations.sorted { a, b in
            let ay = a.boundingBox.midY
            let by = b.boundingBox.midY
            if abs(ay - by) > 0.012 {
                return ay > by
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        var lines: [String] = []
        var currentLineTokens: [(x: CGFloat, text: String)] = []
        var currentY: CGFloat?

        for obs in sorted {
            guard let top = obs.topCandidates(1).first else { continue }
            let y = obs.boundingBox.midY
            if let cy = currentY, abs(cy - y) <= 0.012 {
                currentLineTokens.append((obs.boundingBox.minX, top.string))
            } else {
                if !currentLineTokens.isEmpty {
                    currentLineTokens.sort { $0.x < $1.x }
                    lines.append(currentLineTokens.map(\.text).joined(separator: "  "))
                }
                currentLineTokens = [(obs.boundingBox.minX, top.string)]
                currentY = y
            }
        }
        if !currentLineTokens.isEmpty {
            currentLineTokens.sort { $0.x < $1.x }
            lines.append(currentLineTokens.map(\.text).joined(separator: "  "))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Native Structured Fallback & RFC4180 CSV Parser

    private nonisolated static func fallbackNativeStructuredConversion(url: URL, ext: String) throws -> String {
        if ext == "csv" {
            let content = try String(contentsOf: url, encoding: .utf8)
            return convertRFC4180CSVToMarkdownTable(content)
        }
        if ext == "tsv" {
            let content = try String(contentsOf: url, encoding: .utf8)
            return convertDelimitedToMarkdownTable(content, delimiter: "\t")
        }

        if ["doc", "docx", "rtf", "odt", "html", "htm"].contains(ext) {
            if let html = try? runProcess(
                executable: "/usr/bin/textutil",
                arguments: ["-convert", "html", "-stdout", url.path],
                timeout: 30
            ), !html.isEmpty {
                let md = simpleHTMLToMarkdown(html)
                if !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return md
                }
            }
            if let txt = try? runProcess(
                executable: "/usr/bin/textutil",
                arguments: ["-convert", "txt", "-stdout", url.path],
                timeout: 30
            ) {
                return txt
            }
        }

        if let data = try? Data(contentsOf: url),
           let attr = try? NSAttributedString(data: data, options: [:], documentAttributes: nil) {
            return attr.string
        }

        throw MarkdownConversionError.conversionFailed("Không thể chuyển đổi '\(url.lastPathComponent)'. Hãy kiểm tra cài đặt LibreOffice hoặc AI Toolkit.")
    }

    private nonisolated static func convertRFC4180CSVToMarkdownTable(_ csv: String) -> String {
        var rows: [[String]] = []
        var curRow: [String] = []
        var curField = ""
        var inQuotes = false
        let chars = Array(csv.replacingOccurrences(of: "\r\n", with: "\n"))
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if inQuotes {
                if ch == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        curField.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    curField.append(ch == "\n" ? " " : ch)
                }
            } else {
                if ch == "\"" {
                    inQuotes = true
                } else if ch == "," {
                    curRow.append(curField.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|"))
                    curField = ""
                } else if ch == "\n" {
                    curRow.append(curField.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|"))
                    curField = ""
                    if curRow.contains(where: { !$0.isEmpty }) {
                        rows.append(curRow)
                    }
                    curRow = []
                } else {
                    curField.append(ch)
                }
            }
            i += 1
        }
        if !curField.isEmpty || !curRow.isEmpty {
            curRow.append(curField.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|"))
            if curRow.contains(where: { !$0.isEmpty }) {
                rows.append(curRow)
            }
        }

        guard !rows.isEmpty else { return csv }
        let colCount = rows.map(\.count).max() ?? 1
        func pad(_ r: [String]) -> [String] {
            r.count >= colCount ? r : r + Array(repeating: "", count: colCount - r.count)
        }
        var out: [String] = []
        out.append("| " + pad(rows[0]).joined(separator: " | ") + " |")
        out.append("| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |")
        for r in rows.dropFirst() {
            out.append("| " + pad(r).joined(separator: " | ") + " |")
        }
        return out.joined(separator: "\n")
    }

    private nonisolated static func convertDelimitedToMarkdownTable(_ text: String, delimiter: Character) -> String {
        let rows = text
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !rows.isEmpty else { return "" }

        let parsed: [[String]] = rows.map { line in
            line.split(separator: delimiter, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")).replacingOccurrences(of: "|", with: "\\|") }
        }
        let colCount = parsed.map(\.count).max() ?? 1
        guard colCount > 0 else { return text }

        func pad(_ row: [String]) -> [String] {
            row.count >= colCount ? row : row + Array(repeating: "", count: colCount - row.count)
        }

        var out: [String] = []
        out.append("| " + pad(parsed[0]).joined(separator: " | ") + " |")
        out.append("| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |")
        for r in parsed.dropFirst() {
            out.append("| " + pad(r).joined(separator: " | ") + " |")
        }
        return out.joined(separator: "\n")
    }

    private nonisolated static func simpleHTMLToMarkdown(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: "(?is)<head[^>]*>.*?</head>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)

        if let tableRegex = try? NSRegularExpression(pattern: "(?is)<table[^>]*>(.*?)</table>") {
            let matches = tableRegex.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed()
            for m in matches {
                guard let fullRange = Range(m.range, in: s),
                      let bodyRange = Range(m.range(at: 1), in: s) else { continue }
                let tableMD = convertHTMLTableBodyToMarkdown(String(s[bodyRange]))
                s.replaceSubrange(fullRange, with: "\n\n\(tableMD)\n\n")
            }
        }

        for level in 1...6 {
            let hashes = String(repeating: "#", count: level)
            s = s.replacingOccurrences(of: "(?is)<h\(level)[^>]*>(.*?)</h\(level)>", with: "\n\n\(hashes) $1\n\n", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: "(?is)<(strong|b)[^>]*>(.*?)</\\1>", with: "**$2**", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<(em|i)[^>]*>(.*?)</\\1>", with: "*$2*", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<li[^>]*>(.*?)</li>", with: "\n- $1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)</p>", with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)</div>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<[^>]+>", with: "", options: .regularExpression)
        s = decodeHTMLEntities(s)
        return optimizeMarkdownText(s)
    }

    private nonisolated static func convertHTMLTableBodyToMarkdown(_ tableInner: String) -> String {
        guard let trRegex = try? NSRegularExpression(pattern: "(?is)<tr[^>]*>(.*?)</tr>"),
              let cellRegex = try? NSRegularExpression(pattern: "(?is)<t[dh][^>]*>(.*?)</t[dh]>") else {
            return ""
        }
        var rows: [[String]] = []
        for trMatch in trRegex.matches(in: tableInner, range: NSRange(tableInner.startIndex..., in: tableInner)) {
            guard let trRange = Range(trMatch.range(at: 1), in: tableInner) else { continue }
            let rowStr = String(tableInner[trRange])
            var cells: [String] = []
            for cMatch in cellRegex.matches(in: rowStr, range: NSRange(rowStr.startIndex..., in: rowStr)) {
                guard let cRange = Range(cMatch.range(at: 1), in: rowStr) else { continue }
                let rawCell = String(rowStr[cRange])
                    .replacingOccurrences(of: "(?is)<[^>]+>", with: " ", options: .regularExpression)
                let cleaned = decodeHTMLEntities(rawCell)
                    .components(separatedBy: .whitespacesAndNewlines)
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
                cells.append(cleaned)
            }
            if !cells.isEmpty { rows.append(cells) }
        }
        guard !rows.isEmpty else { return "" }
        let cols = rows.map(\.count).max() ?? 1
        func pad(_ r: [String]) -> [String] {
            r.count >= cols ? r : r + Array(repeating: "", count: cols - r.count)
        }
        var md: [String] = []
        md.append("| " + pad(rows[0]).joined(separator: " | ") + " |")
        md.append("| " + Array(repeating: "---", count: cols).joined(separator: " | ") + " |")
        for r in rows.dropFirst() {
            md.append("| " + pad(r).joined(separator: " | ") + " |")
        }
        return md.joined(separator: "\n")
    }

    private nonisolated static func decodeHTMLEntities(_ text: String) -> String {
        var out = text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&mdash;", with: "—")
            .replacingOccurrences(of: "&ndash;", with: "–")

        if let decRx = try? NSRegularExpression(pattern: "&#([0-9]{1,7});") {
            for m in decRx.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                if let full = Range(m.range, in: out),
                   let numR = Range(m.range(at: 1), in: out),
                   let code = UInt32(out[numR]),
                   let scalar = UnicodeScalar(code) {
                    out.replaceSubrange(full, with: String(scalar))
                }
            }
        }
        if let hexRx = try? NSRegularExpression(pattern: "(?i)&#x([0-9a-f]{1,6});") {
            for m in hexRx.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                if let full = Range(m.range, in: out),
                   let hexR = Range(m.range(at: 1), in: out),
                   let code = UInt32(out[hexR], radix: 16),
                   let scalar = UnicodeScalar(code) {
                    out.replaceSubrange(full, with: String(scalar))
                }
            }
        }
        return out
    }

    // MARK: - Token Optimization & Utilities

    nonisolated static func optimizeMarkdownText(_ input: String) -> String {
        var text = input.precomposedStringWithCanonicalMapping
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\u{200B}", with: "")
        text = text.replacingOccurrences(of: "\u{FEFF}", with: "")

        let lines = text.components(separatedBy: "\n").map { line -> String in
            var l = line
            while l.last == " " || l.last == "\t" {
                l.removeLast()
            }
            return l
        }

        var collapsed: [String] = []
        collapsed.reserveCapacity(lines.count)
        var emptyStreak = 0
        for line in lines {
            if line.isEmpty {
                emptyStreak += 1
                if emptyStreak <= 2 {
                    collapsed.append("")
                }
            } else {
                emptyStreak = 0
                collapsed.append(line)
            }
        }
        return collapsed.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    nonisolated static func estimateTokens(_ text: String) -> Int {
        max(1, Int(Double(text.count) / 3.6))
    }

    nonisolated static func safeNFCStem(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent.precomposedStringWithCanonicalMapping
    }

    private nonisolated static func hasMeaningfulText(_ text: String, minChars: Int) -> Bool {
        let stripped = text.components(separatedBy: .whitespacesAndNewlines).joined()
        return stripped.count >= minChars
    }

    private nonisolated static func materializeCloudFileBlocking(_ url: URL) {
        if let fh = try? FileHandle(forReadingFrom: url) {
            _ = try? fh.read(upToCount: 4096)
            try? fh.close()
        }
    }

    private nonisolated static func collectConvertibleFiles(from urls: [URL]) -> [URL] {
        let fm = FileManager.default
        var collected: [URL] = []
        let allExts = imageExtensions
            .union(markItDownExtensions)
            .union(libreOfficeLegacyExtensions)
            .union(codeAndPlainExtensions)
            .union(googleWorkspaceExtensions)
            .union(["pdf"])

        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if !isDir.boolValue {
                collected.append(u)
            } else if let enumerator = fm.enumerator(
                at: u,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) {
                for case let child as URL in enumerator {
                    if enumerator.level > 3 {
                        enumerator.skipDescendants()
                        continue
                    }
                    if allExts.contains(child.pathExtension.lowercased()) {
                        collected.append(child)
                    }
                }
            }
        }
        return collected.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private nonisolated static func isoTimestamp() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: Date())
    }

    private nonisolated static func runProcess(executable: String, arguments: [String], timeout: TimeInterval) throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        env["PATH"] = "\(extraPath):\(env["PATH"] ?? "")"
        env["PYTHONIOENCODING"] = "utf-8"
        proc.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        try proc.run()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        if proc.terminationStatus != 0 && stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let stderr = String(data: errData, encoding: .utf8) ?? "Exit code \(proc.terminationStatus)"
            throw MarkdownConversionError.conversionFailed(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return stdout
    }
}
