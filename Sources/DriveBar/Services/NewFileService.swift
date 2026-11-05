import Foundation
import AppKit

@MainActor
final class NewFileService {
    static let shared = NewFileService()

    private init() {}

    struct FilePreviewInfo {
        let fileName: String
        let baseName: String
        let ext: String
        let sfSymbol: String
        let targetDirectory: URL
        let folderDisplayName: String
    }

    // MARK: - Directory Resolution

    /// Resolves the active folder in Finder (or falls back to Desktop).
    func resolveActiveFinderDirectory() -> (url: URL, displayName: String) {
        let scriptSource = """
        tell application "Finder"
            try
                if (count of Finder windows) > 0 then
                    return POSIX path of (target of front Finder window as alias)
                else
                    return POSIX path of (desktop as alias)
                end if
            on error
                try
                    return POSIX path of (desktop as alias)
                on error
                    return ""
                end try
            end try
        end tell
        """

        var resolvedPath: String?
        if let script = NSAppleScript(source: scriptSource) {
            var errorInfo: NSDictionary?
            let result = script.executeAndReturnError(&errorInfo)
            if errorInfo == nil, let stringValue = result.stringValue, !stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resolvedPath = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let targetURL: URL
        if let path = resolvedPath, FileManager.default.fileExists(atPath: path) {
            targetURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            targetURL = desktop ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        }

        let display = formatFolderDisplay(targetURL)
        return (targetURL, display)
    }

    private func formatFolderDisplay(_ url: URL) -> String {
        let path = url.standardized.path
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path == (home + "/Desktop") { return L("Màn hình Desktop", "Desktop") }
        if path == (home + "/Downloads") { return L("Thư mục Downloads", "Downloads") }
        if path == (home + "/Documents") { return L("Thư mục Documents", "Documents") }

        // Shorten to last 2 components for readability
        let comps = path.split(separator: "/").map(String.init)
        if comps.count > 2 {
            return "…/" + comps.suffix(2).joined(separator: "/")
        }
        return url.lastPathComponent.isEmpty ? path : url.lastPathComponent
    }

    // MARK: - File Name & Extension Parsing

    func parseInput(_ raw: String) -> (baseName: String, ext: String, fileName: String, sfSymbol: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ("untitled", "txt", "untitled.txt", "doc.text")
        }

        let ns = trimmed as NSString
        let pathExt = ns.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pathBase = ns.deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)

        let finalExt: String
        let finalBase: String

        if pathExt.isEmpty || trimmed.hasSuffix(".") {
            finalExt = "txt"
            finalBase = pathBase.isEmpty ? trimmed : pathBase
        } else {
            finalExt = pathExt
            finalBase = pathBase.isEmpty ? "untitled" : pathBase
        }

        let finalFileName = "\(finalBase).\(finalExt)"
        let symbol = sfSymbolForExtension(finalExt)
        return (finalBase, finalExt, finalFileName, symbol)
    }

    func preview(input: String) -> FilePreviewInfo {
        let (dir, folderDisplay) = resolveActiveFinderDirectory()
        let (base, ext, fileName, symbol) = parseInput(input)
        return FilePreviewInfo(
            fileName: fileName,
            baseName: base,
            ext: ext,
            sfSymbol: symbol,
            targetDirectory: dir,
            folderDisplayName: folderDisplay
        )
    }

    func sfSymbolForExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "docx", "doc", "rtf", "pages":
            return "doc.fill"
        case "xlsx", "xls", "numbers", "csv", "tsv":
            return "tablecells.fill"
        case "pptx", "ppt", "keynote":
            return "rectangle.inset.filled.and.person.filled"
        case "pdf":
            return "doc.text.fill"
        case "md", "markdown", "txt":
            return "doc.text"
        case "py", "python":
            return "chevron.left.forwardslash.chevron.right"
        case "sh", "zsh", "bash", "command":
            return "terminal.fill"
        case "json", "xml", "yaml", "yml", "toml":
            return "curlybraces"
        case "html", "htm", "css", "js", "ts", "jsx", "tsx":
            return "globe"
        case "swift":
            return "swift"
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "svg":
            return "photo.fill"
        case "zip", "tar", "gz", "7z":
            return "archivebox.fill"
        default:
            return "doc.text"
        }
    }

    // MARK: - File Creation

    enum NewFileError: LocalizedError {
        case failure(String)
        var errorDescription: String? {
            switch self {
            case .failure(let msg): return msg
            }
        }
    }

    func createNewFile(rawInput: String, openAfter: Bool) -> Result<URL, NewFileError> {
        let (targetDir, folderDisplay) = resolveActiveFinderDirectory()
        let (baseName, ext, _, _) = parseInput(rawInput)

        // Generate non-colliding file name
        var destinationURL = targetDir.appendingPathComponent("\(baseName).\(ext)")
        var counter = 1
        while FileManager.default.fileExists(atPath: destinationURL.path) {
            destinationURL = targetDir.appendingPathComponent("\(baseName) (\(counter)).\(ext)")
            counter += 1
        }

        let finalName = destinationURL.lastPathComponent

        do {
            let lowerExt = ext.lowercased()
            if ["docx", "xlsx", "pptx"].contains(lowerExt) {
                try copyOfficeTemplate(ext: lowerExt, to: destinationURL)
            } else {
                let initialContent = defaultContentForExtension(lowerExt, baseName: baseName)
                try initialContent.write(to: destinationURL, atomically: true, encoding: .utf8)
                if ["sh", "zsh", "bash", "command"].contains(lowerExt) {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destinationURL.path)
                }
            }

            // Reveal in Finder
            NSWorkspace.shared.activateFileViewerSelecting([destinationURL])

            // Open if requested
            if openAfter {
                NSWorkspace.shared.open(destinationURL)
            }

            let successTitle = openAfter
                ? L("Đã tạo và mở tệp: \(finalName)", "Created and opened: \(finalName)")
                : L("Đã tạo tệp mới: \(finalName)", "Created new file: \(finalName)")
            let successSubtitle = L("Tại: \(folderDisplay)", "In: \(folderDisplay)")
            FloatingToastController.shared.showSuccess(title: successTitle, subtitle: successSubtitle)

            return .success(destinationURL)
        } catch {
            let errorMsg = error.localizedDescription
            FloatingToastController.shared.showError(
                title: L("Không thể tạo tệp", "Failed to create file"),
                subtitle: errorMsg
            )
            return .failure(.failure(errorMsg))
        }
    }

    private func copyOfficeTemplate(ext: String, to destination: URL) throws {
        // 1. Try App Bundle Resources/Templates
        var templateURL: URL?
        if let bundleURL = Bundle.main.url(forResource: "blank", withExtension: ext, subdirectory: "Templates") {
            templateURL = bundleURL
        } else if let resourcePath = Bundle.main.resourcePath {
            let direct = URL(fileURLWithPath: "\(resourcePath)/Templates/blank.\(ext)")
            if FileManager.default.fileExists(atPath: direct.path) {
                templateURL = direct
            }
        }

        // 2. Try development workspace relative templates
        if templateURL == nil {
            let devPath = "/Users/hunglx/Documents/antigravity/BuildApp/DriveBar/Resources/Templates/blank.\(ext)"
            if FileManager.default.fileExists(atPath: devPath) {
                templateURL = URL(fileURLWithPath: devPath)
            }
        }

        if let templateURL {
            try FileManager.default.copyItem(at: templateURL, to: destination)
        } else {
            // Minimal fallback
            let fallbackText = "New \(ext.uppercased()) Document"
            try fallbackText.write(to: destination, atomically: true, encoding: .utf8)
        }
    }

    private func defaultContentForExtension(_ ext: String, baseName: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let nowStr = formatter.string(from: Date())

        switch ext {
        case "md", "markdown":
            return """
            # \(baseName)

            *Created: \(nowStr)*

            ---

            """
        case "py":
            return """
            #!/usr/bin/env python3
            # -*- coding: utf-8 -*-

            \"\"\"
            \(baseName)
            Created: \(nowStr)
            \"\"\"

            def main():
                pass

            if __name__ == "__main__":
                main()

            """
        case "sh", "zsh", "bash":
            return """
            #!/bin/bash
            set -euo pipefail

            # \(baseName)
            # Created: \(nowStr)

            """
        case "json":
            return "{\n  \n}\n"
        case "html", "htm":
            return """
            <!DOCTYPE html>
            <html lang="en">
            <head>
              <meta charset="UTF-8">
              <meta name="viewport" content="width=device-width, initial-scale=1.0">
              <title>\(baseName)</title>
            </head>
            <body>
              <h1>\(baseName)</h1>
            </body>
            </html>

            """
        case "csv":
            return "ID,Name,Date,Notes\n"
        case "swift":
            return """
            import Foundation

            // MARK: - \(baseName)

            """
        default:
            return ""
        }
    }
}
