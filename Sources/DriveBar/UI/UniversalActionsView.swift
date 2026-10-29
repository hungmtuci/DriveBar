import SwiftUI
import AppKit

/// Universal Actions Split-Pane View styled natively after macOS Spotlight & Finder Preview Pane,
/// prioritizing `Convert to Markdown`, `Convert for AI`, `Convert to PDF`, and live document preview.
struct UniversalActionsView: View {
    @ObservedObject var viewModel: LauncherViewModel
    let target: ActionTarget

    var body: some View {
        VStack(spacing: 0) {
            // 1. Target Item Header
            HStack(spacing: 12) {
                targetLeadingIcon
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(target.primaryTitle)
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(target.primarySubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                if !viewModel.openedDirectlyInUniversalActions {
                    Button {
                        viewModel.returnToSearchMode()
                    } label: {
                        Label("Tìm kiếm", systemImage: "chevron.left")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 13)
            .padding(.bottom, 9)

            // 2. Native macOS Recessed Filter Input Bar
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                NativeSearchInputField(
                    text: $viewModel.actionFilterText,
                    placeholder: "Lọc nhanh hành động (vd: 'md', 'copy', 'ai', 'pdf', 'open')...",
                    fontSize: 15,
                    focusTrigger: viewModel.focusTrigger,
                    selectAllOnFocus: false,
                    onMoveSelection: { viewModel.moveSelection(delta: $0) },
                    onSubmit: { viewModel.executeCurrentSelection(modifiers: $0) },
                    onTab: { viewModel.handleTabKey() },
                    onEscape: { viewModel.handleEscapeKey() }
                )
                .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 24)

                if !viewModel.actionFilterText.isEmpty {
                    Button {
                        viewModel.actionFilterText = ""
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

            // 3. Split-Pane Content: Left Actions List + Right Finder-style Preview Pane
            HStack(spacing: 0) {
                // Left Column: Action List
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 2) {
                            if viewModel.filteredActions.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 22))
                                        .foregroundStyle(.tertiary)
                                    Text("Không có hành động khớp '\(viewModel.actionFilterText)'")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                            } else {
                                ForEach(Array(viewModel.filteredActions.enumerated()), id: \.offset) { idx, action in
                                    UniversalActionRowView(
                                        action: action,
                                        index: idx,
                                        isSelected: idx == viewModel.selectedIndex,
                                        isLatchedFavorite: SyncAndLatchingService.shared.isFrequentlyUsed(actionID: action.id, target: target)
                                    )
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        viewModel.executeAtIndex(
                                            idx,
                                            modifiers: NSEvent.modifierFlags.cleanShortcutModifiers
                                        )
                                    }
                                    .id(idx)
                                }
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: viewModel.selectedIndex) { _, newIdx in
                        proxy.scrollTo(newIdx)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                // Right Column: Finder-style Inspector & Preview Pane
                UniversalActionRightPreviewPane(viewModel: viewModel, target: target)
                    .frame(width: 260)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // 4. Bottom Action Hints & Live Description
            HStack(spacing: 11) {
                if viewModel.selectedIndex >= 0 && viewModel.selectedIndex < viewModel.filteredActions.count {
                    Text(viewModel.filteredActions[viewModel.selectedIndex].subtitle)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                } else {
                    FooterShortcutHint(key: "↩", label: "Thực hiện")
                    FooterShortcutHint(key: "⌥↩", label: "Chỉ Copy Markdown")
                }
                Spacer(minLength: 8)
                Button {
                    LauncherPanelController.shared.hide()
                    HotKeyService.shared.openSettingsAndRecord(.universalAction)
                } label: {
                    Text("Finder: \(AppSettings.shared.universalActionHotKey.readableDisplay)")
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7.5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                }
                .buttonStyle(.plain)
                .fixedSize(horizontal: true, vertical: false)
                .help("Bấm để đổi phím tắt mở Universal Actions khi thao tác trên Finder (Mặc định: ⌘/)")

                FooterShortcutHint(key: "⇧", label: "Quick Look")
                FooterShortcutHint(key: "Esc", label: "Đóng")
            }
            .font(.system(size: 10.5, weight: .regular))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7.5)
            .background(Color.primary.opacity(0.02))
        }
    }

    @ViewBuilder
    private var targetLeadingIcon: some View {
        switch target {
        case .files(let urls, _):
            if let first = urls.first {
                let isDir = GoogleDriveIndexService.shared.isKnownDirectory(first.path, hasDirectoryHint: first.hasDirectoryPath)
                FileOrSymbolIconView(path: first.path, fallbackSymbol: isDir ? "folder.fill" : "doc.fill")
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.secondary)
            }
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
        case .url:
            Image(systemName: "globe")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

private struct UniversalActionRowView: View {
    let action: UniversalActionDefinition
    let index: Int
    let isSelected: Bool
    let isLatchedFavorite: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: action.sfSymbol)
                .font(.system(size: 13.5, weight: .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.75))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(action.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)

                    if action.id == "ai.convert_md" || action.id == "ai.url_to_md" {
                        Text("AI")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.92) : Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                (isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                    } else if isLatchedFavorite {
                        Text("Hay dùng")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.92) : Color.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                (isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.06)),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                    }
                }

                if isSelected {
                    Text(action.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isSelected {
                Text("↩")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isSelected ? 7 : 5.5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        )
    }
}

private struct UniversalActionRightPreviewPane: View {
    @ObservedObject var viewModel: LauncherViewModel
    let target: ActionTarget

    var body: some View {
        VStack(spacing: 10) {
            switch target {
            case .files(let urls, _):
                if let img = viewModel.previewImage {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                            )

                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .padding(14)
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                    }
                    .frame(height: 185)
                    .padding(.top, 12)
                    .padding(.horizontal, 14)
                }

                VStack(alignment: .leading, spacing: 5) {
                    if !viewModel.previewFileSizeText.isEmpty {
                        HStack {
                            Text("Dung lượng")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(viewModel.previewFileSizeText)
                                .foregroundStyle(.primary)
                        }
                    }
                    if !viewModel.previewCreatedText.isEmpty {
                        HStack {
                            Text("Ngày tạo")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(viewModel.previewCreatedText)
                                .foregroundStyle(.primary)
                        }
                    }
                    if !viewModel.previewModifiedText.isEmpty {
                        HStack {
                            Text("Cập nhật")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(viewModel.previewModifiedText)
                                .foregroundStyle(.primary)
                        }
                    }
                    if !viewModel.previewRouteHint.isEmpty {
                        Divider().padding(.vertical, 3)
                        Text("Chuyển đổi sang Markdown")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(viewModel.previewRouteHint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 14)

                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    Button {
                        QuickLookCoordinator.shared.toggleQuickLook(for: urls)
                    } label: {
                        Label("Quick Look", systemImage: "eye")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let mdDef = UniversalActionCatalog.all.first(where: { $0.id == "ai.convert_md" }),
                       mdDef.matches(target: target, isInsideGoogleDrive: false) {
                        Button {
                            UniversalActionExecutor.shared.execute(
                                action: mdDef,
                                target: target,
                                modifierFlags: [],
                                viewModel: viewModel
                            )
                        } label: {
                            Label("Sang .MD", systemImage: "doc.plaintext")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(.bottom, 12)

            case .text(let s, _):
                ScrollView {
                    Text(s)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(12)

            case .url(let u, _):
                VStack(spacing: 10) {
                    Image(systemName: "globe")
                        .font(.system(size: 34, weight: .regular))
                        .foregroundStyle(.secondary)
                    Text(u.host ?? "URL")
                        .font(.system(size: 13, weight: .semibold))
                    Text(u.absoluteString)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)

                    Divider().padding(.vertical, 2)
                    Text("Hỗ trợ lọc bài viết Web, Google Docs & GitHub sang Markdown sạch cho AI.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    if let urlDef = UniversalActionCatalog.all.first(where: { $0.id == "ai.url_to_md" }) {
                        Button {
                            UniversalActionExecutor.shared.execute(
                                action: urlDef,
                                target: target,
                                modifierFlags: [],
                                viewModel: viewModel
                            )
                        } label: {
                            Label("Copy Markdown", systemImage: "doc.on.clipboard")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                .padding(16)
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color.primary.opacity(0.015))
    }
}
