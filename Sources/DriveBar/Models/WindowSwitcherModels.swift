import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

enum WindowSwitcherScope: String, Codable, CaseIterable, Sendable {
    case allSpacesAndDisplays = "all"
    case currentDisplayOnly = "display"
    case currentSpaceOnly = "space"

    var displayName: String {
        switch self {
        case .allSpacesAndDisplays:
            return "Tất cả Desktop & Màn hình"
        case .currentDisplayOnly:
            return "Màn hình hiện tại"
        case .currentSpaceOnly:
            return "Desktop hiện tại"
        }
    }

    var shortBadgeTitle: String {
        switch self {
        case .allSpacesAndDisplays:
            return "Tất cả màn hình & Desktop"
        case .currentDisplayOnly:
            return "Màn hình này"
        case .currentSpaceOnly:
            return "Desktop này"
        }
    }

    func nextCycle() -> WindowSwitcherScope {
        switch self {
        case .allSpacesAndDisplays:
            return .currentDisplayOnly
        case .currentDisplayOnly:
            return .currentSpaceOnly
        case .currentSpaceOnly:
            return .allSpacesAndDisplays
        }
    }
}

struct SwitchableWindowItem: Identifiable {
    let id: String
    let windowID: CGWindowID?
    let pid: pid_t
    let bundleIdentifier: String
    let appName: String
    let windowTitle: String
    let appIcon: NSImage
    let bounds: CGRect
    let displayIndex: Int
    let displayName: String
    let totalDisplaysCount: Int
    let isOnCurrentDisplay: Bool
    let isOnCurrentSpace: Bool
    var isMinimized: Bool
    var isAppHidden: Bool
    let isFullscreen: Bool
    let isWindowlessApp: Bool
    let axWindow: AXUIElement?

    /// Card label shown below thumbnail (matches screenshot: concise window title or app name)
    var cardLabel: String {
        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return appName
        }
        return trimmed
    }

    /// Detailed header title shown in the Large Zoomed Preview card above the strip
    var zoomedHeaderTitle: String {
        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == appName {
            return appName
        }
        return trimmed
    }

    var zoomedHeaderSubtitle: String {
        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !trimmed.isEmpty && trimmed != appName {
            parts.append(appName)
        }
        if totalDisplaysCount > 1 && !displayName.isEmpty {
            parts.append(displayName)
        }
        if !isWindowlessApp && bounds.width > 0 && bounds.height > 0 {
            parts.append("\(Int(bounds.width))×\(Int(bounds.height))")
        }
        return parts.joined(separator: "  •  ")
    }

    var statusBadges: [String] {
        var badges: [String] = []
        if isMinimized {
            badges.append("Minimize")
        }
        if isAppHidden {
            badges.append("Đang ẩn (⌘H)")
        }
        if isWindowlessApp {
            badges.append("Không có cửa sổ")
        } else if !isMinimized && !isAppHidden && !isOnCurrentSpace {
            badges.append("Desktop khác")
        }
        if isFullscreen {
            badges.append("Toàn màn hình")
        }
        if totalDisplaysCount > 1 && !isOnCurrentDisplay && !isWindowlessApp {
            badges.append("Màn hình \(displayIndex + 1)")
        }
        return badges
    }
}
