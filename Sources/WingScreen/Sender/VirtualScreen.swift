import CoreGraphics
import Foundation
import CGVirtualDisplayKit
import WingScreenShared

/// Màn hình ảo trên máy chính, giả lập đúng kích thước màn hình MacBook Pro 16" 2019.
final class VirtualScreen {
    private let display: NSObject
    let displayID: CGDirectDisplayID
    let pointWidth: Int
    let pointHeight: Int
    let hiDPI: Bool

    init?(name: String, pointWidth: Int, pointHeight: Int, hiDPI: Bool, refreshRate: Double) {
        let scale = hiDPI ? 2 : 1
        let pixelW = pointWidth * scale
        let pixelH = pointHeight * scale
        // Kích thước vật lý giả định ~226 ppi (màn Retina 16" 2019: 3072x1920 ≈ 345 x 215 mm)
        let mm = CGSize(width: Double(pointWidth * 2) / 226.0 * 25.4,
                        height: Double(pointHeight * 2) / 226.0 * 25.4)

        guard let d = WSCreateVirtualDisplay(name,
                                             UInt32(pointWidth), UInt32(pointHeight),
                                             UInt32(pixelW), UInt32(pixelH),
                                             refreshRate, hiDPI, mm) else { return nil }
        let id = WSVirtualDisplayGetID(d)
        guard id != 0 else { return nil }

        self.display = d
        self.displayID = id
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.hiDPI = hiDPI
    }

    /// Bảo đảm màn hình ảo là màn hình MỞ RỘNG, không nằm trong nhóm phát trùng (mirror).
    /// macOS (thấy rõ trên macOS 12) có thể tự đặt màn hình mới ở chế độ "Mirror Built-in Display";
    /// khi đó không quay được hình riêng và máy phụ đứng ở "đang chờ hình ảnh".
    /// Trả về true nếu đã phải đổi cấu hình màn hình.
    @discardableResult
    func ensureExtended() -> Bool {
        guard CGDisplayIsInMirrorSet(displayID) != 0 else { return false }
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for id in ids.prefix(Int(count)) {
            let master = CGDisplayMirrorsDisplay(id)
            // màn hình ảo đang phát trùng màn hình khác, hoặc màn hình khác đang phát trùng màn hình ảo
            if (id == displayID && master != kCGNullDirectDisplay) || master == displayID {
                CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
            }
        }
        let err = CGCompleteDisplayConfiguration(config, .forSession)
        wsLog(err == .success
              ? tr("Màn hình ảo đang ở chế độ phát trùng (Mirror) — đã chuyển sang mở rộng", "The virtual display was mirrored — switched it to extended")
              : tr("Màn hình ảo đang ở chế độ phát trùng, không chuyển được: \(err.rawValue)", "The virtual display is mirrored and couldn't be switched: \(err.rawValue)"))
        return err == .success
    }

    /// Chọn chế độ hiển thị có đúng kích thước point mong muốn (ưu tiên HiDPI).
    func selectMode() {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
        let wantScale = hiDPI ? 2 : 1
        let match = modes.first {
            $0.width == pointWidth && $0.height == pointHeight && $0.pixelWidth == pointWidth * wantScale
        } ?? modes.first { $0.width == pointWidth && $0.height == pointHeight }
        if let match, CGDisplayCopyDisplayMode(displayID)?.ioDisplayModeID != match.ioDisplayModeID {
            CGDisplaySetDisplayMode(displayID, match, nil)
        }
    }
}
