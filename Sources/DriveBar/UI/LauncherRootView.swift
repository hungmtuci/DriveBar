import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LauncherRootView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var driveService = GoogleDriveIndexService.shared
    @ObservedObject private var bufferService = FileBufferService.shared

    var body: some View {
        VStack(spacing: 0) {
            if !bufferService.items.isEmpty, case .search = viewModel.screenMode {
                FileBufferStripView(bufferService: bufferService, viewModel: viewModel)
                Divider()
            }

            switch viewModel.screenMode {
            case .search:
                SearchModeContentView(viewModel: viewModel, driveService: driveService)

            case .universalActions(let target):
                UniversalActionsView(viewModel: viewModel, target: target)

            case .openWithPicker(let fileURL, let prevTarget):
                OpenWithPickerView(viewModel: viewModel, fileURL: fileURL, previousTarget: prevTarget)

            case .destinationPicker(let op, let sources):
                DestinationFolderPickerView(viewModel: viewModel, operation: op, sources: sources)

            case .batchRename:
                BatchRenameView(viewModel: viewModel)

            case .markdownPreview(let title, let srcURL, let savedURL, let md, let tokens, let engine):
                MarkdownPreviewView(
                    viewModel: viewModel,
                    title: title,
                    sourceURL: srcURL,
                    savedMDURL: savedURL,
                    markdown: md,
                    estimatedTokens: tokens,
                    engineUsed: engine
                )

            case .contactDetail(let contactID, _, _):
                ContactDetailView(viewModel: viewModel, contactID: contactID)
            }
        }
        .frame(width: 760, height: 500)
        .background(
            ZStack {
                VisualEffectFrostView(material: .menu, blendingMode: .behindWindow)
                Color(nsColor: .windowBackgroundColor).opacity(0.66)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDroppedProviders(providers)
            return true
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            var droppedURLs: [URL] = []
            for p in providers {
                if let item = try? await p.loadItem(forTypeIdentifier: "public.file-url", options: nil),
                   let data = item as? Data,
                   let u = URL(dataRepresentation: data, relativeTo: nil) {
                    droppedURLs.append(u)
                }
            }
            if !droppedURLs.isEmpty {
                viewModel.openUniversalActions(
                    for: .files(droppedURLs, sourceNote: L("Kéo thả", "Drag & Drop")),
                    directExternalTrigger: false
                )
            }
        }
    }
}

// MARK: - Search & Browse Mode View

private struct SearchModeContentView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var driveService: GoogleDriveIndexService
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 0) {
            // Search Input Bar (Native macOS Spotlight-style header)
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.secondary)

                NativeSearchInputField(
                    text: $viewModel.searchText,
                    placeholder: L("Tìm thư mục, tệp & ứng dụng ('m ' mục Mac, 'c ' danh bạ, 'cb ' clipboard, 'a ' app, 's ' lệnh)...", "Search folders, files & apps ('m ' Mac folders, 'c ' contacts, 'cb ' clipboard, 'a ' apps, 's ' system)..."),
                    fontSize: 18,
                    focusTrigger: viewModel.focusTrigger,
                    selectAllOnFocus: viewModel.selectAllOnFocus,
                    onMoveSelection: { viewModel.moveSelection(delta: $0) },
                    onSubmit: { viewModel.executeCurrentSelection(modifiers: $0) },
                    onTab: { viewModel.handleTabKey() },
                    onEscape: { viewModel.handleEscapeKey() },
                    onBackspaceAtBoundary: { viewModel.popParentFolderIfAtSlashBoundary() }
                )
                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 26)

                if viewModel.isLoadingBrowseFiles {
                    ProgressView()
                        .controlSize(.small)
                        .help(L("Đang đọc danh sách tệp trong thư mục ở nền...", "Reading directory files in background..."))
                }

                if !viewModel.searchText.isEmpty {
                    Button {
                        viewModel.searchText = ""
                        viewModel.triggerInputFocus(selectAll: false)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help(L("Xóa nội dung tìm kiếm (Esc)", "Clear search query (Esc)"))
                }

                if driveService.isRebuildingFolders || driveService.isRebuildingShared || driveService.isRebuildingFiles || driveService.isRebuildingMacFolders {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(driveService.rebuildProgressText ?? L("Đang đồng bộ...", "Syncing..."))
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .fixedSize(horizontal: true, vertical: false)
                }

                let badge = viewModel.currentSearchModeBadge
                Text(badge.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            // Results List (Eager VStack + single integer ID for instant 120fps selection & scroll)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(viewModel.searchResults.enumerated()), id: \.offset) { idx, item in
                            SearchResultRowView(
                                item: item,
                                index: idx,
                                isSelected: idx == viewModel.selectedIndex,
                                activeModifiers: viewModel.activeModifiers,
                                onPrimaryActivate: {
                                    let mods = NSEvent.modifierFlags.cleanShortcutModifiers
                                    viewModel.executeAtIndex(idx, modifiers: mods)
                                },
                                onOpenActions: {
                                    viewModel.selectedIndex = idx
                                    _ = viewModel.openUniversalActionsForSelectedSearchItem()
                                }
                            )
                            .id(idx)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onChange(of: viewModel.selectedIndex) { _, newIdx in
                    proxy.scrollTo(newIdx)
                }
            }

            Divider()

            // Bottom Shortcut Hints Footer
            SearchFooterBar(viewModel: viewModel, folderCount: driveService.folderCount)
        }
    }
}

private struct SearchResultRowView: View {
    let item: SearchResultItem
    let index: Int
    let isSelected: Bool
    let activeModifiers: NSEvent.ModifierFlags
    var onPrimaryActivate: (() -> Void)? = nil
    var onOpenActions: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 11) {
            HStack(spacing: 11) {
                if case .contactItem(let contactID) = item.kind {
                    ContactAvatarView(
                        contactID: contactID,
                        initials: ContactsSearchService.shared.contact(withID: contactID)?.initials ?? "?",
                        size: 28,
                        isRowSelected: isSelected
                    )
                    .frame(width: 28, height: 28)
                } else {
                    FileOrSymbolIconView(
                        path: item.path,
                        fallbackSymbol: item.sfSymbolFallback ?? "folder.fill",
                        isRowSelected: isSelected
                    )
                    .frame(width: 28, height: 28)
                }

                VStack(alignment: .leading, spacing: 1.5) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .lineLimit(1)

                        if let badge = item.badge {
                            Text(badge)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(isSelected ? Color.white.opacity(0.92) : Color.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 5.5)
                                .padding(.vertical, 1)
                                .background(
                                    (isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)),
                                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                                )
                                .fixedSize(horizontal: true, vertical: false)
                        }
                    }

                    Text(dynamicSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onPrimaryActivate?()
            }

            if isSelected {
                HStack(spacing: 6) {
                    if supportsUniversalActions, let onOpenActions {
                        Text("→ Actions")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2.5)
                            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .fixedSize(horizontal: true, vertical: false)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onOpenActions()
                            }
                            .help(L("Mở Universal Actions & Convert sang Markdown (Phím →, Tab hoặc ⌘/)", "Open Universal Actions & Convert to Markdown (→, Tab or ⌘/)"))
                    }

                    if case .contactItem = item.kind {
                        Text(L("Chi tiết ↩", "Detail ↩"))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 2.5)
                            .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .fixedSize(horizontal: true, vertical: false)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onPrimaryActivate?()
                            }
                    } else {
                        Text("↩")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onPrimaryActivate?()
                            }
                    }
                }
            } else if index < 9 {
                HStack(spacing: 6) {
                    if supportsUniversalActions, let onOpenActions {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 12.5))
                            .foregroundStyle(.tertiary)
                            .padding(3)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onOpenActions()
                            }
                            .help(L("Mở Universal Actions cho mục này", "Open Universal Actions for this item"))
                    }
                    Text("⌘\(index + 1)")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        )
    }

    private var supportsUniversalActions: Bool {
        switch item.kind {
        case .systemCommand, .contactItem, .calculatorResult, .infoBanner:
            return false
        case .clipboardItem, .webURLQuickConvert:
            return true
        default:
            return item.path != nil
        }
    }

    private var dynamicSubtitle: String {
        if isSelected, case .contactItem(let contactID) = item.kind {
            if activeModifiers.contains(.option),
               let rec = ContactsSearchService.shared.contact(withID: contactID) {
                return "\(L("⌥↩ Sao chép nhanh", "⌥↩ Quick copy")) \(rec.primaryQuickCopyLabel): \(rec.primaryQuickCopyValue)"
            }
            if activeModifiers.contains(.command) {
                return L("⌘↩ Mở liên hệ này trong ứng dụng Danh bạ macOS", "⌘↩ Open contact in macOS Contacts app")
            }
            if activeModifiers.contains(.shift) {
                return L("⇧ (Thả phím Shift) Phóng to chữ Large Type", "⇧ (Release Shift) Show Large Type")
            }
            return item.subtitle
        }
        if case .systemCommand = item.kind {
            return item.subtitle
        }
        if isSelected, case .clipboardItem = item.kind {
            if activeModifiers.contains(.option) {
                return L("⌥↩ Chỉ sao chép lại vào Clipboard (không tự dán)", "⌥↩ Copy to Clipboard only (no paste)")
            }
            if activeModifiers.contains(.command) && item.path != nil {
                return L("⌘↩ Mở vị trí tệp / ảnh trong Finder  •  ⇥ Mở Universal Actions", "⌘↩ Reveal file / image in Finder  •  ⇥ Universal Actions")
            }
            if activeModifiers.contains(.shift) {
                return L("⇧ (Thả phím Shift) Xem nhanh Quick Look  •  ⇧↩ Mở Universal Actions", "⇧ (Release Shift) Quick Look  •  ⇧↩ Universal Actions")
            }
            return item.subtitle
        }
        guard isSelected, item.path != nil else { return item.subtitle }
        if case .localApp = item.kind {
            if activeModifiers.contains(.command) {
                return L("⌘↩ Mở vị trí ứng dụng trong Finder  •  ⌘D Ghim  •  ⌘/ Universal Actions", "⌘↩ Reveal application in Finder  •  ⌘D Pin  •  ⌘/ Universal Actions")
            }
            if activeModifiers.contains(.option) {
                return L("⌥↩ Sao chép đường dẫn ứng dụng vào Clipboard", "⌥↩ Copy application path to Clipboard")
            }
            if activeModifiers.contains(.shift) {
                return L("⇧↩ Mở Universal Actions cho ứng dụng này", "⇧↩ Open Universal Actions for this app")
            }
            return item.subtitle
        }
        if activeModifiers.contains(.command) {
            return L("⌘↩ Mở vị trí trực tiếp trong Finder  •  ⌘D Ghim  •  ⌘/ Universal Actions", "⌘↩ Reveal in Finder  •  ⌘D Pin  •  ⌘/ Universal Actions")
        }
        if activeModifiers.contains(.option) {
            return L("⌥↩ Sao chép liên kết chia sẻ Google Drive vào Clipboard", "⌥↩ Copy Google Drive share link to Clipboard")
        }
        if activeModifiers.contains(.control) {
            return L("⌃↩ Mở trực tiếp trên trình duyệt Google Drive Web", "⌃↩ Open directly in Google Drive Web")
        }
        if activeModifiers.contains(.shift) {
            return L("⇧ (Thả phím Shift) Xem nhanh Quick Look  •  ⇧↩ Mở Universal Actions", "⇧ (Release Shift) Quick Look  •  ⇧↩ Universal Actions")
        }
        return item.subtitle
    }
}

private struct SearchFooterBar: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updater = UpdateCheckerService.shared
    let folderCount: Int

    var body: some View {
        HStack(spacing: 8) {
            FooterShortcutHint(key: "↩", label: L("Mở", "Open"))
            FooterShortcutHint(key: "⇥", label: "Actions")
            if updater.availableVersion == nil {
                FooterShortcutHint(key: "⇧", label: L("Xem nhanh", "Quick Look"))
                FooterShortcutHint(key: "⌘D", label: L("Ghim", "Pin"))
            }

            Spacer(minLength: 4)

            if folderCount > 0 && updater.availableVersion == nil {
                Text(L("\(folderCount.formatted()) mục", "\(folderCount.formatted()) items"))
                    .lineLimit(1)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }

            if let ver = updater.availableVersion {
                Button {
                    LauncherPanelController.shared.hide()
                    updater.installAvailableUpdate()
                } label: {
                    Label(L("Cập nhật v\(ver)", "Update v\(ver)"), systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .help(L("Tự động tải và cập nhật phiên bản mới từ GitHub", "Automatically download and update from GitHub"))
            }

            Button {
                settings.toggleLaunchAtLogin(!settings.launchAtLogin)
                viewModel.triggerInputFocus(selectAll: false)
            } label: {
                footerCheckPill(
                    title: L("Khởi động cùng macOS", "Launch at login"),
                    isChecked: settings.launchAtLogin
                )
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .help(L("Tự động chạy nền DriveBar ngay khi đăng nhập vào macOS", "Start DriveBar in background on macOS login"))

            Button {
                settings.showLauncherOnStartup.toggle()
                viewModel.triggerInputFocus(selectAll: false)
            } label: {
                footerCheckPill(
                    title: L("Bật bảng này khi khởi động", "Show launcher on startup"),
                    isChecked: settings.showLauncherOnStartup
                )
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .help(L("Tự động mở sẵn thanh Tìm kiếm này ngay khi khởi động DriveBar", "Automatically show launcher window on app startup"))

            Button {
                LauncherPanelController.shared.hide()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    WindowSwitcherController.shared.openPinnedFromMenuOrSearch()
                }
            } label: {
                footerActionPill(L("Cửa sổ \(settings.windowSwitcherHotKey.readableDisplay)", "Windows \(settings.windowSwitcherHotKey.readableDisplay)"), monospaced: true)
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .contextMenu {
                Button(L("Mở Windows Preview ngay", "Open Windows Preview now")) {
                    LauncherPanelController.shared.hide()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                        WindowSwitcherController.shared.openPinnedFromMenuOrSearch()
                    }
                }
                Button(L("Cài đặt Windows Preview (\(settings.windowSwitcherHotKey.readableDisplay))...", "Configure Windows Preview (\(settings.windowSwitcherHotKey.readableDisplay))...")) {
                    LauncherPanelController.shared.hide()
                    HotKeyService.shared.openSettingsAndRecord(.windowSwitcher)
                }
            }
            .help(L("Mở Windows Preview (Chuột phải để đổi phím tắt \(settings.windowSwitcherHotKey.readableDisplay))", "Open Windows Preview (Right-click to configure \(settings.windowSwitcherHotKey.readableDisplay))"))

            Button {
                LauncherPanelController.shared.hide()
                AppDelegate.shared?.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .contextMenu {
                Button(L("Cài đặt DriveBar (⌘,)...", "DriveBar Settings (⌘,)...")) {
                    LauncherPanelController.shared.hide()
                    AppDelegate.shared?.openSettingsWindow()
                }
                Divider()
                Button(settings.launchAtLogin ? L("✓ Khởi động cùng macOS", "✓ Launch at login") : L("Khởi động cùng macOS", "Launch at login")) {
                    settings.toggleLaunchAtLogin(!settings.launchAtLogin)
                }
                Button(settings.showLauncherOnStartup ? L("✓ Bật bảng này khi khởi động", "✓ Show launcher on startup") : L("Bật bảng này khi khởi động", "Show launcher on startup")) {
                    settings.showLauncherOnStartup.toggle()
                }
                Button(settings.showDockIcon ? L("Ẩn khỏi thanh Dock", "Hide from Dock") : L("Hiện trên thanh Dock", "Show on Dock")) {
                    settings.showDockIcon.toggle()
                }
                Divider()
                Button(L("Đổi phím tắt Tìm kiếm (\(settings.searchHotKey.readableDisplay))...", "Change Search Hotkey (\(settings.searchHotKey.readableDisplay))...")) {
                    LauncherPanelController.shared.hide()
                    HotKeyService.shared.openSettingsAndRecord(.search)
                }
                Button(L("Đổi phím tắt Universal Actions (\(settings.universalActionHotKey.readableDisplay))...", "Change Universal Actions Hotkey (\(settings.universalActionHotKey.readableDisplay))...")) {
                    LauncherPanelController.shared.hide()
                    HotKeyService.shared.openSettingsAndRecord(.universalAction)
                }
                Divider()
                Button(L("Kiểm tra cập nhật...", "Check for Updates...")) {
                    LauncherPanelController.shared.hide()
                    AppDelegate.shared?.openSettingsWindow()
                    UpdateCheckerService.shared.checkForUpdatesManually()
                }
            }
            .help(L("Cài đặt DriveBar (⌘,) • Chuột phải để truy cập nhanh tùy chọn khởi động & phím tắt", "DriveBar Settings (⌘,) • Right-click for quick shortcuts"))
        }
        .font(.system(size: 10.5, weight: .regular))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7.5)
        .background(Color.primary.opacity(0.02))
        .onAppear {
            settings.refreshLaunchAtLoginStatus()
        }
    }

    private func footerCheckPill(title: String, isChecked: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(isChecked ? Color.accentColor : Color.secondary)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isChecked ? Color.primary : Color.secondary)
        }
        .padding(.horizontal, 6.5)
        .padding(.vertical, 2.5)
        .background(
            isChecked ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(
                    isChecked ? Color.accentColor.opacity(0.32) : Color.primary.opacity(0.08),
                    lineWidth: 0.5
                )
        )
    }

    private func footerActionPill(_ title: String, monospaced: Bool) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .medium, design: monospaced ? .monospaced : .default))
            .lineLimit(1)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7.5)
            .padding(.vertical, 2.5)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }
}

// MARK: - File Buffer Strip

private struct FileBufferStripView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var bufferService: FileBufferService
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))

            Text(L("Buffer (\(bufferService.items.count)):", "Buffer (\(bufferService.items.count)):"))
                .font(.system(size: 11.5, weight: .medium))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(bufferService.items, id: \.path) { url in
                        HStack(spacing: 4) {
                            Text(url.lastPathComponent)
                                .font(.system(size: 11))
                                .lineLimit(1)
                            Button {
                                bufferService.remove(url)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                }
            }

            Spacer()

            Button(L("Tác vụ (⌥→)", "Actions (⌥→)")) {
                viewModel.openUniversalActions(
                    for: .files(bufferService.items, sourceNote: L("Bộ nhớ tạm tập tin", "File Buffer")),
                    directExternalTrigger: false
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.mini)

            Button(L("Xóa (⌥⌫)", "Clear (⌥⌫)")) {
                bufferService.clear()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
    }
}

// MARK: - Open With & Destination Folder Pickers

private struct OpenWithPickerView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var viewModel: LauncherViewModel
    let fileURL: URL
    let previousTarget: ActionTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    viewModel.openUniversalActions(for: previousTarget, directExternalTrigger: viewModel.openedDirectlyInUniversalActions)
                } label: {
                    Label(L("Quay lại", "Back"), systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text(L("Mở '\(fileURL.lastPathComponent)' bằng ứng dụng:", "Open '\(fileURL.lastPathComponent)' with:"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Text(L("↩ Mở  •  ← / Esc để quay lại", "↩ Open  •  ← / Esc to back"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(viewModel.openWithApps.enumerated()), id: \.offset) { idx, app in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                    .resizable()
                                    .frame(width: 24, height: 24)
                                Text(app.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(idx == viewModel.selectedIndex ? .white : .primary)
                                Spacer()
                                if idx == viewModel.selectedIndex {
                                    Text("↩")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                } else if idx < 9 {
                                    Text("⌘\(idx + 1)")
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6.5)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(idx == viewModel.selectedIndex ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.executeAtIndex(idx, modifiers: [])
                            }
                            .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onChange(of: viewModel.selectedIndex) { _, newIdx in
                    proxy.scrollTo(newIdx)
                }
            }
        }
    }
}

private struct DestinationFolderPickerView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var viewModel: LauncherViewModel
    let operation: FileTransferOperation
    let sources: [URL]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    viewModel.openUniversalActions(
                        for: .files(sources),
                        directExternalTrigger: viewModel.openedDirectlyInUniversalActions
                    )
                } label: {
                    Label(L("Quay lại", "Back"), systemImage: "chevron.left")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 1) {
                    Text(operation.localizedTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(sources.count == 1 ? sources[0].lastPathComponent : L("\(sources.count) mục đã chọn", "\(sources.count) items selected"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text(L("\(sources.count) mục", "\(sources.count) items"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14.5, weight: .medium))
                    .foregroundStyle(.secondary)

                NativeSearchInputField(
                    text: $viewModel.destinationSearchText,
                    placeholder: L(
                        "Gõ tìm thư mục Google Drive đích (hoặc nhấn Tab / → để duyệt cây thư mục con)...",
                        "Search target Google Drive folder (or press Tab / → to browse subfolders)..."
                    ),
                    fontSize: 15,
                    focusTrigger: viewModel.focusTrigger,
                    selectAllOnFocus: false,
                    onMoveSelection: { viewModel.moveSelection(delta: $0) },
                    onSubmit: { viewModel.executeCurrentSelection(modifiers: $0) },
                    onTab: { viewModel.handleTabKey() },
                    onEscape: { viewModel.handleEscapeKey() },
                    onBackspaceAtBoundary: { viewModel.popParentFolderIfAtSlashBoundary() }
                )
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 24)

                if !viewModel.destinationSearchText.isEmpty {
                    Button {
                        viewModel.destinationSearchText = ""
                        viewModel.triggerInputFocus(selectAll: false)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(viewModel.destinationFolders.enumerated()), id: \.offset) { idx, folder in
                            SearchResultRowView(
                                item: folder,
                                index: idx,
                                isSelected: idx == viewModel.selectedIndex,
                                activeModifiers: viewModel.activeModifiers,
                                onPrimaryActivate: {
                                    let mods = NSEvent.modifierFlags.cleanShortcutModifiers
                                    viewModel.executeAtIndex(idx, modifiers: mods)
                                },
                                onOpenActions: nil
                            )
                            .id(idx)
                        }
                    }
                    .padding(8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onChange(of: viewModel.selectedIndex) { _, newIdx in
                    proxy.scrollTo(newIdx)
                }
            }

            Divider()

            HStack(spacing: 12) {
                FooterShortcutHint(key: "↩", label: L("Thực hiện tại đây", "Run here"))
                FooterShortcutHint(key: "⇥", label: L("Duyệt thư mục con", "Browse subfolder"))
                FooterShortcutHint(key: "⌘↩", label: L("Thực hiện & Mở Finder", "Run & Reveal in Finder"))
                FooterShortcutHint(key: "⇧", label: L("Quick Look", "Quick Look"))
                Spacer()
                FooterShortcutHint(key: "Esc", label: L("Quay lại", "Back"))
            }
            .font(.system(size: 10.5, weight: .regular))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7.5)
            .background(Color.primary.opacity(0.02))
        }
    }
}

// MARK: - Shared Visual Helpers

struct FooterShortcutHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 1.5)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
            Text(label)
                .font(.system(size: 10.5, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct FileOrSymbolIconView: View {
    let path: String?
    let fallbackSymbol: String
    var isRowSelected: Bool = false

    private var prefersDirectSymbol: Bool {
        fallbackSymbol == "arrow.turn.left.up" ||
        fallbackSymbol == "checkmark.circle.fill" ||
        fallbackSymbol == "function"
    }

    var body: some View {
        if prefersDirectSymbol {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isRowSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06))
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isRowSelected ? Color.white : Color.secondary)
            }
        } else if let path {
            if path.contains("/Library/CloudStorage/") {
                Image(nsImage: Self.fastCloudIcon(for: path, fallbackSymbol: fallbackSymbol))
                    .resizable()
                    .interpolation(.high)
            } else if FileManager.default.fileExists(atPath: path) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(isRowSelected ? Color.white : Color.secondary)
            }
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(isRowSelected ? Color.white : Color.secondary)
        }
    }

    static func fastCloudIcon(for path: String, fallbackSymbol: String) -> NSImage {
        if fallbackSymbol.contains("folder") || fallbackSymbol.contains("externaldrive") {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if !ext.isEmpty, !ext.contains(" "), let utType = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .data)
    }
}

struct VisualEffectFrostView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
