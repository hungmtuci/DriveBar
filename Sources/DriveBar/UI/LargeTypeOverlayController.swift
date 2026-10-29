import SwiftUI
import AppKit

@MainActor
final class LargeTypeOverlayController {
    static let shared = LargeTypeOverlayController()

    private var window: NSPanel?
    private var localKeyMonitor: Any?

    private init() {}

    func show(text: String) {
        dismiss()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let width = min(max(frame.width * 0.78, 560), 1280)
        let height = min(max(frame.height * 0.45, 240), 580)
        let rect = NSRect(
            x: frame.midX - width / 2,
            y: frame.midY - height / 2,
            width: width,
            height: height
        )

        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: LargeTypeBannerView(text: text) { [weak self] in
                self?.dismiss()
            }
        )
        self.window = panel
        panel.makeKeyAndOrderFront(nil)

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            self?.dismiss()
            return event.type == .keyDown ? nil : event
        }
    }

    func dismiss() {
        if let mon = localKeyMonitor {
            NSEvent.removeMonitor(mon)
            localKeyMonitor = nil
        }
        window?.orderOut(nil)
        window = nil
    }
}

private struct LargeTypeBannerView: View {
    let text: String
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(text)
                .font(.system(size: text.count > 80 ? 38 : 58, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.35)
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.black.opacity(0.86))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5)
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onClose()
                }

            Text("Nhấn phím bất kỳ hoặc Click để đóng")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(16)
        }
    }
}
