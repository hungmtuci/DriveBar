import Foundation
import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem!

    private override init() {
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        refreshTooltip()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func refreshTooltip() {
        guard let button = statusItem?.button else { return }
        let hasUpdate = UpdateCheckerService.shared.availableVersion != nil
        let symbolName = hasUpdate ? "arrow.down.circle.fill" : "bolt.horizontal.circle.fill"
        let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "DriveBar")
        img?.isTemplate = true
        button.image = img

        if let ver = UpdateCheckerService.shared.availableVersion {
            button.toolTip = "DriveBar — Đã có bản cập nhật mới v\(ver)! Bấm để cập nhật tự động."
        } else {
            button.toolTip = "DriveBar — Tìm kiếm Google Drive & Convert Markdown cho AI"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let settings = AppSettings.shared
        let drive = GoogleDriveIndexService.shared
        let updater = UpdateCheckerService.shared
        settings.refreshLaunchAtLoginStatus()

        let header = NSMenuItem(
            title: "DriveBar v\(updater.currentVersion) — Google Drive & AI Actions",
            action: nil,
            keyEquivalent: ""
        )
        header.isEnabled = false
        menu.addItem(header)

        let openSearch = NSMenuItem(
            title: "Mở Thanh Tìm Kiếm Google Drive (\(settings.searchHotKey.readableDisplay))",
            action: #selector(openSearchAction),
            keyEquivalent: ""
        )
        openSearch.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        openSearch.target = self
        menu.addItem(openSearch)

        let openUA = NSMenuItem(
            title: "Universal Actions trên mục đang chọn (\(settings.universalActionHotKey.readableDisplay))",
            action: #selector(openUniversalAction),
            keyEquivalent: ""
        )
        openUA.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: nil)
        openUA.target = self
        menu.addItem(openUA)

        let quickConvertMD = NSMenuItem(
            title: "Convert mục đang chọn trong Finder sang Markdown (.md + Copy)",
            action: #selector(convertFinderSelectionToMD),
            keyEquivalent: ""
        )
        quickConvertMD.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        quickConvertMD.target = self
        menu.addItem(quickConvertMD)

        menu.addItem(.separator())

        let recentHeader = NSMenuItem(
            title: "Thư mục Google Drive gần đây (\(drive.folderCount.formatted()) thư mục)",
            action: nil,
            keyEquivalent: ""
        )
        recentHeader.isEnabled = false
        menu.addItem(recentHeader)

        let recents = drive.recentMyDriveFolders(limit: 6)
        if recents.isEmpty {
            let empty = NSMenuItem(title: "  (Chưa có lịch sử gần đây)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for r in recents {
                guard let path = r.path else { continue }
                let item = NSMenuItem(
                    title: r.title,
                    action: #selector(openRecentFolderInFinder(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = path
                item.image = NSWorkspace.shared.icon(forFile: path)
                item.image?.size = NSSize(width: 16, height: 16)
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Dock Show/Hide & Launch at Login Toggles
        let showDockItem = NSMenuItem(
            title: "Hiển thị biểu tượng trên thanh Dock",
            action: #selector(toggleShowDockAction),
            keyEquivalent: ""
        )
        showDockItem.state = settings.showDockIcon ? .on : .off
        showDockItem.target = self
        menu.addItem(showDockItem)

        let launchItem = NSMenuItem(
            title: "Tự khởi động cùng macOS",
            action: #selector(toggleLaunchAtLoginAction),
            keyEquivalent: ""
        )
        launchItem.state = settings.launchAtLogin ? .on : .off
        launchItem.target = self
        menu.addItem(launchItem)

        menu.addItem(.separator())

        // Auto-Update Section
        if let newVer = updater.availableVersion {
            let installItem = NSMenuItem(
                title: "Tải & Cập nhật tự động v\(newVer)",
                action: #selector(installUpdateAction),
                keyEquivalent: ""
            )
            installItem.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            installItem.target = self
            menu.addItem(installItem)
        }

        let checkTitle: String = {
            switch updater.state {
            case .checking: return "Đang kiểm tra cập nhật..."
            case .downloading(let v): return "Đang tải v\(v)..."
            case .installing(let v): return "Đang cài đặt v\(v)..."
            default: return "Kiểm tra cập nhật từ GitHub..."
            }
        }()
        let checkItem = NSMenuItem(
            title: checkTitle,
            action: updater.isBusy ? nil : #selector(checkUpdatesAction),
            keyEquivalent: ""
        )
        checkItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        checkItem.isEnabled = !updater.isBusy
        checkItem.target = self
        menu.addItem(checkItem)

        let rebuildTitle = drive.isRebuildingFolders
            ? "⏳ \(drive.rebuildProgressText ?? "Đang quét lại Cache Google Drive...")"
            : "Quét lại Cache Google Drive ngay"
        let rebuildItem = NSMenuItem(title: rebuildTitle, action: #selector(rebuildCacheAction), keyEquivalent: "")
        rebuildItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        rebuildItem.isEnabled = !drive.isRebuildingFolders
        rebuildItem.target = self
        menu.addItem(rebuildItem)

        let prefsItem = NSMenuItem(title: "Cài đặt & Quản lý DriveBar...", action: #selector(openPrefsAction), keyEquivalent: ",")
        prefsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Thoát DriveBar", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func openSearchAction() {
        LauncherPanelController.shared.toggleSearchPanel()
    }

    @objc private func openUniversalAction() {
        LauncherPanelController.shared.triggerUniversalActionsOnSelection()
    }

    @objc private func convertFinderSelectionToMD() {
        let urls = SelectionCaptureService.fetchFinderSelectionURLs()
        guard !urls.isEmpty else {
            FloatingToastController.shared.showError(
                title: "Chưa chọn tệp nào trong Finder",
                subtitle: "Hãy chọn ít nhất 1 tệp tài liệu trong Finder"
            )
            return
        }
        if let def = UniversalActionCatalog.all.first(where: { $0.id == "ai.convert_md" }) {
            UniversalActionExecutor.shared.execute(
                action: def,
                target: .files(urls, sourceNote: "Finder"),
                viewModel: LauncherViewModel.shared
            )
        }
    }

    @objc private func openRecentFolderInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        GoogleDriveIndexService.shared.recordUsed(path)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func toggleShowDockAction() {
        AppSettings.shared.showDockIcon.toggle()
    }

    @objc private func toggleLaunchAtLoginAction() {
        AppSettings.shared.toggleLaunchAtLogin(!AppSettings.shared.launchAtLogin)
    }

    @objc private func installUpdateAction() {
        UpdateCheckerService.shared.installAvailableUpdate()
    }

    @objc private func checkUpdatesAction() {
        AppDelegate.shared?.openSettingsWindow()
        UpdateCheckerService.shared.checkForUpdatesManually()
    }

    @objc private func rebuildCacheAction() {
        GoogleDriveIndexService.shared.rebuildAllCaches()
    }

    @objc private func openPrefsAction() {
        AppDelegate.shared?.openSettingsWindow()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
