import AppKit
import Foundation

// Usage:
//   folder_badge_helper --set <folder_path>      (Synced / Active: Emerald Green Cloud Checkmark)
//   folder_badge_helper --broken <folder_path>   (Broken / Locked Shared Link: Red-Orange Cloud Slash Warning)
//   folder_badge_helper --clear <folder_path>    (Clear custom icon & tags)

enum BadgeState {
    case synced
    case broken
    case clear
}

func makeBadgedFolderIcon(state: BadgeState) -> NSImage {
    let baseIcon = NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericFolderIcon)))
    let targetSize = NSSize(width: 512, height: 512)
    baseIcon.size = targetSize

    let result = NSImage(size: targetSize)
    result.lockFocus()
    defer { result.unlockFocus() }

    baseIcon.draw(
        in: NSRect(origin: .zero, size: targetSize),
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )

    let badgeRect = NSRect(x: 272, y: 52, width: 204, height: 204)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.38)
    shadow.shadowBlurRadius = 14
    shadow.shadowOffset = NSSize(width: 0, height: -4)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let circlePath = NSBezierPath(ovalIn: badgeRect)
    switch state {
    case .synced:
        NSColor(calibratedRed: 0.06, green: 0.72, blue: 0.50, alpha: 1.0).setFill() // Emerald #10B981
    case .broken:
        NSColor(calibratedRed: 0.90, green: 0.22, blue: 0.21, alpha: 1.0).setFill() // Crimson Red #E53935
    case .clear:
        break
    }
    circlePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let borderPath = NSBezierPath(ovalIn: badgeRect.insetBy(dx: 4, dy: 4))
    borderPath.lineWidth = 8
    NSColor.white.withAlphaComponent(0.96).setStroke()
    borderPath.stroke()

    let symbolName: String = (state == .broken) ? "icloud.slash.fill" : "checkmark.icloud.fill"
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 100, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let configured = symbol.withSymbolConfiguration(config) {
            let symSize = configured.size
            let symRect = NSRect(
                x: badgeRect.midX - symSize.width / 2,
                y: badgeRect.midY - symSize.height / 2,
                width: symSize.width,
                height: symSize.height
            )
            configured.draw(in: symRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
    }

    return result
}

func setFolderVisualSyncState(path: String, state: BadgeState) {
    let url = URL(fileURLWithPath: path)
    let nsURL = url as NSURL
    let syncTag = "Đồng bộ GDrive"
    let brokenTag = "⚠️ Link GDrive bị khóa"

    var existingTags: [String] = []
    if let vals = try? url.resourceValues(forKeys: [.tagNamesKey]),
       let tags = vals.tagNames {
        existingTags = tags
    }

    let cleaned = existingTags.filter {
        !$0.hasPrefix(syncTag) && !$0.hasPrefix(brokenTag) && !$0.hasPrefix("Link GDrive")
    }

    switch state {
    case .synced:
        var newTags = cleaned
        newTags.append(syncTag)
        try? nsURL.setResourceValue(newTags, forKey: .tagNamesKey)
        try? nsURL.setResourceValue(NSNumber(value: 2), forKey: .labelNumberKey) // 2 = Green
        let icon = makeBadgedFolderIcon(state: .synced)
        _ = NSWorkspace.shared.setIcon(icon, forFile: path, options: [])

    case .broken:
        var newTags = cleaned
        newTags.append(brokenTag)
        try? nsURL.setResourceValue(newTags, forKey: .tagNamesKey)
        try? nsURL.setResourceValue(NSNumber(value: 6), forKey: .labelNumberKey) // 6 = Red
        let icon = makeBadgedFolderIcon(state: .broken)
        _ = NSWorkspace.shared.setIcon(icon, forFile: path, options: [])

    case .clear:
        try? nsURL.setResourceValue(cleaned, forKey: .tagNamesKey)
        try? nsURL.setResourceValue(NSNumber(value: 0), forKey: .labelNumberKey)
        _ = NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
    }
    NSWorkspace.shared.noteFileSystemChanged(path)
}

let args = CommandLine.arguments
if args.count >= 3 {
    let flag = args[1]
    let state: BadgeState
    if flag == "--set" {
        state = .synced
    } else if flag == "--broken" {
        state = .broken
    } else {
        state = .clear
    }
    for rawPath in args.dropFirst(2) {
        let std = (rawPath as NSString).standardizingPath
        setFolderVisualSyncState(path: std, state: state)
    }
}
