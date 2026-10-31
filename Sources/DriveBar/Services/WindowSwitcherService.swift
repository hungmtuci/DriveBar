import Foundation
import AppKit
import Carbon
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

enum WindowSnapPlacement: String, Sendable {
    case leftHalf
    case rightHalf
    case maximize
    case centerRestore

    var toastLabel: String {
        switch self {
        case .leftHalf: return "Đã căn cửa sổ sang Nửa trái (⌃←)"
        case .rightHalf: return "Đã căn cửa sổ sang Nửa phải (⌃→)"
        case .maximize: return "Đã phóng tối đa cửa sổ (⌃↑)"
        case .centerRestore: return "Đã đưa cửa sổ ra giữa màn hình (⌃↓)"
        }
    }
}

@_silgen_name("CGSMainConnectionID")
private func _CGSMainConnectionID() -> UInt32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func _CGSCopyManagedDisplaySpaces(_ cid: UInt32) -> CFArray?

@_silgen_name("CGSCopySpacesForWindows")
private func _CGSCopySpacesForWindows(_ cid: UInt32, _ mask: Int32, _ windowIDs: CFArray) -> CFArray?

@_silgen_name("CGDisplayCreateUUIDFromDisplayID")
private func _CGDisplayCreateUUIDFromDisplayID(_ displayID: UInt32) -> Unmanaged<CFUUID>?

@MainActor
final class WindowSwitcherService: ObservableObject {
    static let shared = WindowSwitcherService()

    @Published private(set) var items: [SwitchableWindowItem] = []
    @Published var filterQuery: String = "" {
        didSet {
            if filterQuery != oldValue && !isSuppressingFilterDidSet {
                applySearchFilterFromSessionCache(resetSelectionToFirst: true)
            }
        }
    }
    @Published var selectedIndex: Int = 0 {
        didSet {
            requestHighResZoomPreviewForSelection(debounced: true)
        }
    }
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    @Published private(set) var zoomedPreviewImage: NSImage?
    @Published private(set) var zoomedPreviewWindowID: CGWindowID?
    @Published private(set) var hasScreenRecordingPermission: Bool = CGPreflightScreenCaptureAccess()
    @Published private(set) var hasAccessibilityPermission: Bool = AXIsProcessTrusted()
    @Published var sessionSameAppPID: pid_t? {
        didSet {
            if sessionSameAppPID == nil {
                sessionSameAppName = nil
                sessionSameAppIcon = nil
            } else if let pid = sessionSameAppPID,
                      let app = NSRunningApplication(processIdentifier: pid) {
                sessionSameAppName = app.localizedName ?? sessionSameAppName
                sessionSameAppIcon = app.icon ?? sessionSameAppIcon
            }
        }
    }

    /// True only when user is navigating windows using keyboard shortcuts (Tab / Arrow keys).
    /// Used by SwiftUI ScrollView to prevent jarring automatic scroll jumps during mouse hover!
    @Published var isKeyboardNavigating: Bool = false
    @Published private(set) var sessionSameAppName: String?
    @Published private(set) var sessionSameAppIcon: NSImage?
    @Published var focusSearchTrigger: Int = 0

    private var isSuppressingFilterDidSet: Bool = false

    private var allSessionItems: [SwitchableWindowItem] = []
    private var mruPIDs: [pid_t] = []
    private var mruWindowKeys: [String] = []
    private var scWindowsByID: [CGWindowID: SCWindow] = [:]
    private var scWindowTitlesByID: [CGWindowID: String] = [:]
    private var thumbnailCaptureTask: Task<Void, Never>?
    private var zoomCaptureTask: Task<Void, Never>?

    private struct DisplayInfo {
        let index: Int
        let displayID: CGDirectDisplayID
        let uuidString: String
        let cgBounds: CGRect
        let name: String
        let isActiveDisplay: Bool
    }

    private struct SpaceMetadata {
        let spaceID: UInt64
        let desktopName: String
        let desktopOrder: Int
        let display: DisplayInfo
        let isCurrentOnDisplay: Bool
        let isFullScreenSpace: Bool
    }

    private struct SpaceCatalog {
        let bySpaceID: [UInt64: SpaceMetadata]
        let activeSpaceIDsAllDisplays: Set<UInt64>
        let activeDisplayCurrentSpaceID: UInt64?
        let defaultSpaceForDisplayID: [CGDirectDisplayID: SpaceMetadata]
    }

    private struct RawCGWindow {
        let wid: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let cgTitle: String?
        let isOnScreen: Bool
        let zRank: Int
        let spaceIDs: [UInt64]
    }

    private init() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            mruPIDs.append(front.processIdentifier)
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                guard let self else { return }
                if pid != ProcessInfo.processInfo.processIdentifier {
                    self.recordMRUPID(pid)
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            Task { @MainActor in
                guard let self else { return }
                self.mruPIDs.removeAll { $0 == pid }
                if WindowSwitcherController.shared.isVisible {
                    self.purgeSessionItemsForPID(pid)
                }
            }
        }
    }

    func recordMRUPID(_ pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        mruPIDs.removeAll { $0 == pid }
        mruPIDs.insert(pid, at: 0)
        if mruPIDs.count > 64 {
            mruPIDs.removeLast(mruPIDs.count - 64)
        }
    }

    func recordMRUWindowKey(_ key: String) {
        mruWindowKeys.removeAll { $0 == key }
        mruWindowKeys.insert(key, at: 0)
        if mruWindowKeys.count > 128 {
            mruWindowKeys.removeLast(mruWindowKeys.count - 128)
        }
    }

    var selectedItem: SwitchableWindowItem? {
        guard selectedIndex >= 0 && selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    func triggerSearchInputFocus() {
        focusSearchTrigger &+= 1
    }

    func refreshPermissionStates() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        hasScreenRecordingPermission = CGPreflightScreenCaptureAccess()
    }

    func promptAccessibilityPermission() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func promptScreenRecordingPermission() {
        _ = CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Full Multi-Window / Multi-Space / Multi-Display Discovery

    func reloadSessionWindows(
        sameAppPID: pid_t? = nil,
        frontmostPIDBeforePresentation: pid_t? = nil,
        selectPreviousWindow: Bool = true,
        moveBackward: Bool = false
    ) {
        refreshPermissionStates()
        if let frontPID = frontmostPIDBeforePresentation {
            recordMRUPID(frontPID)
        }
        self.sessionSameAppPID = sameAppPID
        if !filterQuery.isEmpty {
            isSuppressingFilterDidSet = true
            filterQuery = ""
            isSuppressingFilterDidSet = false
        }

        let discovered = collectSwitchableWindows(
            sameAppPID: sameAppPID,
            frontmostPID: frontmostPIDBeforePresentation
        )
        self.allSessionItems = discovered
        self.items = discovered

        if discovered.isEmpty {
            selectedIndex = 0
            zoomedPreviewImage = nil
            zoomedPreviewWindowID = nil
        } else if moveBackward {
            selectedIndex = discovered.count - 1
        } else if selectPreviousWindow && discovered.count > 1 {
            selectedIndex = 1
        } else {
            selectedIndex = 0
        }

        requestHighResZoomPreviewForSelection(debounced: false)
        startAsyncScreenCaptureRefresh()
    }

    func focusSameAppWindows(for item: SwitchableWindowItem) {
        let targetID = item.id
        sessionSameAppName = item.appName
        sessionSameAppIcon = item.appIcon
        sessionSameAppPID = item.pid
        if !filterQuery.isEmpty {
            isSuppressingFilterDidSet = true
            filterQuery = ""
            isSuppressingFilterDidSet = false
        }
        rebuildFilteredItemsPreservingSelection(preferredItemID: targetID)
    }

    func focusSameAppPID(_ pid: pid_t, appName: String? = nil, appIcon: NSImage? = nil) {
        let targetID = selectedItem?.id
        if let appName { sessionSameAppName = appName }
        if let appIcon { sessionSameAppIcon = appIcon }
        sessionSameAppPID = pid
        if !filterQuery.isEmpty {
            isSuppressingFilterDidSet = true
            filterQuery = ""
            isSuppressingFilterDidSet = false
        }
        rebuildFilteredItemsPreservingSelection(preferredItemID: targetID)
    }

    func clearSameAppFilter() {
        let targetID = selectedItem?.id
        sessionSameAppPID = nil
        rebuildFilteredItemsPreservingSelection(preferredItemID: targetID)
    }

    func rebuildFilteredItemsPreservingSelection(preferredItemID: String? = nil) {
        let previousID = preferredItemID ?? selectedItem?.id
        let discovered = collectSwitchableWindows(
            sameAppPID: sessionSameAppPID,
            frontmostPID: mruPIDs.first
        )
        self.allSessionItems = discovered
        applySearchFilterFromSessionCache(resetSelectionToFirst: false, preferredItemID: previousID)
        requestHighResZoomPreviewForSelection(debounced: false)
        startAsyncScreenCaptureRefresh()
    }

    private func applySearchFilterFromSessionCache(resetSelectionToFirst: Bool, preferredItemID: String? = nil) {
        let previousID = preferredItemID ?? selectedItem?.id
        let trimmed = GoogleDriveIndexService.removeAccents(filterQuery)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.isEmpty {
            self.items = allSessionItems
        } else {
            let tokens = trimmed.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            // Filter & score while preserving adjacent same-app grouping!
            var matched: [SwitchableWindowItem] = []
            var bestAppScoreByPID: [pid_t: Int] = [:]
            var itemScoreByID: [String: Int] = [:]

            for (idx, item) in allSessionItems.enumerated() {
                let allFound = tokens.allSatisfy { item.searchableTextNormalized.contains($0) }
                guard allFound else { continue }

                let appNorm = GoogleDriveIndexService.removeAccents(item.appName).lowercased()
                let titleNorm = GoogleDriveIndexService.removeAccents(item.windowTitle).lowercased()

                var score = max(0, 500 - idx)
                if appNorm.hasPrefix(trimmed) {
                    score += 4_000
                } else if appNorm.contains(trimmed) {
                    score += 2_500
                }
                if titleNorm.hasPrefix(trimmed) {
                    score += 3_200
                } else if titleNorm.contains(trimmed) {
                    score += 1_800
                }

                matched.append(item)
                itemScoreByID[item.id] = score
                bestAppScoreByPID[item.pid] = max(bestAppScoreByPID[item.pid] ?? 0, score)
            }

            // Keep windows of the same app adjacent even during search filtering!
            matched.sort { a, b in
                if a.pid != b.pid {
                    let appA = bestAppScoreByPID[a.pid] ?? 0
                    let appB = bestAppScoreByPID[b.pid] ?? 0
                    if appA != appB { return appA > appB }
                }
                return (itemScoreByID[a.id] ?? 0) > (itemScoreByID[b.id] ?? 0)
            }
            self.items = matched
        }

        if items.isEmpty {
            selectedIndex = 0
            zoomedPreviewImage = nil
            zoomedPreviewWindowID = nil
        } else if resetSelectionToFirst {
            selectedIndex = 0
        } else if let previousID, let foundIdx = items.firstIndex(where: { $0.id == previousID }) {
            selectedIndex = foundIdx
        } else {
            selectedIndex = min(max(0, selectedIndex), items.count - 1)
        }
    }

    func stepSelection(delta: Int) {
        guard !items.isEmpty else { return }
        isKeyboardNavigating = true
        let count = items.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    private func collectSwitchableWindows(sameAppPID: pid_t?, frontmostPID: pid_t?) -> [SwitchableWindowItem] {
        let settings = AppSettings.shared
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = Self.buildDisplayList()
        let spaceCatalog = Self.buildSpaceCatalog(displays: displays)
        let cid = _CGSMainConnectionID()
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())

        // 1. Snapshot WindowServer Z-Order & Space Membership across ALL Spaces
        let cgAllRaw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let cgOnScreenRaw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreenIDs = Set(cgOnScreenRaw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })

        var cgByPID: [pid_t: [RawCGWindow]] = [:]
        var cgByWID: [CGWindowID: RawCGWindow] = [:]
        var bestZByPID: [pid_t: Int] = [:]

        for (zIdx, dict) in cgAllRaw.enumerated() {
            let layer = dict[kCGWindowLayer as String] as? Int ?? -1
            guard layer == 0 else { continue }
            let alpha = dict[kCGWindowAlpha as String] as? Double ?? 0
            guard alpha > 0.02 else { continue }
            guard let wid = dict[kCGWindowNumber as String] as? CGWindowID,
                  let pidInt = dict[kCGWindowOwnerPID as String] as? Int else { continue }
            let pid = pid_t(pidInt)

            let bDict = dict[kCGWindowBounds as String] as? [String: Double] ?? [:]
            let rect = CGRect(
                x: bDict["X"] ?? 0,
                y: bDict["Y"] ?? 0,
                width: bDict["Width"] ?? 0,
                height: bDict["Height"] ?? 0
            )
            guard rect.width >= 110 && rect.height >= 80 else { continue }

            let cgTitle = dict[kCGWindowName as String] as? String
            let spaceIDs: [UInt64]
            if cid != 0, let rawSpaces = _CGSCopySpacesForWindows(cid, 0x7, [NSNumber(value: wid)] as CFArray) as? [NSNumber] {
                spaceIDs = rawSpaces.map(\.uint64Value)
            } else {
                spaceIDs = []
            }

            let entry = RawCGWindow(
                wid: wid,
                pid: pid,
                bounds: rect,
                cgTitle: cgTitle,
                isOnScreen: onScreenIDs.contains(wid),
                zRank: zIdx,
                spaceIDs: spaceIDs
            )
            cgByPID[pid, default: []].append(entry)
            cgByWID[wid] = entry
            if !spaceIDs.isEmpty && bestZByPID[pid] == nil {
                bestZByPID[pid] = zIdx
            }
        }

        // 2. Enumerate Regular Running Applications
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated else { return false }
            if app.processIdentifier == ownPID {
                return AppDelegate.shared?.isSettingsWindowVisible == true
            }
            if let filterPID = sameAppPID, app.processIdentifier != filterPID {
                return false
            }
            return app.activationPolicy == .regular
        }

        let axTrusted = AXIsProcessTrusted()

        struct RankedCandidate {
            let item: SwitchableWindowItem
            let appGroupRank: Int
            let stateTier: Int
            let intraAppRank: Int
        }

        var candidates: [RankedCandidate] = []

        for app in runningApps {
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier ?? ""
            let appName = app.localizedName ?? "Ứng dụng"
            let appIcon = app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle)
            let appHidden = app.isHidden

            if appHidden && !settings.windowSwitcherShowHiddenApps && sameAppPID == nil {
                continue
            }

            let appRank: Int = {
                if let frontmostPID, pid == frontmostPID {
                    return 0
                }
                if let mruIdx = mruPIDs.firstIndex(of: pid) {
                    return 1 + mruIdx
                }
                if let bestZ = bestZByPID[pid] {
                    return 200 + bestZ
                }
                return 5_000 + Int(pid % 1_000)
            }()

            var handledWIDs = Set<CGWindowID>()
            var appProducedWindow = false
            var axQuerySucceeded = false
            var axRawCount = 0
            let isSafariFamily = Self.isSafariBundleIdentifier(bundleID)

            // 2A. Rich Accessibility Window Discovery (exact window titles, minimized windows, individual AX handles)
            if axTrusted && pid != ownPID {
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, 0.05)

                var winsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
                   let axWins = winsRef as? [AXUIElement] {
                    axQuerySucceeded = true
                    axRawCount = axWins.count

                    for (axIdx, axWin) in axWins.enumerated() {
                        // Record WID immediately BEFORE any filter `continue` so Step 2B can NEVER
                        // resurrect an AX element that Accessibility explicitly classified as non-standard!
                        var wid: CGWindowID = 0
                        let hasWID = (_AXUIElementGetWindow(axWin, &wid) == .success && wid != 0)
                        if hasWID {
                            if handledWIDs.contains(wid) { continue }
                            handledWIDs.insert(wid)
                        }

                        let role = Self.axString(axWin, kAXRoleAttribute) ?? ""
                        let subrole = Self.axString(axWin, kAXSubroleAttribute) ?? ""
                        guard role == "AXWindow" else { continue }
                        guard subrole == "AXStandardWindow" || subrole == "AXDialog" else { continue }

                        let isMin = Self.axBool(axWin, kAXMinimizedAttribute) ?? false
                        if isMin && !settings.windowSwitcherShowMinimized && sameAppPID == nil {
                            continue
                        }

                        let rawAXTitle = Self.axString(axWin, kAXTitleAttribute) ?? ""
                        let axTitle = rawAXTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                        let isFull = Self.axBool(axWin, "AXFullScreen") ?? false

                        let hasCloseBtn = Self.axHasElement(axWin, kAXCloseButtonAttribute)
                        let hasMinBtn = Self.axHasElement(axWin, kAXMinimizeButtonAttribute)
                        let hasZoomBtn = Self.axHasElement(axWin, kAXZoomButtonAttribute)
                            || Self.axHasElement(axWin, "AXFullScreenButton")

                        // Exclude borderless/auxiliary internal AXWindows (popovers, completion lists, backdrops)
                        if !hasCloseBtn && !hasMinBtn && !hasZoomBtn && !isFull {
                            if isSafariFamily || subrole != "AXStandardWindow" || axTitle.isEmpty {
                                continue
                            }
                        }

                        // Every real Safari browser/settings window has a non-empty AXTitle (e.g. "Start Page",
                        // "Trang bắt đầu", "Untitled", webpage title, or Settings tab title); empty-title Safari
                        // AXWindows are internal StartPage / TabOverview / AutoFill / Fullscreen helper windows.
                        if isSafariFamily && axTitle.isEmpty {
                            continue
                        }

                        let cgEntry = hasWID ? cgByWID[wid] : nil

                        // For non-minimized, non-hidden windows with a CGWindowID, WindowServer must actually own
                        // a visible layer-0 backing surface on >= 1 Space (eliminates alpha-0 / ordered-out / off-Space ghosts!).
                        if !isMin && !appHidden && hasWID {
                            guard let cgEntry else {
                                continue
                            }
                            if cid != 0 && cgEntry.spaceIDs.isEmpty && !cgEntry.isOnScreen {
                                continue
                            }
                        }

                        var winBounds = cgEntry?.bounds ?? Self.axBounds(axWin) ?? .zero
                        if bundleID == "com.apple.finder" && axTitle.isEmpty && winBounds.width >= mainDisplayBounds.width {
                            continue
                        }
                        if (winBounds.width < 110 || winBounds.height < 80) && !isMin {
                            continue
                        }
                        if winBounds == .zero {
                            winBounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
                        }

                        let resolvedLoc = Self.resolveWindowLocation(
                            bounds: winBounds,
                            spaceIDs: cgEntry?.spaceIDs ?? [],
                            cgIsOnScreen: cgEntry?.isOnScreen ?? false,
                            isMinimized: isMin,
                            isAppHidden: appHidden,
                            isFullscreen: isFull,
                            displays: displays,
                            spaceCatalog: spaceCatalog
                        )

                        let effectiveScope: WindowSwitcherScope = (sameAppPID != nil)
                            ? .allSpacesAndDisplays
                            : settings.windowSwitcherScope
                        if !Self.matchesScope(
                            effectiveScope,
                            isOnCurrentDisplay: resolvedLoc.display.isActiveDisplay,
                            isOnActiveDisplayCurrentSpace: resolvedLoc.isOnActiveDisplayCurrentSpace,
                            isMinimized: isMin,
                            isHidden: appHidden
                        ) {
                            continue
                        }

                        let resolvedTitle = !axTitle.isEmpty
                            ? axTitle
                            : (hasWID ? (scWindowTitlesByID[wid] ?? cgEntry?.cgTitle ?? "") : "")

                        let itemID = hasWID ? "wid:\(wid)" : "ax:\(pid):\(axIdx)"
                        let stateTier = Self.computeWindowStateTier(
                            isVisibleOnAnyMonitorCurrentSpace: resolvedLoc.isVisibleOnItsDisplaySpace,
                            isMinimized: isMin,
                            isAppHidden: appHidden
                        )
                        let intraRank = Self.computeIntraAppRank(
                            itemID: itemID,
                            cgRank: cgEntry?.zRank,
                            desktopOrder: resolvedLoc.desktopOrder,
                            mruWindowKeys: mruWindowKeys,
                            fallbackOffset: axIdx
                        )

                        let item = SwitchableWindowItem(
                            id: itemID,
                            windowID: hasWID ? wid : nil,
                            pid: pid,
                            bundleIdentifier: bundleID,
                            appName: appName,
                            windowTitle: resolvedTitle,
                            appIcon: appIcon,
                            bounds: winBounds,
                            displayIndex: resolvedLoc.display.index,
                            displayName: resolvedLoc.display.name,
                            desktopName: resolvedLoc.desktopName,
                            spaceID: resolvedLoc.primarySpaceID,
                            totalDisplaysCount: displays.count,
                            isOnCurrentDisplay: resolvedLoc.display.isActiveDisplay,
                            isOnCurrentSpace: resolvedLoc.isVisibleOnItsDisplaySpace,
                            isMinimized: isMin,
                            isAppHidden: appHidden,
                            isFullscreen: isFull || resolvedLoc.isFullScreenSpace,
                            isWindowlessApp: false,
                            axWindow: axWin
                        )
                        candidates.append(RankedCandidate(
                            item: item,
                            appGroupRank: appRank,
                            stateTier: stateTier,
                            intraAppRank: intraRank
                        ))
                        appProducedWindow = true
                    }
                }
            }

            // 2B. Windows on OTHER Desktops / Full-Screen Spaces (verified via CGS Space membership!)
            if let cgWins = cgByPID[pid] {
                for cgEntry in cgWins where !handledWIDs.contains(cgEntry.wid) {
                    // Eliminate phantom offscreen backing windows (e.g. Electron/Singlebox/Safari 500x500 or titlebar proxies):
                    // Every real user window on any Desktop or Full-Screen Space belongs to >= 1 CGS Space!
                    if cid != 0 && cgEntry.spaceIDs.isEmpty {
                        continue
                    }

                    // CRITICAL: kAXWindowsAttribute (Step 2A) ALREADY returned 100% of real user windows on
                    // currently active Spaces across all displays! Any remaining on-screen / active-Space CGWindow
                    // not in kAXWindowsAttribute is an internal child/backdrop/popover/toolbar surface (e.g. Safari).
                    let isOnAnyActiveSpace = cgEntry.isOnScreen || cgEntry.spaceIDs.contains(where: {
                        spaceCatalog.activeSpaceIDsAllDisplays.contains($0)
                    })
                    if axQuerySucceeded && isOnAnyActiveSpace {
                        if appProducedWindow || axRawCount > 0 || isSafariFamily || bundleID.hasPrefix("com.apple.") {
                            continue
                        }
                    }

                    // If ScreenCaptureKit has already cataloged shareable windows, exclude non-shareable helper CGWindows
                    if !scWindowsByID.isEmpty && scWindowsByID[cgEntry.wid] == nil {
                        continue
                    }

                    // Filter Finder desktop backdrop
                    if bundleID == "com.apple.finder" &&
                       cgEntry.bounds.width >= mainDisplayBounds.width &&
                       cgEntry.bounds.height >= mainDisplayBounds.height - 40 &&
                       cgEntry.bounds.minY <= 30 {
                        continue
                    }

                    let scTitle = (scWindowTitlesByID[cgEntry.wid] ?? cgEntry.cgTitle ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if isSafariFamily && !scWindowsByID.isEmpty && scTitle.isEmpty {
                        continue
                    }

                    let resolvedLoc = Self.resolveWindowLocation(
                        bounds: cgEntry.bounds,
                        spaceIDs: cgEntry.spaceIDs,
                        cgIsOnScreen: cgEntry.isOnScreen,
                        isMinimized: false,
                        isAppHidden: appHidden,
                        isFullscreen: false,
                        displays: displays,
                        spaceCatalog: spaceCatalog
                    )

                    // Filter NSToolbarFullScreenWindow & shallow blank toolbar/tabbar companion CGWindows on other Spaces
                    if scTitle.isEmpty && cgEntry.bounds.height < 165 {
                        let hasLargerSiblingOnSameSpace = cgWins.contains { other in
                            other.wid != cgEntry.wid &&
                            other.bounds.height >= max(220, cgEntry.bounds.height * 1.8) &&
                            !Set(other.spaceIDs).isDisjoint(with: cgEntry.spaceIDs)
                        }
                        if hasLargerSiblingOnSameSpace || resolvedLoc.isFullScreenSpace {
                            continue
                        }
                    }

                    let isFull = resolvedLoc.isFullScreenSpace || (
                        abs(cgEntry.bounds.width - resolvedLoc.display.cgBounds.width) <= 4 &&
                        abs(cgEntry.bounds.height - resolvedLoc.display.cgBounds.height) <= 40
                    )

                    let effectiveCGScope: WindowSwitcherScope = (sameAppPID != nil)
                        ? .allSpacesAndDisplays
                        : settings.windowSwitcherScope
                    if !Self.matchesScope(
                        effectiveCGScope,
                        isOnCurrentDisplay: resolvedLoc.display.isActiveDisplay,
                        isOnActiveDisplayCurrentSpace: resolvedLoc.isOnActiveDisplayCurrentSpace,
                        isMinimized: false,
                        isHidden: appHidden
                    ) {
                        continue
                    }

                    let itemID = "wid:\(cgEntry.wid)"
                    let stateTier = Self.computeWindowStateTier(
                        isVisibleOnAnyMonitorCurrentSpace: resolvedLoc.isVisibleOnItsDisplaySpace,
                        isMinimized: false,
                        isAppHidden: appHidden
                    )
                    let intraRank = Self.computeIntraAppRank(
                        itemID: itemID,
                        cgRank: cgEntry.zRank,
                        desktopOrder: resolvedLoc.desktopOrder,
                        mruWindowKeys: mruWindowKeys,
                        fallbackOffset: cgEntry.zRank
                    )

                    let item = SwitchableWindowItem(
                        id: itemID,
                        windowID: cgEntry.wid,
                        pid: pid,
                        bundleIdentifier: bundleID,
                        appName: appName,
                        windowTitle: scTitle,
                        appIcon: appIcon,
                        bounds: cgEntry.bounds,
                        displayIndex: resolvedLoc.display.index,
                        displayName: resolvedLoc.display.name,
                        desktopName: resolvedLoc.desktopName,
                        spaceID: resolvedLoc.primarySpaceID,
                        totalDisplaysCount: displays.count,
                        isOnCurrentDisplay: resolvedLoc.display.isActiveDisplay,
                        isOnCurrentSpace: resolvedLoc.isVisibleOnItsDisplaySpace,
                        isMinimized: false,
                        isAppHidden: appHidden,
                        isFullscreen: isFull,
                        isWindowlessApp: false,
                        axWindow: nil
                    )
                    candidates.append(RankedCandidate(
                        item: item,
                        appGroupRank: appRank,
                        stateTier: stateTier,
                        intraAppRank: intraRank
                    ))
                    appProducedWindow = true
                }
            }

            // 2C. Optional Windowless Running Applications
            if !appProducedWindow && settings.windowSwitcherShowWindowlessApps && pid != ownPID {
                let activeDisp = displays.first(where: \.isActiveDisplay) ?? displays.first
                let activeSpaceName = activeDisp.flatMap { spaceCatalog.defaultSpaceForDisplayID[$0.displayID]?.desktopName } ?? ""
                let itemID = "app:\(pid)"
                let mruPos = mruPIDs.firstIndex(of: pid) ?? 99
                let item = SwitchableWindowItem(
                    id: itemID,
                    windowID: nil,
                    pid: pid,
                    bundleIdentifier: bundleID,
                    appName: appName,
                    windowTitle: "",
                    appIcon: appIcon,
                    bounds: .zero,
                    displayIndex: activeDisp?.index ?? 0,
                    displayName: activeDisp?.name ?? "",
                    desktopName: activeSpaceName,
                    spaceID: nil,
                    totalDisplaysCount: displays.count,
                    isOnCurrentDisplay: true,
                    isOnCurrentSpace: true,
                    isMinimized: false,
                    isAppHidden: appHidden,
                    isFullscreen: false,
                    isWindowlessApp: true,
                    axWindow: nil
                )
                candidates.append(RankedCandidate(
                    item: item,
                    appGroupRank: 10_000 + mruPos,
                    stateTier: 4,
                    intraAppRank: 0
                ))
            }
        }

        // Sort so ALL windows of the same application sit right next to each other!
        candidates.sort { a, b in
            if a.appGroupRank != b.appGroupRank {
                return a.appGroupRank < b.appGroupRank
            }
            if a.item.pid != b.item.pid {
                return a.item.pid < b.item.pid
            }
            if a.stateTier != b.stateTier {
                return a.stateTier < b.stateTier
            }
            return a.intraAppRank < b.intraAppRank
        }
        return candidates.map(\.item)
    }

    private struct ResolvedWindowLocation {
        let display: DisplayInfo
        let desktopName: String
        let primarySpaceID: UInt64?
        let desktopOrder: Int
        let isVisibleOnItsDisplaySpace: Bool
        let isOnActiveDisplayCurrentSpace: Bool
        let isFullScreenSpace: Bool
    }

    private static func resolveWindowLocation(
        bounds: CGRect,
        spaceIDs: [UInt64],
        cgIsOnScreen: Bool,
        isMinimized: Bool,
        isAppHidden: Bool,
        isFullscreen: Bool,
        displays: [DisplayInfo],
        spaceCatalog: SpaceCatalog
    ) -> ResolvedWindowLocation {
        let geometricDisplay = matchDisplay(for: bounds, displays: displays)

        if !spaceIDs.isEmpty {
            // Prefer an active Space if the window spans multiple Spaces (e.g. "All Desktops")
            let chosenSpaceID = spaceIDs.first(where: { spaceCatalog.activeSpaceIDsAllDisplays.contains($0) }) ?? spaceIDs[0]
            if let meta = spaceCatalog.bySpaceID[chosenSpaceID] {
                let deskLabel: String = {
                    if spaceIDs.count > 1 && !meta.isFullScreenSpace {
                        return "\(meta.desktopName) (Mọi Desktop)"
                    }
                    return meta.desktopName
                }()
                let visibleOnItsDisplay = !isMinimized && !isAppHidden && spaceCatalog.activeSpaceIDsAllDisplays.contains(chosenSpaceID)
                let onActiveDisplaySpace = !isMinimized && !isAppHidden && (
                    spaceCatalog.activeDisplayCurrentSpaceID.map { spaceIDs.contains($0) } ?? cgIsOnScreen
                )
                return ResolvedWindowLocation(
                    display: meta.display,
                    desktopName: deskLabel,
                    primarySpaceID: chosenSpaceID,
                    desktopOrder: meta.desktopOrder,
                    isVisibleOnItsDisplaySpace: visibleOnItsDisplay,
                    isOnActiveDisplayCurrentSpace: onActiveDisplaySpace,
                    isFullScreenSpace: meta.isFullScreenSpace
                )
            }
        }

        // Fallback (e.g. minimized window whose CGS space list is empty while docked)
        let fallbackSpace = spaceCatalog.defaultSpaceForDisplayID[geometricDisplay.displayID]
        let deskLabel = isFullscreen ? "Toàn màn hình" : (fallbackSpace?.desktopName ?? "Desktop 1")
        let visibleNow = !isMinimized && !isAppHidden && cgIsOnScreen
        return ResolvedWindowLocation(
            display: geometricDisplay,
            desktopName: deskLabel,
            primarySpaceID: fallbackSpace?.spaceID,
            desktopOrder: fallbackSpace?.desktopOrder ?? 1,
            isVisibleOnItsDisplaySpace: visibleNow,
            isOnActiveDisplayCurrentSpace: visibleNow && geometricDisplay.isActiveDisplay,
            isFullScreenSpace: isFullscreen
        )
    }

    private static func matchesScope(
        _ scope: WindowSwitcherScope,
        isOnCurrentDisplay: Bool,
        isOnActiveDisplayCurrentSpace: Bool,
        isMinimized: Bool,
        isHidden: Bool
    ) -> Bool {
        switch scope {
        case .allSpacesAndDisplays:
            return true
        case .currentDisplayOnly:
            return isOnCurrentDisplay
        case .currentSpaceOnly:
            return isOnActiveDisplayCurrentSpace || (isOnCurrentDisplay && (isMinimized || isHidden))
        }
    }

    private static func computeWindowStateTier(
        isVisibleOnAnyMonitorCurrentSpace: Bool,
        isMinimized: Bool,
        isAppHidden: Bool
    ) -> Int {
        if isMinimized { return 2 }
        if isAppHidden { return 3 }
        if isVisibleOnAnyMonitorCurrentSpace { return 0 }
        return 1
    }

    private static func computeIntraAppRank(
        itemID: String,
        cgRank: Int?,
        desktopOrder: Int,
        mruWindowKeys: [String],
        fallbackOffset: Int
    ) -> Int {
        if let cgRank, cgRank == 0 {
            return 0
        }
        if let mruIdx = mruWindowKeys.firstIndex(of: itemID) {
            return 10 + mruIdx * 5
        }
        if let cgRank {
            return 500 + cgRank
        }
        return 5_000 + desktopOrder * 50 + fallbackOffset
    }

    // MARK: - Live ScreenCaptureKit Thumbnails & Debounced High-Res Zoom Preview

    private func startAsyncScreenCaptureRefresh() {
        thumbnailCaptureTask?.cancel()
        guard CGPreflightScreenCaptureAccess() else { return }

        let targetItems = self.allSessionItems
        guard !targetItems.isEmpty else { return }

        thumbnailCaptureTask = Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else {
                return
            }
            guard !Task.isCancelled else { return }

            var winMap: [CGWindowID: SCWindow] = [:]
            var titleUpdated = false
            for scWin in content.windows {
                winMap[scWin.windowID] = scWin
                if let t = scWin.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !t.isEmpty,
                   scWindowTitlesByID[scWin.windowID] != t {
                    scWindowTitlesByID[scWin.windowID] = t
                    titleUpdated = true
                }
            }
            self.scWindowsByID = winMap

            // Prune any cross-Space Step 2B ghost CGWindows that ScreenCaptureKit confirms are non-shareable
            // or empty Safari auxiliary surfaces, AND backfill cross-Space window titles cleanly
            var didMutateSessionItems = false
            let beforeCount = self.allSessionItems.count
            self.allSessionItems.removeAll { item in
                guard item.axWindow == nil,
                      !item.isMinimized,
                      !item.isAppHidden,
                      !item.isWindowlessApp,
                      let wid = item.windowID else {
                    return false
                }
                guard let scWin = winMap[wid] else {
                    return true
                }
                if Self.isSafariBundleIdentifier(item.bundleIdentifier) {
                    let liveTitle = (scWin.title ?? item.windowTitle).trimmingCharacters(in: .whitespacesAndNewlines)
                    if liveTitle.isEmpty {
                        return true
                    }
                }
                return false
            }
            if self.allSessionItems.count != beforeCount {
                didMutateSessionItems = true
            }

            if titleUpdated {
                for idx in self.allSessionItems.indices {
                    if self.allSessionItems[idx].windowTitle.isEmpty,
                       let wid = self.allSessionItems[idx].windowID,
                       let scTitle = scWindowTitlesByID[wid], !scTitle.isEmpty {
                        let old = self.allSessionItems[idx]
                        self.allSessionItems[idx] = SwitchableWindowItem(
                            id: old.id,
                            windowID: old.windowID,
                            pid: old.pid,
                            bundleIdentifier: old.bundleIdentifier,
                            appName: old.appName,
                            windowTitle: scTitle,
                            appIcon: old.appIcon,
                            bounds: old.bounds,
                            displayIndex: old.displayIndex,
                            displayName: old.displayName,
                            desktopName: old.desktopName,
                            spaceID: old.spaceID,
                            totalDisplaysCount: old.totalDisplaysCount,
                            isOnCurrentDisplay: old.isOnCurrentDisplay,
                            isOnCurrentSpace: old.isOnCurrentSpace,
                            isMinimized: old.isMinimized,
                            isAppHidden: old.isAppHidden,
                            isFullscreen: old.isFullscreen,
                            isWindowlessApp: old.isWindowlessApp,
                            axWindow: old.axWindow
                        )
                        didMutateSessionItems = true
                    }
                }
            }

            if didMutateSessionItems {
                applySearchFilterFromSessionCache(resetSelectionToFirst: false)
            }

            // Capture High-Res Zoom Preview for currently selected item FIRST
            requestHighResZoomPreviewForSelection(debounced: false)

            // Capture strip thumbnails in batches, pruning any 100% transparent empty ghost windows
            let activeSnapshot = self.allSessionItems
            var pendingBatch: [CGWindowID: NSImage] = [:]
            var transparentGhostWIDs = Set<CGWindowID>()

            for item in activeSnapshot {
                if Task.isCancelled { break }
                guard let wid = item.windowID, let scWin = winMap[wid] else { continue }
                if let cgImg = await Self.captureSCWindowImage(scWin: scWin, maxDimension: 520) {
                    let shouldVerifyOpacity = !item.isMinimized && !item.isAppHidden && !item.isWindowlessApp && (
                        item.windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        Self.isSafariBundleIdentifier(item.bundleIdentifier)
                    )
                    if shouldVerifyOpacity && Self.isImageCompletelyTransparent(cgImg) {
                        transparentGhostWIDs.insert(wid)
                        continue
                    }

                    let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                    pendingBatch[wid] = nsImg
                    if self.selectedItem?.windowID == wid && self.zoomedPreviewImage == nil {
                        self.zoomedPreviewImage = nsImg
                        self.zoomedPreviewWindowID = wid
                    }
                    if pendingBatch.count >= 4 {
                        for (k, v) in pendingBatch {
                            self.thumbnails[k] = v
                        }
                        pendingBatch.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !pendingBatch.isEmpty && !Task.isCancelled {
                for (k, v) in pendingBatch {
                    self.thumbnails[k] = v
                }
            }
            if !transparentGhostWIDs.isEmpty && !Task.isCancelled {
                let prevCount = self.allSessionItems.count
                self.allSessionItems.removeAll { item in
                    guard let wid = item.windowID else { return false }
                    return transparentGhostWIDs.contains(wid)
                }
                if self.allSessionItems.count != prevCount {
                    applySearchFilterFromSessionCache(resetSelectionToFirst: false)
                    requestHighResZoomPreviewForSelection(debounced: false)
                }
            }
        }
    }

    private func requestHighResZoomPreviewForSelection(debounced: Bool) {
        zoomCaptureTask?.cancel()
        guard let item = selectedItem, let wid = item.windowID else {
            zoomedPreviewImage = nil
            zoomedPreviewWindowID = nil
            return
        }

        // Instant 0ms preview from strip thumbnail cache while stepping rapidly
        if zoomedPreviewWindowID != wid {
            zoomedPreviewImage = thumbnails[wid]
            zoomedPreviewWindowID = wid
        }

        guard CGPreflightScreenCaptureAccess(), let scWin = scWindowsByID[wid] else { return }

        zoomCaptureTask = Task { @MainActor in
            if debounced {
                try? await Task.sleep(nanoseconds: 65_000_000)
                guard !Task.isCancelled else { return }
            }
            if let cgImg = await Self.captureSCWindowImage(scWin: scWin, maxDimension: 1440) {
                guard !Task.isCancelled else { return }
                let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                if self.selectedItem?.windowID == wid {
                    self.zoomedPreviewImage = nsImg
                    self.zoomedPreviewWindowID = wid
                }
                if self.thumbnails[wid] == nil {
                    self.thumbnails[wid] = nsImg
                }
            }
        }
    }

    private nonisolated static func captureSCWindowImage(scWin: SCWindow, maxDimension: CGFloat) async -> CGImage? {
        let frame = scWin.frame
        guard frame.width >= 40 && frame.height >= 40 else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: scWin)
        let config = SCStreamConfiguration()
        let aspect = frame.width / max(frame.height, 1)
        if aspect >= 1.0 {
            let w = min(maxDimension, frame.width * 2.0)
            config.width = max(64, Int(w.rounded()))
            config.height = max(64, Int((w / aspect).rounded()))
        } else {
            let h = min(maxDimension, frame.height * 2.0)
            config.height = max(64, Int(h.rounded()))
            config.width = max(64, Int((h * aspect).rounded()))
        }
        config.showsCursor = false
        config.scalesToFit = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    // MARK: - Jump to Window (Same App Multi-Window, Minimized, Hidden, Other Monitor, Other Space)

    func activateWindow(_ item: SwitchableWindowItem) {
        recordMRUPID(item.pid)
        recordMRUWindowKey(item.id)

        if item.pid == ProcessInfo.processInfo.processIdentifier {
            AppDelegate.shared?.bringSettingsWindowToFront()
            return
        }

        guard let runningApp = NSRunningApplication(processIdentifier: item.pid) else { return }

        if runningApp.isHidden {
            runningApp.unhide()
        }

        NSApp.yieldActivation(to: runningApp)

        if item.isWindowlessApp {
            runningApp.activate(options: [.activateAllWindows])
            if let bundleURL = runningApp.bundleURL {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg, completionHandler: nil)
            }
            return
        }

        if let axWin = item.axWindow ?? item.windowID.flatMap({ Self.findAXWindow(pid: item.pid, targetWID: $0) }) {
            Self.raiseAndFocusAXWindow(axWin, unminimize: item.isMinimized)
            runningApp.activate()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035) {
                Self.raiseAndFocusAXWindow(axWin, unminimize: false)
            }
            return
        }

        // Cross-Space / Full-Screen Space window activation:
        // 1. Try direct AX remote token resolution by exact CGWindowID (jumps accurately even when multiple windows share the same title!)
        if AXIsProcessTrusted(), let targetWID = item.windowID {
            let pid = item.pid
            if let remoteWin = Self.resolveOffSpaceAXWindow(pid: pid, targetWID: targetWID) {
                Self.raiseAndFocusAXWindow(remoteWin, unminimize: item.isMinimized)
                runningApp.activate()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    Self.raiseAndFocusAXWindow(remoteWin, unminimize: false)
                }
                return
            }
        }

        // 2. Fallback to app's Window menu if title is unique across this app's windows
        if AXIsProcessTrusted() && !item.windowTitle.isEmpty {
            let duplicateTitleCount = allSessionItems.filter {
                $0.pid == item.pid && $0.windowTitle == item.windowTitle
            }.count
            if duplicateTitleCount <= 1 && Self.selectWindowFromAppWindowMenu(pid: item.pid, targetTitle: item.windowTitle) {
                runningApp.activate()
                return
            }
        }

        // 3. Final fallback: activate app & re-query AXWindow once macOS transitions Space
        runningApp.activate(options: [.activateAllWindows])

        if AXIsProcessTrusted(), let targetWID = item.windowID {
            let pid = item.pid
            let fallbackTitle = item.windowTitle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                if !Self.raiseAXWindowMatchingWID(pid: pid, targetWID: targetWID), !fallbackTitle.isEmpty {
                    _ = Self.selectWindowFromAppWindowMenu(pid: pid, targetTitle: fallbackTitle)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                _ = Self.raiseAXWindowMatchingWID(pid: pid, targetWID: targetWID)
            }
        }
    }

    func snapAndActivateWindow(_ item: SwitchableWindowItem, placement: WindowSnapPlacement) {
        activateWindow(item)
        guard AXIsProcessTrusted(), !item.isWindowlessApp, !item.isFullscreen else { return }

        let screens = NSScreen.screens
        let targetScreen: NSScreen? = {
            if item.displayIndex >= 0 && item.displayIndex < screens.count {
                return screens[item.displayIndex]
            }
            let mouse = NSEvent.mouseLocation
            return screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? screens.first
        }()
        guard let screen = targetScreen else { return }

        let vis = screen.visibleFrame
        let cocoaTarget: NSRect
        switch placement {
        case .leftHalf:
            cocoaTarget = NSRect(x: vis.minX, y: vis.minY, width: floor(vis.width / 2.0), height: vis.height)
        case .rightHalf:
            let halfW = floor(vis.width / 2.0)
            cocoaTarget = NSRect(x: vis.maxX - halfW, y: vis.minY, width: halfW, height: vis.height)
        case .maximize:
            cocoaTarget = vis
        case .centerRestore:
            let w = round(vis.width * 0.78)
            let h = round(vis.height * 0.82)
            cocoaTarget = NSRect(
                x: round(vis.midX - w / 2.0),
                y: round(vis.midY - h / 2.0),
                width: w,
                height: h
            )
        }

        // Convert Cocoa bottom-left visibleFrame to Accessibility/Quartz top-left coordinates
        let primaryHeight = screens.first?.frame.height ?? screen.frame.height
        let axRect = CGRect(
            x: cocoaTarget.minX.rounded(),
            y: (primaryHeight - cocoaTarget.maxY).rounded(),
            width: cocoaTarget.width.rounded(),
            height: cocoaTarget.height.rounded()
        )

        let pid = item.pid
        let wid = item.windowID
        let directAX = item.axWindow

        let applySnap = {
            let resolved = directAX
                ?? wid.flatMap { Self.findAXWindow(pid: pid, targetWID: $0) }
                ?? wid.flatMap { Self.resolveOffSpaceAXWindow(pid: pid, targetWID: $0) }
            guard let axWin = resolved else { return }
            Self.applyAXWindowFrame(axWin, quartzRect: axRect)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            applySnap()
        }
        if !item.isOnCurrentSpace || item.isMinimized {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
                applySnap()
            }
        }
        FloatingToastController.shared.showSuccess(
            title: placement.toastLabel,
            subtitle: item.zoomedHeaderTitle,
            symbol: "rectangle.split.2x1"
        )
    }

    // MARK: - In-Switcher Quick Actions (Close ⌘W, Minimize ⌘M, Hide ⌘H, Quit ⌘Q / Force Quit ⌥⌘Q)

    func purgeSessionItemsForPID(_ pid: pid_t) {
        let before = allSessionItems.count
        allSessionItems.removeAll { $0.pid == pid }
        if allSessionItems.count != before {
            applySearchFilterFromSessionCache(resetSelectionToFirst: false)
            requestHighResZoomPreviewForSelection(debounced: false)
            if allSessionItems.isEmpty && filterQuery.isEmpty && sessionSameAppPID == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    if WindowSwitcherController.shared.isVisible && WindowSwitcherService.shared.items.isEmpty {
                        WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)
                    }
                }
            }
        }
    }

    func purgeSessionItem(id: String) {
        let before = allSessionItems.count
        allSessionItems.removeAll { $0.id == id }
        if allSessionItems.count != before {
            applySearchFilterFromSessionCache(resetSelectionToFirst: false)
            requestHighResZoomPreviewForSelection(debounced: false)
            if allSessionItems.isEmpty && filterQuery.isEmpty && sessionSameAppPID == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    if WindowSwitcherController.shared.isVisible && WindowSwitcherService.shared.items.isEmpty {
                        WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)
                    }
                }
            }
        }
    }

    private func resolveLiveAXWindow(for item: SwitchableWindowItem, timeout: Float = 0.85) -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let resolved = item.windowID.flatMap { Self.findAXWindow(pid: item.pid, targetWID: $0, timeout: timeout) }
            ?? item.axWindow
            ?? item.windowID.flatMap { Self.resolveOffSpaceAXWindow(pid: item.pid, targetWID: $0) }
        if let resolved {
            AXUIElementSetMessagingTimeout(resolved, timeout)
        }
        return resolved
    }

    func closeSelectedWindow() {
        guard let item = selectedItem else { return }
        closeWindow(item)
    }

    func closeWindow(_ item: SwitchableWindowItem) {
        if item.isWindowlessApp {
            quitApp(for: item, force: false)
            return
        }

        if item.pid == ProcessInfo.processInfo.processIdentifier {
            NSApp.windows.first(where: { $0.title.contains("DriveBar") })?.close()
            purgeSessionItem(id: item.id)
            return
        }

        refreshPermissionStates()
        guard hasAccessibilityPermission else {
            WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)
            FloatingToastController.shared.showError(
                title: "Cần bật lại quyền Trợ năng (Accessibility) để đóng cửa sổ (⌘W)",
                subtitle: "Đang mở Cài đặt Trợ năng macOS — hãy bật công tắc DriveBar"
            )
            promptAccessibilityPermission()
            return
        }

        let initialModalPresent = Self.appHasActiveModalOrSheet(pid: item.pid, targetWID: item.windowID)
        var didSendClose = false
        var usedMenuFallback = false

        if let axWin = resolveLiveAXWindow(for: item, timeout: 0.85) {
            if !item.isMinimized {
                AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
            }
            var closeBtnRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, kAXCloseButtonAttribute as CFString, &closeBtnRef) == .success,
               let closeBtn = closeBtnRef {
                let closeElem = closeBtn as! AXUIElement
                AXUIElementSetMessagingTimeout(closeElem, 0.85)
                if Self.axBool(closeElem, kAXEnabledAttribute) != false,
                   AXUIElementPerformAction(closeElem, kAXPressAction as CFString) == .success {
                    didSendClose = true
                }
            }

            if !didSendClose {
                AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(axWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                usedMenuFallback = true
                if Self.pressMenuCommandChar(pid: item.pid, cmdChar: "W") {
                    didSendClose = true
                } else if Self.postCommandKeyToPID(pid: item.pid, keyCode: CGKeyCode(kVK_ANSI_W)) {
                    didSendClose = true
                }
            }
        } else {
            usedMenuFallback = true
            if Self.pressMenuCommandChar(pid: item.pid, cmdChar: "W")
                || Self.postCommandKeyToPID(pid: item.pid, keyCode: CGKeyCode(kVK_ANSI_W)) {
                didSendClose = true
            }
        }

        guard didSendClose else {
            NSSound.beep()
            return
        }

        scheduleWindowCloseFollowUp(
            item: item,
            initialModalPresent: initialModalPresent,
            usedMenuFallback: usedMenuFallback,
            delays: [0.08, 0.24, 0.48, 0.85],
            stepIndex: 0
        )
    }

    private func scheduleWindowCloseFollowUp(
        item: SwitchableWindowItem,
        initialModalPresent: Bool,
        usedMenuFallback: Bool,
        delays: [TimeInterval],
        stepIndex: Int
    ) {
        guard stepIndex < delays.count else { return }
        let wait = stepIndex == 0 ? delays[0] : (delays[stepIndex] - delays[stepIndex - 1])

        DispatchQueue.main.asyncAfter(deadline: .now() + max(0.05, wait)) { [weak self] in
            guard let self else { return }
            guard WindowSwitcherController.shared.isVisible else { return }

            if !Self.isWindowStillAlive(wid: item.windowID, pid: item.pid, wasMinimized: item.isMinimized) {
                self.purgeSessionItem(id: item.id)
                return
            }

            // If closing triggered a "Save changes?" sheet/dialog (e.g. Microsoft Word, Excel, TextEdit),
            // automatically dismiss Windows Preview and bring that window & Save prompt to the front!
            if stepIndex >= 1,
               !initialModalPresent,
               Self.appHasActiveModalOrSheet(pid: item.pid, targetWID: item.windowID) {
                WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)
                self.activateWindow(item)
                return
            }

            // Second-stage fallback if AXCloseButton reported .success on a custom-chrome window without closing it
            var nextUsedFallback = usedMenuFallback
            if stepIndex == 1 && !usedMenuFallback {
                nextUsedFallback = true
                if !Self.pressMenuCommandChar(pid: item.pid, cmdChar: "W") {
                    _ = Self.postCommandKeyToPID(pid: item.pid, keyCode: CGKeyCode(kVK_ANSI_W))
                }
            }

            if stepIndex + 1 < delays.count {
                self.scheduleWindowCloseFollowUp(
                    item: item,
                    initialModalPresent: initialModalPresent,
                    usedMenuFallback: nextUsedFallback,
                    delays: delays,
                    stepIndex: stepIndex + 1
                )
            } else {
                self.rebuildFilteredItemsPreservingSelection()
            }
        }
    }

    func toggleMinimizeSelectedWindow() {
        guard let item = selectedItem, !item.isWindowlessApp else { return }
        refreshPermissionStates()
        guard hasAccessibilityPermission else {
            WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)
            FloatingToastController.shared.showError(
                title: "Cần bật lại quyền Trợ năng (Accessibility) để thu nhỏ cửa sổ (⌘M)",
                subtitle: "Đang mở Cài đặt Trợ năng macOS — hãy bật công tắc DriveBar"
            )
            promptAccessibilityPermission()
            return
        }

        if let axWin = resolveLiveAXWindow(for: item, timeout: 0.8) {
            let newState: CFBoolean = item.isMinimized ? kCFBooleanFalse : kCFBooleanTrue
            if AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, newState) == .success {
                for delay in [0.12, 0.32] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, WindowSwitcherController.shared.isVisible else { return }
                        self.rebuildFilteredItemsPreservingSelection()
                    }
                }
                return
            }
        }
        NSSound.beep()
    }

    func toggleHideSelectedApp() {
        guard let item = selectedItem,
              let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        if app.isHidden {
            app.unhide()
        } else {
            app.hide()
        }
        for delay in [0.10, 0.28] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, WindowSwitcherController.shared.isVisible else { return }
                self.rebuildFilteredItemsPreservingSelection()
            }
        }
    }

    func quitSelectedApp(force: Bool = false) {
        guard let item = selectedItem else { return }
        quitApp(for: item, force: force)
    }

    func quitApp(for item: SwitchableWindowItem, force: Bool = false) {
        guard item.pid != ProcessInfo.processInfo.processIdentifier else { return }

        // Finder does not exit on NSRunningApplication.terminate(); close its open windows instead unless Force Quit (Relaunch)
        if item.bundleIdentifier == "com.apple.finder" && !force {
            refreshPermissionStates()
            guard hasAccessibilityPermission else {
                WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)
                FloatingToastController.shared.showError(
                    title: "Cần bật lại quyền Trợ năng (Accessibility) để đóng cửa sổ Finder",
                    subtitle: "Đang mở Cài đặt Trợ năng macOS — hãy bật công tắc DriveBar"
                )
                promptAccessibilityPermission()
                return
            }
            let finderWindows = allSessionItems.filter { $0.pid == item.pid && !$0.isWindowlessApp }
            for fw in finderWindows {
                if let axWin = resolveLiveAXWindow(for: fw, timeout: 0.65) {
                    var closeBtnRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(axWin, kAXCloseButtonAttribute as CFString, &closeBtnRef) == .success,
                       let closeBtn = closeBtnRef {
                        let closeElem = closeBtn as! AXUIElement
                        AXUIElementSetMessagingTimeout(closeElem, 0.65)
                        _ = AXUIElementPerformAction(closeElem, kAXPressAction as CFString)
                    }
                }
            }
            for delay in [0.12, 0.30, 0.55] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, WindowSwitcherController.shared.isVisible else { return }
                    self.rebuildFilteredItemsPreservingSelection()
                }
            }
            return
        }

        guard let app = NSRunningApplication(processIdentifier: item.pid) else {
            purgeSessionItemsForPID(item.pid)
            return
        }

        if force {
            _ = app.forceTerminate()
            FloatingToastController.shared.showSuccess(
                title: "Đã buộc thoát \(item.appName)",
                subtitle: "Force Quit (⌥⌘Q)",
                symbol: "xmark.octagon"
            )
            for delay in [0.08, 0.25, 0.50] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    if app.isTerminated {
                        self.purgeSessionItemsForPID(item.pid)
                    }
                }
            }
            return
        }

        let initialModalPresent = AXIsProcessTrusted()
            ? Self.appHasActiveModalOrSheet(pid: item.pid, targetWID: item.windowID)
            : false

        let accepted = app.terminate()
        if !accepted && AXIsProcessTrusted() {
            if !Self.pressMenuCommandChar(pid: item.pid, cmdChar: "Q") {
                _ = Self.postCommandKeyToPID(pid: item.pid, keyCode: CGKeyCode(kVK_ANSI_Q))
            }
        }

        // Multi-wave monitoring:
        // - Clean apps exit within 40–1,000ms -> didTerminateApplicationNotification + wave checks purge immediately.
        // - Apps with unsaved documents (e.g. Microsoft Word, Excel) open a Save prompt or wait for foreground activation ->
        //   automatically hand focus to the app so the user can interact with the Save / Quit dialog!
        for checkDelay in [0.16, 0.36, 0.68] {
            DispatchQueue.main.asyncAfter(deadline: .now() + checkDelay) { [weak self] in
                guard let self, WindowSwitcherController.shared.isVisible else { return }
                if app.isTerminated {
                    self.purgeSessionItemsForPID(item.pid)
                    return
                }
                if !item.isWindowlessApp,
                   !Self.isWindowStillAlive(wid: item.windowID, pid: item.pid, wasMinimized: item.isMinimized) {
                    self.purgeSessionItem(id: item.id)
                }
                if AXIsProcessTrusted(),
                   !initialModalPresent,
                   Self.appHasActiveModalOrSheet(pid: item.pid, targetWID: item.windowID) {
                    WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)
                    self.activateWindow(item)
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) { [weak self] in
            guard let self, WindowSwitcherController.shared.isVisible else { return }
            if app.isTerminated {
                self.purgeSessionItemsForPID(item.pid)
                return
            }
            // App is still alive after 1.15s -> it blocked silent quit (unsaved changes / quit confirmation prompt).
            // Bring the app forward so its confirmation dialog is visible and actionable!
            WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)
            self.activateWindow(item)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                if !app.isTerminated && (!AXIsProcessTrusted() || !Self.appHasActiveModalOrSheet(pid: item.pid, targetWID: item.windowID)) {
                    _ = app.terminate()
                }
            }
        }
    }

    private static func isWindowStillAlive(wid: CGWindowID?, pid: pid_t, wasMinimized: Bool) -> Bool {
        if let app = NSRunningApplication(processIdentifier: pid), app.isTerminated {
            return false
        }

        if AXIsProcessTrusted(), let wid {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.12)
            var winsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
               let wins = winsRef as? [AXUIElement] {
                for w in wins {
                    var foundWID: CGWindowID = 0
                    if _AXUIElementGetWindow(w, &foundWID) == .success && foundWID == wid {
                        return true
                    }
                }
                if wasMinimized {
                    return false
                }
            }
        }

        guard let wid else { return false }
        let cgAll = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for dict in cgAll {
            guard let num = dict[kCGWindowNumber as String] as? CGWindowID, num == wid else { continue }
            let layer = dict[kCGWindowLayer as String] as? Int ?? -1
            let alpha = dict[kCGWindowAlpha as String] as? Double ?? 0
            if layer == 0 && alpha > 0.05 {
                let cid = _CGSMainConnectionID()
                if cid != 0, !wasMinimized {
                    let spaces = (_CGSCopySpacesForWindows(cid, 0x7, [NSNumber(value: wid)] as CFArray) as? [NSNumber]) ?? []
                    if spaces.isEmpty {
                        return false
                    }
                }
                return true
            }
        }
        return false
    }

    private static func appHasActiveModalOrSheet(pid: pid_t, targetWID: CGWindowID?) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.15)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else {
            return false
        }

        for w in wins {
            let role = axString(w, kAXRoleAttribute) ?? ""
            let subrole = axString(w, kAXSubroleAttribute) ?? ""
            if role == "AXSheet" || subrole == "AXDialog" || subrole == "AXSystemDialog" {
                return true
            }
            if axBool(w, kAXModalAttribute) == true {
                return true
            }
            var sheetsRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(w, "AXSheets" as CFString, &sheetsRef) == .success,
               let sheets = sheetsRef as? [AXUIElement],
               !sheets.isEmpty {
                return true
            }
            if let targetWID {
                var wid: CGWindowID = 0
                if _AXUIElementGetWindow(w, &wid) == .success && wid == targetWID {
                    var childrenRef: CFTypeRef?
                    if AXUIElementCopyAttributeValue(w, kAXChildrenAttribute as CFString, &childrenRef) == .success,
                       let children = childrenRef as? [AXUIElement],
                       children.contains(where: { (axString($0, kAXRoleAttribute) ?? "") == "AXSheet" }) {
                        return true
                    }
                }
            }
        }
        return false
    }

    private static func pressMenuCommandChar(pid: pid_t, cmdChar: String) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let targetUpper = cmdChar.uppercased()
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return false }

        var barItemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &barItemsRef) == .success,
              let barItems = barItemsRef as? [AXUIElement] else { return false }

        for barItem in barItems.prefix(8) {
            var subMenusRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(barItem, kAXChildrenAttribute as CFString, &subMenusRef) == .success,
                  let subMenus = subMenusRef as? [AXUIElement],
                  let menu = subMenus.first else { continue }

            var itemsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
                  let menuItems = itemsRef as? [AXUIElement] else { continue }

            for mi in menuItems {
                let charAttr = (axString(mi, kAXMenuItemCmdCharAttribute) ?? "").uppercased()
                guard charAttr == targetUpper else { continue }
                var modsRef: CFTypeRef?
                var modsVal = 0
                if AXUIElementCopyAttributeValue(mi, kAXMenuItemCmdModifiersAttribute as CFString, &modsRef) == .success,
                   let num = modsRef as? NSNumber {
                    modsVal = num.intValue
                }
                // kAXMenuItemModifierNone (0) means pure Command+<char> without Shift/Option/Control!
                guard modsVal == 0 else { continue }
                if axBool(mi, kAXEnabledAttribute) == false { continue }
                AXUIElementSetMessagingTimeout(mi, 0.5)
                if AXUIElementPerformAction(mi, kAXPressAction as CFString) == .success {
                    return true
                }
            }
        }
        return false
    }

    private static func postCommandKeyToPID(pid: pid_t, keyCode: CGKeyCode) -> Bool {
        guard let src = CGEventSource(stateID: .combinedSessionState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.postToPid(pid)
        up.postToPid(pid)
        return true
    }

    // MARK: - Display Localized Names & Mission Control Desktop / Space Mapping

    private static func buildDisplayList() -> [DisplayInfo] {
        let mouseLoc = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let activeID = activeScreen.flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }

        return NSScreen.screens.enumerated().map { idx, scr in
            let id = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
            let uuidStr = _CGDisplayCreateUUIDFromDisplayID(id)
                .map { (CFUUIDCreateString(nil, $0.takeRetainedValue()) as String).uppercased() } ?? ""
            let cleanName = scr.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
            return DisplayInfo(
                index: idx,
                displayID: id,
                uuidString: uuidStr,
                cgBounds: CGDisplayBounds(id),
                name: cleanName.isEmpty ? "Màn hình \(idx + 1)" : cleanName,
                isActiveDisplay: id == activeID
            )
        }
    }

    private static func buildSpaceCatalog(displays: [DisplayInfo]) -> SpaceCatalog {
        let cid = _CGSMainConnectionID()
        guard cid != 0,
              let managedDisplays = _CGSCopyManagedDisplaySpaces(cid) as? [[String: Any]],
              !managedDisplays.isEmpty else {
            var defaultsByDisplay: [CGDirectDisplayID: SpaceMetadata] = [:]
            for (i, d) in displays.enumerated() {
                defaultsByDisplay[d.displayID] = SpaceMetadata(
                    spaceID: UInt64(i + 1),
                    desktopName: "Desktop \(i + 1)",
                    desktopOrder: i + 1,
                    display: d,
                    isCurrentOnDisplay: true,
                    isFullScreenSpace: false
                )
            }
            return SpaceCatalog(
                bySpaceID: [:],
                activeSpaceIDsAllDisplays: [],
                activeDisplayCurrentSpaceID: nil,
                defaultSpaceForDisplayID: defaultsByDisplay
            )
        }

        var bySpaceID: [UInt64: SpaceMetadata] = [:]
        var activeSpaceIDs = Set<UInt64>()
        var activeDisplayCurrentSpaceID: UInt64?
        var defaultSpaceForDisplayID: [CGDirectDisplayID: SpaceMetadata] = [:]

        let mainDisp = displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? displays.first
        var globalDesktopCounter = 0

        for (dispIdx, dDict) in managedDisplays.enumerated() {
            let ident = (dDict["Display Identifier"] as? String ?? "").uppercased()
            let matchedDisplay: DisplayInfo = {
                if !ident.isEmpty, let exact = displays.first(where: { $0.uuidString == ident }) {
                    return exact
                }
                if ident == "MAIN", let mainDisp {
                    return mainDisp
                }
                if dispIdx < displays.count {
                    return displays[dispIdx]
                }
                return mainDisp ?? DisplayInfo(
                    index: 0,
                    displayID: CGMainDisplayID(),
                    uuidString: "",
                    cgBounds: CGDisplayBounds(CGMainDisplayID()),
                    name: "Màn hình chính",
                    isActiveDisplay: true
                )
            }()

            let currentSpaceDict = dDict["Current Space"] as? [String: Any]
            let currentSpaceID = Self.extractUInt64(currentSpaceDict?["id64"]) ?? Self.extractUInt64(currentSpaceDict?["ManagedSpaceID"])
            if let currentSpaceID {
                activeSpaceIDs.insert(currentSpaceID)
                if matchedDisplay.isActiveDisplay {
                    activeDisplayCurrentSpaceID = currentSpaceID
                }
            }

            let spacesList = dDict["Spaces"] as? [[String: Any]] ?? []
            for sp in spacesList {
                guard let sid = Self.extractUInt64(sp["id64"]) ?? Self.extractUInt64(sp["ManagedSpaceID"]) else {
                    continue
                }
                let spType = sp["type"] as? Int ?? 0
                let isFullScreen = (spType != 0)
                let customName = (sp["wsname"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                let desktopLabel: String
                let orderVal: Int
                if !isFullScreen {
                    globalDesktopCounter += 1
                    orderVal = globalDesktopCounter
                    desktopLabel = customName.isEmpty ? "Desktop \(globalDesktopCounter)" : customName
                } else {
                    orderVal = globalDesktopCounter + 100
                    desktopLabel = customName.isEmpty ? "Toàn màn hình" : "Toàn màn hình (\(customName))"
                }

                let isCur = (sid == currentSpaceID)
                let meta = SpaceMetadata(
                    spaceID: sid,
                    desktopName: desktopLabel,
                    desktopOrder: orderVal,
                    display: matchedDisplay,
                    isCurrentOnDisplay: isCur,
                    isFullScreenSpace: isFullScreen
                )
                bySpaceID[sid] = meta
                if isCur || defaultSpaceForDisplayID[matchedDisplay.displayID] == nil {
                    defaultSpaceForDisplayID[matchedDisplay.displayID] = meta
                }
            }
        }

        return SpaceCatalog(
            bySpaceID: bySpaceID,
            activeSpaceIDsAllDisplays: activeSpaceIDs,
            activeDisplayCurrentSpaceID: activeDisplayCurrentSpaceID,
            defaultSpaceForDisplayID: defaultSpaceForDisplayID
        )
    }

    private static func extractUInt64(_ anyVal: Any?) -> UInt64? {
        if let u = anyVal as? UInt64 { return u }
        if let n = anyVal as? NSNumber { return n.uint64Value }
        if let i = anyVal as? Int { return UInt64(i) }
        return nil
    }

    private static func matchDisplay(for windowBounds: CGRect, displays: [DisplayInfo]) -> DisplayInfo {
        guard let fallback = displays.first else {
            return DisplayInfo(
                index: 0,
                displayID: CGMainDisplayID(),
                uuidString: "",
                cgBounds: CGDisplayBounds(CGMainDisplayID()),
                name: "Màn hình chính",
                isActiveDisplay: true
            )
        }
        let center = CGPoint(x: windowBounds.midX, y: windowBounds.midY)
        if let containing = displays.first(where: { $0.cgBounds.contains(center) }) {
            return containing
        }
        var best = fallback
        var bestArea: CGFloat = 0
        for d in displays {
            let inter = d.cgBounds.intersection(windowBounds)
            if !inter.isNull {
                let area = inter.width * inter.height
                if area > bestArea {
                    bestArea = area
                    best = d
                }
            }
        }
        return best
    }

    private nonisolated static func isSafariBundleIdentifier(_ bundleID: String) -> Bool {
        switch bundleID {
        case "com.apple.Safari", "com.apple.SafariTechnologyPreview":
            return true
        default:
            return false
        }
    }

    private nonisolated static func isImageCompletelyTransparent(_ cgImage: CGImage) -> Bool {
        let sampleSize = 8
        var rgba = [UInt8](repeating: 0, count: sampleSize * sampleSize * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(
            data: &rgba,
            width: sampleSize,
            height: sampleSize,
            bitsPerComponent: 8,
            bytesPerRow: sampleSize * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }
        ctx.interpolationQuality = .low
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        for idx in stride(from: 3, to: rgba.count, by: 4) {
            if rgba[idx] > 2 {
                return false
            }
        }
        return true
    }

    private static func axHasElement(_ elem: AXUIElement, _ attr: String) -> Bool {
        var ref: CFTypeRef?
        return AXUIElementCopyAttributeValue(elem, attr as CFString, &ref) == .success && ref != nil
    }

    private static func axString(_ elem: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func axBool(_ elem: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, attr as CFString, &ref) == .success else { return nil }
        return ref as? Bool
    }

    private static func axBounds(_ elem: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(elem, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(elem, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posVal = posRef,
              let sizeVal = sizeRef else { return nil }
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(posVal as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    private static func findAXWindow(pid: pid_t, targetWID: CGWindowID, timeout: Float = 0.12) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, timeout)
        var winsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
              let wins = winsRef as? [AXUIElement] else { return nil }
        for w in wins {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(w, &wid) == .success && wid == targetWID {
                return w
            }
        }
        return nil
    }

    @discardableResult
    private static func raiseAXWindowMatchingWID(pid: pid_t, targetWID: CGWindowID) -> Bool {
        guard let w = findAXWindow(pid: pid, targetWID: targetWID) else { return false }
        raiseAndFocusAXWindow(w, unminimize: false)
        return true
    }

    private static func raiseAndFocusAXWindow(_ axWin: AXUIElement, unminimize: Bool) {
        AXUIElementSetMessagingTimeout(axWin, 0.12)
        if unminimize {
            AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(axWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func applyAXWindowFrame(_ axWin: AXUIElement, quartzRect: CGRect) {
        AXUIElementSetMessagingTimeout(axWin, 0.12)
        AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        var pt = quartzRect.origin
        var sz = quartzRect.size
        if let sizeVal = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeVal)
        }
        if let posVal = AXValueCreate(.cgPoint, &pt) {
            AXUIElementSetAttributeValue(axWin, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal = AXValueCreate(.cgSize, &sz) {
            AXUIElementSetAttributeValue(axWin, kAXSizeAttribute as CFString, sizeVal)
        }
    }

    /// Resolves an `AXUIElement` handle for a `CGWindowID` residing on another Mission Control Desktop / Space
    /// using HIServices' 20-byte remote accessibility token (`pid` + `0` + `'coco'` + `axElementID`).
    private static func resolveOffSpaceAXWindow(pid: pid_t, targetWID: CGWindowID) -> AXUIElement? {
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })

        for elementID: UInt64 in 0..<450 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let candidate = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else {
                continue
            }
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(candidate, &wid) == .success && wid == targetWID {
                return candidate
            }
        }
        return nil
    }

    private static func selectWindowFromAppWindowMenu(pid: pid_t, targetTitle: String) -> Bool {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.08)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBar = menuBarRef else { return false }

        var barItemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar as! AXUIElement, kAXChildrenAttribute as CFString, &barItemsRef) == .success,
              let barItems = barItemsRef as? [AXUIElement] else { return false }

        let windowMenuTitles = Set(["window", "cửa sổ", "fenêtre", "fenster", "ventana"])
        for barItem in barItems.reversed() {
            let barTitle = (axString(barItem, kAXTitleAttribute) ?? "").lowercased()
            guard windowMenuTitles.contains(barTitle) else { continue }
            var subMenusRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(barItem, kAXChildrenAttribute as CFString, &subMenusRef) == .success,
                  let subMenus = subMenusRef as? [AXUIElement],
                  let menu = subMenus.first else { continue }

            var itemsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
                  let menuItems = itemsRef as? [AXUIElement] else { continue }

            let cleanTarget = targetTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            for mi in menuItems {
                guard let miTitle = axString(mi, kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !miTitle.isEmpty else { continue }
                if miTitle == cleanTarget || miTitle.contains(cleanTarget) || cleanTarget.contains(miTitle) {
                    if AXUIElementPerformAction(mi, kAXPressAction as CFString) == .success {
                        return true
                    }
                }
            }
        }
        return false
    }
}
