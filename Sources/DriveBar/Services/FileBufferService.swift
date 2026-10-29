import Foundation
import AppKit

@MainActor
final class FileBufferService: ObservableObject {
    static let shared = FileBufferService()

    @Published private(set) var items: [URL] = []

    private init() {}

    func add(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard FileManager.default.fileExists(atPath: standardized.path) else { return }
        if !items.contains(standardized) {
            items.append(standardized)
        }
    }

    func addAll(_ urls: [URL]) {
        for u in urls {
            add(u)
        }
    }

    func remove(_ url: URL) {
        let standardized = url.standardizedFileURL
        items.removeAll { $0 == standardized }
    }

    func removeLast() {
        if !items.isEmpty {
            items.removeLast()
        }
    }

    func clear() {
        items.removeAll()
    }
}
