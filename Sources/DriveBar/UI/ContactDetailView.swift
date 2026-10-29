import SwiftUI
import AppKit

struct ContactAvatarView: View {
    let contactID: String
    let initials: String
    let size: CGFloat
    var isRowSelected: Bool = false

    var body: some View {
        if let nsImg = ContactsSearchService.shared.cachedAvatarImage(for: contactID) {
            Image(nsImage: nsImg)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(
                            isRowSelected ? Color.white.opacity(0.35) : Color.primary.opacity(0.10),
                            lineWidth: 0.75
                        )
                )
        } else {
            ZStack {
                Circle()
                    .fill(isRowSelected ? Color.white.opacity(0.20) : Color.primary.opacity(0.08))
                Text(initials)
                    .font(.system(size: max(10, round(size * 0.38)), weight: .semibold, design: .rounded))
                    .foregroundStyle(isRowSelected ? Color.white : Color.secondary)
            }
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .strokeBorder(
                        isRowSelected ? Color.white.opacity(0.28) : Color.primary.opacity(0.10),
                        lineWidth: 0.75
                    )
            )
        }
    }
}

struct ContactDetailView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject private var contactsService = ContactsSearchService.shared
    let contactID: String

    var body: some View {
        let record = contactsService.contact(withID: contactID)
        let fields = viewModel.filteredContactDetailFields

        VStack(spacing: 0) {
            // 1. Contact Header Bar
            HStack(spacing: 12) {
                Button {
                    viewModel.returnFromContactDetail()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Danh bạ")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Quay lại danh sách tìm kiếm Danh bạ (Esc hoặc ←)")

                ContactAvatarView(
                    contactID: contactID,
                    initials: record?.initials ?? "?",
                    size: 42,
                    isRowSelected: false
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(record?.displayName ?? "Chi tiết liên hệ")
                        .font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let roleLine = record?.roleAndOrgLine, !roleLine.isEmpty {
                        Text(roleLine)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("Chọn mục bất kỳ bên dưới và nhấn Enter (↩) hoặc Click để sao chép")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                if let summaryField = record?.fields.first(where: { $0.id == "summary:all" }) {
                    Button {
                        contactsService.copyField(
                            summaryField,
                            contactName: record?.displayName ?? "",
                            closeLauncher: true,
                            autoPaste: false,
                            previousApp: LauncherPanelController.shared.previousFrontApp
                        )
                    } label: {
                        Label("Copy tất cả", systemImage: "doc.on.doc")
                            .font(.system(size: 11.5, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Sao chép toàn bộ thông tin liên hệ vào Clipboard")
                }

                Button {
                    contactsService.openInContactsApp(contactID: contactID)
                } label: {
                    Label("Mở Danh bạ", systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Mở trực tiếp liên hệ này trong ứng dụng Danh bạ macOS (⌘O)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            // 2. Quick Filter Input for Contact Fields
            HStack(spacing: 9) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)

                NativeSearchInputField(
                    text: $viewModel.contactDetailFilterText,
                    placeholder: "Dùng phím ↑↓ chọn mục rồi nhấn Enter để Copy (hoặc gõ lọc: 'sdt', 'email', 'dia chi')...",
                    fontSize: 13.5,
                    focusTrigger: viewModel.focusTrigger,
                    selectAllOnFocus: false,
                    onMoveSelection: { viewModel.moveSelection(delta: $0) },
                    onSubmit: { viewModel.executeCurrentSelection(modifiers: $0) },
                    onTab: { viewModel.handleTabKey() },
                    onEscape: { viewModel.handleEscapeKey() },
                    onBackspaceAtBoundary: { false }
                )
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 22)

                if !viewModel.contactDetailFilterText.isEmpty {
                    Button {
                        viewModel.contactDetailFilterText = ""
                        viewModel.triggerInputFocus(selectAll: false)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6.5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.75)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            Divider()

            // 3. Selectable & Copyable Contact Fields List
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 3) {
                        if fields.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundStyle(.secondary)
                                Text("Không có trường thông tin nào khớp '\(viewModel.contactDetailFilterText)'")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(18)
                        } else {
                            ForEach(Array(fields.enumerated()), id: \.offset) { idx, field in
                                ContactDetailFieldRow(
                                    field: field,
                                    index: idx,
                                    isSelected: idx == viewModel.selectedIndex,
                                    justCopied: contactsService.lastCopiedFieldID == field.id,
                                    activeModifiers: viewModel.activeModifiers,
                                    onCopyAndClose: {
                                        let mods = NSEvent.modifierFlags.cleanShortcutModifiers
                                        viewModel.executeAtIndex(idx, modifiers: mods)
                                    },
                                    onCopyKeepOpen: {
                                        viewModel.selectedIndex = idx
                                        contactsService.copyField(
                                            field,
                                            contactName: record?.displayName ?? "",
                                            closeLauncher: false,
                                            autoPaste: false,
                                            previousApp: LauncherPanelController.shared.previousFrontApp
                                        )
                                    },
                                    onPerformActionURL: {
                                        if let url = field.actionURL {
                                            LauncherPanelController.shared.hide()
                                            _ = NSWorkspace.shared.open(url)
                                        }
                                    }
                                )
                                .id(idx)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .onChange(of: viewModel.selectedIndex) { _, newIdx in
                    proxy.scrollTo(newIdx)
                }
            }

            Divider()

            // 4. Footer Keyboard Hints
            HStack(spacing: 12) {
                FooterShortcutHint(key: "↩", label: "Sao chép")
                FooterShortcutHint(key: "⌘C", label: "Copy & Giữ mở")
                FooterShortcutHint(key: "⌥↩", label: "Copy & Dán ngay")
                FooterShortcutHint(key: "⇧", label: "Phóng to chữ")
                FooterShortcutHint(key: "⌘O", label: "Mở Danh bạ")
                Spacer()
                FooterShortcutHint(key: "← / Esc", label: "Quay lại")
            }
            .font(.system(size: 10.5, weight: .regular))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7.5)
            .background(Color.primary.opacity(0.02))
        }
    }
}

private struct ContactDetailFieldRow: View {
    let field: ContactDetailField
    let index: Int
    let isSelected: Bool
    let justCopied: Bool
    let activeModifiers: NSEvent.ModifierFlags
    let onCopyAndClose: () -> Void
    let onCopyKeepOpen: () -> Void
    let onPerformActionURL: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.055))
                Image(systemName: field.sfSymbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(field.categoryLabel)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.84) : Color.secondary)

                    if justCopied {
                        Text("✓ Đã sao chép")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                (isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08)),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                            )
                    }
                }

                Text(field.displayValue)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if isSelected {
                HStack(spacing: 6) {
                    if let hint = field.actionHint, field.actionURL != nil {
                        Button {
                            onPerformActionURL()
                        } label: {
                            Text(hint)
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        onCopyAndClose()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10.5, weight: .medium))
                            Text(primaryActionLabel)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Color.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        onCopyKeepOpen()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                    .help("Sao chép nhanh mục này (giữ cửa sổ mở)")

                    if index < 9 {
                        Text("⌘\(index + 1)")
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7.5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onCopyAndClose()
        }
    }

    private var primaryActionLabel: String {
        if activeModifiers.contains(.option) {
            return "Copy & Dán ⌥↩"
        }
        if activeModifiers.contains(.command), field.actionURL != nil {
            return "Mở ⌘↩"
        }
        return "Sao chép ↩"
    }
}
