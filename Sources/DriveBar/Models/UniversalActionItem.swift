import Foundation
import AppKit

enum ActionCategory: String, Codable, CaseIterable, Sendable {
    case aiConvert = "AI & Convert sang Markdown"
    case googleDrive = "Google Drive"
    case visibility = "Ẩn / Hiện File (chflags)"
    case fileSystem = "Thao tác File & Thư mục"
    case clipboard = "Clipboard & Đường dẫn"
    case textAndURL = "Văn bản & Liên kết Web"

    var localizedTitle: String {
        switch self {
        case .aiConvert:
            return L("AI & Convert sang Markdown", "AI & Markdown Conversion")
        case .googleDrive:
            return "Google Drive"
        case .visibility:
            return L("Ẩn / Hiện File (chflags)", "File Visibility (chflags)")
        case .fileSystem:
            return L("Thao tác File & Thư mục", "File & Folder Operations")
        case .clipboard:
            return L("Clipboard & Đường dẫn", "Clipboard & Paths")
        case .textAndURL:
            return L("Văn bản & Liên kết Web", "Text & Web Links")
        }
    }
}

enum ActionTarget: Equatable {
    case files([URL], sourceNote: String? = nil)
    case text(String, sourceNote: String? = nil)
    case url(URL, sourceNote: String? = nil)

    var primaryTitle: String {
        switch self {
        case .files(let urls, _):
            guard let first = urls.first else { return L("Không có mục nào", "No items") }
            if urls.count == 1 {
                return first.lastPathComponent
            }
            return "\(urls.count) \(L("mục đã chọn", "items selected")) (\(first.lastPathComponent)...)"
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
            let base = "\(L("Cùng thư mục", "In folder")): \(parent)"
            return note != nil ? "\(base)  •  \(note!)" : base
        case .text(let str, let note):
            let words = str.split { $0.isWhitespace || $0.isNewline }.count
            let base = "\(L("Văn bản", "Text")) • \(str.count) \(L("ký tự", "chars")) • \(words) \(L("từ", "words"))"
            return note != nil ? "\(base) • \(note!)" : base
        case .url(let u, let note):
            let host = u.host ?? "URL"
            let label = "\(L("Liên kết Web", "Web Link")) (\(host))"
            return note != nil ? "\(label) • \(note!)" : label
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

    var localizedTitle: String {
        switch self {
        case .copy: return L("Sao chép tới...", "Copy to...")
        case .move: return L("Di chuyển tới...", "Move to...")
        case .copyReplace: return L("Sao chép [Ghi đè] tới...", "Copy [Overwrite] to...")
        case .moveReplace: return L("Di chuyển [Ghi đè] tới...", "Move [Overwrite] to...")
        }
    }
}

struct UniversalActionDefinition: Identifiable, Equatable, Sendable {
    let id: String
    let titleVI: String
    let titleEN: String
    var title: String {
        customTitleOverride ?? L(titleVI, titleEN)
    }
    let subtitleVI: String
    let subtitleEN: String
    var subtitle: String {
        customSubtitleOverride ?? L(subtitleVI, subtitleEN)
    }
    var customTitleOverride: String?
    var customSubtitleOverride: String?
    let keywords: String
    let category: ActionCategory
    var sfSymbol: String
    let tintHex: String
    let acceptsFiles: Bool
    let acceptsFolders: Bool
    let acceptsMulti: Bool
    let acceptsText: Bool
    let acceptsURL: Bool
    let requiresGoogleDrive: Bool
    let requiresBundle: Bool
    let priority: Int

    var bilingualSearchText: String {
        "\(titleVI) \(titleEN) \(subtitleVI) \(subtitleEN) \(keywords)"
    }

    init(
        id: String,
        titleVI: String,
        titleEN: String,
        subtitleVI: String,
        subtitleEN: String,
        customTitleOverride: String? = nil,
        customSubtitleOverride: String? = nil,
        keywords: String,
        category: ActionCategory,
        sfSymbol: String,
        tintHex: String,
        acceptsFiles: Bool,
        acceptsFolders: Bool,
        acceptsMulti: Bool,
        acceptsText: Bool,
        acceptsURL: Bool,
        requiresGoogleDrive: Bool,
        requiresBundle: Bool,
        priority: Int
    ) {
        self.id = id
        self.titleVI = titleVI
        self.titleEN = titleEN
        self.subtitleVI = subtitleVI
        self.subtitleEN = subtitleEN
        self.customTitleOverride = customTitleOverride
        self.customSubtitleOverride = customSubtitleOverride
        self.keywords = keywords
        self.category = category
        self.sfSymbol = sfSymbol
        self.tintHex = tintHex
        self.acceptsFiles = acceptsFiles
        self.acceptsFolders = acceptsFolders
        self.acceptsMulti = acceptsMulti
        self.acceptsText = acceptsText
        self.acceptsURL = acceptsURL
        self.requiresGoogleDrive = requiresGoogleDrive
        self.requiresBundle = requiresBundle
        self.priority = priority
    }

    @MainActor
    func customized(for target: ActionTarget, settings: AppSettings) -> UniversalActionDefinition {
        let urls = target.fileURLs
        guard !urls.isEmpty else { return self }
        if id == "file.toggle_custom_mac_folder" {
            let allIncluded = urls.allSatisfy { settings.isCustomMacFolder($0.path) }
            if allIncluded {
                var copy = self
                copy.customTitleOverride = L("Gỡ khỏi danh sách thư mục Mac (m)", "Remove from Mac Folders (m)")
                copy.customSubtitleOverride = L("Xóa thư mục này khỏi phạm vi tìm kiếm nhanh của tiền tố 'm'", "Remove this folder from quick search scope of 'm' prefix")
                copy.sfSymbol = "folder.badge.minus"
                return copy
            }
        } else if id == "gdrive.sync_local_folder" {
            if let first = urls.first,
               let pair = LocalFolderDriveSyncService.shared.pair(forLocalOrDrivePath: first.path) {
                var copy = self
                copy.customTitleOverride = L("Quản lý / Đồng bộ ngay với Google Drive (Đang đồng bộ)", "Manage / Sync Now with Google Drive (Active)")
                copy.customSubtitleOverride = L("Đích: \(pair.prettyDrivePath) • Chế độ: \(pair.syncMode.localizedShortBadge)", "Target: \(pair.prettyDrivePath) • Mode: \(pair.syncMode.localizedShortBadge)")
                copy.sfSymbol = "checkmark.icloud.fill"
                return copy
            }
        } else if id == "file.toggle_pin" {
            let allPinned = urls.allSatisfy { settings.isPinned($0.path) }
            var copy = self
            if allPinned {
                copy.customTitleOverride = L("Bỏ ghim khỏi đầu DriveBar (⌘D)", "Unpin from DriveBar (⌘D)")
                copy.customSubtitleOverride = L("Gỡ mục này khỏi danh sách ghim đầu tiên trong thanh tìm kiếm", "Remove item from pinned list at top of search")
                copy.sfSymbol = "pin.slash.fill"
            } else {
                copy.customTitleOverride = L("Ghim lên đầu DriveBar (⌘D)", "Pin to top of DriveBar (⌘D)")
                copy.customSubtitleOverride = L("Luôn hiển thị mục này đầu tiên khi mở DriveBar (đồng bộ qua Syncthing)", "Always show item first in DriveBar (synced via Syncthing)")
                copy.sfSymbol = "pin.fill"
            }
            return copy
        }
        return self
    }

    @MainActor
    func matches(target: ActionTarget, isInsideGoogleDrive: Bool) -> Bool {
        if id == "ai.ocr_clipboard" {
            return ClipboardHistoryService.shared.hasClipboardImageAvailable
        }

        switch target {
        case .files(let urls, _):
            guard !urls.isEmpty else { return false }
            if urls.count > 1 && !acceptsMulti { return false }
            if requiresGoogleDrive && !isInsideGoogleDrive { return false }
            if id == "gdrive.sync_local_folder" || id == "gdrive.sync_local_folder_instant" {
                let allDirectCloud = urls.allSatisfy { GoogleDriveIndexService.shared.isDirectGoogleDriveCloudStoragePath($0.path) }
                if allDirectCloud { return false }
            }

            if id == "file.extract_archive" {
                let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "tbz2", "xz", "7z", "rar"]
                return urls.allSatisfy { archiveExts.contains($0.pathExtension.lowercased()) }
            }

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
            titleVI: "Chuyển sang Markdown",
            titleEN: "Convert to Markdown",
            subtitleVI: "Tạo file .md tối ưu cho AI đọc (cạnh file/thư mục gốc + tự động Copy vào Clipboard)",
            subtitleEN: "Generate AI-optimized .md file next to source + copy to Clipboard",
            keywords: "convert to markdown md ai llm docling pymupdf markitdown chuyen sang md",
            category: .aiConvert,
            sfSymbol: "doc.text.magnifyingglass",
            tintHex: "#8B5CF6",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 1000
        ),
        UniversalActionDefinition(
            id: "ai.copy_md",
            titleVI: "Chuyển sang Markdown → Chỉ sao chép",
            titleEN: "Convert to Markdown → Copy Only",
            subtitleVI: "Chuyển sang Markdown chuẩn AI và chép thẳng vào Clipboard (không sinh file .md)",
            subtitleEN: "Convert to clean AI Markdown and copy to Clipboard without creating a file",
            keywords: "convert markdown copy clipboard paste claude chatgpt gemini ai md",
            category: .aiConvert,
            sfSymbol: "doc.on.clipboard.fill",
            tintHex: "#A855F7",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 990
        ),
        UniversalActionDefinition(
            id: "ai.convert_for_ai",
            titleVI: "Đóng gói cho AI (Convert for AI)",
            titleEN: "Convert for AI",
            subtitleVI: "Đóng gói trọn bộ thư mục _AI/ (.md, .txt, .html, .json, manifest) tối ưu LLM",
            subtitleEN: "Package into full _AI/ bundle (.md, .txt, .html, .json, manifest) for LLMs",
            keywords: "convert for ai package toolkit folder md json context dong goi cho ai",
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
            titleVI: "Chuyển đổi sang PDF",
            titleEN: "Convert to PDF",
            subtitleVI: "Chuyển đổi tài liệu Word, Excel, PowerPoint, HTML, Ảnh sang PDF chuẩn",
            subtitleEN: "Convert Word, Excel, PowerPoint, HTML, and images to standard PDF",
            keywords: "convert to pdf libreoffice word doc docx xls ppt chuyen sang pdf",
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
            titleVI: "Chuyển đổi & Xem trước Markdown (AI Inspector)",
            titleEN: "Convert & Preview Markdown (AI Inspector)",
            subtitleVI: "Xem trước nội dung Markdown, đếm số Token ước tính cho LLM và sao chép nhanh",
            subtitleEN: "Preview Markdown content, inspect estimated LLM tokens, and quick copy",
            keywords: "preview inspect markdown token count view md ai xem truoc markdown",
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
            titleVI: "OCR sang Markdown (Apple Vision Tiếng Việt)",
            titleEN: "OCR to Markdown (Apple Vision)",
            subtitleVI: "Nhận diện chữ từ PDF scan / Ảnh chụp có dấu tiếng Việt sang Markdown sạch",
            subtitleEN: "Recognize text from scanned PDFs / photos into clean Markdown",
            keywords: "ocr scan pdf image anh tieng viet vision markdown md nhan dien chu",
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
            id: "ai.ocr_clipboard",
            titleVI: "OCR ảnh trong Clipboard sang Markdown",
            titleEN: "OCR Clipboard Image to Markdown",
            subtitleVI: "Nhận diện chữ Tiếng Việt & Tiếng Anh từ ảnh chụp màn hình đang lưu trong Clipboard (⌥↩ xem trước)",
            subtitleEN: "Recognize Vietnamese & English text from screenshot in Clipboard (⌥↩ preview)",
            keywords: "ocr clipboard screenshot image anh chup man hinh vision markdown md",
            category: .aiConvert,
            sfSymbol: "camera.viewfinder",
            tintHex: "#0284C7",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: true,
            acceptsURL: true,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 952
        ),
        UniversalActionDefinition(
            id: "ai.merge_folder_md",
            titleVI: "Gộp tài liệu sang 1 File AI Context (.md)",
            titleEN: "Merge Documents into Single AI Context (.md)",
            subtitleVI: "Trích xuất & nối toàn bộ tài liệu được chọn (hoặc trong thư mục) thành 1 file .md duy nhất cho AI",
            subtitleEN: "Extract and combine selected files or folder contents into a single .md file for AI",
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
            titleVI: "Chuyển & Sao chép dạng XML Claude/Gemini (<document>)",
            titleEN: "Convert & Copy as Claude/Gemini XML (<document>)",
            subtitleVI: "Chuyển sang Markdown bọc trong thẻ cấu trúc <documents><document> tối ưu nhất cho LLM",
            subtitleEN: "Convert to Markdown wrapped in <documents><document> XML tags for LLMs",
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
            titleVI: "Chia nhỏ tài liệu lớn theo Chương/Mục (Smart Chunks .md)",
            titleEN: "Split Large Document into Sections (Smart Chunks .md)",
            subtitleVI: "Tự động cắt tài liệu dài theo tiêu đề H1/H2 thành thư mục _Chunks/ kèm 00_INDEX.md",
            subtitleEN: "Automatically split long documents by H1/H2 headings into _Chunks/ folder with 00_INDEX.md",
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
            titleVI: "Chuyển URL Web sang Markdown (AI Reader)",
            titleEN: "Convert Web URL to Markdown (AI Reader)",
            subtitleVI: "Tải trang web / Google Docs / GitHub, lọc sạch rác HTML và Copy Markdown chuẩn AI vào Clipboard (⌥↩ lưu file .md)",
            subtitleEN: "Fetch webpage / Google Docs / GitHub, strip HTML, and copy clean Markdown to Clipboard (⌥↩ save file)",
            keywords: "convert web url link to markdown ai reader jina gdoc github chuyen link sang md",
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
            titleVI: "Chuyển URL Web & Xem trước trong AI Inspector",
            titleEN: "Convert Web URL & Preview in AI Inspector",
            subtitleVI: "Trích xuất nội dung bài viết Web sang Markdown sạch, đếm số Token và xem trực tiếp",
            subtitleEN: "Extract webpage article to clean Markdown, count tokens, and preview directly",
            keywords: "preview web url markdown inspector token ai reader xem truoc web",
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
            id: "gdrive.sync_local_folder",
            titleVI: "Đồng bộ với Google Drive",
            titleEN: "Sync with Google Drive",
            subtitleVI: "Đồng bộ 2 chiều thời gian thực với Google Drive & mở bảng lấy link chia sẻ Public / Khóa quyền",
            subtitleEN: "Real-time 2-way sync with Google Drive & open Public Share / Lock permissions dialog",
            keywords: "sync google drive folder dong bo thu muc mac antigravity gdrive 2 chieu",
            category: .googleDrive,
            sfSymbol: "icloud.and.arrow.up.fill",
            tintHex: "#0EA5E9",
            acceptsFiles: false,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 965
        ),
        UniversalActionDefinition(
            id: "gdrive.share_public_read",
            titleVI: "Lấy link chia sẻ Public — Chỉ xem (Viewer)",
            titleEN: "Get Public Share Link — View Only (Viewer)",
            subtitleVI: "Mở quyền 'Bất kỳ ai có liên kết đều có thể xem' trên Google Drive & tự động Copy link vào Clipboard",
            subtitleEN: "Enable 'Anyone with the link can view' on Google Drive & copy share link to Clipboard",
            keywords: "public link share view reader google drive chia se cong khai chi xem",
            category: .googleDrive,
            sfSymbol: "globe",
            tintHex: "#10B981",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: true,
            requiresBundle: false,
            priority: 928
        ),
        UniversalActionDefinition(
            id: "gdrive.share_public_edit",
            titleVI: "Lấy link chia sẻ Public — Cho phép sửa (Editor)",
            titleEN: "Get Public Share Link — Can Edit (Editor)",
            subtitleVI: "Mở quyền 'Bất kỳ ai có liên kết đều có thể chỉnh sửa' trên Google Drive & tự động Copy link",
            subtitleEN: "Enable 'Anyone with the link can edit' on Google Drive & copy share link to Clipboard",
            keywords: "public link share edit writer google drive chia se cong khai chinh sua",
            category: .googleDrive,
            sfSymbol: "pencil.and.outline",
            tintHex: "#8B5CF6",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: true,
            requiresBundle: false,
            priority: 926
        ),
        UniversalActionDefinition(
            id: "gdrive.share_lock_restricted",
            titleVI: "Khóa link chia sẻ Google Drive (Chỉ mình tôi)",
            titleEN: "Lock Google Drive Share Link (Restricted)",
            subtitleVI: "Thu hồi quyền truy cập công khai (anyoneWithLink) để khóa lại chỉ mình chủ sở hữu xem được",
            subtitleEN: "Revoke public link access (anyoneWithLink) so only the owner can access",
            keywords: "lock restrict private google drive khoa link han che thu hoi quyen",
            category: .googleDrive,
            sfSymbol: "lock.fill",
            tintHex: "#F59E0B",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: false,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: true,
            requiresBundle: false,
            priority: 924
        ),
        UniversalActionDefinition(
            id: "gdrive.open_web",
            titleVI: "Mở trên Google Drive Web",
            titleEN: "Open with Google Drive",
            subtitleVI: "Mở trực tiếp tệp hoặc thư mục này trên trình duyệt Google Drive Web",
            subtitleEN: "Open this file or folder directly in Google Drive web browser",
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
            titleVI: "Sao chép liên kết chia sẻ Google Drive",
            titleEN: "Copy Google Drive Share Link",
            subtitleVI: "Sao chép liên kết chia sẻ Google Drive (?usp=sharing) vào Clipboard",
            subtitleEN: "Copy Google Drive shareable link (?usp=sharing) to Clipboard",
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
            titleVI: "Cài đặt chia sẻ Google Drive",
            titleEN: "Share with Google Drive",
            subtitleVI: "Mở trang thiết lập chia sẻ & phân quyền truy cập trên Google Drive",
            subtitleEN: "Open Google Drive share settings and access permissions",
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
            titleVI: "Lưu trữ để dùng ngoại tuyến (Offline)",
            titleEN: "Make Available Offline",
            subtitleVI: "Kích hoạt tải toàn bộ tệp về ổ cứng cục bộ để đọc & convert offline",
            subtitleEN: "Trigger local caching to read and convert files offline",
            keywords: "offline download local google drive tai ve may ngoai tuyen",
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

        // MARK: - 3. Default macOS File & Folder Actions
        UniversalActionDefinition(
            id: "file.extract_archive",
            titleVI: "Giải nén tệp lưu trữ tại đây",
            titleEN: "Extract Archive Here",
            subtitleVI: "Giải nén nhanh tệp .zip / .tar / .gz ra thư mục nằm ngay cạnh tệp gốc",
            subtitleEN: "Quickly extract .zip / .tar / .gz archive next to original file",
            keywords: "extract unzip unarchive giai nen zip tar gz",
            category: .fileSystem,
            sfSymbol: "archivebox.fill",
            tintHex: "#64748B",
            acceptsFiles: true,
            acceptsFolders: false,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 854
        ),
        UniversalActionDefinition(
            id: "file.open",
            titleVI: "Mở",
            titleEN: "Open",
            subtitleVI: "Mở bằng ứng dụng mặc định trên macOS",
            subtitleEN: "Open with macOS default application",
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
            id: "file.toggle_pin",
            titleVI: "Ghim / Bỏ ghim trong DriveBar (⌘D)",
            titleEN: "Pin / Unpin in DriveBar (⌘D)",
            subtitleVI: "Ghim hoặc bỏ ghim mục này lên đầu thanh tìm kiếm DriveBar (đồng bộ qua Syncthing)",
            subtitleEN: "Pin or unpin this item at the top of DriveBar search (synced via Syncthing)",
            keywords: "pin unpin favorite ghim bo ghim dau danh sach star",
            category: .fileSystem,
            sfSymbol: "pin.fill",
            tintHex: "#64748B",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 848
        ),
        UniversalActionDefinition(
            id: "file.open_with",
            titleVI: "Mở bằng...",
            titleEN: "Open With...",
            subtitleVI: "Chọn ứng dụng bất kỳ để mở tệp đang chọn",
            subtitleEN: "Choose any application to open the selected file",
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
            titleVI: "Hiện trong Finder",
            titleEN: "Reveal in Finder",
            subtitleVI: "Hiển thị vị trí tệp / thư mục trực tiếp trong cửa sổ Finder",
            subtitleEN: "Show file or folder location directly in Finder",
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
            titleVI: "Duyệt thư mục trong DriveBar",
            titleEN: "Browse Folder in DriveBar",
            subtitleVI: "Duyệt nhanh cây thư mục bên trong thanh tìm kiếm DriveBar",
            subtitleEN: "Quickly navigate directory contents directly in DriveBar",
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
            id: "file.toggle_custom_mac_folder",
            titleVI: "Thêm vào danh sách thư mục Mac (m)",
            titleEN: "Add to Mac Folders (m)",
            subtitleVI: "Đưa thư mục này vào danh sách tìm kiếm nhanh bằng tiền tố 'm'",
            subtitleEN: "Include this folder in quick search scope using 'm' prefix",
            keywords: "mac folder search them thu muc tim kiem m",
            category: .fileSystem,
            sfSymbol: "folder.badge.plus",
            tintHex: "#10B981",
            acceptsFiles: false,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 832
        ),
        UniversalActionDefinition(
            id: "file.quicklook",
            titleVI: "Xem nhanh (Quick Look)",
            titleEN: "Quick Look",
            subtitleVI: "Mở cửa sổ Xem nhanh (Quick Look) chuẩn của macOS (⌘Y)",
            subtitleEN: "Open standard macOS Quick Look preview (⌘Y)",
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
            titleVI: "Thông tin tệp (Get Info)",
            titleEN: "Get Info",
            subtitleVI: "Mở bảng Thông tin chi tiết (Get Info) của Finder",
            subtitleEN: "Open Finder Get Info inspector panel",
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
            id: "file.batch_rename",
            titleVI: "Đổi tên / Đổi tên hàng loạt...",
            titleEN: "Rename / Batch Rename...",
            subtitleVI: "Đổi tên nhanh hoặc đổi tên hàng loạt (Tìm & Thay thế, Tiền tố/Hậu tố, Đánh số 01, 02...)",
            subtitleEN: "Quick rename or batch rename (Find & Replace, Prefix/Suffix, Numbering 01, 02...)",
            keywords: "rename batch doi ten hang loat replace prefix suffix number",
            category: .fileSystem,
            sfSymbol: "pencil.line",
            tintHex: "#64748B",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 815
        ),
        UniversalActionDefinition(
            id: "file.copy_to",
            titleVI: "Sao chép tới...",
            titleEN: "Copy to...",
            subtitleVI: "Sao chép tới thư mục đích (tìm nhanh thư mục Google Drive / cục bộ)",
            subtitleEN: "Copy to destination folder (quick search Google Drive / local)",
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
            titleVI: "Di chuyển tới...",
            titleEN: "Move to...",
            subtitleVI: "Di chuyển tới thư mục đích (tìm nhanh thư mục Google Drive / cục bộ)",
            subtitleEN: "Move to destination folder (quick search Google Drive / local)",
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
            titleVI: "Sao chép [Ghi đè] tới...",
            titleEN: "Copy [with Replace] to...",
            subtitleVI: "Sao chép và tự động ghi đè nếu tệp trùng tên tại thư mục đích",
            subtitleEN: "Copy and overwrite existing files with same name at destination",
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
            titleVI: "Di chuyển [Ghi đè] tới...",
            titleEN: "Move [with Replace] to...",
            subtitleVI: "Di chuyển và tự động ghi đè nếu tệp trùng tên tại thư mục đích",
            subtitleEN: "Move and overwrite existing files with same name at destination",
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
            titleVI: "Mở Terminal tại đây",
            titleEN: "Open Terminal Here",
            subtitleVI: "Mở cửa sổ Terminal (hoặc iTerm) tại đúng thư mục này",
            subtitleEN: "Open Terminal (or iTerm) window at this directory path",
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
            titleVI: "Hiển thị nội dung gói (Package Contents)",
            titleEN: "Show Package Contents",
            subtitleVI: "Mở bên trong gói Bundle (.app, .alfredworkflow, .xcodeproj...)",
            subtitleEN: "Inspect inside application or bundle package (.app, .xcodeproj...)",
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
        UniversalActionDefinition(
            id: "file.compress_zip",
            titleVI: "Nén thành tệp lưu trữ .ZIP",
            titleEN: "Compress to .ZIP Archive",
            subtitleVI: "Nén các tệp hoặc thư mục đã chọn thành 1 tệp .zip chuẩn macOS nằm ngay cạnh mục gốc",
            subtitleEN: "Compress selected items into a standard .zip archive next to source",
            keywords: "compress zip archive nen tep thu muc",
            category: .fileSystem,
            sfSymbol: "doc.zipper",
            tintHex: "#64748B",
            acceptsFiles: true,
            acceptsFolders: true,
            acceptsMulti: true,
            acceptsText: false,
            acceptsURL: false,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 772
        ),

        // MARK: - 4. Clipboard & Buffer Actions
        UniversalActionDefinition(
            id: "clip.copy_path",
            titleVI: "Sao chép đường dẫn vào Clipboard",
            titleEN: "Copy Path to Clipboard",
            subtitleVI: "Sao chép đường dẫn tuyệt đối POSIX vào Clipboard",
            subtitleEN: "Copy absolute POSIX file path to Clipboard",
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
            titleVI: "Sao chép tệp vào Clipboard",
            titleEN: "Copy File to Clipboard",
            subtitleVI: "Sao chép đối tượng tệp tin vào Clipboard để dán (⌘V) ở mọi nơi",
            subtitleEN: "Copy file object to Clipboard for pasting (⌘V) anywhere",
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
            titleVI: "Thêm tệp vào Khay đệm (Buffer)",
            titleEN: "Add File to Buffer",
            subtitleVI: "Đưa tệp vào Khay đệm (File Buffer ⌥↑) để gom xử lý hàng loạt",
            subtitleEN: "Add item to File Buffer (⌥↑) for batch processing",
            keywords: "add file to buffer gom tep hang loat khay dem",
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
            titleVI: "Ẩn / Hiện file (chflags)",
            titleEN: "Toggle Hide / Unhide (chflags)",
            subtitleVI: "Đảo trạng thái ẩn/hiện hệ thống (UF_HIDDEN) và cập nhật Finder tức thì",
            subtitleEN: "Toggle system hidden flag (UF_HIDDEN) and refresh Finder immediately",
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
            titleVI: "Hiện file (chflags nohidden)",
            titleEN: "Unhide (chflags nohidden)",
            subtitleVI: "Bỏ cờ ẩn hệ thống macOS (chflags nohidden) cho các mục đã chọn",
            subtitleEN: "Remove macOS system hidden flag (chflags nohidden) for selected items",
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
            titleVI: "Ẩn file (chflags hidden)",
            titleEN: "Hide (chflags hidden)",
            subtitleVI: "Đặt cờ ẩn hệ thống macOS (chflags hidden) cho các mục đã chọn",
            subtitleEN: "Set macOS system hidden flag (chflags hidden) for selected items",
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
            titleVI: "Email / Chia sẻ...",
            titleEN: "Email / Share...",
            subtitleVI: "Chia sẻ nhanh qua AirDrop, Mail, Zalo, Tin nhắn...",
            subtitleEN: "Quick share via AirDrop, Mail, Messages, or apps",
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
            titleVI: "Tìm kiếm bằng Finder",
            titleEN: "Search with Finder",
            subtitleVI: "Mở tìm kiếm Spotlight trong cửa sổ Finder với tên mục này",
            subtitleEN: "Open Spotlight search in Finder window for this item",
            keywords: "search with finder spotlight tim kiem",
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
            titleVI: "Xóa (Chuyển vào Thùng rác)",
            titleEN: "Delete (Move to Trash)",
            subtitleVI: "Chuyển an toàn các mục đã chọn vào Thùng rác (Trash)",
            subtitleEN: "Safely move selected items to Trash",
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

        // MARK: - 7. Text & URL Universal Actions
        UniversalActionDefinition(
            id: "text.clean_md_ai",
            titleVI: "Làm sạch & Định dạng Markdown cho AI",
            titleEN: "Clean & Format as Markdown for AI",
            subtitleVI: "Chuẩn hóa văn bản (NFC, dọn dòng thừa) và sao chép dạng Markdown sạch cho LLM",
            subtitleEN: "Normalize text (NFC, clean whitespace) and copy clean Markdown for LLMs",
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
            titleVI: "Mở liên kết URL",
            titleEN: "Open URL",
            subtitleVI: "Mở đường dẫn liên kết trong trình duyệt mặc định",
            subtitleEN: "Open URL link in default web browser",
            keywords: "open url browser web link mo duong dan",
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
            titleVI: "Lấy tên miền từ URL...",
            titleEN: "Use Domain From URL...",
            subtitleVI: "Trích xuất tên miền gốc (Domain) từ liên kết và chép vào Clipboard",
            subtitleEN: "Extract origin domain from URL and copy to Clipboard",
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
            titleVI: "Sao chép dạng văn bản thuần",
            titleEN: "Copy as Plain Text",
            subtitleVI: "Xóa toàn bộ định dạng font/màu và lưu dạng văn bản thuần vào Clipboard",
            subtitleEN: "Strip all rich formatting and copy plain text to Clipboard",
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
            titleVI: "Dán dạng văn bản thuần",
            titleEN: "Paste as Plain Text",
            subtitleVI: "Dán ngay nội dung văn bản thuần vào ứng dụng đang mở phía trước",
            subtitleEN: "Paste plain text directly into frontmost active application",
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
            titleVI: "Chuyển thành CHỮ IN HOA",
            titleEN: "Case Converter: UPPERCASE",
            subtitleVI: "Chuyển toàn bộ chữ thành IN HOA và chép vào Clipboard",
            subtitleEN: "Convert all text to UPPERCASE and copy to Clipboard",
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
            titleVI: "Chuyển thành chữ thường",
            titleEN: "Case Converter: lowercase",
            subtitleVI: "Chuyển toàn bộ chữ thành chữ thường và chép vào Clipboard",
            subtitleEN: "Convert all text to lowercase and copy to Clipboard",
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
            titleVI: "Viết Hoa Chữ Cái Đầu Mỗi Từ",
            titleEN: "Case Converter: Title Case",
            subtitleVI: "Viết Hoa Chữ Cái Đầu Mỗi Từ và chép vào Clipboard",
            subtitleEN: "Capitalize First Letter Of Each Word and copy to Clipboard",
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
            titleVI: "Trích xuất URL từ văn bản",
            titleEN: "Extract URLs from Text",
            subtitleVI: "Tách mọi đường dẫn http/https trong đoạn văn bản ra danh sách sạch",
            subtitleEN: "Extract all http/https links from text into a clean list",
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
            titleVI: "Tra cứu trong Từ điển",
            titleEN: "Open in Dictionary",
            subtitleVI: "Tra cứu nhanh từ vựng trong Từ điển macOS (Dictionary.app)",
            subtitleEN: "Quickly look up words in macOS Dictionary",
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
            titleVI: "Phóng to chữ lớn (Large Type)",
            titleEN: "Show as Large Type",
            subtitleVI: "Hiển thị cỡ chữ khổng lồ giữa màn hình (giống Alfred Large Type)",
            subtitleEN: "Display large text across the center of screen (Alfred Large Type)",
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
            titleVI: "Tìm kiếm trên Google",
            titleEN: "Search Google",
            subtitleVI: "Tìm kiếm đoạn văn bản này trên Google",
            subtitleEN: "Search for this text on Google",
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
        ),
        UniversalActionDefinition(
            id: "gdrive.subscribe_shared_folder_link",
            titleVI: "Tải về máy & Theo dõi Đồng bộ Link Thư mục Google Drive được chia sẻ...",
            titleEN: "Download & Subscribe to Shared Google Drive Folder Link...",
            subtitleVI: "Tự động copy nội dung về máy, kiểm tra cập nhật mới định kỳ và bảo toàn 100% file nếu link bị khóa",
            subtitleEN: "Auto-copy shared folder to Mac, poll for updates, and preserve 100% of local files if link is locked",
            keywords: "google drive shared folder link download sync copy subscribe dan link thu muc chia se",
            category: .googleDrive,
            sfSymbol: "icloud.and.arrow.down.fill",
            tintHex: "#4F46E5",
            acceptsFiles: false,
            acceptsFolders: false,
            acceptsMulti: false,
            acceptsText: true,
            acceptsURL: true,
            requiresGoogleDrive: false,
            requiresBundle: false,
            priority: 995
        )
    ]
}
