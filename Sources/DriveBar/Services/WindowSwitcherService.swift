import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

@MainActor
final class WindowSwitcherService: ObservableObject {
    static let shared = WindowSwitcherService()

    @Published private(set) var items: [SwitchableWindowItem] = []
    @Published var selectedIndex: Int = 0 {
        didSet {
            requestHighResZoomPreviewForSelection()
        }
    }
    @Published private(set) var thumbnails: [CGWindowID: NSImage] = [:]
    @Published private(set) var zoomedPreviewImage: NSImage?
    @Published private(set) var zoomedPreviewWindowID: CGWindowID?
    @Published private(set) var hasScreenRecordingPermission: Bool = CGPreflightScreenCaptureAccess()
    @Published private(set) var hasAccessibilityPermission: Bool = AXIsProcessTrusted()
    @Published var sessionSameAppPID: pid_t?

    private var mruPIDs: [pid_t] = []
    private var mruWindowKeys: [String] = []
    private var scWindowsByID: [CGWindowID: SCWindow] = [:]
    private var scWindowTitlesByID: [CGWindowID: String] = [:]
    private var thumbnailCaptureTask: Task<Void, Never>?
    private var zoomCaptureTask: Task<Void, Never>?

    private struct DisplayInfo {
        let index: Int
        let displayID: CGDirectDisplayID
        let cgBounds: CGRect
        let name: String
        let isActiveDisplay: Bool
    }

    private struct RawCGWindow {
        let wid: CGWindowID
        let pid: pid_t
        let bounds: CGRect
        let cgTitle: String?
        let isOnScreen: Bool
        let zRank: Int
    }

    private init() {
        if let front = NSWorkspace.shared.frontmostApplication {
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
    }

    func recordMRUPID(_ pid: pid_t) {
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

    func reloadSessionWindows(sameAppPID: pid_t? = nil, selectPreviousWindow: Bool = true, moveBackward: Bool = false) {
        refreshPermissionStates()
        self.sessionSameAppPID = sameAppPID

        let discovered = collectSwitchableWindows(sameAppPID: sameAppPID)
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

        requestHighResZoomPreviewForSelection()
        startAsyncScreenCaptureRefresh()
    }

    func rebuildFilteredItemsPreservingSelection() {
        let previousID = selectedItem?.id
        let discovered = collectSwitchableWindows(sameAppPID: sessionSameAppPID)
        self.items = discovered
        if let previousID, let newIdx = discovered.firstIndex(where: { $0.id == previousID }) {
            selectedIndex = newIdx
        } else {
            selectedIndex = min(max(0, selectedIndex), max(0, discovered.count - 1))
        }
        requestHighResZoomPreviewForSelection()
        startAsyncScreenCaptureRefresh()
    }

    func stepSelection(delta: Int) {
        guard !items.isEmpty else { return }
        let count = items.count
        selectedIndex = ((selectedIndex + delta) % count + count) % count
    }

    private func collectSwitchableWindows(sameAppPID: pid_t?) -> [SwitchableWindowItem] {
        let settings = AppSettings.shared
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = Self.buildDisplayList()
        let mainDisplayBounds = CGDisplayBounds(CGMainDisplayID())

        // 1. Snapshot WindowServer Z-Order across ALL Spaces & Current Space
        let cgAllRaw = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let cgOnScreenRaw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let onScreenIDs = Set(cgOnScreenRaw.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })

        var cgByPID: [pid_t: [RawCGWindow]] = [:]
        var cgByWID: [CGWindowID: RawCGWindow] = [:]

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
            let entry = RawCGWindow(
                wid: wid,
                pid: pid,
                bounds: rect,
                cgTitle: cgTitle,
                isOnScreen: onScreenIDs.contains(wid),
                zRank: zIdx
            )
            cgByPID[pid, default: []].append(entry)
            cgByWID[wid] = entry
        }

        // 2. Enumerate Regular Running Applications
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard !app.isTerminated else { return false }
            if app.processIdentifier == ownPID {
                // Only include DriveBar if Settings window is visibly open
                return AppDelegate.shared?.isSettingsWindowVisible == true
            }
            if let filterPID = sameAppPID, app.processIdentifier != filterPID {
                return false
            }
            return app.activationPolicy == .regular
        }

        let axTrusted = AXIsProcessTrusted()
        var candidates: [(item: SwitchableWindowItem, sortRank: Int)] = []

        for app in runningApps {
            let pid = app.processIdentifier
            let bundleID = app.bundleIdentifier ?? ""
            let appName = app.localizedName ?? "Ứng dụng"
            let appIcon = app.icon ?? NSWorkspace.shared.icon(for: .applicationBundle)
            let appHidden = app.isHidden

            if appHidden && !settings.windowSwitcherShowHiddenApps {
                continue
            }

            var matchedWIDs = Set<CGWindowID>()
            var appProducedWindow = false

            // 2A. Rich Accessibility Window Discovery (captures exact window titles, minimized windows, multi-window handles)
            if axTrusted && pid != ownPID {
                let axApp = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(axApp, 0.06)

                var winsRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &winsRef) == .success,
                   let axWins = winsRef as? [AXUIElement] {
                    for (axIdx, axWin) in axWins.enumerated() {
                        let subrole = Self.axString(axWin, kAXSubroleAttribute) ?? ""
                        let role = Self.axString(axWin, kAXRoleAttribute) ?? ""
                        if role == "AXScrollArea" || subrole == "AXDesktop" || subrole == "AXUnknown" {
                            continue
                        }
                        if !subrole.isEmpty && subrole != "AXStandardWindow" && subrole != "AXDialog" && subrole != "AXFloatingWindow" {
                            continue
                        }

                        let isMin = Self.axBool(axWin, kAXMinimizedAttribute) ?? false
                        if isMin && !settings.windowSwitcherShowMinimized {
                            var skipWid: CGWindowID = 0
                            if _AXUIElementGetWindow(axWin, &skipWid) == .success && skipWid != 0 {
                                matchedWIDs.insert(skipWid)
                            }
                            continue
                        }

                        var wid: CGWindowID = 0
                        let hasWID = (_AXUIElementGetWindow(axWin, &wid) == .success && wid != 0)
                        if hasWID {
                            if matchedWIDs.contains(wid) { continue }
                            matchedWIDs.insert(wid)
                        }

                        let axTitle = Self.axString(axWin, kAXTitleAttribute) ?? ""
                        let isFull = Self.axBool(axWin, "AXFullScreen") ?? false
                        let cgEntry = hasWID ? cgByWID[wid] : nil

                        var winBounds = cgEntry?.bounds ?? Self.axBounds(axWin) ?? .zero
                        // Skip Finder's giant desktop backdrop window
                        if bundleID == "com.apple.finder" && axTitle.isEmpty && winBounds.width >= mainDisplayBounds.width {
                            continue
                        }
                        if winBounds.width < 80 && winBounds.height < 60 && !isMin {
                            continue
                        }
                        if winBounds == .zero {
                            winBounds = CGRect(x: 0, y: 0, width: 1280, height: 800)
                        }

                        let disp = Self.matchDisplay(for: winBounds, displays: displays)
                        let isOnSpace: Bool = {
                            if isMin || appHidden { return false }
                            if let cgEntry { return cgEntry.isOnScreen }
                            return true
                        }()

                        if !Self.matchesScope(settings.windowSwitcherScope, isOnCurrentDisplay: disp.isActiveDisplay, isOnCurrentSpace: isOnSpace, isMinimized: isMin, isHidden: appHidden) {
                            continue
                        }

                        let resolvedTitle = !axTitle.isEmpty
                            ? axTitle
                            : (hasWID ? (scWindowTitlesByID[wid] ?? cgEntry?.cgTitle ?? "") : "")

                        let itemID = hasWID ? "wid:\(wid)" : "ax:\(pid):\(axIdx)"
                        let rank = Self.computeSortRank(
                            itemID: itemID,
                            pid: pid,
                            cgRank: cgEntry?.zRank,
                            isMinimized: isMin,
                            isAppHidden: appHidden,
                            isOnCurrentSpace: isOnSpace,
                            mruWindowKeys: mruWindowKeys,
                            mruPIDs: mruPIDs,
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
                            displayIndex: disp.index,
                            displayName: disp.name,
                            totalDisplaysCount: displays.count,
                            isOnCurrentDisplay: disp.isActiveDisplay,
                            isOnCurrentSpace: isOnSpace,
                            isMinimized: isMin,
                            isAppHidden: appHidden,
                            isFullscreen: isFull,
                            isWindowlessApp: false,
                            axWindow: axWin
                        )
                        candidates.append((item, rank))
                        appProducedWindow = true
                    }
                }
            }

            // 2B. Supplement with CGWindowList windows on OTHER Spaces / Full-Screen Spaces (or when AX isn't granted yet)
            if let cgWins = cgByPID[pid] {
                for cgEntry in cgWins where !matchedWIDs.contains(cgEntry.wid) {
                    // Filter Finder desktop backdrop
                    if bundleID == "com.apple.finder" &&
                       cgEntry.bounds.width >= mainDisplayBounds.width &&
                       cgEntry.bounds.height >= mainDisplayBounds.height - 40 &&
                       cgEntry.bounds.minY <= 30 {
                        continue
                    }

                    // Filter AppKit / Chromium / Office invisible 500x500 offscreen dummy backing windows
                    let scTitle = scWindowTitlesByID[cgEntry.wid] ?? cgEntry.cgTitle ?? ""
                    if !cgEntry.isOnScreen &&
                       scTitle.isEmpty &&
                       abs(cgEntry.bounds.width - 500) <= 2 &&
                       abs(cgEntry.bounds.height - 500) <= 2 {
                        continue
                    }

                    let disp = Self.matchDisplay(for: cgEntry.bounds, displays: displays)
                    let isFull = abs(cgEntry.bounds.width - disp.cgBounds.width) <= 4 &&
                                 abs(cgEntry.bounds.height - disp.cgBounds.height) <= 40

                    // If AX is trusted and didn't report this window on the current Space, and it's not onScreen,
                    // it lives on another Desktop (Space) or Full-Screen Space!
                    let isOnSpace = cgEntry.isOnScreen && !appHidden

                    if !Self.matchesScope(settings.windowSwitcherScope, isOnCurrentDisplay: disp.isActiveDisplay, isOnCurrentSpace: isOnSpace, isMinimized: false, isHidden: appHidden) {
                        continue
                    }

                    let itemID = "wid:\(cgEntry.wid)"
                    let rank = Self.computeSortRank(
                        itemID: itemID,
                        pid: pid,
                        cgRank: cgEntry.zRank,
                        isMinimized: false,
                        isAppHidden: appHidden,
                        isOnCurrentSpace: isOnSpace,
                        mruWindowKeys: mruWindowKeys,
                        mruPIDs: mruPIDs,
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
                        displayIndex: disp.index,
                        displayName: disp.name,
                        totalDisplaysCount: displays.count,
                        isOnCurrentDisplay: disp.isActiveDisplay,
                        isOnCurrentSpace: isOnSpace,
                        isMinimized: false,
                        isAppHidden: appHidden,
                        isFullscreen: isFull,
                        isWindowlessApp: false,
                        axWindow: nil
                    )
                    candidates.append((item, rank))
                    appProducedWindow = true
                }
            }

            // 2C. Optional Windowless Running Applications (e.g. Finder/Mail with all windows closed)
            if !appProducedWindow && settings.windowSwitcherShowWindowlessApps && pid != ownPID {
                let activeDisp = displays.first(where: \.isActiveDisplay) ?? displays.first
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
                    totalDisplaysCount: displays.count,
                    isOnCurrentDisplay: true,
                    isOnCurrentSpace: true,
                    isMinimized: false,
                    isAppHidden: appHidden,
                    isFullscreen: false,
                    isWindowlessApp: true,
                    axWindow: nil
                )
                candidates.append((item, 50_000 + mruPos))
            }
        }

        candidates.sort { $0.sortRank < $1.sortRank }
        return candidates.map(\.item)
    }

    private static func matchesScope(
        _ scope: WindowSwitcherScope,
        isOnCurrentDisplay: Bool,
        isOnCurrentSpace: Bool,
        isMinimized: Bool,
        isHidden: Bool
    ) -> Bool {
        switch scope {
        case .allSpacesAndDisplays:
            return true
        case .currentDisplayOnly:
            return isOnCurrentDisplay
        case .currentSpaceOnly:
            return isOnCurrentSpace || isMinimized || isHidden
        }
    }

    private static func computeSortRank(
        itemID: String,
        pid: pid_t,
        cgRank: Int?,
        isMinimized: Bool,
        isAppHidden: Bool,
        isOnCurrentSpace: Bool,
        mruWindowKeys: [String],
        mruPIDs: [pid_t],
        fallbackOffset: Int
    ) -> Int {
        // Frontmost visible window on active Space always stays near the front in true Z-order
        if let cgRank, isOnCurrentSpace && !isMinimized && !isAppHidden {
            return cgRank
        }
        if let mruWinIdx = mruWindowKeys.firstIndex(of: itemID) {
            return 2_000 + mruWinIdx * 10 + fallbackOffset
        }
        if let cgRank, !isMinimized && !isAppHidden {
            // Windows on other Spaces keep their WindowServer Z-order right after current-Space windows
            return 5_000 + cgRank
        }
        let pidRank = mruPIDs.firstIndex(of: pid) ?? 80
        if isMinimized {
            return 15_000 + pidRank * 20 + fallbackOffset
        }
        if isAppHidden {
            return 25_000 + pidRank * 20 + fallbackOffset
        }
        return 30_000 + pidRank * 20 + fallbackOffset
    }

    // MARK: - Live ScreenCaptureKit Thumbnails & High-Res Zoom Preview

    private func startAsyncScreenCaptureRefresh() {
        thumbnailCaptureTask?.cancel()
        guard CGPreflightScreenCaptureAccess() else { return }

        let targetItems = self.items
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
                if let t = scWin.title, !t.isEmpty, scWindowTitlesByID[scWin.windowID] != t {
                    scWindowTitlesByID[scWin.windowID] = t
                    titleUpdated = true
                }
            }
            self.scWindowsByID = winMap

            // Backfill titles for windows on other Spaces immediately if SCWindow provided them
            if titleUpdated {
                for idx in self.items.indices {
                    if self.items[idx].windowTitle.isEmpty,
                       let wid = self.items[idx].windowID,
                       let scTitle = scWindowTitlesByID[wid], !scTitle.isEmpty {
                        let old = self.items[idx]
                        self.items[idx] = SwitchableWindowItem(
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
                            totalDisplaysCount: old.totalDisplaysCount,
                            isOnCurrentDisplay: old.isOnCurrentDisplay,
                            isOnCurrentSpace: old.isOnCurrentSpace,
                            isMinimized: old.isMinimized,
                            isAppHidden: old.isAppHidden,
                            isFullscreen: old.isFullscreen,
                            isWindowlessApp: old.isWindowlessApp,
                            axWindow: old.axWindow
                        )
                    }
                }
            }

            // Capture High-Res Zoom Preview for currently selected item FIRST
            requestHighResZoomPreviewForSelection()

            // Then capture crisp strip thumbnails for all items
            for item in targetItems {
                if Task.isCancelled { break }
                guard let wid = item.windowID, let scWin = winMap[wid] else { continue }
                if let cgImg = await Self.captureSCWindowImage(scWin: scWin, maxDimension: 520) {
                    let nsImg = NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height))
                    self.thumbnails[wid] = nsImg
                    if self.selectedItem?.windowID == wid && self.zoomedPreviewImage == nil {
                        self.zoomedPreviewImage = nsImg
                        self.zoomedPreviewWindowID = wid
                    }
                }
            }
        }
    }

    private func requestHighResZoomPreviewForSelection() {
        zoomCaptureTask?.cancel()
        guard let item = selectedItem, let wid = item.windowID else {
            zoomedPreviewImage = nil
            zoomedPreviewWindowID = nil
            return
        }

        // Instant zero-latency fallback from cached strip thumbnail while high-res renders
        if zoomedPreviewWindowID != wid {
            zoomedPreviewImage = thumbnails[wid]
            zoomedPreviewWindowID = wid
        }

        guard CGPreflightScreenCaptureAccess(), let scWin = scWindowsByID[wid] else { return }

        zoomCaptureTask = Task { @MainActor in
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
            // Reopen default window if app supports reopen (like Finder/Mail/Safari)
            if let bundleURL = runningApp.bundleURL {
                let cfg = NSWorkspace.OpenConfiguration()
                cfg.activates = true
                NSWorkspace.shared.openApplication(at: bundleURL, configuration: cfg, completionHandler: nil)
            }
            return
        }

        if let axWin = item.axWindow {
            if item.isMinimized {
                AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            _ = AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)

            runningApp.activate()

            // Re-assert exact target window after app activation so sibling windows never jump ahead
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                _ = AXUIElementPerformAction(axWin, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(axWin, kAXMainAttribute as CFString, kCFBooleanTrue)
                AXUIElementSetAttributeValue(axWin, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            }
            return
        }

        // Cross-Space / Full-Screen Space window activation:
        // 1. Try clicking the window's item in the app's Menu Bar -> "Window" menu (switches Spaces even when same app has windows on multiple Spaces!)
        if AXIsProcessTrusted() && !item.windowTitle.isEmpty {
            if Self.selectWindowFromAppWindowMenu(pid: item.pid, targetTitle: item.windowTitle) {
                runningApp.activate()
                return
            }
        }

        // 2. Activate app across Spaces, then raise the exact CGWindowID once macOS lands on that Space
        runningApp.activate(options: [.activateAllWindows])

        if AXIsProcessTrusted(), let targetWID = item.windowID {
            let pid = item.pid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                Self.raiseAXWindowMatchingWID(pid: pid, targetWID: targetWID)
            }
        }
    }

    // MARK: - In-Switcher Quick Actions (Close W, Minimize M, Hide H, Quit Q)

    func closeSelectedWindow() {
        guard let item = selectedItem, !item.isWindowlessApp else { return }
        if let axWin = item.axWindow ?? item.windowID.flatMap({ Self.findAXWindow(pid: item.pid, targetWID: $0) }) {
            var closeBtnRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axWin, kAXCloseButtonAttribute as CFString, &closeBtnRef) == .success,
               let closeBtn = closeBtnRef {
                _ = AXUIElementPerformAction(closeBtn as! AXUIElement, kAXPressAction as CFString)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.rebuildFilteredItemsPreservingSelection()
                }
                return
            }
        }
        NSSound.beep()
    }

    func toggleMinimizeSelectedWindow() {
        guard let item = selectedItem, !item.isWindowlessApp else { return }
        if let axWin = item.axWindow ?? item.windowID.flatMap({ Self.findAXWindow(pid: item.pid, targetWID: $0) }) {
            let newState: CFBoolean = item.isMinimized ? kCFBooleanFalse : kCFBooleanTrue
            if AXUIElementSetAttributeValue(axWin, kAXMinimizedAttribute as CFString, newState) == .success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.rebuildFilteredItemsPreservingSelection()
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            self?.rebuildFilteredItemsPreservingSelection()
        }
    }

    func quitSelectedApp() {
        guard let item = selectedItem,
              item.pid != ProcessInfo.processInfo.processIdentifier,
              let app = NSRunningApplication(processIdentifier: item.pid) else { return }
        app.terminate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.rebuildFilteredItemsPreservingSelection()
        }
    }

    // MARK: - Private AX & Display Helpers

    private static func buildDisplayList() -> [DisplayInfo] {
        let mouseLoc = NSEvent.mouseLocation
        let activeScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLoc, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        let activeID = activeScreen.flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }

        return NSScreen.screens.enumerated().map { idx, scr in
            let id = (scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? CGMainDisplayID()
            return DisplayInfo(
                index: idx,
                displayID: id,
                cgBounds: CGDisplayBounds(id),
                name: scr.localizedName,
                isActiveDisplay: id == activeID
            )
        }
    }

    private static func matchDisplay(for windowBounds: CGRect, displays: [DisplayInfo]) -> DisplayInfo {
        guard let fallback = displays.first else {
            return DisplayInfo(index: 0, displayID: CGMainDisplayID(), cgBounds: CGDisplayBounds(CGMainDisplayID()), name: "Màn hình chính", isActiveDisplay: true)
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

    private static func findAXWindow(pid: pid_t, targetWID: CGWindowID) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.08)
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

    private static func raiseAXWindowMatchingWID(pid: pid_t, targetWID: CGWindowID) {
        guard let w = findAXWindow(pid: pid, targetWID: targetWID) else { return }
        _ = AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(w, kAXFocusedAttribute as CFString, kCFBooleanTrue)
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
