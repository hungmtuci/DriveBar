import SwiftUI
import AppKit
import QuickLookUI

final class DriveBarApplication: NSApplication {
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
        appMenu.addItem(withTitle: "Cài đặt DriveBar...", action: #selector(openSettingsWindow), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "Mở Thanh Tìm Kiếm", action: #selector(toggleLauncherFromMenu), keyEquivalent: "f").target = self
        appMenu.addItem(withTitle: "Mở Windows Preview (Chuyển cửa sổ)", action: #selector(openWindowSwitcherFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Tra cứu Danh bạ ('c ')", action: #selector(openContactsFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Mở Lịch sử Clipboard ('cb ')", action: #selector(openClipboardHistoryFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Mở Lệnh Hệ thống ('s ')", action: #selector(openSystemCommandsFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(withTitle: "Kiểm tra cập nhật từ GitHub...", action: #selector(checkUpdatesFromMenu), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Ẩn DriveBar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Thoát DriveBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        // Edit Menu
        let editMenuItem = NSMenuItem()
        mainMenu.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Chỉnh sửa")
        editMenu.addItem(withTitle: "Hoàn tác", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Làm lại", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cắt", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Sao chép", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Dán", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Chọn tất cả", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu

        // Window Menu
        let winMenuItem = NSMenuItem()
        mainMenu.addItem(winMenuItem)
        let winMenu = NSMenu(title: "Cửa sổ")
        winMenu.addItem(withTitle: "Đóng cửa sổ", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenuItem.submenu = winMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.shared = self

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

        if settings.isFirstLaunch {
            LauncherPanelController.shared.toggleSearchPanel()
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
        let valid = urls.filter { $0.path.contains("/Library/CloudStorage/") || FileManager.default.fileExists(atPath: $0.path) }
        guard !valid.isEmpty else { return }
        LauncherViewModel.shared.openUniversalActions(
            for: .files(valid, sourceNote: "Mở trực tiếp / Kéo vào Dock"),
            directExternalTrigger: true
        )
        LauncherPanelController.shared.showAndFocus()
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
            win.title = "Cài đặt DriveBar"
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
}
