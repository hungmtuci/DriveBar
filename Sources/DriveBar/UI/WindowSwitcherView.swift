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
                        controller.dismissWithoutActivating()
                    }

                VStack(spacing: 16) {
                    Spacer(minLength: 24)

                    // 1. Upper Center: Large High-Resolution Magnified Window Content Preview
                    if settings.windowSwitcherShowZoomPreview, let selected = service.selectedItem {
                        ZoomedWindowPreviewCard(
                            item: selected,
                            previewImage: (service.zoomedPreviewWindowID == selected.windowID ? service.zoomedPreviewImage : nil)
                                ?? selected.windowID.flatMap { service.thumbnails[$0] },
                            hasScreenRecordingPermission: service.hasScreenRecordingPermission,
                            maxWidth: min(geo.size.width * 0.64, 920),
                            maxHeight: min(geo.size.height * 0.50, 490),
                            onActivate: {
                                controller.commitSelectionAndDismiss()
                            },
                            onCloseWindow: {
                                controller.isPinnedOpen = true
                                service.closeSelectedWindow()
                            },
                            onToggleMinimize: {
                                controller.isPinnedOpen = true
                                service.toggleMinimizeSelectedWindow()
                            },
                            onRequestScreenRecording: {
                                controller.dismissWithoutActivating()
                                service.promptScreenRecordingPermission()
                            }
                        )
                        .transition(.opacity)
                    }

                    // 2. Lower Center: Horizontal Frosted-Glass Window Thumbnail Strip (Matches Reference Screenshot)
                    WindowThumbnailStripCard(
                        controller: controller,
                        service: service,
                        settings: settings,
                        maxStripWidth: min(geo.size.width - 56, 1260)
                    )

                    Spacer(minLength: 28)
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
            // Compact Finder/macOS Window Header
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
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6.5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
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
                        .help(item.isMinimized ? "Khôi phục cửa sổ (M)" : "Thu nhỏ cửa sổ xuống Dock (M)")

                        Button(action: onCloseWindow) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Đóng cửa sổ này (W)")
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
                            .frame(width: 76, height: 76)
                            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)

                        Text(item.zoomedHeaderTitle)
                            .font(.system(size: 14.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        if !hasScreenRecordingPermission && !item.isWindowlessApp {
                            Button(action: onRequestScreenRecording) {
                                Text("Cấp quyền Ghi màn hình để xem ảnh chụp nội dung trực tiếp")
                                    .font(.system(size: 11.5, weight: .medium))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else if item.isMinimized {
                            Text("Cửa sổ đang thu nhỏ dưới thanh Dock • Nhấn chọn để khôi phục ngay")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        } else if item.isWindowlessApp {
                            Text("Ứng dụng đang chạy nền chưa có cửa sổ mở • Nhấn chọn để mở cửa sổ")
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
                Color(nsColor: .windowBackgroundColor).opacity(0.72)
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

// MARK: - 2. Horizontal Frosted-Glass Window Thumbnail Strip

private struct WindowThumbnailStripCard: View {
    @ObservedObject var controller: WindowSwitcherController
    @ObservedObject var service: WindowSwitcherService
    @ObservedObject var settings: AppSettings
    let maxStripWidth: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if service.items.isEmpty {
                VStack(spacing: 8) {
                    Text("Không có cửa sổ nào khớp bộ lọc hiện tại")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if service.sessionSameAppPID != nil {
                            Button("Hiện tất cả ứng dụng") {
                                controller.isPinnedOpen = true
                                service.sessionSameAppPID = nil
                                service.rebuildFilteredItemsPreservingSelection()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        if settings.windowSwitcherScope != .allSpacesAndDisplays {
                            Button("Mở rộng sang Tất cả Desktop & Màn hình") {
                                controller.isPinnedOpen = true
                                settings.windowSwitcherScope = .allSpacesAndDisplays
                                service.rebuildFilteredItemsPreservingSelection()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 26)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(Array(service.items.enumerated()), id: \.element.id) { idx, item in
                                WindowThumbnailItemCard(
                                    item: item,
                                    thumbnail: item.windowID.flatMap { service.thumbnails[$0] },
                                    isSelected: idx == service.selectedIndex
                                )
                                .id(idx)
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
                        .padding(.top, 16)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: service.selectedIndex) { _, newIdx in
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo(newIdx, anchor: .center)
                        }
                    }
                }
            }

            Divider()

            // Subtle Single-Line Controls & Filter Toggles Footer
            HStack(spacing: 10) {
                FooterShortcutHint(key: "⇥", label: "Kế tiếp")
                FooterShortcutHint(key: "← →", label: "Di chuyển")
                FooterShortcutHint(key: "Space", label: settings.windowSwitcherShowZoomPreview ? "Ẩn phóng to" : "Phóng to")
                FooterShortcutHint(key: "W", label: "Đóng")
                FooterShortcutHint(key: "M", label: "Minimize")
                FooterShortcutHint(key: "Esc", label: "Hủy")

                Spacer(minLength: 10)

                if !service.hasScreenRecordingPermission {
                    Button {
                        controller.dismissWithoutActivating()
                        service.promptScreenRecordingPermission()
                    } label: {
                        filterTogglePill(title: "Bật ảnh chụp nội dung", isActive: true)
                    }
                    .buttonStyle(.plain)
                    .help("Cấp quyền Screen Recording để hiện ảnh chụp nội dung cửa sổ trực tiếp")
                }

                Button {
                    controller.isPinnedOpen = true
                    settings.windowSwitcherScope = settings.windowSwitcherScope.nextCycle()
                    service.rebuildFilteredItemsPreservingSelection()
                } label: {
                    filterTogglePill(
                        title: settings.windowSwitcherScope.shortBadgeTitle,
                        isActive: settings.windowSwitcherScope != .allSpacesAndDisplays
                    )
                }
                .buttonStyle(.plain)
                .help("Phím 1: Đổi phạm vi hiển thị (Tất cả màn hình & Desktop / Màn hình này / Desktop này)")

                Button {
                    controller.isPinnedOpen = true
                    settings.windowSwitcherShowMinimized.toggle()
                    service.rebuildFilteredItemsPreservingSelection()
                } label: {
                    filterTogglePill(
                        title: settings.windowSwitcherShowMinimized ? "Minimize: Hiện" : "Minimize: Ẩn",
                        isActive: settings.windowSwitcherShowMinimized
                    )
                }
                .buttonStyle(.plain)
                .help("Phím 2: Bật/tắt hiển thị các cửa sổ đang thu nhỏ dưới Dock")

                Button {
                    controller.isPinnedOpen = true
                    settings.windowSwitcherShowHiddenApps.toggle()
                    service.rebuildFilteredItemsPreservingSelection()
                } label: {
                    filterTogglePill(
                        title: settings.windowSwitcherShowHiddenApps ? "App ẩn: Hiện" : "App ẩn: Ẩn",
                        isActive: settings.windowSwitcherShowHiddenApps
                    )
                }
                .buttonStyle(.plain)
                .help("Phím 3: Bật/tắt hiển thị cửa sổ của ứng dụng đang ẩn bằng ⌘H")

                Button {
                    controller.isPinnedOpen = true
                    controller.toggleSameAppFilterLive()
                } label: {
                    filterTogglePill(
                        title: "Cùng App",
                        isActive: service.sessionSameAppPID != nil
                    )
                }
                .buttonStyle(.plain)
                .help("Phím 4 / A: Chỉ lọc các cửa sổ thuộc cùng 1 ứng dụng")
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
                Color(nsColor: .windowBackgroundColor).opacity(0.74)
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

// MARK: - Individual Window Card in Horizontal Strip (Matches Screenshot Aesthetics)

private struct WindowThumbnailItemCard: View {
    let item: SwitchableWindowItem
    let thumbnail: NSImage?
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
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
                            .frame(width: 40, height: 40)
                        Text(item.appName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity((item.isMinimized || item.isAppHidden) ? 0.65 : 1.0)
                }

                // Compact Status Corner Pill (Minimized / Hidden / Other Space / Display)
                if let primaryBadge = item.statusBadges.first {
                    Text(primaryBadge)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(5)
                }
            }
            .frame(width: 172, height: 104)
            .shadow(color: .black.opacity(isSelected ? 0.14 : 0.07), radius: isSelected ? 6 : 3, y: 2)

            // App Icon + Window Title Label Below Card
            HStack(spacing: 6) {
                Image(nsImage: item.appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)

                Text(item.cardLabel)
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 168)
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
        .scaleEffect(isSelected ? 1.055 : 1.0)
        .animation(.spring(response: 0.20, dampingFraction: 0.82), value: isSelected)
        .contentShape(Rectangle())
    }
}
