import SwiftUI
import AppKit

enum BatchRenameMode: String, CaseIterable {
    case directSingle = "Đổi tên mới"
    case replaceText = "Tìm & Thay thế"
    case prefixSuffix = "Tiền tố & Hậu tố"
    case sequential = "Đánh số (01, 02...)"
}

struct RenamePreviewRow: Identifiable, Equatable {
    var id: String { sourceURL.path }
    let sourceURL: URL
    let oldName: String
    let newName: String
    let isChanged: Bool
    let errorMessage: String?
}

@MainActor
final class BatchRenameState: ObservableObject {
    static let shared = BatchRenameState()

    @Published var urls: [URL] = []
    @Published var previousTarget: ActionTarget = .files([])
    @Published var mode: BatchRenameMode = .replaceText {
        didSet { recomputePreview() }
    }

    @Published var singleNewStem: String = "" {
        didSet { recomputePreview() }
    }
    @Published var findText: String = "" {
        didSet { recomputePreview() }
    }
    @Published var replaceWithText: String = "" {
        didSet { recomputePreview() }
    }
    @Published var prefixText: String = "" {
        didSet { recomputePreview() }
    }
    @Published var suffixText: String = "" {
        didSet { recomputePreview() }
    }
    @Published var sequenceBaseName: String = "" {
        didSet { recomputePreview() }
    }
    @Published var sequenceStartNumber: Int = 1 {
        didSet { recomputePreview() }
    }

    @Published private(set) var previewRows: [RenamePreviewRow] = []
    @Published private(set) var validChangeCount: Int = 0
    @Published private(set) var hasValidationError: Bool = false

    private init() {}

    var availableModes: [BatchRenameMode] {
        if urls.count == 1 {
            return [.directSingle, .replaceText, .prefixSuffix]
        }
        return [.replaceText, .prefixSuffix, .sequential]
    }

    func configure(for urls: [URL], previousTarget: ActionTarget) {
        self.urls = urls
        self.previousTarget = previousTarget
        self.findText = ""
        self.replaceWithText = ""
        self.prefixText = ""
        self.suffixText = ""
        self.sequenceStartNumber = 1

        if let first = urls.first {
            let isDir = GoogleDriveIndexService.shared.isKnownDirectory(first.path, hasDirectoryHint: first.hasDirectoryPath)
            let stem = isDir ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
            self.singleNewStem = stem
            self.sequenceBaseName = stem
        } else {
            self.singleNewStem = ""
            self.sequenceBaseName = "TaiLieu"
        }

        self.mode = (urls.count == 1) ? .directSingle : .replaceText
        recomputePreview()
    }

    func recomputePreview() {
        var rows: [RenamePreviewRow] = []
        rows.reserveCapacity(urls.count)
        var targetPathCounts: [String: Int] = [:]
        var proposedNames: [(url: URL, oldName: String, newName: String)] = []

        let padDigits = max(2, String(max(1, sequenceStartNumber + urls.count - 1)).count)

        for (idx, u) in urls.enumerated() {
            let oldName = u.lastPathComponent
            let isDir = GoogleDriveIndexService.shared.isKnownDirectory(u.path, hasDirectoryHint: u.hasDirectoryPath)
            let ext = isDir ? "" : u.pathExtension
            let stem = (isDir || ext.isEmpty) ? oldName : u.deletingPathExtension().lastPathComponent

            let newStem: String
            switch mode {
            case .directSingle:
                newStem = singleNewStem.trimmingCharacters(in: .whitespacesAndNewlines)

            case .replaceText:
                if findText.isEmpty {
                    newStem = stem
                } else {
                    newStem = stem.replacingOccurrences(of: findText, with: replaceWithText)
                }

            case .prefixSuffix:
                newStem = "\(prefixText)\(stem)\(suffixText)"

            case .sequential:
                let base = sequenceBaseName.trimmingCharacters(in: .whitespacesAndNewlines)
                let numStr = String(format: "%0\(padDigits)d", sequenceStartNumber + idx)
                newStem = base.isEmpty ? numStr : "\(base)_\(numStr)"
            }

            let cleanStem = newStem.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName: String
            if cleanStem.isEmpty {
                finalName = ""
            } else if ext.isEmpty {
                finalName = cleanStem
            } else {
                finalName = "\(cleanStem).\(ext)"
            }

            let targetPath = u.deletingLastPathComponent().appendingPathComponent(finalName).path.lowercased()
            if !finalName.isEmpty {
                targetPathCounts[targetPath, default: 0] += 1
            }
            proposedNames.append((u, oldName, finalName))
        }

        var changed = 0
        var anyError = false

        for item in proposedNames {
            let targetURL = item.url.deletingLastPathComponent().appendingPathComponent(item.newName)
            let lowerTarget = targetURL.path.lowercased()
            var err: String?

            if item.newName.isEmpty {
                err = "Tên mới không được để trống"
            } else if item.newName.contains("/") || item.newName.contains(":") {
                err = "Chứa ký tự không hợp lệ (/ hoặc :)"
            } else if (targetPathCounts[lowerTarget] ?? 0) > 1 {
                err = "Trùng tên đích trong danh sách"
            } else if item.newName != item.oldName &&
                      item.newName.lowercased() != item.oldName.lowercased() &&
                      FileManager.default.fileExists(atPath: targetURL.path) {
                err = "Tệp tên này đã tồn tại trong thư mục"
            }

            let didChange = (err == nil && item.newName != item.oldName)
            if didChange { changed += 1 }
            if err != nil { anyError = true }

            rows.append(RenamePreviewRow(
                sourceURL: item.url,
                oldName: item.oldName,
                newName: item.newName.isEmpty ? "(Trống)" : item.newName,
                isChanged: didChange,
                errorMessage: err
            ))
        }

        self.previewRows = rows
        self.validChangeCount = changed
        self.hasValidationError = anyError
    }

    func executeCommit(revealInFinder: Bool = false) {
        guard validChangeCount > 0 && !hasValidationError else {
            NSSound.beep()
            return
        }

        let operations = previewRows
            .filter { $0.isChanged && $0.errorMessage == nil }
            .map { (src: $0.sourceURL, dst: $0.sourceURL.deletingLastPathComponent().appendingPathComponent($0.newName)) }

        LauncherPanelController.shared.hide()

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var renamedURLs: [URL] = []
            var lastErr: String?

            // Two-phase safe rename if case-only or overlapping sequence names exist
            var tempPairs: [(tmp: URL, dst: URL)] = []
            for op in operations {
                let tmpName = ".drivebar_rename_\(UUID().uuidString.prefix(8))_\(op.dst.lastPathComponent)"
                let tmpURL = op.src.deletingLastPathComponent().appendingPathComponent(tmpName)
                do {
                    try fm.moveItem(at: op.src, to: tmpURL)
                    tempPairs.append((tmpURL, op.dst))
                } catch {
                    lastErr = error.localizedDescription
                }
            }

            for pair in tempPairs {
                do {
                    try fm.moveItem(at: pair.tmp, to: pair.dst)
                    renamedURLs.append(pair.dst)
                } catch {
                    lastErr = error.localizedDescription
                }
            }

            let finalCount = renamedURLs.count
            let finalURLs = renamedURLs
            let finalErr = lastErr
            await MainActor.run {
                if finalCount > 0 {
                    GoogleDriveIndexService.shared.rebuildAllCaches()
                    FloatingToastController.shared.showSuccess(
                        title: finalCount == 1
                            ? "Đã đổi tên thành '\(finalURLs[0].lastPathComponent)'"
                            : "Đã đổi tên hàng loạt \(finalCount) mục",
                        subtitle: finalURLs[0].deletingLastPathComponent().lastPathComponent,
                        symbol: "pencil"
                    )
                    if revealInFinder {
                        NSWorkspace.shared.activateFileViewerSelecting(finalURLs)
                    }
                } else {
                    FloatingToastController.shared.showError(
                        title: "Không thể đổi tên tệp",
                        subtitle: finalErr ?? "Kiểm tra quyền ghi thư mục"
                    )
                }
            }
        }
    }
}

struct BatchRenameView: View {
    @ObservedObject var viewModel: LauncherViewModel
    @ObservedObject var state: BatchRenameState = BatchRenameState.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Button {
                    viewModel.openUniversalActions(
                        for: state.previousTarget,
                        directExternalTrigger: viewModel.openedDirectlyInUniversalActions
                    )
                } label: {
                    Label("Quay lại", systemImage: "chevron.left")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                VStack(alignment: .leading, spacing: 1) {
                    Text(state.urls.count == 1 ? "Đổi tên mục đã chọn" : "Đổi tên hàng loạt (\(state.urls.count) mục)")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text("Xem trước kết quả trực tiếp trước khi áp dụng")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Picker("", selection: $state.mode) {
                    ForEach(state.availableModes, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 330)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)

            Divider()

            // Controls Area
            Group {
                switch state.mode {
                case .directSingle:
                    HStack(spacing: 10) {
                        Text("Tên mới:")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                        TextField("Nhập tên mới (giữ nguyên phần mở rộng)...", text: $state.singleNewStem)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 13))
                            .onSubmit {
                                state.executeCommit(revealInFinder: NSEvent.modifierFlags.contains(.command))
                            }
                    }

                case .replaceText:
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Text("Tìm:")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("Cụm từ cần thay...", text: $state.findText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5))
                        }
                        HStack(spacing: 6) {
                            Text("Thay bằng:")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("Nội dung mới (để trống nếu muốn xóa)...", text: $state.replaceWithText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5))
                                .onSubmit {
                                    state.executeCommit(revealInFinder: NSEvent.modifierFlags.contains(.command))
                                }
                        }
                    }

                case .prefixSuffix:
                    HStack(spacing: 10) {
                        HStack(spacing: 6) {
                            Text("Tiền tố (Đầu):")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("VD: 2026_...", text: $state.prefixText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5))
                        }
                        HStack(spacing: 6) {
                            Text("Hậu tố (Cuối):")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("VD: _Final...", text: $state.suffixText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5))
                                .onSubmit {
                                    state.executeCommit(revealInFinder: NSEvent.modifierFlags.contains(.command))
                                }
                        }
                    }

                case .sequential:
                    HStack(spacing: 12) {
                        HStack(spacing: 6) {
                            Text("Tên gốc:")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                            TextField("VD: BaiGiang...", text: $state.sequenceBaseName)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12.5))
                                .onSubmit {
                                    state.executeCommit(revealInFinder: NSEvent.modifierFlags.contains(.command))
                                }
                        }
                        Stepper(value: $state.sequenceStartNumber, in: 1...9999) {
                            Text("Bắt đầu từ: \(state.sequenceStartNumber)")
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.primary.opacity(0.02))

            Divider()

            // Live Before -> After Preview Table
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(state.previewRows) { row in
                        HStack(spacing: 10) {
                            FileOrSymbolIconView(
                                path: row.sourceURL.path,
                                fallbackSymbol: "doc",
                                isRowSelected: false
                            )
                            .frame(width: 20, height: 20)

                            Text(row.oldName)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(.tertiary)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.newName)
                                    .font(.system(size: 12.5, weight: row.isChanged ? .semibold : .regular))
                                    .foregroundStyle(
                                        row.errorMessage != nil
                                            ? Color.red
                                            : (row.isChanged ? Color.primary : Color.secondary)
                                    )
                                    .lineLimit(1)
                                    .truncationMode(.middle)

                                if let err = row.errorMessage {
                                    Text(err)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.red)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(row.isChanged ? Color.primary.opacity(0.04) : Color.clear)
                        )
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()

            // Footer with Apply Button
            HStack(spacing: 12) {
                FooterShortcutHint(key: "↩", label: "Áp dụng đổi tên")
                FooterShortcutHint(key: "⌘↩", label: "Áp dụng & Mở Finder")
                FooterShortcutHint(key: "Esc", label: "Hủy / Quay lại")

                Spacer()

                Text("\(state.validChangeCount)/\(state.urls.count) mục thay đổi")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Button {
                    state.executeCommit(revealInFinder: NSEvent.modifierFlags.contains(.command))
                } label: {
                    Text("Áp dụng đổi tên")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(state.validChangeCount == 0 || state.hasValidationError)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.02))
        }
    }
}
