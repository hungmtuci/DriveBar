# DriveBar for macOS

**DriveBar** là ứng dụng tìm kiếm nhanh & điều phối tác vụ toàn cục (lấy cảm hứng từ **Alfred 5**) được viết hoàn toàn bằng **Swift Native (SwiftUI + AppKit)** cho macOS 14+, chuyên biệt hóa cho 2 nhiệm vụ cốt lõi:

1. **Tìm kiếm siêu tốc (< 5ms) hàng chục nghìn thư mục Google Drive** (kế thừa và nâng cấp toàn bộ thuật toán từ `folder_search.py` — tìm phân cấp cha/con, gõ tiếng Việt không dấu, gõ tắt Acronym `sdh` → `02. SauDaiHoc`, dùng chung cache & lịch sử với `~/.config/alfred-scripts/`).
2. **Universal Actions & Convert to Markdown tối ưu dữ liệu cho AI đọc** — chuyển đổi mọi định dạng tài liệu (`.doc`, `.docx`, `.pdf`, `.xlsx`, `.pptx`, `.rtf`, `.html`, `.csv`, PDF scan dấu đỏ & ảnh chụp) thành Markdown sạch chuẩn NFC cho Claude / ChatGPT / Gemini / NotebookLM, vừa tạo file `.md` cạnh file gốc vừa tự động Copy vào Clipboard.

## 📥 Tải về & Tự động Cập nhật

- **Bản phát hành mới nhất (DMG & ZIP):** https://github.com/hungmtuci/DriveBar/releases/latest
- **Tự động cập nhật 1 chạm (1-Click Auto-Update):** Tự động kiểm tra bản mới trên GitHub Releases khi khởi động; bấm **Kiểm tra cập nhật / Tự động cập nhật** ngay trên thanh tiêu đề **Cài đặt**, **Menu Bar** hoặc chân cửa sổ tìm kiếm để tự tải gói `.zip`, gỡ Gatekeeper (`xattr -cr`), nâng cấp vào `/Applications/DriveBar.app` và khởi động lại.
- **Ẩn / Hiện linh hoạt trên thanh Dock:** Chuyển đổi tức thời giữa chế độ **Hiện trên thanh Dock & Menu Bar** (hỗ trợ kéo thả file trực tiếp vào icon Dock để Convert sang Markdown) và **Ẩn khỏi thanh Dock (Chỉ Menu Bar)** ngay bằng nút bấm trên cửa sổ Tìm kiếm, Cài đặt hoặc Menu Bar mà không cần khởi động lại ứng dụng.

---

## ✨ Điểm mới trong v1.2.0

- **Real-time `FSEvents` & Đa tài khoản Google Drive:** Tự động cập nhật chỉ mục ngay tức thì khi tạo mới, đổi tên hoặc xóa thư mục trên Finder mà không cần chờ quét lại 90.000 mục; hỗ trợ gộp hoặc chọn riêng từng tài khoản `GoogleDrive-*`.
- **Convert trực tiếp `.gdoc`, `.gsheet`, `.gslides` & Đường dẫn Web (`URL`) sang Markdown:** Tự trích `doc_id` xuất Markdown / bảng biểu CSV cho file Google Workspace trực tuyến; dán link hoặc bôi đen URL bất kỳ nhấn `⌘⇧A` để lọc sạch bài viết Web / GitHub sang Markdown chuẩn AI.
- **Khung cấu trúc XML `<documents><document>` & Smart Chunking (`H1/H2`):** Tối ưu ngữ cảnh nhiều tài liệu cho Claude / Gemini và tự chia nhỏ tài liệu siêu dài thành thư mục `_Chunks/` kèm `00_INDEX.md`.
- **Báo tiến trình tải file *Online-Only* từ Cloud:** Tự phát hiện cờ `SF_DATALESS` trên APFS CloudStorage và hiển thị tiến trình tải về trước khi chạy OCR/Convert.
- **Đồng bộ P2P qua `~/Sync/` (Syncthing) & Học thói quen Action Latching:** Đồng bộ lịch sử thư mục mở gần đây (`⌘1–⌘9`), cài đặt và thứ tự Universal Actions hay dùng giữa **iMac** và **MacBook Pro** (tự ánh xạ đường dẫn tương đối giữa các tên user macOS khác nhau) + CI/CD GitHub Actions tự động đóng gói Release.

---

## ⌨️ Phím tắt Toàn cục (Tự thiết lập tự do • Mặc định `⌘ Space`)

Bạn có thể tự thu bất kỳ tổ hợp phím nào ngay trong **Cài đặt**, bấm vào nút **`⌘Space`** ở góc dưới cửa sổ tìm kiếm, hoặc chọn nhanh từ **Menu Bar**:

| Phím tắt (Tự thiết lập tùy ý) | Chức năng |
| :--- | :--- |
| **`⌘ Space` (Mặc định)** | Mở / Ẩn thanh tìm kiếm Google Drive siêu tốc (hiện ngay 9 thư mục gần đây `⌘1–⌘9`) |
| **`⌘ ⇧ A`** | Mở bảng **Universal Actions** trên file đang chọn trong Finder hoặc đoạn văn bản đang bôi đen |
| **`⇥` (Tab)** hoặc **`⇧ ↩`** | Mở Universal Actions (Convert sang Markdown, PDF, Google Drive, Ẩn/Hiện...) ngay từ kết quả tìm kiếm |
| **`↩` (Enter)** | Duyệt sâu vào bên trong thư mục (Browse Mode) hoặc thực thi hành động đang chọn |
| **`⌘ ↩`** | Mở vị trí tệp / thư mục trực tiếp trong Finder (`Reveal in Finder`) |
| **`⌥ ↩`** | Trên kết quả GDrive: Copy link chia sẻ • Trên `Convert to Markdown`: Chỉ Copy Markdown vào Clipboard |
| **`⌃ ↩`** | Mở trực tiếp tệp / thư mục trên trình duyệt Google Drive Web |
| **`⌘ Y`** | Bật cửa sổ Xem nhanh Quick Look |
| **`⌥ ↑` / `⌥ ↓` / `⌥ →` / `⌥ ⌫`** | Thêm file vào **File Buffer** và thực hiện Universal Actions / Gộp 1 file AI `.md` hàng loạt |

---

## 🧠 Động cơ Hybrid Convert sang Markdown (4 tầng tự động)

1. **`AI Document Toolkit` (`PyMuPDF4LLM` + `MarkItDown`)**: Giữ nguyên bảng biểu phức tạp và cấu trúc tiêu đề chuẩn cho `.pdf`, `.docx`, `.xlsx`, `.pptx`.
2. **`LibreOffice Headless` (`soffice`)**: Chuyển mượt các định dạng văn bản hành chính cũ (`.doc`, `.xls`, `.ppt`, `.rtf`, `.odt`).
3. **`Apple Vision Neural OCR` (`vi-VN` + `en-US`)**: Tự động nhận diện trang PDF scan (văn bản đóng dấu đỏ không có lớp text) và hình ảnh (`.png`, `.jpg`, `.heic`) sang tiếng Việt có dấu chuẩn xác.
4. **`Native Swift HTML/Table/PDFKit Engine`**: Cơ chế dự phòng tích hợp sẵn trong ứng dụng giúp DriveBar vẫn hoạt động độc lập 100% trên mọi máy Mac mới.

---

## 🛠️ Biên dịch & Đóng gói

```bash
cd /Users/hunglx/Documents/antigravity/BuildApp/DriveBar
chmod +x build_drivebar.sh
./build_drivebar.sh
```

Sản phẩm sau khi đóng gói:
- Ứng dụng Universal Binary (`arm64` + `x86_64`): `./DriveBar.app` (đồng bộ ra `../DriveBar.app`)
- Bộ cài `.dmg` và `.zip`: `./dist/DriveBar-Installer-v1.1.0.dmg` và `./dist/DriveBar-v1.1.0-macOS.zip`
