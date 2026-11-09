import Foundation
import AppKit
import UniformTypeIdentifiers

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
            button.toolTip = L(
                "DriveBar — Đã có bản cập nhật mới v\(ver)! Bấm để cập nhật tự động.",
                "DriveBar — New update v\(ver) available! Click to update automatically."
            )
        } else {
            button.toolTip = L(
                "DriveBar — Tìm kiếm Google Drive & Convert Markdown cho AI",
                "DriveBar — Google Drive Search & AI Markdown Converter"
            )
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
            title: L(
                "Mở Thanh Tìm Kiếm Google Drive (\(settings.searchHotKey.readableDisplay))",
                "Open Google Drive Search (\(settings.searchHotKey.readableDisplay))"
            ),
            action: #selector(openSearchAction),
            keyEquivalent: ""
        )
        openSearch.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        openSearch.target = self
        menu.addItem(openSearch)

        let openUA = NSMenuItem(
            title: L(
                "Universal Actions trên mục đang chọn (\(settings.universalActionHotKey.readableDisplay))",
                "Universal Actions on Selection (\(settings.universalActionHotKey.readableDisplay))"
            ),
            action: #selector(openUniversalAction),
            keyEquivalent: ""
        )
        openUA.image = NSImage(systemSymbolName: "bolt.horizontal.circle", accessibilityDescription: nil)
        openUA.target = self
        menu.addItem(openUA)

        let openWinPreview = NSMenuItem(
            title: L(
                "Windows Preview — Chuyển nhanh cửa sổ (\(settings.windowSwitcherHotKey.readableDisplay))",
                "Windows Preview — Switch Windows (\(settings.windowSwitcherHotKey.readableDisplay))"
            ),
            action: #selector(openWindowsPreviewAction),
            keyEquivalent: ""
        )
        openWinPreview.image = NSImage(systemSymbolName: "macwindow.on.rectangle", accessibilityDescription: nil)
        openWinPreview.target = self
        menu.addItem(openWinPreview)

        let openMacFoldersItem = NSMenuItem(
            title: L(
                "Tìm kiếm Thư mục trên Mac ('m ' — \(settings.customMacFolders.count) thư mục gốc)",
                "Search Mac Folders ('m ' — \(settings.customMacFolders.count) roots)"
            ),
            action: #selector(openMacFoldersSearchAction),
            keyEquivalent: ""
        )
        openMacFoldersItem.image = NSImage(systemSymbolName: "folder.badge.gearshape", accessibilityDescription: nil)
        openMacFoldersItem.target = self
        menu.addItem(openMacFoldersItem)

        let openContactsItem = NSMenuItem(
            title: L(
                "Tra cứu Danh bạ — Tiếng Việt không dấu ('c ')",
                "Search Contacts ('c ')"
            ),
            action: #selector(openContactsLookupAction),
            keyEquivalent: ""
        )
        openContactsItem.image = NSImage(systemSymbolName: "person.crop.circle", accessibilityDescription: nil)
        openContactsItem.target = self
        menu.addItem(openContactsItem)

        let openClipHist = NSMenuItem(
            title: L(
                "Lịch sử Clipboard ('cb ' — \(ClipboardHistoryService.shared.entries.count) mục)",
                "Clipboard History ('cb ' — \(ClipboardHistoryService.shared.entries.count) items)"
            ),
            action: #selector(openClipboardHistoryAction),
            keyEquivalent: ""
        )
        openClipHist.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        openClipHist.target = self
        menu.addItem(openClipHist)

        let openSysCmdItem = NSMenuItem(
            title: L(
                "Lệnh Hệ thống macOS ('s ' — Khóa, Sleep, Quit, Eject...)",
                "macOS System Commands ('s ' — Lock, Sleep, Quit, Eject...)"
            ),
            action: #selector(openSystemCommandsAction),
            keyEquivalent: ""
        )
        openSysCmdItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
        openSysCmdItem.target = self
        menu.addItem(openSysCmdItem)

        let ocrClipItem = NSMenuItem(
            title: L(
                "OCR Ảnh trong Clipboard sang Markdown (Tiếng Việt + Anh)",
                "OCR Clipboard Image to Markdown (Vietnamese + English)"
            ),
            action: #selector(ocrClipboardImageAction),
            keyEquivalent: ""
        )
        ocrClipItem.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)
        ocrClipItem.target = self
        menu.addItem(ocrClipItem)

        let quickConvertMD = NSMenuItem(
            title: L(
                "Convert mục đang chọn trong Finder sang Markdown (.md + Copy)",
                "Convert Finder Selection to Markdown (.md + Copy)"
            ),
            action: #selector(convertFinderSelectionToMD),
            keyEquivalent: ""
        )
        quickConvertMD.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil)
        quickConvertMD.target = self
        menu.addItem(quickConvertMD)

        let syncFinderFolderItem = NSMenuItem(
            title: L(
                "Đồng bộ Thư mục đang chọn trong Finder với Google Drive...",
                "Sync Selected Finder Folder with Google Drive..."
            ),
            action: #selector(syncFinderSelectedFolderAction),
            keyEquivalent: ""
        )
        syncFinderFolderItem.image = NSImage(systemSymbolName: "icloud.and.arrow.up.fill", accessibilityDescription: nil)
        syncFinderFolderItem.target = self
        menu.addItem(syncFinderFolderItem)

        let localSyncService = LocalFolderDriveSyncService.shared
        let syncSubmenuParent = NSMenuItem(
            title: L(
                "Thư mục Mac đang đồng bộ Google Drive (\(localSyncService.syncedPairs.count) thư mục)",
                "Mac Folders Synced with Google Drive (\(localSyncService.syncedPairs.count) folders)"
            ),
            action: nil,
            keyEquivalent: ""
        )
        syncSubmenuParent.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.icloud.fill", accessibilityDescription: nil)
        let syncSubmenu = NSMenu()

        let addSyncFolderItem = NSMenuItem(
            title: L("+ Chọn Thư mục trên ổ cứng Mac để đồng bộ...", "+ Choose Mac Folder to Sync with Google Drive..."),
            action: #selector(chooseMacFolderToSyncAction),
            keyEquivalent: ""
        )
        addSyncFolderItem.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        addSyncFolderItem.target = self
        syncSubmenu.addItem(addSyncFolderItem)

        let syncAllNowItem = NSMenuItem(
            title: L("Đồng bộ tất cả ngay lập tức", "Sync All Folders Now"),
            action: #selector(syncAllFoldersNowAction),
            keyEquivalent: ""
        )
        syncAllNowItem.image = NSImage(systemSymbolName: "arrow.clockwise.icloud", accessibilityDescription: nil)
        syncAllNowItem.target = self
        syncAllNowItem.isEnabled = !localSyncService.syncedPairs.isEmpty
        syncSubmenu.addItem(syncAllNowItem)

        let manageSyncedItem = NSMenuItem(
            title: L("Quản lý danh sách Thư mục đồng bộ...", "Manage Synced Folders..."),
            action: #selector(openSyncSettingsPaneAction),
            keyEquivalent: ""
        )
        manageSyncedItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        manageSyncedItem.target = self
        syncSubmenu.addItem(manageSyncedItem)

        syncSubmenu.addItem(.separator())

        if localSyncService.syncedPairs.isEmpty {
            let emptySync = NSMenuItem(
                title: L("  (Chưa có thư mục nào — Bấm chuột phải vào thư mục trong Finder để thêm)", "  (No folders synced yet — Right-click a folder in Finder to add)"),
                action: nil,
                keyEquivalent: ""
            )
            emptySync.isEnabled = false
            syncSubmenu.addItem(emptySync)
        } else {
            for pair in localSyncService.syncedPairs {
                let pItem = NSMenuItem(
                    title: "\(pair.folderName)  →  \(pair.prettyDrivePath)",
                    action: #selector(openSyncedFolderDialogFromMenu(_:)),
                    keyEquivalent: ""
                )
                pItem.representedObject = pair.localPath
                pItem.image = NSImage(systemSymbolName: pair.isEnabled ? "checkmark.icloud.fill" : "icloud.slash", accessibilityDescription: nil)
                pItem.target = self
                syncSubmenu.addItem(pItem)
            }
        }

        syncSubmenuParent.submenu = syncSubmenu
        menu.addItem(syncSubmenuParent)

        let scratchpadItem = NSMenuItem(
            title: L(
                "Ghi chú nháp Scratchpad HUD ('n ')",
                "Scratchpad HUD Notes ('n ')"
            ),
            action: #selector(openScratchpadAction),
            keyEquivalent: ""
        )
        scratchpadItem.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: nil)
        scratchpadItem.target = self
        menu.addItem(scratchpadItem)

        let newFileItem = NSMenuItem(
            title: L(
                "Tạo nhanh tệp tại thư mục Finder ('nf ' / 'nfo ')",
                "New File in active Finder folder ('nf ' / 'nfo ')"
            ),
            action: #selector(openNewFileAction),
            keyEquivalent: ""
        )
        newFileItem.image = NSImage(systemSymbolName: "doc.badge.plus", accessibilityDescription: nil)
        newFileItem.target = self
        menu.addItem(newFileItem)

        let dupScanItem = NSMenuItem(
            title: L(
                "Quét tệp trùng lặp Google Drive & Mac ('dup ')",
                "Scan Duplicate Files ('dup ')"
            ),
            action: #selector(openDuplicatesAction),
            keyEquivalent: ""
        )
        dupScanItem.image = NSImage(systemSymbolName: "archivebox.circle", accessibilityDescription: nil)
        dupScanItem.target = self
        menu.addItem(dupScanItem)

        menu.addItem(.separator())

        let recentHeader = NSMenuItem(
            title: L(
                "Thư mục Google Drive gần đây (\(drive.folderCount.formatted()) thư mục)",
                "Recent Google Drive Folders (\(drive.folderCount.formatted()) folders)"
            ),
            action: nil,
            keyEquivalent: ""
        )
        recentHeader.isEnabled = false
        menu.addItem(recentHeader)

        let recents = drive.recentMyDriveFolders(limit: 6)
        if recents.isEmpty {
            let empty = NSMenuItem(title: L("  (Chưa có lịch sử gần đây)", "  (No recent history)"), action: nil, keyEquivalent: "")
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
                item.image = NSWorkspace.shared.icon(for: .folder)
                item.image?.size = NSSize(width: 16, height: 16)
                item.target = self
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // Quick Shortcut Customization Submenu
        let shortcutParent = NSMenuItem(
            title: L(
                "Thiết lập Phím tắt (Tìm: \(settings.searchHotKey.readableDisplay) • Action: \(settings.universalActionHotKey.readableDisplay) • Cửa sổ: \(settings.windowSwitcherHotKey.readableDisplay))",
                "Shortcut Settings (Search: \(settings.searchHotKey.readableDisplay) • Action: \(settings.universalActionHotKey.readableDisplay) • Windows: \(settings.windowSwitcherHotKey.readableDisplay))"
            ),
            action: nil,
            keyEquivalent: ""
        )
        shortcutParent.image = NSImage(systemSymbolName: "command.square", accessibilityDescription: nil)
        let shortcutMenu = NSMenu()

        let recordSearchItem = NSMenuItem(
            title: L(
                "Tự bấm thiết lập phím tắt Tìm kiếm (\(settings.searchHotKey.readableDisplay))...",
                "Record custom Search shortcut (\(settings.searchHotKey.readableDisplay))..."
            ),
            action: #selector(recordSearchShortcutAction),
            keyEquivalent: ""
        )
        recordSearchItem.target = self
        shortcutMenu.addItem(recordSearchItem)

        let presets: [(String, HotKeyBinding)] = [
            (L("⌘Space — Mặc định (Command + Space)", "⌘Space — Default (Command + Space)"), .commandSpace),
            (L("⌥Space (Option + Space)", "⌥Space (Option + Space)"), .optionSpace),
            (L("⌃Space (Control + Space)", "⌃Space (Control + Space)"), .controlSpace),
            (L("⌘⇧Space (Command + Shift + Space)", "⌘⇧Space (Command + Shift + Space)"), .commandShiftSpace)
        ]
        for (idx, preset) in presets.enumerated() {
            let pItem = NSMenuItem(
                title: preset.0,
                action: #selector(selectSearchPresetShortcut(_:)),
                keyEquivalent: ""
            )
            pItem.tag = idx
            pItem.state = (settings.searchHotKey == preset.1) ? .on : .off
            pItem.target = self
            shortcutMenu.addItem(pItem)
        }

        shortcutMenu.addItem(.separator())

        let recordUAItem = NSMenuItem(
            title: L(
                "Tự bấm thiết lập phím tắt Universal Actions trên Finder (\(settings.universalActionHotKey.readableDisplay))...",
                "Record custom Universal Actions shortcut (\(settings.universalActionHotKey.readableDisplay))..."
            ),
            action: #selector(recordUniversalShortcutAction),
            keyEquivalent: ""
        )
        recordUAItem.target = self
        shortcutMenu.addItem(recordUAItem)

        let uaPresets: [(String, HotKeyBinding)] = [
            (L("⌘/ — Mặc định Finder (Command + /)", "⌘/ — Default Finder (Command + /)"), .commandSlash),
            (L("⌘\\ (Command + \\)", "⌘\\ (Command + \\)"), .commandBackslash),
            (L("⌥⌘/ (Option + Command + /)", "⌥⌘/ (Option + Command + /)"), .optionCommandSlash),
            (L("⌘⇧A (Command + Shift + A)", "⌘⇧A (Command + Shift + A)"), .commandShiftA)
        ]
        for (idx, uaPreset) in uaPresets.enumerated() {
            let uItem = NSMenuItem(
                title: uaPreset.0,
                action: #selector(selectUniversalPresetShortcut(_:)),
                keyEquivalent: ""
            )
            uItem.tag = idx
            uItem.state = (settings.universalActionHotKey == uaPreset.1) ? .on : .off
            uItem.target = self
            shortcutMenu.addItem(uItem)
        }

        shortcutMenu.addItem(.separator())

        let recordWinItem = NSMenuItem(
            title: L(
                "Tự bấm thiết lập phím tắt Windows Preview (\(settings.windowSwitcherHotKey.readableDisplay))...",
                "Record custom Windows Preview shortcut (\(settings.windowSwitcherHotKey.readableDisplay))..."
            ),
            action: #selector(recordWindowSwitcherShortcutAction),
            keyEquivalent: ""
        )
        recordWinItem.target = self
        shortcutMenu.addItem(recordWinItem)

        let winPresets: [(String, HotKeyBinding)] = [
            (L("⌘⇥ — Mặc định Windows Preview (Command + Tab)", "⌘⇥ — Default Windows Preview (Command + Tab)"), .commandTab),
            (L("⌥⇥ (Option + Tab)", "⌥⇥ (Option + Tab)"), .optionTab),
            (L("⌃⇥ (Control + Tab)", "⌃⇥ (Control + Tab)"), .controlTab)
        ]
        for (idx, wPreset) in winPresets.enumerated() {
            let wItem = NSMenuItem(
                title: wPreset.0,
                action: #selector(selectWindowSwitcherPresetShortcut(_:)),
                keyEquivalent: ""
            )
            wItem.tag = idx
            wItem.state = (settings.windowSwitcherHotKey == wPreset.1) ? .on : .off
            wItem.target = self
            shortcutMenu.addItem(wItem)
        }

        let toggleMinItem = NSMenuItem(
            title: L("Hiển thị cửa sổ đang Minimize trong Windows Preview", "Show minimized windows in Windows Preview"),
            action: #selector(toggleWindowSwitcherMinimizedAction),
            keyEquivalent: ""
        )
        toggleMinItem.state = settings.windowSwitcherShowMinimized ? .on : .off
        toggleMinItem.target = self
        shortcutMenu.addItem(toggleMinItem)

        shortcutMenu.addItem(.separator())

        let resetHotkeysItem = NSMenuItem(
            title: L("Khôi phục mặc định (⌘Space • ⌘/ • ⌘⇥)", "Restore Defaults (⌘Space • ⌘/ • ⌘⇥)"),
            action: #selector(resetDefaultShortcutsAction),
            keyEquivalent: ""
        )
        resetHotkeysItem.target = self
        shortcutMenu.addItem(resetHotkeysItem)

        shortcutParent.submenu = shortcutMenu
        menu.addItem(shortcutParent)

        // Dock Show/Hide & Launch at Login Toggles
        let showDockItem = NSMenuItem(
            title: L("Hiển thị biểu tượng trên thanh Dock", "Show icon in Dock"),
            action: #selector(toggleShowDockAction),
            keyEquivalent: ""
        )
        showDockItem.state = settings.showDockIcon ? .on : .off
        showDockItem.target = self
        menu.addItem(showDockItem)

        let launchItem = NSMenuItem(
            title: L("Khởi động cùng macOS", "Launch at login"),
            action: #selector(toggleLaunchAtLoginAction),
            keyEquivalent: ""
        )
        launchItem.state = settings.launchAtLogin ? .on : .off
        launchItem.target = self
        menu.addItem(launchItem)

        let showOnStartupItem = NSMenuItem(
            title: L("Bật bảng Tìm kiếm khi khởi động", "Show Search window on startup"),
            action: #selector(toggleShowLauncherOnStartupAction),
            keyEquivalent: ""
        )
        showOnStartupItem.state = settings.showLauncherOnStartup ? .on : .off
        showOnStartupItem.target = self
        menu.addItem(showOnStartupItem)

        menu.addItem(.separator())

        // Auto-Update Section
        if let newVer = updater.availableVersion {
            let installItem = NSMenuItem(
                title: L("Tải & Cập nhật tự động v\(newVer)", "Download & Update automatically v\(newVer)"),
                action: #selector(installUpdateAction),
                keyEquivalent: ""
            )
            installItem.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            installItem.target = self
            menu.addItem(installItem)
        }

        let checkTitle: String = {
            switch updater.state {
            case .checking: return L("Đang kiểm tra cập nhật...", "Checking for updates...")
            case .downloading(let v): return L("Đang tải v\(v)...", "Downloading v\(v)...")
            case .installing(let v): return L("Đang cài đặt v\(v)...", "Installing v\(v)...")
            default: return L("Kiểm tra cập nhật từ GitHub...", "Check for updates from GitHub...")
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
            ? (drive.rebuildProgressText ?? L("Đang quét lại Cache Google Drive...", "Rebuilding Google Drive Cache..."))
            : L("Quét lại Cache Google Drive ngay", "Rebuild Google Drive Cache now")
        let rebuildItem = NSMenuItem(title: rebuildTitle, action: #selector(rebuildCacheAction), keyEquivalent: "")
        rebuildItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        rebuildItem.isEnabled = !drive.isRebuildingFolders
        rebuildItem.target = self
        menu.addItem(rebuildItem)

        let prefsItem = NSMenuItem(title: L("Cài đặt & Quản lý DriveBar...", "Settings & Preferences..."), action: #selector(openPrefsAction), keyEquivalent: ",")
        prefsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: L("Thoát DriveBar", "Quit DriveBar"), action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    @objc private func openSearchAction() {
        LauncherPanelController.shared.toggleSearchPanel()
    }

    @objc private func openUniversalAction() {
        LauncherPanelController.shared.triggerUniversalActionsOnSelection()
    }

    @objc private func openWindowsPreviewAction() {
        WindowSwitcherController.shared.openPinnedFromMenuOrSearch()
    }

    @objc private func openMacFoldersSearchAction() {
        LauncherViewModel.shared.prepareForSearchLaunch()
        LauncherViewModel.shared.searchText = "m "
        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
    }

    @objc private func openContactsLookupAction() {
        LauncherViewModel.shared.prepareForSearchLaunch()
        LauncherViewModel.shared.searchText = "c "
        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
    }

    @objc private func openClipboardHistoryAction() {
        LauncherViewModel.shared.prepareForSearchLaunch()
        LauncherViewModel.shared.searchText = "cb "
        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
    }

    @objc private func openSystemCommandsAction() {
        LauncherViewModel.shared.prepareForSearchLaunch()
        LauncherViewModel.shared.searchText = "s "
        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
    }

    @objc private func openScratchpadAction() {
        ScratchpadHUDController.shared.show()
    }

    @objc private func openNewFileAction() {
        LauncherViewModel.shared.prepareForSearchLaunch()
        LauncherViewModel.shared.searchText = "nf "
        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
    }

    @objc private func openDuplicatesAction() {
        LauncherViewModel.shared.prepareForSearchLaunch()
        LauncherViewModel.shared.searchText = "dup "
        LauncherPanelController.shared.showAndFocus(selectExistingQuery: false)
    }

    @objc private func ocrClipboardImageAction() {
        LauncherViewModel.shared.runClipboardImageOCR(openPreview: false)
    }

    @objc private func convertFinderSelectionToMD() {
        let urls = SelectionCaptureService.fetchFinderSelectionURLs()
        guard !urls.isEmpty else {
            FloatingToastController.shared.showError(
                title: L("Chưa chọn tệp nào trong Finder", "No files selected in Finder"),
                subtitle: L("Hãy chọn ít nhất 1 tệp tài liệu trong Finder", "Please select at least 1 file in Finder")
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

    @objc private func recordSearchShortcutAction() {
        HotKeyService.shared.openSettingsAndRecord(.search)
    }

    @objc private func recordUniversalShortcutAction() {
        HotKeyService.shared.openSettingsAndRecord(.universalAction)
    }

    @objc private func recordWindowSwitcherShortcutAction() {
        HotKeyService.shared.openSettingsAndRecord(.windowSwitcher)
    }

    @objc private func selectWindowSwitcherPresetShortcut(_ sender: NSMenuItem) {
        let presets: [HotKeyBinding] = [.commandTab, .optionTab, .controlTab]
        guard sender.tag >= 0 && sender.tag < presets.count else { return }
        HotKeyService.shared.applyRecordedBinding(presets[sender.tag], for: .windowSwitcher)
    }

    @objc private func toggleWindowSwitcherMinimizedAction() {
        AppSettings.shared.windowSwitcherShowMinimized.toggle()
    }

    @objc private func selectSearchPresetShortcut(_ sender: NSMenuItem) {
        let presets: [HotKeyBinding] = [.commandSpace, .optionSpace, .controlSpace, .commandShiftSpace]
        guard sender.tag >= 0 && sender.tag < presets.count else { return }
        HotKeyService.shared.applyRecordedBinding(presets[sender.tag], for: .search)
    }

    @objc private func selectUniversalPresetShortcut(_ sender: NSMenuItem) {
        let presets: [HotKeyBinding] = [.commandSlash, .commandBackslash, .optionCommandSlash, .commandShiftA]
        guard sender.tag >= 0 && sender.tag < presets.count else { return }
        HotKeyService.shared.applyRecordedBinding(presets[sender.tag], for: .universalAction)
    }

    @objc private func resetDefaultShortcutsAction() {
        AppSettings.shared.resetShortcutsToDefault()
        FloatingToastController.shared.showSuccess(
            title: L("Đã khôi phục phím tắt mặc định", "Restored default shortcuts"),
            subtitle: L("Tìm: ⌘Space  •  Finder: ⌘/  •  Windows: ⌘⇥", "Search: ⌘Space  •  Finder: ⌘/  •  Windows: ⌘⇥")
        )
    }

    @objc private func toggleLaunchAtLoginAction() {
        AppSettings.shared.toggleLaunchAtLogin(!AppSettings.shared.launchAtLogin)
    }

    @objc private func toggleShowLauncherOnStartupAction() {
        AppSettings.shared.showLauncherOnStartup.toggle()
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

    @objc private func syncFinderSelectedFolderAction() {
        let urls = SelectionCaptureService.fetchFinderSelectionURLs()
        guard !urls.isEmpty else {
            chooseMacFolderToSyncAction()
            return
        }
        FolderSyncDialogController.shared.present(forFolderURLs: urls, instantIfSingle: false)
    }

    @objc private func chooseMacFolderToSyncAction() {
        let panel = NSOpenPanel()
        panel.title = L("Chọn thư mục trên ổ cứng Mac để đồng bộ với Google Drive", "Choose a Mac folder to sync with Google Drive")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = L("Chọn thư mục", "Choose Folder")
        let antigravityPath = (NSHomeDirectory() as NSString).appendingPathComponent("Documents/antigravity")
        if FileManager.default.fileExists(atPath: antigravityPath) {
            panel.directoryURL = URL(fileURLWithPath: antigravityPath)
        }
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            FolderSyncDialogController.shared.present(forFolderURLs: panel.urls, instantIfSingle: false)
        }
    }

    @objc private func syncAllFoldersNowAction() {
        LocalFolderDriveSyncService.shared.syncAllEnabledPairs(showToast: true)
    }

    @objc private func openSyncSettingsPaneAction() {
        SettingsUIState.shared.selectedTab = .googleDrive
        AppDelegate.shared?.openSettingsWindow()
    }

    @objc private func openSyncedFolderDialogFromMenu(_ sender: NSMenuItem) {
        guard let localPath = sender.representedObject as? String else { return }
        FolderSyncDialogController.shared.presentDialog(forLocalPath: localPath)
    }

    @objc private func openPrefsAction() {
        AppDelegate.shared?.openSettingsWindow()
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }
}
