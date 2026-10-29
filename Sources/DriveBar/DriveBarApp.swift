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

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}
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
        StatusBarController.shared.install()

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

    func application(_ application: NSApplication, open urls: [URL]) {
        let valid = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
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

    @objc func checkUpdatesFromMenu() {
        openSettingsWindow()
        UpdateCheckerService.shared.checkForUpdatesManually()
    }

    @objc func openSettingsWindow() {
        LauncherPanelController.shared.hide()

        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 840, height: 640),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "Cài đặt & Quản lý DriveBar"
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
