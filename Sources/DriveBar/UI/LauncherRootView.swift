import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct LauncherRootView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject private var driveService = GoogleDriveIndexService.shared
    @ObservedObject private var bufferService = FileBufferService.shared

    var body: some View {
        VStack(spacing: 0) {
            if !bufferService.items.isEmpty, case .search = viewModel.screenMode {
                FileBufferStripView(bufferService: bufferService, viewModel: viewModel)
                Divider().opacity(0.4)
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
            }
        }
        .frame(width: 760)
        .background(
            VisualEffectFrostView(material: .popover, blendingMode: .behindWindow)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.16), lineWidth: 1)
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
                    for: .files(droppedURLs, sourceNote: "Kéo thả"),
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
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search Input Bar
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.purple)

                TextField("Tìm nhanh thư mục Google Drive (gõ không dấu / viết tắt, 'fs ' chia sẻ, 'ai ' convert)...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .regular))
                    .focused($isSearchFocused)

                if driveService.isRebuildingFolders || driveService.isRebuildingShared {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text(driveService.rebuildProgressText ?? "Đang đồng bộ...")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06), in: Capsule())
                }

                let badge = viewModel.currentSearchModeBadge
                Text(badge.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(badge.color)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(badge.color.opacity(0.14), in: Capsule())
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 15)
            .onAppear {
                isSearchFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .driveBarFocusInput)) { _ in
                isSearchFocused = true
            }

            Divider().opacity(0.45)

            // Results List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(Array(viewModel.searchResults.enumerated()), id: \.element.id) { idx, item in
                            SearchResultRowView(
                                item: item,
                                index: idx,
                                isSelected: idx == viewModel.selectedIndex,
                                activeModifiers: viewModel.activeModifiers
                            )
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.selectedIndex = idx
                                viewModel.executeCurrentSelection(modifiers: NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask))
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 378)
                .onChange(of: viewModel.selectedIndex) { _, newIdx in
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(newIdx, anchor: .center)
                    }
                }
            }

            Divider().opacity(0.45)

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

    var body: some View {
        HStack(spacing: 12) {
            FileOrSymbolIconView(path: item.path, fallbackSymbol: item.sfSymbolFallback ?? "folder.fill")
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)

                    if let badge = item.badge {
                        Text(badge)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(isSelected ? Color.white : Color.purple)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(
                                (isSelected ? Color.white.opacity(0.22) : Color.purple.opacity(0.13)),
                                in: Capsule()
                            )
                    }
                }

                Text(dynamicSubtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(isSelected ? Color.white.opacity(0.86) : Color.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if isSelected {
                HStack(spacing: 6) {
                    Text("⇥ Actions")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))

                    Text("↩")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7.5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color(red: 0.36, green: 0.16, blue: 0.62) : Color.clear)
        )
    }

    private var dynamicSubtitle: String {
        guard isSelected, item.path != nil else { return item.subtitle }
        if activeModifiers.contains(.command) {
            return "⌘↩ Mở vị trí trực tiếp trong Finder"
        }
        if activeModifiers.contains(.option) {
            return "⌥↩ Sao chép liên kết chia sẻ Google Drive vào Clipboard"
        }
        if activeModifiers.contains(.control) {
            return "⌃↩ Mở trực tiếp trên trình duyệt Google Drive Web"
        }
        if activeModifiers.contains(.shift) {
            return "⇧↩ Mở bảng Universal Actions (Convert to Markdown / AI / PDF...)"
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
        HStack(spacing: 11) {
            Label("↩ Duyệt/Mở", systemImage: "return")
            Label("⇥ Actions & MD", systemImage: "arrow.right.to.line")
            Label("⌘↩ Finder", systemImage: "folder")
            Label("⌥↩ Link GDrive", systemImage: "link")
            Spacer()

            if folderCount > 0 {
                Text("\(folderCount.formatted()) mục")
                    .foregroundStyle(.tertiary)
            }

            if let ver = updater.availableVersion {
                Button {
                    LauncherPanelController.shared.hide()
                    updater.installAvailableUpdate()
                } label: {
                    Label("Cập nhật v\(ver)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.green, in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Tự động tải và cập nhật phiên bản mới từ GitHub")
            }

            Button {
                settings.showDockIcon.toggle()
            } label: {
                Label(
                    settings.showDockIcon ? "Ẩn Dock" : "Hiện Dock",
                    systemImage: settings.showDockIcon ? "menubar.rectangle" : "dock.arrow.up.rectangle"
                )
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.purple)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Color.purple.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .help(settings.showDockIcon ? "Ẩn biểu tượng DriveBar khỏi thanh Dock" : "Hiện biểu tượng DriveBar trên thanh Dock")

            Button {
                LauncherPanelController.shared.hide()
                AppDelegate.shared?.openSettingsWindow()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(3)
            }
            .buttonStyle(.plain)
            .help("Mở Cài đặt & Kiểm tra cập nhật tự động")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }
}

// MARK: - File Buffer Strip

private struct FileBufferStripView: View {
    @ObservedObject var bufferService: FileBufferService
    @ObservedObject var viewModel: LauncherViewModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tray.full.fill")
                .foregroundStyle(.purple)
                .font(.system(size: 12, weight: .semibold))

            Text("Buffer (\(bufferService.items.count)):")
                .font(.system(size: 11.5, weight: .semibold))

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
                        .padding(.vertical, 3)
                        .background(Color.purple.opacity(0.13), in: Capsule())
                    }
                }
            }

            Spacer()

            Button("Actions (⌥→)") {
                viewModel.openUniversalActions(
                    for: .files(bufferService.items, sourceNote: "File Buffer"),
                    directExternalTrigger: false
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .controlSize(.mini)

            Button("Xóa (⌥⌫)") {
                bufferService.clear()
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.purple.opacity(0.06))
    }
}

// MARK: - Open With & Destination Folder Pickers

private struct OpenWithPickerView: View {
    @ObservedObject var viewModel: LauncherViewModel
    let fileURL: URL
    let previousTarget: ActionTarget

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button {
                    viewModel.openUniversalActions(for: previousTarget, directExternalTrigger: viewModel.openedDirectlyInUniversalActions)
                } label: {
                    Label("Quay lại", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Text("Mở '\(fileURL.lastPathComponent)' bằng ứng dụng:")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Text("Esc để quay lại")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(viewModel.openWithApps.enumerated()), id: \.element.url.path) { idx, app in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                .resizable()
                                .frame(width: 26, height: 26)
                            Text(app.name)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(idx == viewModel.selectedIndex ? .white : .primary)
                            Spacer()
                            if idx < 9 {
                                Text("⌘\(idx + 1)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(idx == viewModel.selectedIndex ? .white.opacity(0.8) : .secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(idx == viewModel.selectedIndex ? Color(red: 0.36, green: 0.16, blue: 0.62) : Color.clear)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.executeAtIndex(idx, modifiers: [])
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 360)
        }
    }
}

private struct DestinationFolderPickerView: View {
    @ObservedObject var viewModel: LauncherViewModel
    let operation: FileTransferOperation
    let sources: [URL]
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.gearshape")
                    .font(.system(size: 18))
                    .foregroundStyle(.purple)
                TextField("\(operation.rawValue) Gõ tên thư mục Google Drive đích...", text: $viewModel.destinationSearchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFocused)
                Text("\(sources.count) mục")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.14), in: Capsule())
            }
            .padding(14)
            .onAppear { isFocused = true }

            Divider()

            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(Array(viewModel.destinationFolders.enumerated()), id: \.element.id) { idx, folder in
                        SearchResultRowView(
                            item: folder,
                            index: idx,
                            isSelected: idx == viewModel.selectedIndex,
                            activeModifiers: []
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.executeAtIndex(idx, modifiers: [])
                        }
                    }
                }
                .padding(10)
            }
            .frame(maxHeight: 360)
        }
    }
}

// MARK: - Shared Visual Helpers

struct FileOrSymbolIconView: View {
    let path: String?
    let fallbackSymbol: String

    var body: some View {
        if let path {
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
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.purple)
            }
        } else {
            Image(systemName: fallbackSymbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Color.purple)
        }
    }

    private static func fastCloudIcon(for path: String, fallbackSymbol: String) -> NSImage {
        if fallbackSymbol.contains("folder") || fallbackSymbol.contains("externaldrive") {
            return NSWorkspace.shared.icon(for: .folder)
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
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
