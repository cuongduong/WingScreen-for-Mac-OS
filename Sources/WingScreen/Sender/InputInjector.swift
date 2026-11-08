import CoreGraphics
import Foundation
import WingScreenShared

/// Nhận sự kiện chuột/bàn phím từ máy phụ và phát lại trên máy chính
/// (toạ độ được ánh xạ vào vùng màn hình ảo). Cần quyền Trợ năng.
final class InputInjector {
    private let displayID: CGDirectDisplayID
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonsDown = Set<Int>()
    private var lastPoint = CGPoint.zero
    private var scrollRemainderX = 0.0
    private var scrollRemainderY = 0.0

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        return CGPoint(x: b.minX + cx * (b.width - 1), y: b.minY + cy * (b.height - 1))
    }

    func handle(_ event: InputEvent) {
        switch event {
        case let .move(x, y):
            let p = point(x, y)
            lastPoint = p
            let type: CGEventType
            let button: CGMouseButton
            if buttonsDown.contains(0) { type = .leftMouseDragged; button = .left }
            else if buttonsDown.contains(1) { type = .rightMouseDragged; button = .right }
            else if !buttonsDown.isEmpty { type = .otherMouseDragged; button = .center }
            else { type = .mouseMoved; button = .left }
            post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button))

        case let .button(index, down, clicks, x, y):
            let p = point(x, y)
            lastPoint = p
            let type: CGEventType
            let button: CGMouseButton
            switch index {
            case 0: type = down ? .leftMouseDown : .leftMouseUp; button = .left
            case 1: type = down ? .rightMouseDown : .rightMouseUp; button = .right
            default: type = down ? .otherMouseDown : .otherMouseUp; button = CGMouseButton(rawValue: UInt32(index)) ?? .center
            }
            if down { buttonsDown.insert(index) } else { buttonsDown.remove(index) }
            let ev = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
            ev?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clicks, 1)))
            if index >= 2 { ev?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(index)) }
            post(ev)

        case let .scroll(dx, dy, precise):
            // Cộng dồn phần lẻ để cuộn mượt bằng trackpad
            scrollRemainderX += dx
            scrollRemainderY += dy
            let ix = Int32(scrollRemainderX.rounded(.towardZero))
            let iy = Int32(scrollRemainderY.rounded(.towardZero))
            scrollRemainderX -= Double(ix)
            scrollRemainderY -= Double(iy)
            guard ix != 0 || iy != 0 else { return }
            let ev = CGEvent(scrollWheelEvent2Source: source, units: precise ? .pixel : .line,
                             wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0)
            ev?.location = lastPoint
            post(ev)

        case let .key(code, down, flags):
            let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            ev?.flags = CGEventFlags(rawValue: flags)
            post(ev)

        case let .modifier(code, flags):
            let ev = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)
            ev?.type = .flagsChanged
            ev?.flags = CGEventFlags(rawValue: flags)
            post(ev)
        }
    }

    /// Nhả mọi phím/nút đang giữ khi mất kết nối (tránh kẹt chuột).
    func releaseAll() {
        for index in buttonsDown {
            handle(.button(index: index, down: false, clicks: 1, x: 0, y: 0))
        }
        buttonsDown.removeAll()
        let ev = CGEvent(source: source)
        ev?.type = .flagsChanged
        ev?.flags = []
        post(ev)
    }

    private func post(_ event: CGEvent?) {
        event?.post(tap: .cghidEventTap)
    }
}
