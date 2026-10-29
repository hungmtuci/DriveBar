import Foundation
import AppKit
import PDFKit
import Vision

struct MarkdownConversionResult: Sendable {
    let sourceURL: URL
    let savedMarkdownURL: URL?
    let markdown: String
    let estimatedTokens: Int
    let engineUsed: String
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

    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "webp", "bmp"
    ]
    static let markItDownExtensions: Set<String> = [
        "docx", "pptx", "xlsx", "html", "htm", "csv", "json", "xml"
    ]
    static let libreOfficeLegacyExtensions: Set<String> = [
        "doc", "rtf", "xls", "ppt", "odt", "ods", "odp"
    ]
    static let codeAndPlainExtensions: Set<String> = [
        "txt", "md", "tsv", "yaml", "yml", "py", "swift", "js", "ts", "tsx", "jsx",
        "sh", "zsh", "sql", "css", " c", "cpp", "h", "java", "go", "rs", "php", "rb", "ini", "toml", "log"
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
        if ext == "pdf" {
            return "PyMuPDF4LLM / PDFKit + Vision OCR (vi-VN) → .md"
        } else if markItDownExtensions.contains(ext) {
            return "MarkItDown / Native AST → .md"
        } else if libreOfficeLegacyExtensions.contains(ext) {
            return "LibreOffice / textutil → PyMuPDF4LLM → .md"
        } else if imageExtensions.contains(ext) {
            return "Apple Vision Neural OCR (vi-VN + en-US) → .md"
        } else {
            return "UTF-8 Text & Token Optimizer → .md"
        }
    }

    // MARK: - Primary API: Convert 1 or Multiple Files to Markdown

    func convertFilesToMarkdown(
        urls: [URL],
        saveBesideSource: Bool,
        copyToClipboard: Bool,
        forceOCR: Bool = false
    ) async throws -> [MarkdownConversionResult] {
        isConverting = true
        defer { isConverting = false }

        let toolkitDir = AppSettings.shared.aiToolkitPath
        let enableOCR = forceOCR || AppSettings.shared.enableVisionOCR
        let optimizeTokens = AppSettings.shared.optimizeMarkdownTokens
        let includeMeta = AppSettings.shared.includeMetadataHeader

        var outputs: [MarkdownConversionResult] = []

        for url in urls {
            let res = try await Task.detached(priority: .userInitiated) {
                try Self.convertSingleFileWorker(
                    url: url,
                    toolkitDir: toolkitDir,
                    saveBesideSource: saveBesideSource,
                    enableOCR: enableOCR,
                    forceOCR: forceOCR,
                    optimizeTokens: optimizeTokens,
                    includeMetadataHeader: includeMeta
                )
            }.value
            outputs.append(res)
        }

        if copyToClipboard, !outputs.isEmpty {
            let combined: String
            if outputs.count == 1 {
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

    // MARK: - Convert for AI (_AI/ Full Package)

    func convertFilesForAIPackage(urls: [URL]) async throws -> [URL] {
        isConverting = true
        defer { isConverting = false }

        let toolkitDir = AppSettings.shared.aiToolkitPath
        let enableOCR = AppSettings.shared.enableVisionOCR
        let optimizeTokens = AppSettings.shared.optimizeMarkdownTokens

        var createdDirs: [URL] = []

        for url in urls {
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

        let result = try await Task.detached(priority: .userInitiated) { () -> MarkdownConversionResult in
            let expandedFiles = Self.collectConvertibleFiles(from: urls)
            guard !expandedFiles.isEmpty else {
                throw MarkdownConversionError.conversionFailed("Không tìm thấy tệp tài liệu hợp lệ để gộp.")
            }

            var sections: [String] = []
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
                    includeMetadataHeader: false
                ) {
                    engines.insert(single.engineUsed)
                    toc.append("- [\(idx + 1). \(fileURL.lastPathComponent)] (`~\(single.estimatedTokens) tokens`)")
                    sections.append("## Tài liệu [\(idx + 1)/\(expandedFiles.count)]: `\(fileURL.lastPathComponent)`\n\n\(single.markdown)")
                }
            }

            guard !sections.isEmpty else {
                throw MarkdownConversionError.conversionFailed("Không trích xuất được nội dung từ các tệp đã chọn.")
            }

            let first = urls[0]
            var isFirstDir: ObjCBool = false
            FileManager.default.fileExists(atPath: first.path, isDirectory: &isFirstDir)
            let baseName = Self.safeNFCStem(for: first)
            let outputDir = isFirstDir.boolValue ? first.deletingLastPathComponent() : first.deletingLastPathComponent()
            let outURL = outputDir.appendingPathComponent("\(baseName)_AI_Context.md")

            let header = """
            # Gói Ngữ Cảnh Tài Liệu AI: \(baseName)

            - **Số lượng tài liệu:** \(sections.count)
            - **Thời gian trích xuất:** \(Self.isoTimestamp())

            ## Mục lục tài liệu
            \(toc.joined(separator: "\n"))

            ---

            """

            let fullMD = Self.optimizeMarkdownText(header + sections.joined(separator: "\n\n---\n\n"))
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

        return try await Task.detached(priority: .userInitiated) {
            var created: [URL] = []
            for url in urls {
                Self.materializeCloudFileIfNeeded(url)
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
        includeMetadataHeader: Bool
    ) throws -> MarkdownConversionResult {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MarkdownConversionError.fileNotFound(url.lastPathComponent)
        }

        materializeCloudFileIfNeeded(url)

        let ext = url.pathExtension.lowercased()
        let stem = safeNFCStem(for: url)
        var rawMarkdown = ""
        var engineName = "Native Swift"

        // 1. Google Workspace Shortcut files (.gdoc, .gsheet, .gslides)
        if ["gdoc", "gsheet", "gslides"].contains(ext) {
            if let urls = GoogleDriveIndexService.googleDriveURLs(for: url.path) {
                rawMarkdown = """
                # \(stem)

                > Tệp Google Workspace trực tuyến (`.\(ext)`).
                - **Mở trực tiếp:** \(urls.webURL.absoluteString)
                - **Liên kết chia sẻ:** \(urls.shareURL.absoluteString)
                """
                engineName = "Google Workspace Link"
            }
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
        // 5. PDF Documents -> PyMuPDF4LLM (if available) + Automatic Vision OCR Rescue for scanned pages!
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

        var savedURL: URL?
        if saveBesideSource {
            let targetURL = url.deletingLastPathComponent().appendingPathComponent("\(stem).md")
            try finalMD.write(to: targetURL, atomically: true, encoding: .utf8)
            savedURL = targetURL
        }

        return MarkdownConversionResult(
            sourceURL: url,
            savedMarkdownURL: savedURL,
            markdown: finalMD,
            estimatedTokens: estimateTokens(finalMD),
            engineUsed: engineName
        )
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
            includeMetadataHeader: false
        )

        let stem = safeNFCStem(for: url)
        let ext = ".\(url.pathExtension.lowercased())"
        let pkgDir = url.deletingLastPathComponent().appendingPathComponent("\(stem)_AI", isDirectory: true)
        let logsDir = pkgDir.appendingPathComponent("logs", isDirectory: true)

        let fm = FileManager.default
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let mdURL = pkgDir.appendingPathComponent("\(stem).md")
        let txtURL = pkgDir.appendingPathComponent("\(stem).txt")
        let htmlURL = pkgDir.appendingPathComponent("\(stem).html")
        let jsonURL = pkgDir.appendingPathComponent("\(stem).json")
        let readmeURL = pkgDir.appendingPathComponent("README.md")
        let manifestURL = pkgDir.appendingPathComponent("manifest.json")
        let logURL = logsDir.appendingPathComponent("convert.log")

        try single.markdown.write(to: mdURL, atomically: true, encoding: .utf8)
        try single.markdown.write(to: txtURL, atomically: true, encoding: .utf8)

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
            "files": ["\(stem).md", "\(stem).txt", "\(stem).html", "\(stem).json", "README.md"]
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

        // Group lines by vertical proximity to reconstruct clean lines & tables
        let sorted = observations.sorted { a, b in
            let ay = a.boundingBox.midY
            let by = b.boundingBox.midY
            if abs(ay - by) > 0.012 {
                return ay > by // Vision origin is bottom-left
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

    // MARK: - Native Structured Fallback (macOS textutil HTML AST + CSV/XLSX)

    private nonisolated static func fallbackNativeStructuredConversion(url: URL, ext: String) throws -> String {
        if ext == "csv" || ext == "tsv" {
            let content = try String(contentsOf: url, encoding: .utf8)
            return convertDelimitedToMarkdownTable(content, delimiter: ext == "tsv" ? "\t" : ",")
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
        let header = pad(parsed[0])
        out.append("| " + header.joined(separator: " | ") + " |")
        out.append("| " + Array(repeating: "---", count: colCount).joined(separator: " | ") + " |")
        for r in parsed.dropFirst() {
            out.append("| " + pad(r).joined(separator: " | ") + " |")
        }
        return out.joined(separator: "\n")
    }

    private nonisolated static func simpleHTMLToMarkdown(_ html: String) -> String {
        var s = html
        // Remove <head>...</head> and <style>...</style>
        s = s.replacingOccurrences(of: "(?is)<head[^>]*>.*?</head>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: "", options: .regularExpression)

        // Convert HTML tables into Markdown tables
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
        text
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
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

    private nonisolated static func materializeCloudFileIfNeeded(_ url: URL) {
        if let fh = try? FileHandle(forReadingFrom: url) {
            _ = try? fh.read(upToCount: 1)
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
