import Foundation
import AppKit

/// Compact representation of a cached My Drive folder (`[path, [cleanSegs], [acrSegs]]`).
struct DriveFolderEntry: Sendable {
    let path: String
    let cleanSegs: [String]
    let acrSegs: [String]
}

extension DriveFolderEntry: Decodable {
    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            let p = try unkeyed.decode(String.self)
            let c = (try? unkeyed.decode([String].self)) ?? []
            let a = (try? unkeyed.decode([String].self)) ?? []
            self.path = p
            self.cleanSegs = c
            self.acrSegs = a
        } else {
            let single = try decoder.singleValueContainer()
            let p = try single.decode(String.self)
            self.path = p
            self.cleanSegs = []
            self.acrSegs = []
        }
    }
}

extension DriveFolderEntry: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(path)
        try container.encode(cleanSegs)
        try container.encode(acrSegs)
    }
}

/// Compact representation of a cached Shared Drive / Shortcut entry (`[path, isDir, displaySub, cleanSegs, acrSegs]`).
struct SharedDriveEntry: Sendable {
    let path: String
    let isDir: Bool
    let displaySub: String
    let cleanSegs: [String]
    let acrSegs: [String]
}

extension SharedDriveEntry: Decodable {
    init(from decoder: Decoder) throws {
        var unkeyed = try decoder.unkeyedContainer()
        self.path = try unkeyed.decode(String.self)
        self.isDir = (try? unkeyed.decode(Bool.self)) ?? true
        self.displaySub = (try? unkeyed.decode(String.self)) ?? ""
        self.cleanSegs = (try? unkeyed.decode([String].self)) ?? []
        self.acrSegs = (try? unkeyed.decode([String].self)) ?? []
    }
}

extension SharedDriveEntry: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(path)
        try container.encode(isDir)
        try container.encode(displaySub)
        try container.encode(cleanSegs)
        try container.encode(acrSegs)
    }
}

struct FolderCachePayload: Codable, Sendable {
    let timestamp: Double
    let root: String?
    let items: [DriveFolderEntry]?
    let folders: [DriveFolderEntry]?
}

struct SharedCachePayload: Codable, Sendable {
    let timestamp: Double
    let root: String?
    let items: [SharedDriveEntry]
}

/// Compact representation of a cached file (`[path, ext, cleanName, acronym, cleanParent]`).
struct DriveFileEntry: Sendable {
    let path: String
    let ext: String
    let cleanName: String
    let acronym: String
    let cleanParent: String
}

extension DriveFileEntry: Decodable {
    init(from decoder: Decoder) throws {
        var unkeyed = try decoder.unkeyedContainer()
        self.path = try unkeyed.decode(String.self)
        self.ext = (try? unkeyed.decode(String.self)) ?? ""
        self.cleanName = (try? unkeyed.decode(String.self)) ?? ""
        self.acronym = (try? unkeyed.decode(String.self)) ?? ""
        self.cleanParent = (try? unkeyed.decode(String.self)) ?? ""
    }
}

extension DriveFileEntry: Encodable {
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(path)
        try container.encode(ext)
        try container.encode(cleanName)
        try container.encode(acronym)
        try container.encode(cleanParent)
    }
}

struct FileCachePayload: Codable, Sendable {
    let timestamp: Double
    let items: [DriveFileEntry]
}

struct HistoryRecord: Codable, Sendable {
    var count: Int
    var last_used: Double
}

enum ResultItemKind: Equatable {
    case driveFolder(path: String)
    case driveFile(path: String)
    case openInFinder(path: String)
    case localApp(path: String)
    case parentFolder(path: String)
    case systemCommand(id: String)
    case aiQuickCommand(action: String)
    case webURLQuickConvert(url: URL, preview: Bool)
    case clipboardItem(id: String)
    case calculatorResult(expression: String, rawValue: String, formattedValue: String)
    case infoBanner
}

extension NSEvent.ModifierFlags {
    /// Intentional shortcut modifiers only (Command, Option, Control, Shift), ignoring CapsLock, Fn, and NumericPad.
    var cleanShortcutModifiers: NSEvent.ModifierFlags {
        intersection([.command, .option, .control, .shift])
    }
}

struct SearchResultItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let path: String?
    let isDirectory: Bool
    let kind: ResultItemKind
    let badge: String?
    let sfSymbolFallback: String?

    var fileURL: URL? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path)
    }
}

enum LauncherScreenMode: Equatable {
    case search
    case universalActions(target: ActionTarget)
    case openWithPicker(fileURL: URL, previousTarget: ActionTarget)
    case destinationPicker(operation: FileTransferOperation, sources: [URL])
    case batchRename(urls: [URL], previousTarget: ActionTarget)
    case markdownPreview(title: String, sourceURL: URL, savedMDURL: URL?, markdown: String, estimatedTokens: Int, engineUsed: String)
}
