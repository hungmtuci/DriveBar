import SwiftUI
import AppKit

@MainActor
final class FloatingToastController: ObservableObject {
    static let shared = FloatingToastController()

    @Published private(set) var title: String = ""
    @Published private(set) var subtitle: String = ""
    @Published private(set) var symbolName: String = "checkmark.circle.fill"
    @Published private(set) var isSpinning: Bool = false

    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func showProgress(title: String, subtitle: String) {
        dismissTask?.cancel()
        self.title = title
        self.subtitle = subtitle
        self.symbolName = "arrow.triangle.2.circlepath.circle.fill"
        self.isSpinning = true
        presentPanel()
    }

    func showSuccess(title: String, subtitle: String, symbol: String = "checkmark.circle.fill", duration: Double = 3.2) {
        dismissTask?.cancel()
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbol
        self.isSpinning = false
        presentPanel()
        NSSound(named: NSSound.Name("Glass"))?.play()
        scheduleDismiss(after: duration)
    }

    func showError(title: String, subtitle: String, duration: Double = 4.2) {
        dismissTask?.cancel()
        self.title = title
        self.subtitle = subtitle
        self.symbolName = "exclamationmark.triangle.fill"
        self.isSpinning = false
        presentPanel()
        NSSound.beep()
        scheduleDismiss(after: duration)
    }

    private func scheduleDismiss(after seconds: Double) {
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            panel?.orderOut(nil)
        }
    }

    private func presentPanel() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 68),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.isFloatingPanel = true
            p.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.contentView = NSHostingView(rootView: ToastBannerView(controller: self))
            panel = p
        }

        guard let panel, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - 230
        let y = frame.maxY - 86
        panel.setFrame(NSRect(x: x, y: y, width: 460, height: 68), display: true)
        panel.orderFrontRegardless()
    }
}

private struct ToastBannerView: View {
    @ObservedObject var controller: FloatingToastController

    var body: some View {
        HStack(spacing: 12) {
            if controller.isSpinning {
                ProgressView()
                    .controlSize(.regular)
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: controller.symbolName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(
                        controller.symbolName.contains("exclamationmark") ? Color.red : Color.green
                    )
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(controller.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(controller.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }
}
