import Foundation
import AppKit
import CryptoKit

struct DeepSearchTokens: Sendable {
    var rawTextQuery: String = ""
    var minSizeBytes: Int64?
    var maxSizeBytes: Int64?
    var allowedExtensions: Set<String>?
    var minDate: Date?
    var isFolderOnly: Bool = false
    var isDuplicateMode: Bool = false

    var hasFilters: Bool {
        minSizeBytes != nil ||
        maxSizeBytes != nil ||
        allowedExtensions != nil ||
        minDate != nil ||
        isFolderOnly ||
        isDuplicateMode
    }
}

struct DuplicateGroup: Identifiable, Sendable {
    let id: String // e.g. size + sample hash
    let fileName: String
    let sizeBytes: Int64
    let items: [URL]

    var wastedBytes: Int64 {
        max(0, Int64(items.count - 1) * sizeBytes)
    }
}

final class DriveDeepSearchService: @unchecked Sendable {
    static let shared = DriveDeepSearchService()

    private init() {}

    // MARK: - Query Parsing

    func parseTokens(from input: String) -> DeepSearchTokens {
        var tokens = DeepSearchTokens()
        let parts = input.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var remainingWords: [String] = []

        for part in parts {
            let lower = part.lowercased()

            // 1. Duplicates trigger
            if lower == "dup" || lower == "duplicate" || lower == "duplicates" {
                tokens.isDuplicateMode = true
                continue
            }

            // 2. Size filter (e.g. size:>100mb, size:<10mb, >50mb, <1gb)
            if lower.hasPrefix("size:") {
                let spec = String(lower.dropFirst(5))
                parseSizeFilter(spec, into: &tokens)
                continue
            }
            if (lower.hasPrefix(">") || lower.hasPrefix("<")) && containsSizeUnit(lower) {
                parseSizeFilter(lower, into: &tokens)
                continue
            }

            // 3. Type/Kind filter (e.g. type:pdf, kind:sheet, type:doc)
            if lower.hasPrefix("type:") || lower.hasPrefix("kind:") {
                let spec = lower.hasPrefix("type:") ? String(lower.dropFirst(5)) : String(lower.dropFirst(5))
                parseTypeFilter(spec, into: &tokens)
                continue
            }

            // 4. Date filter (e.g. date:today, modified:week)
            if lower.hasPrefix("date:") || lower.hasPrefix("modified:") {
                let spec = lower.hasPrefix("date:") ? String(lower.dropFirst(5)) : String(lower.dropFirst(9))
                parseDateFilter(spec, into: &tokens)
                continue
            }

            remainingWords.append(part)
        }

        tokens.rawTextQuery = remainingWords.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return tokens
    }

    private func containsSizeUnit(_ str: String) -> Bool {
        let u = str.lowercased()
        return u.hasSuffix("b") || u.hasSuffix("kb") || u.hasSuffix("mb") || u.hasSuffix("gb") || u.hasSuffix("k") || u.hasSuffix("m") || u.hasSuffix("g")
    }

    private func parseSizeFilter(_ spec: String, into tokens: inout DeepSearchTokens) {
        var clean = spec
        var isGreater = true

        if clean.hasPrefix(">=") {
            isGreater = true
            clean = String(clean.dropFirst(2))
        } else if clean.hasPrefix("<=") {
            isGreater = false
            clean = String(clean.dropFirst(2))
        } else if clean.hasPrefix(">") {
            isGreater = true
            clean = String(clean.dropFirst(1))
        } else if clean.hasPrefix("<") {
            isGreater = false
            clean = String(clean.dropFirst(1))
        }

        guard let bytes = parseBytes(from: clean) else { return }
        if isGreater {
            tokens.minSizeBytes = bytes
        } else {
            tokens.maxSizeBytes = bytes
        }
    }

    private func parseBytes(from text: String) -> Int64? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
        var multiplier: Int64 = 1
        var numStr = lower

        if lower.hasSuffix("gb") || lower.hasSuffix("g") {
            multiplier = 1024 * 1024 * 1024
            numStr = lower.replacingOccurrences(of: "gb", with: "").replacingOccurrences(of: "g", with: "")
        } else if lower.hasSuffix("mb") || lower.hasSuffix("m") {
            multiplier = 1024 * 1024
            numStr = lower.replacingOccurrences(of: "mb", with: "").replacingOccurrences(of: "m", with: "")
        } else if lower.hasSuffix("kb") || lower.hasSuffix("k") {
            multiplier = 1024
            numStr = lower.replacingOccurrences(of: "kb", with: "").replacingOccurrences(of: "k", with: "")
        } else if lower.hasSuffix("b") {
            multiplier = 1
            numStr = lower.replacingOccurrences(of: "b", with: "")
        }

        if let val = Double(numStr) {
            return Int64(val * Double(multiplier))
        }
        return nil
    }

    private func parseTypeFilter(_ spec: String, into tokens: inout DeepSearchTokens) {
        let clean = spec.lowercased().trimmingCharacters(in: .whitespaces)
        switch clean {
        case "pdf":
            tokens.allowedExtensions = ["pdf"]
        case "doc", "docx", "word":
            tokens.allowedExtensions = ["doc", "docx", "pages", "rtf", "odt"]
        case "sheet", "sheets", "excel", "xlsx", "xls":
            tokens.allowedExtensions = ["xls", "xlsx", "numbers", "csv", "tsv"]
        case "slide", "slides", "ppt", "pptx", "powerpoint":
            tokens.allowedExtensions = ["ppt", "pptx", "keynote"]
        case "image", "img", "photo", "pic":
            tokens.allowedExtensions = ["png", "jpg", "jpeg", "webp", "gif", "heic", "svg", "tiff"]
        case "video", "movie", "vid":
            tokens.allowedExtensions = ["mp4", "mov", "m4v", "mkv", "avi", "webm"]
        case "audio", "music", "sound":
            tokens.allowedExtensions = ["mp3", "m4a", "wav", "flac", "aac", "ogg"]
        case "archive", "zip", "compressed":
            tokens.allowedExtensions = ["zip", "tar", "gz", "7z", "rar", "bz2"]
        case "code", "dev":
            tokens.allowedExtensions = ["swift", "py", "sh", "zsh", "bash", "js", "ts", "html", "css", "json", "xml", "cpp", "c", "h", "rs", "go"]
        case "folder", "dir":
            tokens.isFolderOnly = true
        default:
            tokens.allowedExtensions = [clean]
        }
    }

    private func parseDateFilter(_ spec: String, into tokens: inout DeepSearchTokens) {
        let cal = Calendar.current
        let now = Date()

        switch spec.lowercased() {
        case "today", "homnay":
            tokens.minDate = cal.startOfDay(for: now)
        case "yesterday", "homqua":
            if let yesterday = cal.date(byAdding: .day, value: -1, to: now) {
                tokens.minDate = cal.startOfDay(for: yesterday)
            }
        case "week", "tuannay", "7d":
            tokens.minDate = cal.date(byAdding: .day, value: -7, to: now)
        case "month", "thangnay", "30d":
            tokens.minDate = cal.date(byAdding: .day, value: -30, to: now)
        case "year", "namnay", "365d":
            tokens.minDate = cal.date(byAdding: .day, value: -365, to: now)
        default:
            break
        }
    }

    // MARK: - Candidate File Verification

    func matches(fileURL: URL, ext: String, tokens: DeepSearchTokens) -> Bool {
        if tokens.isFolderOnly {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue else {
                return false
            }
        }

        // Check extension
        if let allowed = tokens.allowedExtensions {
            let lowerExt = ext.lowercased()
            if !allowed.contains(lowerExt) {
                return false
            }
        }

        // If size or date filters are active, inspect URL resource values
        if tokens.minSizeBytes != nil || tokens.maxSizeBytes != nil || tokens.minDate != nil {
            guard let vals = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else {
                return false
            }

            if let minBytes = tokens.minSizeBytes, let size = vals.fileSize, Int64(size) < minBytes {
                return false
            }
            if let maxBytes = tokens.maxSizeBytes, let size = vals.fileSize, Int64(size) > maxBytes {
                return false
            }
            if let minDate = tokens.minDate, let modDate = vals.contentModificationDate, modDate < minDate {
                return false
            }
        }

        return true
    }

    // MARK: - Duplicate Finder

    func findDuplicates(in candidateURLs: [URL], maxGroups: Int = 30) -> [DuplicateGroup] {
        var sizeMap: [Int64: [URL]] = [:]

        // 1. Group by exact file size (skipping online-only/dataless cloud files)
        for url in candidateURLs {
            guard !GoogleDriveIndexService.isCloudDatalessFile(url),
                  let vals = try? url.resourceValues(forKeys: [
                      .fileSizeKey,
                      .isDirectoryKey,
                      .isUbiquitousItemKey,
                      .ubiquitousItemDownloadingStatusKey
                  ]),
                  vals.isDirectory != true,
                  let size = vals.fileSize, size > 1024 else { // Ignore 0-byte or <1KB files
                continue
            }
            if vals.isUbiquitousItem == true,
               let dlStatus = vals.ubiquitousItemDownloadingStatus,
               dlStatus != .current {
                continue
            }
            sizeMap[Int64(size), default: []].append(url)
        }

        // 2. Filter potential duplicates (groups >= 2)
        let candidateGroups = sizeMap.filter { $0.value.count >= 2 }
        var resultGroups: [DuplicateGroup] = []

        for (size, urls) in candidateGroups {
            // Partition by deterministic SHA256 over (first 16KB + middle 16KB + last 16KB)
            var sampleBuckets: [String: [URL]] = [:]
            for url in urls {
                guard let fingerprint = computeFastFingerprint(url: url, fileSize: size) else {
                    continue
                }
                sampleBuckets[fingerprint, default: []].append(url)
            }

            for (_, sampleMatchedURLs) in sampleBuckets where sampleMatchedURLs.count >= 2 {
                // Full SHA256 verification for candidate matches
                var fullHashBuckets: [String: [URL]] = [:]
                for url in sampleMatchedURLs {
                    guard let fullHash = computeFullSHA256(url: url) else {
                        continue
                    }
                    fullHashBuckets[fullHash, default: []].append(url)
                }

                for (fullHash, matchedURLs) in fullHashBuckets where matchedURLs.count >= 2 {
                    let group = DuplicateGroup(
                        id: "\(size)_\(fullHash)",
                        fileName: matchedURLs.first?.lastPathComponent ?? "Duplicate",
                        sizeBytes: size,
                        items: matchedURLs
                    )
                    resultGroups.append(group)
                    if resultGroups.count >= maxGroups {
                        break
                    }
                }
                if resultGroups.count >= maxGroups {
                    break
                }
            }
            if resultGroups.count >= maxGroups {
                break
            }
        }

        // Sort by most wasted space first
        resultGroups.sort { $0.wastedBytes > $1.wastedBytes }
        return resultGroups
    }

    private func computeFastFingerprint(url: URL, fileSize: Int64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        let chunkSize = 16_384
        var hasher = SHA256()

        guard let firstChunk = try? handle.read(upToCount: chunkSize) else {
            return nil
        }
        hasher.update(data: firstChunk)

        if fileSize > Int64(chunkSize * 2) {
            let midOffset = UInt64(max(0, (fileSize / 2) - Int64(chunkSize / 2)))
            try? handle.seek(toOffset: midOffset)
            if let midChunk = try? handle.read(upToCount: chunkSize) {
                hasher.update(data: midChunk)
            }
        }

        if fileSize > Int64(chunkSize) {
            let tailOffset = UInt64(max(0, fileSize - Int64(chunkSize)))
            try? handle.seek(toOffset: tailOffset)
            if let lastChunk = try? handle.read(upToCount: chunkSize) {
                hasher.update(data: lastChunk)
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func computeFullSHA256(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 65_536
        while true {
            guard let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
