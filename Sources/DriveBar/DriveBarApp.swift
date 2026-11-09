import SwiftUI
import AppKit
import QuickLookUI

final class DriveBarApplication: NSApplication {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard WindowSwitcherController.shared.isVisible else { return false }
                return WindowSwitcherController.shared.handleLocalNSEventShortcut(event)
            }
            if handled {
                return
            }
        }
        super.sendEvent(event)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        true
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = QuickLookCoordinator.shared
            panel.delegate = QuickLookCoordinator.shared
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            if NSApp.isActive && LauncherPanelController.shared.isVisible {
                LauncherPanelController.shared.restoreFocusFromAuxiliaryPanel()
            }
        }
    }
}

@main
enum DriveBarMain {
    @MainActor private static var retainedDelegate: AppDelegate?

    static func main() {
        let app = DriveBarApplication.shared
        MainActor.assumeIsolated {
            let delegate = AppDelegate()
            retainedDelegate = delegate
            app.delegate = delegate
            delegate.installMainMenu()
        }
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    private var settingsWindow: NSWindow?

    var isSettingsWindowVisible: Bool {
        settingsWindow?.isVisible ?? false
    }

    func installMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Cài đặt DriveBar...", "DriveBar Settings..."), action: #selector(openSettingsWindow), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: L("Mở Thanh Tìm Kiếm", "Open Search Bar"), action: #selector(toggleLauncherFromMenu), keyEquivalent: "f").target = self
        appMenu.addItem(withTitle: L("Mở Windows Preview (Chuyển cửa sổ)", "Open Windows Preview (Window Switcher)"), action: #selector(openWindowSwitcherFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("Tìm kiếm Thư mục trên Mac ('m ')", "Search Mac Folders ('m ')"), action: #selector(openMacFoldersFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("Tra cứu Danh bạ ('c ')", "Search Contacts ('c ')"), action: #selector(openContactsFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("Mở Lịch sử Clipboard ('cb ')", "Open Clipboard History ('cb ')"), action: #selector(openClipboardHistoryFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("Mở Lệnh Hệ thống ('s ')", "Open System Commands ('s ')"), action: #selector(openSystemCommandsFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: L("Kiểm tra cập nhật từ GitHub...", "Check for Updates from GitHub..."), action: #selector(checkUpdatesFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Ẩn DriveBar", "Hide DriveBar"), action: #selector(handleMenuHide(_:)), keyEquivalent: "h").target = self
        appMenu.addItem(withTitle: L("Thoát DriveBar", "Quit DriveBar"), action: #selector(handleMenuQuit(_:)), keyEquivalent: "q").target = self
        appMenuItem.submenu = appMenu

        // Edit Menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: L("Chỉnh sửa", "Edit"))
        editMenu.addItem(withTitle: L("Hoàn tác", "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: L("Làm lại", "Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("Cắt", "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("Sao chép", "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("Dán", "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("Chọn tất cả", "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // Window Menu
        let winMenuItem = NSMenuItem()
        mainMenu.addItem(winMenuItem)
        let winMenu = NSMenu(title: L("Cửa sổ", "Window"))
        winMenu.addItem(withTitle: L("Đóng cửa sổ", "Close Window"), action: #selector(handleMenuCloseWindow(_:)), keyEquivalent: "w").target = self
        winMenuItem.submenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

        NotificationCenter.default.addObserver(
            forName: AppLocalization.languageDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                AppDelegate.shared?.installMainMenu()
                StatusBarController.shared.refreshTooltip()
            }
        }

        if let bundleID = Bundle.main.bundleIdentifier {
            let ownPID = ProcessInfo.processInfo.processIdentifier
            if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { $0.processIdentifier != ownPID }) {
                existing.activate()
                NSApp.terminate(nil)
                return
            }
        }

        let settings = AppSettings.shared
        settings.applyDockPolicy()

        _ = GoogleDriveIndexService.shared
        SyncAndLatchingService.shared.start()
        LocalFolderDriveSyncService.shared.start()
        ClipboardHistoryService.shared.start()
        ContactsSearchService.shared.preloadIfAuthorized()
        StatusBarController.shared.install()

        _ = WindowSwitcherService.shared
        WindowSwitcherController.shared.start()

        let hotKeys = HotKeyService.shared
        hotKeys.onToggleSearch = {
            LauncherPanelController.shared.toggleSearchPanel()
        }
        hotKeys.onTriggerUniversalAction = {
            LauncherPanelController.shared.triggerUniversalActionsOnSelection()
        }
        hotKeys.installAndRegisterAll()

        NSApp.servicesProvider = self

        if settings.isFirstLaunch || settings.showLauncherOnStartup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                LauncherViewModel.shared.prepareForSearchLaunch()
                LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
            }
        }

        // Silent background check against GitHub Releases (hungmtuci/DriveBar)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            UpdateCheckerService.shared.checkSilentlyOnLaunchIfNeeded()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        LauncherPanelController.shared.toggleSearchPanel()
        return true
    }

    func applicationDidResignActive(_ notification: Notification) {
        if LauncherPanelController.shared.isVisible && !LauncherPanelController.shared.shouldSuppressAutoHide {
            LauncherPanelController.shared.hide()
        }
        if WindowSwitcherController.shared.isVisible {
            if WindowSwitcherController.shared.shouldSuppressAutoDismiss {
                WindowSwitcherController.shared.noteAppDidResignActiveDuringScreenshotGrace()
            } else {
                WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // 1. Handle custom URL scheme `drivebar://sync-folder?mode=dialog|instant&path=/Users/...`
        let schemeURLs = urls.filter { $0.scheme?.lowercased() == "drivebar" }
        if !schemeURLs.isEmpty {
            var folderURLs: [URL] = []
            var isInstant = false
            for u in schemeURLs {
                if let comps = URLComponents(url: u, resolvingAgainstBaseURL: false) {
                    let mode = comps.queryItems?.first(where: { $0.name == "mode" })?.value ?? "dialog"
                    if mode == "instant" {
                        isInstant = true
                    }
                    if let pathVal = comps.queryItems?.first(where: { $0.name == "path" })?.value,
                       !pathVal.isEmpty {
                        folderURLs.append(URL(fileURLWithPath: pathVal))
                    }
                }
            }
            if !folderURLs.isEmpty {
                FolderSyncDialogController.shared.present(forFolderURLs: folderURLs, instantIfSingle: isInstant)
                return
            }
        }

        // 2. Standard file/folder open or Dock drop
        let valid = urls.filter { $0.isFileURL && ($0.path.contains("/Library/CloudStorage/") || FileManager.default.fileExists(atPath: $0.path)) }
        guard !valid.isEmpty else { return }
        LauncherViewModel.shared.openUniversalActions(
            for: .files(valid, sourceNote: L("Mở trực tiếp / Kéo vào Dock", "Direct open / Dragged to Dock")),
            directExternalTrigger: true
        )
        LauncherPanelController.shared.showAndFocus()
    }

    @objc func handleSyncFolderWithGoogleDriveService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            FolderSyncDialogController.shared.present(forFolderURLs: urls, instantIfSingle: false)
        }
    }

    @objc func handleInstantSyncFolderWithGoogleDriveService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            FolderSyncDialogController.shared.present(forFolderURLs: urls, instantIfSingle: true)
        }
    }

    @objc func handleUniversalActionService(
        _ pboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            LauncherViewModel.shared.openUniversalActions(
                for: .files(urls, sourceNote: "macOS Services"),
                directExternalTrigger: true
            )
            LauncherPanelController.shared.showAndFocus()
        } else if let str = pboard.string(forType: .string), !str.isEmpty {
            LauncherViewModel.shared.openUniversalActions(
                for: .text(str, sourceNote: "macOS Services"),
                directExternalTrigger: true
            )
            LauncherPanelController.shared.showAndFocus()
        }
    }

    @objc func toggleLauncherFromMenu() {
        LauncherPanelController.shared.toggleSearchPanel()
    }

    @objc func openWindowSwitcherFromMenu() {
        WindowSwitcherController.shared.openPinnedFromMenuOrSearch()
    }

    @objc func openMacFoldersFromMenu() {
        LauncherViewModel.shared.prepareForSearchLaunch()
        LauncherViewModel.shared.searchText = "m "
        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
    }

    @objc func openContactsFromMenu() {
        LauncherViewModel.shared.prepareForSearchLaunch()
        LauncherViewModel.shared.searchText = "c "
        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
    }

    @objc func openClipboardHistoryFromMenu() {
        LauncherViewModel.shared.prepareForSearchLaunch()
        LauncherViewModel.shared.searchText = "cb "
        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
    }

    @objc func openSystemCommandsFromMenu() {
        LauncherViewModel.shared.prepareForSearchLaunch()
        LauncherViewModel.shared.searchText = "s "
        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
    }

    @objc func checkUpdatesFromMenu() {
        openSettingsWindow()
        UpdateCheckerService.shared.checkForUpdatesManually()
    }

    @objc func openSettingsWindow() {
        LauncherPanelController.shared.hide()
        WindowSwitcherController.shared.dismissWithoutActivating(restorePreviousApp: false)

        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = L("Cài đặt DriveBar", "DriveBar Settings")
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.minSize = NSSize(width: 780, height: 540)
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: SettingsView())
            settingsWindow = win
        }

        bringSettingsWindowToFront()
    }

    func bringSettingsWindowToFront() {
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func handleMenuHide(_ sender: Any?) {
        if WindowSwitcherController.shared.isVisible {
            WindowSwitcherController.shared.triggerHideSelectedApp()
            return
        }
        NSApp.hide(sender)
    }

    @objc func handleMenuQuit(_ sender: Any?) {
        if WindowSwitcherController.shared.isVisible {
            let force = NSEvent.modifierFlags.contains(.option)
            WindowSwitcherController.shared.triggerQuitSelectedApp(force: force)
            return
        }
        NSApp.terminate(sender)
    }

    @objc func handleMenuCloseWindow(_ sender: Any?) {
        if WindowSwitcherController.shared.isVisible {
            WindowSwitcherController.shared.triggerCloseSelectedWindow()
            return
        }
        if LauncherPanelController.shared.isVisible {
            LauncherPanelController.shared.hide()
            return
        }
        NSApp.keyWindow?.performClose(sender)
    }
}
