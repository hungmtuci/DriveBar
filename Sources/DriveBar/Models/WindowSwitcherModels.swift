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
    let desktopName: String
    let spaceID: UInt64?
    let totalDisplaysCount: Int
    let isOnCurrentDisplay: Bool
    let isOnCurrentSpace: Bool
    var isMinimized: Bool
    var isAppHidden: Bool
    let isFullscreen: Bool
    let isWindowlessApp: Bool
    let axWindow: AXUIElement?
    let searchableTextNormalized: String

    init(
        id: String,
        windowID: CGWindowID?,
        pid: pid_t,
        bundleIdentifier: String,
        appName: String,
        windowTitle: String,
        appIcon: NSImage,
        bounds: CGRect,
        displayIndex: Int,
        displayName: String,
        desktopName: String,
        spaceID: UInt64?,
        totalDisplaysCount: Int,
        isOnCurrentDisplay: Bool,
        isOnCurrentSpace: Bool,
        isMinimized: Bool,
        isAppHidden: Bool,
        isFullscreen: Bool,
        isWindowlessApp: Bool,
        axWindow: AXUIElement?
    ) {
        self.id = id
        self.windowID = windowID
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.windowTitle = windowTitle
        self.appIcon = appIcon
        self.bounds = bounds
        self.displayIndex = displayIndex
        self.displayName = displayName
        self.desktopName = desktopName
        self.spaceID = spaceID
        self.totalDisplaysCount = totalDisplaysCount
        self.isOnCurrentDisplay = isOnCurrentDisplay
        self.isOnCurrentSpace = isOnCurrentSpace
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
        self.isFullscreen = isFullscreen
        self.isWindowlessApp = isWindowlessApp
        self.axWindow = axWindow

        let rawCombined = "\(appName) \(windowTitle) \(desktopName) \(displayName) \(bundleIdentifier)"
        self.searchableTextNormalized = GoogleDriveIndexService.removeAccents(rawCombined).lowercased()
    }

    /// Card primary label shown below thumbnail
    var cardLabel: String {
        let trimmed = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return appName
        }
        return trimmed
    }

    /// Card secondary location label: always shows Desktop name + Monitor name clearly
    var cardLocationSubtitle: String {
        var parts: [String] = []
        if isMinimized {
            parts.append("Minimize")
        } else if isWindowlessApp {
            parts.append("Không có cửa sổ")
        }
        if !desktopName.isEmpty {
            parts.append(desktopName)
        }
        if !displayName.isEmpty {
            parts.append(displayName)
        }
        return parts.joined(separator: " • ")
    }

    /// Optional compact corner pill on thumbnail only for minimized/hidden/fullscreen states
    var cardStateCornerBadge: String? {
        if isMinimized {
            return "Minimize"
        }
        if isAppHidden {
            return "Đang ẩn"
        }
        if isFullscreen {
            return "Toàn màn hình"
        }
        return nil
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
        if !isWindowlessApp && bounds.width > 0 && bounds.height > 0 {
            parts.append("\(Int(bounds.width))×\(Int(bounds.height))")
        }
        return parts.joined(separator: "  •  ")
    }

    /// Badges shown in the right side of the Zoomed Preview header (Desktop Name, Monitor Name, State)
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
        }
        if !desktopName.isEmpty {
            badges.append(desktopName)
        }
        if !displayName.isEmpty {
            badges.append(displayName)
        }
        return badges
    }
}
