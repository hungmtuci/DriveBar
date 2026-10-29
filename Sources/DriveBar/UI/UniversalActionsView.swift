import SwiftUI
import AppKit

/// Universal Actions Split-Pane View modeled directly on Alfred's Universal Actions (Screenshot 2),
/// prioritizing `Convert to Markdown`, `Convert for AI`, `Convert to PDF`, and live document preview.
struct UniversalActionsView: View {
    @ObservedObject var viewModel: LauncherViewModel
    let target: ActionTarget
    @FocusState private var isFilterFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // 1. Target Item Header (Matches Screenshot 2 top bar!)
            HStack(spacing: 14) {
                targetLeadingIcon
                    .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text(target.primaryTitle)
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(target.primarySubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            // 2. Filter Input Bar (e.g. typing "con" or "md" just like Screenshot 2!)
            HStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.42, green: 0.18, blue: 0.72))

                TextField("Gõ lọc nhanh hành động (vd: 'md', 'con', 'ai', 'pdf', 'hide', 'open')...", text: $viewModel.actionFilterText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($isFilterFocused)

                if !viewModel.actionFilterText.isEmpty {
                    Button {
                        viewModel.actionFilterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
            .onAppear {
                isFilterFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .driveBarFocusInput)) { _ in
                isFilterFocused = true
            }

            Divider().opacity(0.45)

            // 3. Split-Pane Content: Left Actions List + Right Live Document Preview Card
            HStack(spacing: 0) {
                // Left Column: Action List
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            if viewModel.filteredActions.isEmpty {
                                VStack(spacing: 8) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 24))
                                        .foregroundStyle(.secondary)
                                    Text("Không có Universal Action khớp '\(viewModel.actionFilterText)'")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                            } else {
                                ForEach(Array(viewModel.filteredActions.enumerated()), id: \.element.id) { idx, action in
                                    UniversalActionRowView(
                                        action: action,
                                        index: idx,
                                        isSelected: idx == viewModel.selectedIndex,
                                        isLatchedFavorite: SyncAndLatchingService.shared.isFrequentlyUsed(actionID: action.id, target: target)
                                    )
                                    .id(idx)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        viewModel.executeAtIndex(
                                            idx,
                                            modifiers: NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
                                        )
                                    }
                                }
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: viewModel.selectedIndex) { _, newIdx in
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: 340)

                Divider().opacity(0.45)

                // Right Column: Live Document Preview & AI Conversion Inspector Card
                UniversalActionRightPreviewPane(viewModel: viewModel, target: target)
                    .frame(width: 265)
            }

            Divider().opacity(0.45)

            // 4. Bottom Action Hints
            HStack(spacing: 14) {
                Label("↩ Thực hiện", systemImage: "return")
                Label("⌥↩ Convert MD (Chỉ Copy Clipboard)", systemImage: "doc.on.clipboard")
                Label("⌘Y Quick Look", systemImage: "eye")
                Spacer()
                Text("⎋ Esc quay lại")
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.03))
        }
    }

    @ViewBuilder
    private var targetLeadingIcon: some View {
        switch target {
        case .files(let urls, _):
            if let first = urls.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first.path))
                    .resizable()
                    .interpolation(.high)
            } else {
                Image(systemName: "doc.fill")
                    .font(.system(size: 28))
            }
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.purple)
        case .url:
            Image(systemName: "globe")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.blue)
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
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.purple.opacity(0.10))
                    .frame(width: 26, height: 26)

                Image(systemName: action.sfSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : (action.category == .aiConvert ? Color.purple : Color.primary))
            }

            VStack(alignment: .leading, spacing: 1.5) {
                HStack(spacing: 6) {
                    Text(action.title)
                        .font(.system(size: 13.5, weight: action.category == .aiConvert ? .bold : .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)

                    if action.id == "ai.convert_md" || action.id == "ai.url_to_md" {
                        Text("AI Ready")
                            .font(.system(size: 9.5, weight: .bold))
                            .foregroundStyle(isSelected ? Color.white : Color.purple)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((isSelected ? Color.white.opacity(0.24) : Color.purple.opacity(0.14)), in: Capsule())
                    } else if isLatchedFavorite {
                        Text("★ Hay dùng")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : Color.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background((isSelected ? Color.white.opacity(0.22) : Color.orange.opacity(0.14)), in: Capsule())
                    }
                }

                if isSelected {
                    Text(action.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isSelected {
                Text("↩")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            } else if index < 9 {
                Text("⌘\(index + 1)")
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 0.36, green: 0.16, blue: 0.62).opacity(0.85))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, isSelected ? 7.5 : 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color(red: 0.35, green: 0.14, blue: 0.58) : Color.clear)
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
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(0.92))
                            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)

                        Image(nsImage: img)
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .frame(height: 195)
                    .padding(.top, 12)
                    .padding(.horizontal, 14)
                }

                VStack(alignment: .leading, spacing: 5) {
                    if !viewModel.previewFileSizeText.isEmpty {
                        HStack {
                            Text("Dung lượng:")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(viewModel.previewFileSizeText)
                                .fontWeight(.medium)
                        }
                    }
                    if !viewModel.previewModifiedText.isEmpty {
                        HStack {
                            Text("Cập nhật:")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(viewModel.previewModifiedText)
                                .fontWeight(.medium)
                        }
                    }
                    if !viewModel.previewRouteHint.isEmpty {
                        Divider().padding(.vertical, 2)
                        Text("Luồng tối ưu AI:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.purple)
                        Text(viewModel.previewRouteHint)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
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
                            Label("Sang .MD", systemImage: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
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
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                .padding(12)

            case .url(let u, _):
                VStack(spacing: 10) {
                    Image(systemName: "globe.desk.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(.purple)
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
                            Label("Copy Markdown", systemImage: "sparkles")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.small)
                    }
                }
                .padding(16)
                .frame(maxHeight: .infinity)
            }
        }
        .background(Color.primary.opacity(0.025))
    }
}
