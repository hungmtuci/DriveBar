import SwiftUI
import AppKit

struct WindowSwitcherOverlayView: View {
    @ObservedObject var controller: WindowSwitcherController
    @ObservedObject var service: WindowSwitcherService
    @ObservedObject var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Transparent click-outside backdrop to cancel & dismiss cleanly
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture {
                        controller.dismissWithoutActivating(restorePreviousApp: true)
                    }

                VStack(spacing: 14) {
                    Spacer(minLength: 20)

                    // 1. Upper Center: Large High-Resolution Magnified Window Content Preview
                    if settings.windowSwitcherShowZoomPreview, let selected = service.selectedItem {
                        ZoomedWindowPreviewCard(
                            item: selected,
                            previewImage: (service.zoomedPreviewWindowID == selected.windowID ? service.zoomedPreviewImage : nil)
                                ?? selected.windowID.flatMap { service.thumbnails[$0] },
                            hasScreenRecordingPermission: service.hasScreenRecordingPermission,
                            maxWidth: min(geo.size.width * 0.64, 920),
                            maxHeight: min(geo.size.height * 0.47, 465),
                            onActivate: {
                                controller.commitSelectionAndDismiss()
                            },
                            onCloseWindow: {
                                controller.pinOpenFromInteraction()
                                service.closeSelectedWindow()
                            },
                            onToggleMinimize: {
                                controller.pinOpenFromInteraction()
                                service.toggleMinimizeSelectedWindow()
                            },
                            onRequestScreenRecording: {
                                controller.dismissWithoutActivating(restorePreviousApp: false)
                                service.promptScreenRecordingPermission()
                            }
                        )
                        .transition(.opacity)
                    }

                    // 2. Lower Center: Search Filter + Grouped Horizontal Window Thumbnail Strip
                    WindowThumbnailStripCard(
                        controller: controller,
                        service: service,
                        settings: settings,
                        maxStripWidth: min(geo.size.width - 52, 1280)
                    )

                    Spacer(minLength: 22)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - 1. Large Magnified Window Content Preview Card

private struct ZoomedWindowPreviewCard: View {
    let item: SwitchableWindowItem
    let previewImage: NSImage?
    let hasScreenRecordingPermission: Bool
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let onActivate: () -> Void
    let onCloseWindow: () -> Void
    let onToggleMinimize: () -> Void
    let onRequestScreenRecording: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Compact Finder/macOS Window Header with Desktop Name + Real Monitor Name
            HStack(spacing: 10) {
                Image(nsImage: item.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 22, height: 22)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.zoomedHeaderTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !item.zoomedHeaderSubtitle.isEmpty {
                        Text(item.zoomedHeaderSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                ForEach(item.statusBadges, id: \.self) { badge in
                    Text(badge)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                }

                if !item.isWindowlessApp {
                    HStack(spacing: 4) {
                        Button(action: onToggleMinimize) {
                            Image(systemName: item.isMinimized ? "arrow.up.left.and.arrow.down.right" : "minus")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(item.isMinimized ? "Khôi phục cửa sổ (⌘M)" : "Thu nhỏ cửa sổ xuống Dock (⌘M)")

                        Button(action: onCloseWindow) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Đóng cửa sổ này (⌘W)")
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            // Magnified Window Content Area
            ZStack {
                Color.primary.opacity(0.025)

                if let previewImage {
                    Image(nsImage: previewImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
                        .padding(12)
                } else {
                    VStack(spacing: 12) {
                        Image(nsImage: item.appIcon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 72, height: 72)
                            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)

                        Text(item.zoomedHeaderTitle)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        if !item.cardLocationSubtitle.isEmpty {
                            Text(item.cardLocationSubtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }

                        if !hasScreenRecordingPermission && !item.isWindowlessApp {
                            Button(action: onRequestScreenRecording) {
                                Text("Cấp quyền Ghi màn hình để xem ảnh chụp nội dung trực tiếp")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else if item.isMinimized {
                            Text("Cửa sổ đang thu nhỏ dưới thanh Dock • Nhấn Enter hoặc click để khôi phục ngay")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        } else if item.isWindowlessApp {
                            Text("Ứng dụng đang chạy nền chưa có cửa sổ mở • Nhấn Enter hoặc click để mở")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                onActivate()
            }
        }
        .frame(width: maxWidth, height: maxHeight)
        .background(
            ZStack {
                VisualEffectFrostView(material: .menu, blendingMode: .behindWindow)
                Color(nsColor: .windowBackgroundColor).opacity(0.74)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 22, y: 8)
    }
}

// MARK: - 2. Horizontal Frosted-Glass Window Thumbnail Strip + Live Keyword Filter Bar

private struct WindowThumbnailStripCard: View {
    @ObservedObject var controller: WindowSwitcherController
    @ObservedObject var service: WindowSwitcherService
    @ObservedObject var settings: AppSettings
    let maxStripWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            // Top Live Keyword Filter Bar (Auto-focused: type immediately or use ← → ↑ ↓ / Tab)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                NativeSearchInputField(
                    text: $service.filterQuery,
                    placeholder: "Gõ từ khóa lọc theo tên ứng dụng, tiêu đề cửa sổ, Desktop hoặc màn hình (hoặc dùng ← → / ⌘Tab)...",
                    fontSize: 13,
                    focusTrigger: service.focusSearchTrigger,
                    selectAllOnFocus: false,
                    interceptHorizontalArrows: true,
                    onMoveSelection: { delta in
                        controller.stepFromKeyboard(delta: delta)
                    },
                    onSubmit: { _ in
                        controller.commitSelectionAndDismiss()
                    },
                    onTab: {
                        let back = NSEvent.modifierFlags.contains(.shift)
                        controller.stepFromKeyboard(delta: back ? -1 : 1)
                    },
                    onEscape: {
                        controller.handleEscapeInSwitcher()
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 22)

                if !service.filterQuery.isEmpty {
                    Button {
                        service.filterQuery = ""
                        service.triggerSearchInputFocus()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Xóa từ khóa lọc (Esc)")
                }

                Text("\(service.items.count) cửa sổ")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Horizontal Window Cards (Same-App Windows Grouped Adjacent with Subtle Hairline Separators)
            if service.items.isEmpty {
                VStack(spacing: 8) {
                    Text(service.filterQuery.isEmpty
                         ? "Không có cửa sổ nào khớp bộ lọc hiện tại"
                         : "Không có cửa sổ hay ứng dụng nào khớp từ khóa '\(service.filterQuery)'")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if !service.filterQuery.isEmpty {
                            Button("Xóa từ khóa lọc") {
                                service.filterQuery = ""
                                service.triggerSearchInputFocus()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        if service.sessionSameAppPID != nil {
                            Button("Hiện tất cả ứng dụng") {
                                controller.pinOpenFromInteraction()
                                service.sessionSameAppPID = nil
                                service.rebuildFilteredItemsPreservingSelection()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        if settings.windowSwitcherScope != .allSpacesAndDisplays {
                            Button("Mở rộng sang Tất cả Desktop & Màn hình") {
                                controller.pinOpenFromInteraction()
                                settings.windowSwitcherScope = .allSpacesAndDisplays
                                service.rebuildFilteredItemsPreservingSelection()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Array(service.items.enumerated()), id: \.element.id) { idx, item in
                                if idx > 0 && service.items[idx - 1].pid != item.pid {
                                    Rectangle()
                                        .fill(Color(nsColor: .separatorColor).opacity(0.65))
                                        .frame(width: 1, height: 104)
                                        .padding(.horizontal, 2)
                                }

                                WindowThumbnailItemCard(
                                    item: item,
                                    thumbnail: item.windowID.flatMap { service.thumbnails[$0] },
                                    isSelected: idx == service.selectedIndex
                                )
                                .id(item.id)
                                .onHover { hovering in
                                    if hovering {
                                        controller.hoverItemAtIndex(idx)
                                    }
                                }
                                .onTapGesture {
                                    controller.selectAndActivateAtIndex(idx)
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: service.selectedItem?.id) { _, selectedID in
                        guard let selectedID else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(selectedID, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            // Subtle Single-Line Controls & Filter Toggles Footer
            HStack(spacing: 10) {
                FooterShortcutHint(key: "↩", label: "Mở cửa sổ")
                FooterShortcutHint(key: "← →", label: "Di chuyển")
                FooterShortcutHint(key: "⌘⇥", label: "Kế tiếp")
                FooterShortcutHint(key: "⌘Y", label: settings.windowSwitcherShowZoomPreview ? "Ẩn phóng to" : "Phóng to")
                FooterShortcutHint(key: "⌘W", label: "Đóng")
                FooterShortcutHint(key: "⌘M", label: "Minimize")
                FooterShortcutHint(key: "Esc", label: service.filterQuery.isEmpty ? "Đóng bảng" : "Xóa lọc")

                Spacer(minLength: 10)

                if !service.hasScreenRecordingPermission {
                    Button {
                        controller.dismissWithoutActivating(restorePreviousApp: false)
                        service.promptScreenRecordingPermission()
                    } label: {
                        filterTogglePill(title: "Bật ảnh chụp nội dung", isActive: true)
                    }
                    .buttonStyle(.plain)
                    .help("Cấp quyền Screen Recording để hiện ảnh chụp nội dung cửa sổ trực tiếp")
                }

                Button {
                    controller.pinOpenFromInteraction()
                    settings.windowSwitcherScope = settings.windowSwitcherScope.nextCycle()
                    service.rebuildFilteredItemsPreservingSelection()
                } label: {
                    filterTogglePill(
                        title: settings.windowSwitcherScope.shortBadgeTitle,
                        isActive: settings.windowSwitcherScope != .allSpacesAndDisplays
                    )
                }
                .buttonStyle(.plain)
                .help("⌘1: Đổi phạm vi hiển thị (Tất cả màn hình & Desktop / Màn hình này / Desktop này)")

                Button {
                    controller.pinOpenFromInteraction()
                    settings.windowSwitcherShowMinimized.toggle()
                    service.rebuildFilteredItemsPreservingSelection()
                } label: {
                    filterTogglePill(
                        title: settings.windowSwitcherShowMinimized ? "Minimize: Hiện" : "Minimize: Ẩn",
                        isActive: settings.windowSwitcherShowMinimized
                    )
                }
                .buttonStyle(.plain)
                .help("⌘2: Bật/tắt hiển thị các cửa sổ đang thu nhỏ dưới Dock")

                Button {
                    controller.pinOpenFromInteraction()
                    settings.windowSwitcherShowHiddenApps.toggle()
                    service.rebuildFilteredItemsPreservingSelection()
                } label: {
                    filterTogglePill(
                        title: settings.windowSwitcherShowHiddenApps ? "App ẩn: Hiện" : "App ẩn: Ẩn",
                        isActive: settings.windowSwitcherShowHiddenApps
                    )
                }
                .buttonStyle(.plain)
                .help("⌘3: Bật/tắt hiển thị cửa sổ của ứng dụng đang ẩn bằng ⌘H")

                Button {
                    controller.pinOpenFromInteraction()
                    controller.toggleSameAppFilterLive()
                } label: {
                    filterTogglePill(
                        title: "Cùng App",
                        isActive: service.sessionSameAppPID != nil
                    )
                }
                .buttonStyle(.plain)
                .help("⌘4: Chỉ lọc các cửa sổ thuộc cùng 1 ứng dụng")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7.5)
            .background(Color.primary.opacity(0.02))
        }
        .frame(maxWidth: maxStripWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            ZStack {
                VisualEffectFrostView(material: .menu, blendingMode: .behindWindow)
                Color(nsColor: .windowBackgroundColor).opacity(0.76)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.24), radius: 20, y: 8)
    }

    private func filterTogglePill(title: String, isActive: Bool) -> some View {
        Text(title)
            .font(.system(size: 10.5, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            .padding(.horizontal, 7.5)
            .padding(.vertical, 2.5)
            .background(
                (isActive ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05)),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(
                        isActive ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08),
                        lineWidth: 0.5
                    )
            )
            .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Individual Window Card in Horizontal Strip (Shows Window Title + Desktop Name + Real Monitor Name)

private struct WindowThumbnailItemCard: View {
    let item: SwitchableWindowItem
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            // Window Thumbnail Frame
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    )

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 7.5, style: .continuous))
                        .opacity((item.isMinimized || item.isAppHidden) ? 0.68 : 1.0)
                } else {
                    VStack(spacing: 5) {
                        Image(nsImage: item.appIcon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 38, height: 38)
                        Text(item.appName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity((item.isMinimized || item.isAppHidden) ? 0.65 : 1.0)
                }

                if let stateBadge = item.cardStateCornerBadge {
                    Text(stateBadge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(5)
                }
            }
            .frame(width: 180, height: 104)
            .shadow(color: .black.opacity(isSelected ? 0.14 : 0.07), radius: isSelected ? 6 : 3, y: 2)

            // App Icon + Window Title + Desktop & Monitor Name
            VStack(spacing: 2) {
                HStack(spacing: 5.5) {
                    Image(nsImage: item.appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 15, height: 15)

                    Text(item.cardLabel)
                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(width: 176)

                if !item.cardLocationSubtitle.isEmpty {
                    Text(item.cardLocationSubtitle)
                        .font(.system(size: 9.5, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 176)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.13) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isSelected ? Color(nsColor: .selectedContentBackgroundColor) : Color.clear,
                    lineWidth: 2
                )
        )
        .scaleEffect(isSelected ? 1.045 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.84), value: isSelected)
        .contentShape(Rectangle())
    }
}
