import AppKit
import Foundation

// Usage:
//   folder_badge_helper --set <folder_path>
//   folder_badge_helper --clear <folder_path>

func makeBadgedFolderIcon() -> NSImage {
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

    // Draw a subtle dark-glass pill + green checkmark cloud badge in the lower-right / center-right of the folder
    let badgeRect = NSRect(x: 276, y: 56, width: 196, height: 196)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 14
    shadow.shadowOffset = NSSize(width: 0, height: -4)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    let circlePath = NSBezierPath(ovalIn: badgeRect)
    NSColor(calibratedRed: 0.06, green: 0.72, blue: 0.50, alpha: 1.0).setFill() // Emerald green #10B981
    circlePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let borderPath = NSBezierPath(ovalIn: badgeRect.insetBy(dx: 4, dy: 4))
    borderPath.lineWidth = 8
    NSColor.white.withAlphaComponent(0.95).setStroke()
    borderPath.stroke()

    if let symbol = NSImage(systemSymbolName: "checkmark.icloud.fill", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 102, weight: .bold)
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

func setFolderVisualSyncState(path: String, synced: Bool) {
    let url = URL(fileURLWithPath: path)
    let nsURL = url as NSURL
    let tagName = "Đồng bộ GDrive"

    var existingTags: [String] = []
    if let vals = try? url.resourceValues(forKeys: [.tagNamesKey]),
       let tags = vals.tagNames {
        existingTags = tags
    }

    if synced {
        var newTags = existingTags.filter { !$0.hasPrefix(tagName) }
        newTags.append(tagName)
        try? nsURL.setResourceValue(newTags, forKey: .tagNamesKey)
        try? nsURL.setResourceValue(NSNumber(value: 2), forKey: .labelNumberKey) // 2 = Green Finder label
        let icon = makeBadgedFolderIcon()
        _ = NSWorkspace.shared.setIcon(icon, forFile: path, options: [])
    } else {
        let newTags = existingTags.filter { !$0.hasPrefix(tagName) }
        try? nsURL.setResourceValue(newTags, forKey: .tagNamesKey)
        try? nsURL.setResourceValue(NSNumber(value: 0), forKey: .labelNumberKey)
        _ = NSWorkspace.shared.setIcon(nil, forFile: path, options: [])
    }
    NSWorkspace.shared.noteFileSystemChanged(path)
}

let args = CommandLine.arguments
if args.count >= 3 {
    let mode = args[1]
    for rawPath in args.dropFirst(2) {
        let std = (rawPath as NSString).standardizingPath
        setFolderVisualSyncState(path: std, synced: mode == "--set")
    }
}
