import SwiftUI
import AppKit

struct MarkdownPreviewView: View {
    @ObservedObject var viewModel: LauncherViewModel
    let title: String
    let sourceURL: URL
    let savedMDURL: URL?
    let markdown: String
    let estimatedTokens: Int
    let engineUsed: String

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("AI Markdown Inspector — \(title)")
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)

                    HStack(spacing: 10) {
                        Text("Engine: \(engineUsed)")
                        Text("•")
                        Text("\(markdown.count.formatted()) ký tự")
                        Text("•")
                        Text("~\(estimatedTokens.formatted()) LLM tokens")
                            .fontWeight(.medium)
                            .foregroundStyle(.primary)
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if let savedMDURL {
                    Button {
                        LauncherPanelController.shared.hide()
                        NSWorkspace.shared.activateFileViewerSelecting([savedMDURL])
                    } label: {
                        Label("Hiện file .md", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(markdown, forType: .string)
                    LauncherPanelController.shared.hide()
                    FloatingToastController.shared.showSuccess(
                        title: "Đã sao chép Markdown vào Clipboard ✓",
                        subtitle: "Nhấn ⌘V trực tiếp vào Claude / ChatGPT / Gemini"
                    )
                } label: {
                    Label("Copy Markdown (↩)", systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(14)

            Divider()

            ScrollView {
                Text(markdown)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.03))

            Divider()

            HStack {
                Text("Mẹo: Văn bản đã được chuẩn hóa Unicode NFC Tiếng Việt & rút gọn dòng trống để tiết kiệm Token cho AI.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("⎋ Esc để quay lại")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
