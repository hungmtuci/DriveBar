import SwiftUI
import AppKit

struct ScratchpadView: View {
    @ObservedObject var service = ScratchpadService.shared
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 10) {
                Image(systemName: "note.text")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text(L("Ghi chú nháp (Scratchpad)", "Scratchpad Notes"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                // Word / Char count badge
                HStack(spacing: 4) {
                    Text("\(service.wordCount) " + L("từ", "words"))
                    Text("•")
                        .foregroundStyle(.secondary.opacity(0.6))
                    Text("\(service.charCount) " + L("ký tự", "chars"))
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5, style: .continuous))

                // Actions
                Button {
                    service.togglePin()
                } label: {
                    Image(systemName: service.isPinnedOnTop ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(service.isPinnedOnTop ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(service.isPinnedOnTop ? L("Bỏ ghim trên cùng", "Unpin from top") : L("Ghim cửa sổ trên cùng", "Pin window on top"))

                Button {
                    service.copyAll()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Sao chép toàn bộ (⌘C)", "Copy all (⌘C)"))

                Button {
                    service.exportToFile()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Lưu ra tệp .md (⌘S)", "Export to .md file (⌘S)"))

                Button {
                    service.clear()
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Xóa sạch ghi chú", "Clear all notes"))

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("Đóng (Esc)", "Close (Esc)"))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.03))

            Divider()

            // Editor
            TextEditor(text: $service.text)
                .font(.system(size: 13, weight: .regular, design: .default))
                .lineSpacing(4)
                .padding(10)
                .scrollContentBackground(.hidden)
                .background(Color.clear)

            Divider()

            // Footer bar
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                    Text(L("Tự động lưu", "Auto-saved"))
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                }

                Text(service.filePathString)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                HStack(spacing: 8) {
                    ScratchpadFooterHint(key: "Esc", label: L("Đóng", "Close"))
                    ScratchpadFooterHint(key: "⌘C", label: L("Copy", "Copy"))
                    ScratchpadFooterHint(key: "⌘S", label: L("Xuất tệp", "Export"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.02))
        }
        .frame(minWidth: 440, minHeight: 320)
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow))
    }
}

private struct ScratchpadFooterHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            Text(label)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
