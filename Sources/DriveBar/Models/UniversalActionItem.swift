import Foundation
import AppKit

enum ActionCategory: String, Codable, CaseIterable, Sendable {
    case aiConvert = "AI & Convert sang Markdown"
    case googleDrive = "Google Drive"
    case visibility = "Ẩn / Hiện File (chflags)"
    case fileSystem = "Thao tác File & Thư mục"
    case clipboard = "Clipboard & Đường dẫn"
    case textAndURL = "Văn bản & Liên kết Web"
}

enum ActionTarget: Equatable {
    case files([URL], sourceNote: String? = nil)
    case text(String, sourceNote: String? = nil)
    case url(URL, sourceNote: String? = nil)

    var primaryTitle: String {
        switch self {
        case .files(let urls, _):
            guard let first = urls.first else { return "Không có mục nào" }
            if urls.count == 1 {
                return first.lastPathComponent
            }
            return "\(urls.count) mục đã chọn (\(first.lastPathComponent)...)"
        case .text(let str, _):
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            return trimmed.count > 64 ? String(trimmed.prefix(64)) + "…" : trimmed
        case .url(let u, _):
            return u.absoluteString
        }
    }

    var primarySubtitle: String {
        switch self {
        case .files(let urls, let note):
            guard let first = urls.first else { return "" }
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let pretty = first.path.replacingOccurrences(of: home, with: "~")
            if urls.count == 1 {
                if let note { return "\(pretty)  •  \(note)" }
                return pretty
            }
            let parent = first.deletingLastPathComponent().path.replacingOccurrences(of: home, with: "~")
            let base = "Cùng thư mục: \(parent)"
            return note != nil ? "\(base)  •  \(note!)" : base
        case .text(let str, let note):
            let words = str.split { $0.isWhitespace || $0.isNewline }.count
            let base = "Văn bản • \(str.count) ký tự • \(words) từ"
            return note != nil ? "\(base) • \(note!)" : base
        case .url(let u, let note):
            let host = u.host ?? "URL"
            return note != nil ? "Liên kết Web (\(host)) • \(note!)" : "Liên kết Web (\(host))"
        }
    }

    var fileURLs: [URL] {
        if case .files(let urls, _) = self { return urls }
        return []
    }
}

enum FileTransferOperation: String, Equatable {
    case copy = "Sao chép tới..."
    case move = "Di chuyển tới..."
    case copyReplace = "Sao chép [Ghi đè] tới..."
    case moveReplace = "Di chuyển [Ghi đè] tới..."
}

struct UniversalActionDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let keywords: String
    let category: ActionCategory
    let sfSymbol: String
    let tintHex: String
    let acceptsFiles: Bool
    let acceptsFolders: Bool
    let acceptsMulti: Bool
    let acceptsText: Bool
    let acceptsURL: Bool
    let requiresGoogleDrive: Bool
    let requiresBundle: Bool
    let priority: Int

    @MainActor
    func matches(target: ActionTarget, isInsideGoogleDrive: Bool) -> Bool {
        switch target {
        case .files(let urls, _):
            guard !urls.isEmpty else { return false }
            if urls.count > 1 && !acceptsMulti { return false }
            if requiresGoogleDrive && !isInsideGoogleDrive { return false }

            var hasFolder = false
            var hasFile = false
            var hasBundle = false

            for url in urls {
                let path = url.path
                let isDirVal: Bool
                let exists: Bool
                if path.contains("/Library/CloudStorage/") {
                    exists = true
                    isDirVal = GoogleDriveIndexService.shared.isKnownDirectory(path, hasDirectoryHint: url.hasDirectoryPath)
                } else {
                    var isDirObj: ObjCBool = false
                    exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirObj)
                    isDirVal = isDirObj.boolValue
                }

                if exists {
                    let ext = url.pathExtension.lowercased()
                    let isPkg = ["app", "bundle", "framework", "xcodeproj", "xcworkspace", "alfredworkflow", "prefpane"].contains(ext)
                    if isPkg { hasBundle = true }
                    if isDirVal && !isPkg {
                        hasFolder = true
                    } else {
                        hasFile = true
                    }
                }
            }

            if requiresBundle && !hasBundle { return false }
            if hasFolder && !hasFile {
                return acceptsFolders
            }
            if hasFile && !hasFolder {
                return acceptsFiles || (hasBundle && acceptsFolders)
            }
            return acceptsFiles || acceptsFolders

        case .text:
            return acceptsText
        case .url:
            return acceptsURL || acceptsText
        }
    }
}

enum UniversalActionCatalog {
    static let all: [UniversalActionDefinition] = [
        // MARK: - 1. AI & Markdown Conversion (Top Priority)
        UniversalActionDefinition(
            id: "ai.convert_md",
            title: "Convert to Markdown",
            subtitle: "Tạo file .md tối ưu cho AI đọc (cạnh file gốc + tự động Copy vào Clipboard)",
            keywords: "convert to markdown md ai llm docling pymupdf markitdown chuyen sang md",
            category: .aiConvert,
            sfSymbol: "doc.text.magnifyingglass",
            tintHex: "#8B5CF6",
            acceptsFiles: true,
            acceptsFolders: false,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 1000
        ),
        UniversalActionDefinition(
            id: "ai.copy_md",
            title: "Convert to Markdown → Copy Only",
            subtitle: "Chuyển sang Markdown chuẩn AI và chép thẳng vào Clipboard (không sinh file .md)",
            keywords: "convert markdown copy clipboard paste claude chatgpt gemini ai md",
            category: .aiConvert,
            sfSymbol: "doc.on.clipboard.fill",
            tintHex: "#A855F7",
            acceptsFiles: true,
            acceptsFolders: false,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 990
        ),
        UniversalActionDefinition(
            id: "ai.convert_for_ai",
            title: "Convert for AI",
            subtitle: "Đóng gói trọn bộ thư mục _AI/ (.md, .txt, .html, .json, manifest) tối ưu LLM",
            keywords: "convert for ai package toolkit folder md json context",
            category: .aiConvert,
            sfSymbol: "sparkles.rectangle.stack.fill",
            tintHex: "#6366F1",
            acceptsFiles: true,
            acceptsFolders: false,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 980
        ),
        UniversalActionDefinition(
            id: "ai.convert_pdf",
            title: "Convert to PDF",
            subtitle: "Chuyển đổi tài liệu Word, Excel, PowerPoint, HTML, Ảnh sang PDF chuẩn",
            keywords: "convert to pdf libreoffice word doc docx xls ppt",
            category: .aiConvert,
            sfSymbol: "doc.richtext.fill",
            tintHex: "#EC4899",
            acceptsFiles: true,
            acceptsFolders: false,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 975
        ),
        UniversalActionDefinition(
            id: "ai.preview_md",
            title: "Convert & Preview Markdown (AI Inspector)",
            subtitle: "Xem trước nội dung Markdown, đếm số Token ước tính cho LLM và sao chép nhanh",
            keywords: "preview inspect markdown token count view md ai",
            category: .aiConvert,
            sfSymbol: "eye.square.fill",
            tintHex: "#7C3AED",
            acceptsFiles: true,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 965
        ),
        UniversalActionDefinition(
            id: "ai.ocr_md",
            title: "OCR to Markdown (Apple Vision Tiếng Việt)",
            subtitle: "Nhận diện chữ từ PDF scan / Ảnh chụp có dấu tiếng Việt sang Markdown sạch",
            keywords: "ocr scan pdf image anh tieng viet vision markdown md",
            category: .aiConvert,
            sfSymbol: "text.viewfinder",
            tintHex: "#0EA5E9",
            acceptsFiles: true,
            acceptsFolders: false,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 955
        ),
        UniversalActionDefinition(
            id: "ai.merge_folder_md",
            title: "Gộp tài liệu sang 1 File AI Context (.md)",
            subtitle: "Trích xuất & nối toàn bộ tài liệu được chọn (hoặc trong thư mục) thành 1 file .md duy nhất cho AI",
            keywords: "merge combine gop folder context markdown ai notebooklm",
            category: .aiConvert,
            sfSymbol: "square.stack.3d.up.badge.a.fill",
            tintHex: "#10B981",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 950
        ),
        UniversalActionDefinition(
            id: "ai.wrap_xml_clipboard",
            title: "Convert & Copy as Claude/Gemini XML (<document>)",
            subtitle: "Chuyển sang Markdown bọc trong thẻ cấu trúc <documents><document> tối ưu nhất cho LLM",
            keywords: "xml claude gemini document tag wrapper context markdown ai copy",
            category: .aiConvert,
            sfSymbol: "chevron.left.forwardslash.chevron.right",
            tintHex: "#8B5CF6",
            acceptsFiles: true,
            acceptsFolders: false,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 948
        ),
        UniversalActionDefinition(
            id: "ai.chunk_md",
            title: "Chia nhỏ tài liệu lớn theo Chương/Mục (Smart Chunks .md)",
            subtitle: "Tự động cắt tài liệu dài theo tiêu đề H1/H2 thành thư mục _Chunks/ kèm 00_INDEX.md",
            keywords: "chunk split chia nho chuong muc large pdf word markdown ai tokens",
            category: .aiConvert,
            sfSymbol: "rectangle.split.3x1.fill",
            tintHex: "#F59E0B",
            acceptsFiles: true,
            acceptsFolders: false,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 945
        ),
        UniversalActionDefinition(
            id: "ai.url_to_md",
            title: "Convert Web URL to Markdown (AI Reader)",
            subtitle: "Tải trang web / Google Docs / GitHub, lọc sạch rác HTML và Copy Markdown chuẩn AI vào Clipboard (⌥↩ lưu file .md)",
            keywords: "convert web url link to markdown ai reader jina gdoc github",
            category: .aiConvert,
            sfSymbol: "globe.desk.fill",
            tintHex: "#8B5CF6",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: true,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 1050
        ),
        UniversalActionDefinition(
            id: "ai.url_preview_md",
            title: "Convert Web URL & Xem trước trong AI Inspector",
            subtitle: "Trích xuất nội dung bài viết Web sang Markdown sạch, đếm số Token và xem trực tiếp",
            keywords: "preview web url markdown inspector token ai reader",
            category: .aiConvert,
            sfSymbol: "doc.viewfinder.fill",
            tintHex: "#7C3AED",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: true,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 1040
        ),

        // MARK: - 2. Google Drive Actions
        UniversalActionDefinition(
            id: "gdrive.open_web",
            title: "Open with Google Drive",
            subtitle: "Mở trực tiếp tệp hoặc thư mục này trên trình duyệt Google Drive Web",
            keywords: "google drive web browser open mo tren web gda",
            category: .googleDrive,
            sfSymbol: "globe.asia.australia.fill",
            tintHex: "#2563EB",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: true,
            requiresBundle: false,
            priority: 920
        ),
        UniversalActionDefinition(
            id: "gdrive.copy_link",
            title: "Copy Google Drive Share Link",
            subtitle: "Sao chép liên kết chia sẻ Google Drive (?usp=sharing) vào Clipboard",
            keywords: "copy link share google drive lien ket chia se url",
            category: .googleDrive,
            sfSymbol: "link.badge.plus",
            tintHex: "#16A34A",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: true,
            requiresBundle: false,
            priority: 915
        ),
        UniversalActionDefinition(
            id: "gdrive.share",
            title: "Share with Google Drive",
            subtitle: "Mở trang thiết lập chia sẻ & phân quyền truy cập trên Google Drive",
            keywords: "share permission google drive phan quyen chia se",
            category: .googleDrive,
            sfSymbol: "person.2.badge.gearshape.fill",
            tintHex: "#0D9488",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: true,
            requiresBundle: false,
            priority: 910
        ),
        UniversalActionDefinition(
            id: "gdrive.offline",
            title: "Make Available Offline",
            subtitle: "Kích hoạt tải toàn bộ tệp về ổ cứng cục bộ để đọc & convert offline",
            keywords: "offline download local google drive tai ve may",
            category: .googleDrive,
            sfSymbol: "arrow.down.circle.fill",
            tintHex: "#0284C7",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: true,
            requiresBundle: false,
            priority: 905
        ),

        // MARK: - 3. Default macOS File & Folder Actions (Alfred Universal Actions parity)
        UniversalActionDefinition(
            id: "file.open",
            title: "Open",
            subtitle: "Mở bằng ứng dụng mặc định trên macOS",
            keywords: "open mo file app default",
            category: .fileSystem,
            sfSymbol: "arrow.up.forward.app.fill",
            tintHex: "#3B82F6",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 850
        ),
        UniversalActionDefinition(
            id: "file.open_with",
            title: "Open With...",
            subtitle: "Chọn ứng dụng bất kỳ để mở tệp đang chọn",
            keywords: "open with chon ung dung mo bang",
            category: .fileSystem,
            sfSymbol: "square.grid.2x2.fill",
            tintHex: "#6366F1",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 845
        ),
        UniversalActionDefinition(
            id: "file.reveal",
            title: "Reveal in Finder",
            subtitle: "Hiển thị vị trí tệp / thư mục trực tiếp trong cửa sổ Finder",
            keywords: "reveal in finder show hien thi mo thu muc chua",
            category: .fileSystem,
            sfSymbol: "folder.fill",
            tintHex: "#0EA5E9",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 840
        ),
        UniversalActionDefinition(
            id: "file.browse",
            title: "Browse Folder in DriveBar",
            subtitle: "Duyệt nhanh cây thư mục bên trong thanh tìm kiếm DriveBar",
            keywords: "browse folder navigate duyet thu muc",
            category: .fileSystem,
            sfSymbol: "folder.badge.magnifyingglass",
            tintHex: "#2563EB",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 835
        ),
        UniversalActionDefinition(
            id: "file.quicklook",
            title: "Quick Look",
            subtitle: "Mở cửa sổ Xem nhanh (Quick Look) chuẩn của macOS (⌘Y)",
            keywords: "quick look preview xem nhanh space",
            category: .fileSystem,
            sfSymbol: "eye.fill",
            tintHex: "#06B6D4",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 830
        ),
        UniversalActionDefinition(
            id: "file.get_info",
            title: "Get Info",
            subtitle: "Mở bảng Thông tin chi tiết (Get Info) của Finder",
            keywords: "get info properties thong tin dung luong",
            category: .fileSystem,
            sfSymbol: "info.circle.fill",
            tintHex: "#64748B",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 820
        ),
        UniversalActionDefinition(
            id: "file.copy_to",
            title: "Copy to...",
            subtitle: "Sao chép tới thư mục đích (tìm nhanh thư mục Google Drive / cục bộ)",
            keywords: "copy to sao chep toi thu muc",
            category: .fileSystem,
            sfSymbol: "doc.on.doc.fill",
            tintHex: "#3B82F6",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 810
        ),
        UniversalActionDefinition(
            id: "file.move_to",
            title: "Move to...",
            subtitle: "Di chuyển tới thư mục đích (tìm nhanh thư mục Google Drive / cục bộ)",
            keywords: "move to di chuyen toi thu muc",
            category: .fileSystem,
            sfSymbol: "folder.fill.badge.plus",
            tintHex: "#F59E0B",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 805
        ),
        UniversalActionDefinition(
            id: "file.copy_replace_to",
            title: "Copy [with Replace] to...",
            subtitle: "Sao chép và tự động ghi đè nếu tệp trùng tên tại thư mục đích",
            keywords: "copy replace overwrite sao chep ghi de",
            category: .fileSystem,
            sfSymbol: "arrow.triangle.2.circlepath.doc.on.clipboard",
            tintHex: "#6366F1",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 795
        ),
        UniversalActionDefinition(
            id: "file.move_replace_to",
            title: "Move [with Replace] to...",
            subtitle: "Di chuyển và tự động ghi đè nếu tệp trùng tên tại thư mục đích",
            keywords: "move replace overwrite di chuyen ghi de",
            category: .fileSystem,
            sfSymbol: "arrow.right.doc.on.clipboard",
            tintHex: "#EA580C",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 790
        ),
        UniversalActionDefinition(
            id: "file.open_terminal",
            title: "Open Terminal Here",
            subtitle: "Mở cửa sổ Terminal (hoặc iTerm) tại đúng thư mục này",
            keywords: "open terminal here iterm shell cli",
            category: .fileSystem,
            sfSymbol: "terminal.fill",
            tintHex: "#1E293B",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 780
        ),
        UniversalActionDefinition(
            id: "file.show_package",
            title: "Show Package Contents",
            subtitle: "Mở bên trong gói Bundle (.app, .alfredworkflow, .xcodeproj...)",
            keywords: "show package contents bundle app",
            category: .fileSystem,
            sfSymbol: "shippingbox.fill",
            tintHex: "#8B5CF6",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: true,
            priority: 775
        ),

        // MARK: - 4. Clipboard & Buffer Actions
        UniversalActionDefinition(
            id: "clip.copy_path",
            title: "Copy Path to Clipboard",
            subtitle: "Sao chép đường dẫn tuyệt đối POSIX vào Clipboard",
            keywords: "copy path posix duong dan clipboard",
            category: .clipboard,
            sfSymbol: "link",
            tintHex: "#14B8A6",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 760
        ),
        UniversalActionDefinition(
            id: "clip.copy_file",
            title: "Copy File to Clipboard",
            subtitle: "Sao chép đối tượng tệp tin vào Clipboard để dán (⌘V) ở mọi nơi",
            keywords: "copy file to clipboard sao chep tep",
            category: .clipboard,
            sfSymbol: "doc.on.clipboard",
            tintHex: "#0EA5E9",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 755
        ),
        UniversalActionDefinition(
            id: "clip.add_buffer",
            title: "Add File to Buffer",
            subtitle: "Đưa tệp vào Khay đệm (File Buffer ⌥↑) để gom xử lý hàng loạt",
            keywords: "add file to buffer gom tep hang loat",
            category: .clipboard,
            sfSymbol: "tray.and.arrow.down.fill",
            tintHex: "#6366F1",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 750
        ),

        // MARK: - 5. File Visibility (chflags hidden / nohidden)
        UniversalActionDefinition(
            id: "vis.toggle",
            title: "Toggle Hide / Unhide (chflags)",
            subtitle: "Đảo trạng thái ẩn/hiện hệ thống (UF_HIDDEN) và cập nhật Finder tức thì",
            keywords: "toggle hide unhidden chflags an hien file thu muc",
            category: .visibility,
            sfSymbol: "eye.slash.circle.fill",
            tintHex: "#F59E0B",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 730
        ),
        UniversalActionDefinition(
            id: "vis.unhide",
            title: "Unhide (chflags nohidden)",
            subtitle: "Bỏ cờ ẩn hệ thống macOS (chflags nohidden) cho các mục đã chọn",
            keywords: "unhide nohidden chflags bo an hien file",
            category: .visibility,
            sfSymbol: "eye.circle.fill",
            tintHex: "#10B981",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 725
        ),
        UniversalActionDefinition(
            id: "vis.hide",
            title: "Hide (chflags hidden)",
            subtitle: "Đặt cờ ẩn hệ thống macOS (chflags hidden) cho các mục đã chọn",
            keywords: "hide hidden chflags an file thu muc",
            category: .visibility,
            sfSymbol: "eye.slash.fill",
            tintHex: "#64748B",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 720
        ),

        // MARK: - 6. Share, Search & Delete
        UniversalActionDefinition(
            id: "file.share_sheet",
            title: "Email / Share...",
            subtitle: "Chia sẻ nhanh qua AirDrop, Mail, Zalo, Tin nhắn...",
            keywords: "email mail share airdrop zalo gui",
            category: .fileSystem,
            sfSymbol: "square.and.arrow.up.fill",
            tintHex: "#3B82F6",
            acceptsFiles: true,
            acceptsFolders: false,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 690
        ),
        UniversalActionDefinition(
            id: "file.search_finder",
            title: "Search with Finder",
            subtitle: "Mở tìm kiếm Spotlight trong cửa sổ Finder với tên mục này",
            keywords: "search with finder spotlight tim",
            category: .fileSystem,
            sfSymbol: "magnifyingglass.circle.fill",
            tintHex: "#0284C7",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 680
        ),
        UniversalActionDefinition(
            id: "file.trash",
            title: "Delete (Move to Trash)",
            subtitle: "Chuyển an toàn các mục đã chọn vào Thùng rác (Trash)",
            keywords: "delete trash remove xoa thung rac",
            category: .fileSystem,
            sfSymbol: "trash.fill",
            tintHex: "#EF4444",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 650
        ),

        // MARK: - 7. Text & URL Universal Actions (Screenshot 1 parity)
        UniversalActionDefinition(
            id: "text.clean_md_ai",
            title: "Clean & Format as Markdown for AI",
            subtitle: "Chuẩn hóa văn bản (NFC, dọn dòng thừa) và sao chép dạng Markdown sạch cho LLM",
            keywords: "convert to markdown clean text ai format md",
            category: .textAndURL,
            sfSymbol: "wand.and.stars",
            tintHex: "#8B5CF6",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 960
        ),
        UniversalActionDefinition(
            id: "url.open",
            title: "Open URL",
            subtitle: "Mở đường dẫn liên kết trong trình duyệt mặc định",
            keywords: "open url browser web link",
            category: .textAndURL,
            sfSymbol: "safari.fill",
            tintHex: "#2563EB",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: true,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 940
        ),
        UniversalActionDefinition(
            id: "url.domain",
            title: "Use Domain From URL...",
            subtitle: "Trích xuất tên miền gốc (Domain) từ liên kết và chép vào Clipboard",
            keywords: "domain host url trich xuat ten mien",
            category: .textAndURL,
            sfSymbol: "network",
            tintHex: "#0EA5E9",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: true,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 920
        ),
        UniversalActionDefinition(
            id: "text.copy_plain",
            title: "Copy as Plain Text",
            subtitle: "Xóa toàn bộ định dạng font/màu và lưu dạng văn bản thuần vào Clipboard",
            keywords: "copy as plain text van ban thuan",
            category: .textAndURL,
            sfSymbol: "doc.plaintext.fill",
            tintHex: "#10B981",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: true,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 900
        ),
        UniversalActionDefinition(
            id: "text.paste_plain",
            title: "Paste as Plain Text",
            subtitle: "Dán ngay nội dung văn bản thuần vào ứng dụng đang mở phía trước",
            keywords: "paste as plain text dan van ban thuan",
            category: .textAndURL,
            sfSymbol: "arrow.down.doc.fill",
            tintHex: "#14B8A6",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: true,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 890
        ),
        UniversalActionDefinition(
            id: "text.case_upper",
            title: "Case Converter: UPPERCASE",
            subtitle: "Chuyển toàn bộ chữ thành IN HOA và chép vào Clipboard",
            keywords: "case converter upper hoa",
            category: .textAndURL,
            sfSymbol: "textformat.abc",
            tintHex: "#6366F1",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 860
        ),
        UniversalActionDefinition(
            id: "text.case_lower",
            title: "Case Converter: lowercase",
            subtitle: "Chuyển toàn bộ chữ thành chữ thường và chép vào Clipboard",
            keywords: "case converter lower thuong",
            category: .textAndURL,
            sfSymbol: "textformat.abc.dottedunderline",
            tintHex: "#6366F1",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 855
        ),
        UniversalActionDefinition(
            id: "text.case_title",
            title: "Case Converter: Title Case",
            subtitle: "Viết Hoa Chữ Cái Đầu Mỗi Từ và chép vào Clipboard",
            keywords: "case converter title capitalize",
            category: .textAndURL,
            sfSymbol: "textformat",
            tintHex: "#6366F1",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 850
        ),
        UniversalActionDefinition(
            id: "text.extract_urls",
            title: "Extract URLs from Text",
            subtitle: "Tách mọi đường dẫn http/https trong đoạn văn bản ra danh sách sạch",
            keywords: "extract urls links tach link",
            category: .textAndURL,
            sfSymbol: "link.circle.fill",
            tintHex: "#0284C7",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 840
        ),
        UniversalActionDefinition(
            id: "text.dictionary",
            title: "Open in Dictionary",
            subtitle: "Tra cứu nhanh từ vựng trong Từ điển macOS (Dictionary.app)",
            keywords: "open in dictionary tra tu dien",
            category: .textAndURL,
            sfSymbol: "character.book.closed.fill",
            tintHex: "#EF4444",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 830
        ),
        UniversalActionDefinition(
            id: "text.large_type",
            title: "Show as Large Type",
            subtitle: "Hiển thị cỡ chữ khổng lồ giữa màn hình (giống Alfred Large Type)",
            keywords: "show as large type chu to phong to",
            category: .textAndURL,
            sfSymbol: "textformat.size.larger",
            tintHex: "#F59E0B",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: true,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 820
        ),
        UniversalActionDefinition(
            id: "text.web_search",
            title: "Search Google",
            subtitle: "Tìm kiếm đoạn văn bản này trên Google",
            keywords: "search google web tim tren mang",
            category: .textAndURL,
            sfSymbol: "magnifyingglass",
            tintHex: "#3B82F6",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 810
        )
    ]
}
