// Cầu nối tới API riêng (private) CGVirtualDisplay của CoreGraphics.
// Đây là cơ chế mà DeskPad, BetterDisplay, Chromium... dùng để tạo màn hình ảo.
// Các lớp được tra cứu lúc chạy (NSClassFromString) nên không cần symbol lúc link.
// Lưu ý: API không công khai, có thể thay đổi ở các bản macOS sau.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Tạo một màn hình ảo. Trả về nil nếu thất bại.
/// Giữ tham chiếu tới đối tượng trả về — khi nó bị giải phóng, màn hình ảo biến mất.
/// - pointWidth/pointHeight: kích thước theo point (ví dụ 1536 x 960)
/// - pixelWidth/pixelHeight: kích thước pixel tối đa (ví dụ 3072 x 1920 khi HiDPI)
NSObject *_Nullable WSCreateVirtualDisplay(NSString *name,
                                            uint32_t pointWidth,
                                            uint32_t pointHeight,
                                            uint32_t pixelWidth,
                                            uint32_t pixelHeight,
                                            double refreshRate,
                                            BOOL hiDPI,
                                            CGSize sizeInMillimeters);

/// Lấy CGDirectDisplayID của màn hình ảo đã tạo (0 nếu lỗi).
CGDirectDisplayID WSVirtualDisplayGetID(NSObject *display);

NS_ASSUME_NONNULL_END

// ---------------------------------------------------------------------------
// Quay màn hình bằng CGDisplayStream (API cũ, có từ macOS 10.8).
// Dùng cho máy cũ (macOS 12) khi ScreenCaptureKit không gửi khung hình nào từ màn hình ảo.
// Các hàm được tra cứu lúc chạy (dlsym) nên không phụ thuộc chú thích "deprecated" của SDK mới.
// ---------------------------------------------------------------------------
#import <IOSurface/IOSurfaceRef.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^WSDisplayFrameHandler)(IOSurfaceRef surface);

/// Bắt đầu quay `display`, xuất khung NV12 kích thước width×height. Trả về nil nếu lỗi.
/// Giữ đối tượng trả về; gọi WSStopDisplayStream để dừng.
NSObject *_Nullable WSStartDisplayStream(CGDirectDisplayID display, size_t width, size_t height,
                                         double fps, dispatch_queue_t queue, WSDisplayFrameHandler handler);

void WSStopDisplayStream(NSObject *stream);

NS_ASSUME_NONNULL_END
