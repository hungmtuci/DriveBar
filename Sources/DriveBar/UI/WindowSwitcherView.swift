import SwiftUI
import AppKit

struct WindowSwitcherLayoutSnapshot: Equatable {
    var previewCardFrame: CGRect = .zero
    var previewContentFrame: CGRect = .zero
    var stripCardFrame: CGRect = .zero
    var stripViewportFrame: CGRect = .zero
    var thumbnailFrames: [Int: CGRect] = [:]
    var selectedCloseButtonFrame: CGRect? = nil

    mutating func merge(_ other: WindowSwitcherLayoutSnapshot) {
        if other.previewCardFrame != .zero {
            previewCardFrame = other.previewCardFrame
        }
        if other.previewContentFrame != .zero {
            previewContentFrame = other.previewContentFrame
        }
        if other.stripCardFrame != .zero {
            stripCardFrame = other.stripCardFrame
        }
        if other.stripViewportFrame != .zero {
            stripViewportFrame = other.stripViewportFrame
        }
        if !other.thumbnailFrames.isEmpty {
            for (idx, rect) in other.thumbnailFrames where rect != .zero {
                thumbnailFrames[idx] = rect
            }
        }
        if let closeRect = other.selectedCloseButtonFrame, closeRect != .zero {
            selectedCloseButtonFrame = closeRect
        }
    }
}

struct WindowSwitcherLayoutPreferenceKey: PreferenceKey {
    static var defaultValue = WindowSwitcherLayoutSnapshot()
    static func reduce(value: inout WindowSwitcherLayoutSnapshot, nextValue: () -> WindowSwitcherLayoutSnapshot) {
        value.merge(nextValue())
    }
}

let windowSwitcherCoordinateSpaceName = "switcherSpace"

struct WindowSwitcherOverlayView: View {
    @ObservedObject var controller: WindowSwitcherController
    @ObservedObject var service: WindowSwitcherService
    @ObservedObject var settings: AppSettings

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Transparent click-outside backdrop to cancel & dismiss cleanly
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture {
                        controller.dismissWithoutActivating(restorePreviousApp: true)
                    }

                VStack(spacing: 14) {
                    Spacer(minLength: 20)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            controller.dismissWithoutActivating(restorePreviousApp: true)
                        }

                    // 1. Upper Center: Large High-Resolution Magnified Window Content Preview
                    if settings.windowSwitcherShowZoomPreview, let selected = service.selectedItem {
                        ZoomedWindowPreviewCard(
                            item: selected,
                            previewImage: (service.zoomedPreviewWindowID == selected.windowID ? service.zoomedPreviewImage : nil)
                                ?? selected.windowID.flatMap { service.thumbnails[$0] },
                            hasScreenRecordingPermission: service.hasScreenRecordingPermission,
                            hasAccessibilityPermission: service.hasAccessibilityPermission,
                            maxWidth: min(geo.size.width * 0.64, 920),
                            maxHeight: min(geo.size.height * 0.47, 465),
                            onActivate: {
                                controller.commitSelectionAndDismiss()
                            },
                            onSnapWindow: { placement in
                                controller.commitSnapSelectionAndDismiss(placement)
                            },
                            onCloseWindow: {
                                controller.triggerCloseSelectedWindow()
                            },
                            onQuitApp: { force in
                                controller.triggerQuitSelectedApp(force: force)
                            },
                            onToggleMinimize: {
                                controller.triggerMinimizeSelectedWindow()
                            },
                            onRequestScreenRecording: {
                                controller.dismissWithoutActivating(restorePreviousApp: false)
                                service.promptScreenRecordingPermission()
                            }
                        )
                        .background(
                            GeometryReader { previewGeo in
                                Color.clear.preference(
                                    key: WindowSwitcherLayoutPreferenceKey.self,
                                    value: WindowSwitcherLayoutSnapshot(
                                        previewCardFrame: previewGeo.frame(in: .named(windowSwitcherCoordinateSpaceName))
                                    )
                                )
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
                    .background(
                        GeometryReader { stripGeo in
                            Color.clear.preference(
                                key: WindowSwitcherLayoutPreferenceKey.self,
                                value: WindowSwitcherLayoutSnapshot(
                                    stripCardFrame: stripGeo.frame(in: .named(windowSwitcherCoordinateSpaceName))
                                )
                            )
                        }
                    )

                    Spacer(minLength: 22)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            controller.dismissWithoutActivating(restorePreviousApp: true)
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: windowSwitcherCoordinateSpaceName)
            .onPreferenceChange(WindowSwitcherLayoutPreferenceKey.self) { snapshot in
                controller.layoutSnapshot = snapshot
            }
        }
    }
}

// MARK: - 1. Large Magnified Window Content Preview Card

private struct ZoomedWindowPreviewCard: View {
    let item: SwitchableWindowItem
    let previewImage: NSImage?
    let hasScreenRecordingPermission: Bool
    let hasAccessibilityPermission: Bool
    let maxWidth: CGFloat
    let maxHeight: CGFloat
    let onActivate: () -> Void
    let onSnapWindow: (WindowSnapPlacement) -> Void
    let onCloseWindow: () -> Void
    let onQuitApp: (Bool) -> Void
    let onToggleMinimize: () -> Void
    let onRequestScreenRecording: () -> Void

    private var canQuitApp: Bool {
        item.pid != ProcessInfo.processInfo.processIdentifier && item.bundleIdentifier != "com.apple.finder"
    }

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

                HStack(spacing: 4) {
                    if !item.isWindowlessApp {
                        if !item.isFullscreen {
                            Button { onSnapWindow(.leftHalf) } label: {
                                Image(systemName: "rectangle.lefthalf.inset.filled")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help(L("Chia cửa sổ sang Nửa trái màn hình (⌃←)", "Snap window to Left Half (⌃←)"))

                            Button { onSnapWindow(.rightHalf) } label: {
                                Image(systemName: "rectangle.righthalf.inset.filled")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help(L("Chia cửa sổ sang Nửa phải màn hình (⌃→)", "Snap window to Right Half (⌃→)"))

                            Button { onSnapWindow(.maximize) } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right.rectangle")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .help(L("Phóng tối đa cửa sổ vừa khít màn hình (⌃↑)", "Maximize window to fit display (⌃↑)"))
                        }

                        Button(action: onToggleMinimize) {
                            Image(systemName: item.isMinimized ? "arrow.up.left.and.arrow.down.right" : "minus")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(item.isMinimized ? L("Khôi phục cửa sổ (⌘M)", "Restore window (⌘M)") : L("Thu nhỏ cửa sổ xuống Dock (⌘M)", "Minimize window to Dock (⌘M)"))

                        Button(action: onCloseWindow) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(hasAccessibilityPermission ? L("Đóng cửa sổ này (⌘W)", "Close this window (⌘W)") : L("Cấp quyền Trợ năng để đóng cửa sổ (⌘W)", "Grant Accessibility permission to close window (⌘W)"))
                    }

                    if canQuitApp {
                        Button {
                            let force = NSEvent.modifierFlags.contains(.option)
                            onQuitApp(force)
                        } label: {
                            Image(systemName: "power")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(L("Thoát ứng dụng \(item.appName) (⌘Q • Giữ ⌥ để buộc thoát ⌥⌘Q)", "Quit \(item.appName) (⌘Q • Hold ⌥ to force quit ⌥⌘Q)"))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)

            Divider()

            // Magnified Window Content Area
            Button(action: onActivate) {
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
                                    Text(L("Cấp quyền Ghi màn hình để xem ảnh chụp nội dung trực tiếp", "Grant Screen Recording permission to preview live window content"))
                                        .font(.system(size: 11.5, weight: .medium))
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            } else if item.isMinimized {
                                Text(L("Cửa sổ đang thu nhỏ dưới thanh Dock • Nhấn Enter hoặc click để khôi phục ngay", "Window minimized to Dock • Press Enter or click to restore"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            } else if item.isWindowlessApp {
                                Text(L("Ứng dụng đang chạy nền chưa có cửa sổ mở • Nhấn Enter hoặc click để mở", "App running with no open windows • Press Enter or click to activate"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                GeometryReader { contentGeo in
                    Color.clear.preference(
                        key: WindowSwitcherLayoutPreferenceKey.self,
                        value: WindowSwitcherLayoutSnapshot(
                            previewContentFrame: contentGeo.frame(in: .named(windowSwitcherCoordinateSpaceName))
                        )
                    )
                }
            )
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
                    placeholder: service.sessionSameAppPID != nil
                        ? L("Lọc trong \(service.sessionSameAppName ?? "ứng dụng đang chọn") (bấm ↓ hoặc ↑ để hiện lại tất cả ứng dụng)...", "Filter in \(service.sessionSameAppName ?? "selected app") (press ↓ or ↑ to show all apps)...")
                        : L("Gõ từ khóa lọc cửa sổ (← → di chuyển • ↑ cửa sổ cùng ứng dụng • ⌘ / Enter để mở)...", "Type to filter windows (← → move • ↑ same-app windows • ⌘ / Enter to open)..."),
                    fontSize: 13,
                    focusTrigger: service.focusSearchTrigger,
                    selectAllOnFocus: false,
                    autoFocusOnAppear: false,
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
                    },
                    onUpArrow: {
                        controller.handleUpArrowSameApp()
                        return true
                    },
                    onDownArrow: {
                        controller.handleDownArrowInSwitcher(isAutoRepeat: false)
                        return true
                    }
                )
                .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 22)

                if service.sessionSameAppPID != nil {
                    Button {
                        controller.pinOpenFromInteraction()
                        service.clearSameAppFilter()
                    } label: {
                        HStack(spacing: 5) {
                            if let icon = service.sessionSameAppIcon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: 14, height: 14)
                            }
                            Text(service.sessionSameAppName ?? L("Cùng ứng dụng", "Same App"))
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Image(systemName: "xmark")
                                .font(.system(size: 8.5, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Color.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.32), lineWidth: 0.5)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .help(L("Đang lọc các cửa sổ của \(service.sessionSameAppName ?? "ứng dụng này") • Bấm ↓, ↑ hoặc click để quay lại tất cả ứng dụng", "Filtering windows for \(service.sessionSameAppName ?? "this app") • Press ↓, ↑ or click to show all apps"))
                }

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
                    .help(L("Xóa từ khóa lọc (Esc)", "Clear filter query (Esc)"))
                }

                Text(L("\(service.items.count) cửa sổ", "\(service.items.count) windows"))
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
                         ? L("Không có cửa sổ nào khớp bộ lọc hiện tại", "No windows match current filter")
                         : L("Không có cửa sổ hay ứng dụng nào khớp từ khóa '\(service.filterQuery)'", "No windows or apps match '\(service.filterQuery)'"))
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if !service.filterQuery.isEmpty {
                            Button(L("Xóa từ khóa lọc", "Clear filter query")) {
                                service.filterQuery = ""
                                service.triggerSearchInputFocus()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        if service.sessionSameAppPID != nil {
                            Button(L("Hiện tất cả ứng dụng", "Show all apps")) {
                                controller.pinOpenFromInteraction()
                                service.clearSameAppFilter()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        if settings.windowSwitcherScope != .allSpacesAndDisplays {
                            Button(L("Mở rộng sang Tất cả Desktop & Màn hình", "Expand to All Desktops & Displays")) {
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

                                ZStack(alignment: .topLeading) {
                                    Button {
                                        controller.selectAndActivateAtIndex(idx)
                                    } label: {
                                        WindowThumbnailItemCard(
                                            item: item,
                                            thumbnail: item.windowID.flatMap { service.thumbnails[$0] },
                                            isSelected: idx == service.selectedIndex
                                        )
                                    }
                                    .buttonStyle(.plain)

                                    if idx == service.selectedIndex && !item.isWindowlessApp {
                                        Button {
                                            controller.triggerCloseWindowItem(item)
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 8.5, weight: .bold))
                                                .foregroundStyle(.secondary)
                                                .frame(width: 17, height: 17)
                                                .background(.regularMaterial, in: Circle())
                                                .overlay(
                                                    Circle()
                                                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                                                )
                                        }
                                        .buttonStyle(.plain)
                                        .background(
                                            GeometryReader { closeGeo in
                                                Color.clear.preference(
                                                    key: WindowSwitcherLayoutPreferenceKey.self,
                                                    value: WindowSwitcherLayoutSnapshot(
                                                        selectedCloseButtonFrame: closeGeo.frame(in: .named(windowSwitcherCoordinateSpaceName))
                                                    )
                                                )
                                            }
                                        )
                                        .padding(13)
                                        .help(L("Đóng cửa sổ này (⌘W)", "Close this window (⌘W)"))
                                    }
                                }
                                .background(
                                    GeometryReader { cardGeo in
                                        Color.clear.preference(
                                            key: WindowSwitcherLayoutPreferenceKey.self,
                                            value: WindowSwitcherLayoutSnapshot(
                                                thumbnailFrames: [idx: cardGeo.frame(in: .named(windowSwitcherCoordinateSpaceName))]
                                            )
                                        )
                                    }
                                )
                                .id(item.id)
                                .onHover { hovering in
                                    if hovering {
                                        controller.hoverItemAtIndex(idx)
                                    }
                                }
                                .contextMenu {
                                    Button(L("Mở cửa sổ này (↩ / ⌘)", "Open this window (↩ / ⌘)")) {
                                        controller.selectAndActivateAtIndex(idx)
                                    }
                                    if service.sessionSameAppPID == nil {
                                        Button(L("Hiện các cửa sổ của \(item.appName) (↑)", "Show windows for \(item.appName) (↑)")) {
                                            controller.pinOpenFromInteraction()
                                            service.focusSameAppWindows(for: item)
                                        }
                                    } else {
                                        Button(L("Hiện lại tất cả ứng dụng (↓)", "Show all apps (↓)")) {
                                            controller.pinOpenFromInteraction()
                                            service.clearSameAppFilter()
                                        }
                                    }
                                    if !item.isWindowlessApp {
                                        Divider()
                                        Button(L("Đóng cửa sổ (⌘W)", "Close window (⌘W)")) {
                                            controller.triggerCloseWindowItem(item)
                                        }
                                        Button(item.isMinimized ? L("Khôi phục cửa sổ (⌘M)", "Restore window (⌘M)") : L("Thu nhỏ xuống Dock (⌘M)", "Minimize to Dock (⌘M)")) {
                                            controller.triggerMinimizeWindowItem(item)
                                        }
                                    }
                                    if item.pid != ProcessInfo.processInfo.processIdentifier {
                                        Divider()
                                        Button(item.isAppHidden ? L("Hiện ứng dụng \(item.appName) (⌘H)", "Unhide \(item.appName) (⌘H)") : L("Ẩn ứng dụng \(item.appName) (⌘H)", "Hide \(item.appName) (⌘H)")) {
                                            controller.triggerHideAppForItem(item)
                                        }
                                        if item.bundleIdentifier != "com.apple.finder" {
                                            Button(L("Thoát \(item.appName) (⌘Q)", "Quit \(item.appName) (⌘Q)")) {
                                                controller.triggerQuitAppForItem(item, force: false)
                                            }
                                            Button(L("Buộc thoát \(item.appName) (⌥⌘Q)", "Force Quit \(item.appName) (⌥⌘Q)")) {
                                                controller.triggerQuitAppForItem(item, force: true)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 14)
                        .padding(.bottom, 12)
                    }
                    .background(
                        GeometryReader { viewportGeo in
                            Color.clear.preference(
                                key: WindowSwitcherLayoutPreferenceKey.self,
                                value: WindowSwitcherLayoutSnapshot(
                                    stripViewportFrame: viewportGeo.frame(in: .named(windowSwitcherCoordinateSpaceName))
                                )
                            )
                        }
                    )
                    .onChange(of: service.selectedItem?.id) { _, selectedID in
                        guard let selectedID else { return }
                        if service.isKeyboardNavigating {
                            withAnimation(.easeOut(duration: 0.12)) {
                                proxy.scrollTo(selectedID, anchor: .center)
                            }
                        }
                    }
                }
            }

            Divider()

            // Subtle Single-Line Controls & Filter Toggles Footer
            HStack(spacing: 8) {
                FooterShortcutHint(key: "↩ / ⌘ / ⌥ / Space", label: L("Mở", "Open"))
                FooterShortcutHint(key: "← →", label: L("Di chuyển", "Navigate"))
                FooterShortcutHint(
                    key: service.sessionSameAppPID == nil ? "↑" : "↓",
                    label: service.sessionSameAppPID == nil ? L("Cùng App", "Same App") : L("Tất cả App", "All Apps")
                )
                FooterShortcutHint(key: "⌃←→↑", label: L("Chia đôi", "Snap"))
                FooterShortcutHint(key: "⌘Y", label: settings.windowSwitcherShowZoomPreview ? L("Ẩn phóng to", "Hide preview") : L("Phóng to", "Zoom preview"))
                FooterShortcutHint(key: "⌘W", label: L("Đóng", "Close"))
                FooterShortcutHint(key: "⌘Q", label: L("Thoát", "Quit"))
                FooterShortcutHint(key: "⌘M", label: "Minimize")
                FooterShortcutHint(
                    key: "Esc",
                    label: !service.filterQuery.isEmpty
                        ? L("Xóa lọc", "Clear filter")
                        : (service.sessionSameAppPID != nil && !controller.openedDirectlyInSameAppMode ? L("Tất cả App", "All Apps") : L("Đóng", "Dismiss"))
                )

                Spacer(minLength: 8)

                if !service.hasAccessibilityPermission {
                    Button {
                        controller.dismissWithoutActivating(restorePreviousApp: false)
                        service.promptAccessibilityPermission()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9.5, weight: .semibold))
                            Text(L("Bật quyền Trợ năng (⌘W / ⌘⇥)", "Enable Accessibility (⌘W / ⌘⇥)"))
                                .font(.system(size: 10.5, weight: .semibold))
                                .lineLimit(1)
                        }
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2.5)
                        .background(
                            Color(nsColor: .systemOrange).opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color(nsColor: .systemOrange).opacity(0.42), lineWidth: 0.5)
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .help(L("Cấp quyền Trợ năng (Accessibility) để đóng cửa sổ bằng ⌘W, thu nhỏ bằng ⌘M và dùng phím tắt ⌘Tab", "Grant Accessibility permission to close windows with ⌘W, minimize with ⌘M and use ⌘Tab shortcut"))
                }

                if !service.hasScreenRecordingPermission {
                    Button {
                        controller.dismissWithoutActivating(restorePreviousApp: false)
                        service.promptScreenRecordingPermission()
                    } label: {
                        filterTogglePill(title: L("Bật ảnh chụp nội dung", "Enable Live Previews"), isActive: true)
                    }
                    .buttonStyle(.plain)
                    .help(L("Cấp quyền Screen Recording để hiện ảnh chụp nội dung cửa sổ trực tiếp", "Grant Screen Recording permission to show live window content previews"))
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
                .help(L("⌘1: Đổi phạm vi hiển thị (Tất cả màn hình & Desktop / Màn hình này / Desktop này)", "⌘1: Switch display scope (All Displays & Desktops / This Display / This Desktop)"))

                Button {
                    controller.pinOpenFromInteraction()
                    settings.windowSwitcherShowMinimized.toggle()
                    service.rebuildFilteredItemsPreservingSelection()
                } label: {
                    filterTogglePill(
                        title: settings.windowSwitcherShowMinimized ? L("Minimize: Hiện", "Minimize: Show") : L("Minimize: Ẩn", "Minimize: Hide"),
                        isActive: settings.windowSwitcherShowMinimized
                    )
                }
                .buttonStyle(.plain)
                .help(L("⌘2: Bật/tắt hiển thị các cửa sổ đang thu nhỏ dưới Dock", "⌘2: Toggle showing windows minimized to Dock"))

                Button {
                    controller.pinOpenFromInteraction()
                    settings.windowSwitcherShowHiddenApps.toggle()
                    service.rebuildFilteredItemsPreservingSelection()
                } label: {
                    filterTogglePill(
                        title: settings.windowSwitcherShowHiddenApps ? L("App ẩn: Hiện", "Hidden Apps: Show") : L("App ẩn: Ẩn", "Hidden Apps: Hide"),
                        isActive: settings.windowSwitcherShowHiddenApps
                    )
                }
                .buttonStyle(.plain)
                .help(L("⌘3: Bật/tắt hiển thị cửa sổ của ứng dụng đang ẩn bằng ⌘H", "⌘3: Toggle showing windows of apps hidden with ⌘H"))

                Button {
                    controller.pinOpenFromInteraction()
                    controller.toggleSameAppFilterLive()
                } label: {
                    filterTogglePill(
                        title: L("Cùng App", "Same App"),
                        isActive: service.sessionSameAppPID != nil
                    )
                }
                .buttonStyle(.plain)
                .help(L("⌘4: Chỉ lọc các cửa sổ thuộc cùng 1 ứng dụng", "⌘4: Filter windows belonging to the same app"))
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
