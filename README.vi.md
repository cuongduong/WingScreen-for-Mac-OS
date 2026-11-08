# WingScreen — dùng một máy tính làm màn hình phụ cho máy khác

[English](README.md) · **Tiếng Việt**

Một mã nguồn, hai bản cài đặt. Mỗi bản có **cả hai vai trò**, chọn khi mở app:

| | **Máy chính (phát)** | **Màn hình phụ (nhận)** |
|---|---|---|
| **WingScreen.app** — macOS 12.3+, Intel & Apple Silicon | Tự tạo màn hình ảo, quay + nén phần cứng | Toàn màn hình, giải mã phần cứng |
| **WingScreen.exe** — Windows 10/11 64‑bit (project **WingScreen-Windows** riêng) | Màn hình ảo qua Parsec VDD (hoặc phát màn hình có sẵn) | Toàn màn hình, giải mã phần cứng |

Mọi cặp đều dùng được: Mac → Mac, Mac → Windows, Windows → Mac, Windows → Windows.

```
Máy chính ──[màn hình ảo]→ quay → nén H.264/HEVC ──TCP──→ giải mã → toàn màn hình ── Màn hình phụ
Máy chính ←── giả lập chuột/phím ←───────────────── TCP ←── chuột, trackpad, bàn phím ── Màn hình phụ
```

## Build — cách 1: trên GitHub (GitHub Actions)
1. Tạo repo trên GitHub (có thể để Private) và đẩy toàn bộ thư mục này lên.
2. Vào tab **Actions → Build WingScreen (macOS) → Run workflow**.
3. Khoảng 10 phút sau, tải `WingScreen-macOS.zip` ở mục **Artifacts**. (Bản Windows build từ project WingScreen-Windows.)

Đẩy tag (ví dụ `git tag v2.0 && git push --tags`) thì GitHub tự tạo **Release** kèm file app để tải về máy khác.

## Build — cách 2: build trên máy của bạn
**macOS** (cần Command Line Tools hoặc Xcode):
```bash
./build.sh            # dist/WingScreen.app — universal (Intel + Apple Silicon)
./build.sh native     # chỉ cho loại chip của máy đang dùng (nhanh hơn)
```
**Windows:** xem project **WingScreen-Windows** — `build.bat` tạo bộ cài `WingScreen-Setup-x.y.exe` và bản 1 file `WingScreen-Portable-x.y.exe`.

## Sử dụng
1. Cài app lên cả hai máy:
   - **Mac:** chép `WingScreen.app` vào **Applications**. Lần đầu mở nếu bị chặn: chuột phải → **Open**, hoặc chạy `xattr -dr com.apple.quarantine /Applications/WingScreen.app`.
   - **Windows:** chạy bộ cài `WingScreen-Setup-x.y.exe` (tự mở Windows Firewall), hoặc dùng bản portable.
2. Mở app trên máy chính → chọn **Máy chính (phát)**. Mở app trên máy kia → chọn **Màn hình phụ (nhận)**.
3. Hai máy tự tìm nhau trong cùng mạng (Bonjour). Không tìm thấy thì nhập IP: chạy app với `--receiver --host <IP máy chính>`.
4. **Đổi vai trò:** Mac giữ **⌥ Option** khi mở app; Windows giữ **Shift** khi mở app (hoặc dùng nút/menu "Đổi vai trò…").

### Kết nối qua cáp (khuyên dùng)
- **Mac ↔ Mac:** dùng **cáp Thunderbolt 3/4 hoặc USB4 40Gbps** (có biểu tượng ⚡). Cáp sạc USB‑C thường không truyền được.
  Cắm xong, *System Settings → Network → Thunderbolt Bridge* phải báo **Connected**.
- Màn hình phụ (Mac) **mặc định dùng Wi‑Fi, cắm cáp thì tự chuyển sang cáp** (kiểm tra sau 3 giây rồi cứ 10 giây một lần).
  Rút cáp thì vài giây sau tự quay lại Wi‑Fi. Log ghi rõ đường đang dùng (`~/Library/Logs/WingScreen.log`).
- Khi mạng chập hoặc chuyển đường, máy chính giữ lại màn hình ảo 15 giây nên cửa sổ không bị dồn về màn hình chính.

### Máy chính là Mac
- Cấp quyền trong *System Settings → Privacy & Security*: **Screen & System Audio Recording** và **Accessibility** → bật WingScreen → thoát và mở lại app (hoặc khởi động lại máy).
- Chỉnh độ phân giải, bitrate, fps, HEVC, khởi động cùng máy trong menu ▭▭ trên thanh menu.

### Máy chính là Windows
- **Nên cài Parsec Virtual Display Driver** (miễn phí) để có màn hình ảo riêng, đúng kích thước máy phụ:
  [parsec-vdd-0.45.0.0.exe](https://builds.parsec.app/vdd/parsec-vdd-0.45.0.0.exe) (nếu lỗi trên máy cũ, dùng bản [0.41](https://builds.parsec.app/vdd/parsec-vdd-0.41.0.0.exe)).
  Bấm **Chạy quyền Admin** trong cửa sổ WingScreen để app đặt được độ phân giải tuỳ chỉnh.
- Không cài driver: chọn **Màn hình phát** là một màn hình có sẵn (màn hình thứ 2, hoặc màn hình chính = phát trùng).
  Mẹo: cắm một **HDMI dummy plug** (vài chục nghìn đồng) để Windows tưởng có thêm màn hình thật.
- Bộ nén tự chọn theo card đồ hoạ: NVIDIA NVENC / AMD AMF / Intel QuickSync; không có thì dùng CPU.

### Màn hình phụ
| | Mac | Windows |
|---|---|---|
| Thoát | ⌃⌥⌘X | Ctrl+Alt+Shift+X |
| Bật/tắt toàn màn hình | — | Ctrl+Alt+Shift+F |
| Đổi vai trò | giữ ⌥ khi mở app | Ctrl+Alt+Shift+R |

Bàn phím được đổi tự động: Ctrl trên Windows ↔ ⌘ trên Mac, nên Ctrl+C / ⌘C luôn là copy ở cả hai phía.

## Yêu cầu & giới hạn
- **macOS 12.3 trở lên** (Monterey). Bản cũ hơn không có ScreenCaptureKit nên không chạy được.
- **Windows 10/11 64‑bit.** Màn hình ảo cần Windows 10 bản 19H2 trở lên.
- Độ phân giải video tối đa 4096×2304 (giới hạn H.264), app tự giảm nếu vượt.
- Không truyền âm thanh. Nội dung chống quay (Netflix…) có thể bị đen.
- Trên Windows, cửa sổ chạy quyền Admin chỉ nhận chuột/phím từ máy phụ khi WingScreen cũng chạy quyền Admin.
- Mỗi lần build lại bản Mac, macOS có thể đòi cấp lại quyền Ghi màn hình/Trợ năng.

## Ngôn ngữ
Giao diện có **tiếng Việt** và **tiếng Anh**. Mặc định theo ngôn ngữ của macOS. Đổi ngôn ngữ:
- trong hộp chọn vai trò (hiện lần đầu mở app, hoặc khi giữ ⌥ lúc mở app): ô **Ngôn ngữ / Language**
- ở máy chính: menu ▭▭ → **Ngôn ngữ / Language** → Tự động / English / Tiếng Việt

## Icon
Đặt ảnh vào `icons/` rồi build lại — xem `icons/README.txt`. (Bản Windows: `assets/` trong project WingScreen-Windows.)

## Giới thiệu (About)
Nội dung cửa sổ Giới thiệu lấy từ file **`about.json`** ở thư mục gốc (project WingScreen-Windows có file `about.json` riêng, cùng định dạng):
`name`, `version`, `description`, `author`, `organization`, `website`, `email`, `copyright`, `notes` (danh sách dòng ghi chú).
Để trống `""` thì dòng đó không hiện. Sửa xong thì build lại.

- **Phiên bản khi build:** mặc định lấy `version` trong `about.json`; ghi đè bằng biến môi trường
  `WINGSCREEN_VERSION=2.1 ./build.sh` (Mac) hoặc `set WINGSCREEN_VERSION=2.1` rồi chạy `build.bat` (Windows).
  GitHub Actions build từ tag `v2.1` thì tự đặt phiên bản 2.1. Ngày build được thêm tự động.
- Phiên bản, tên, bản quyền cũng được ghi vào Info.plist (Mac) và Properties → Details của file exe (Windows).
- Mở cửa sổ Giới thiệu:

| | Mac | Windows |
|---|---|---|
| Máy chính | menu ▭▭ → Giới thiệu… | nút **Giới thiệu…** |
| Màn hình phụ | ⌃⌥⌘I | Ctrl+Alt+Shift+I |
| Hộp chọn vai trò | — | nút **Giới thiệu…** |

## Cấu trúc mã nguồn
```
Sources/WingScreen/        app Mac (main.swift chọn vai trò, Sender/, Receiver/)
Sources/WingScreenShared/  giao thức mạng
Sources/CGVirtualDisplayKit/  tạo màn hình ảo trên Mac (API riêng CGVirtualDisplay)
.github/workflows/        build tự động bản macOS
```
