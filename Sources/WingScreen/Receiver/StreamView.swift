import AppKit
import AVFoundation
import CoreMedia
import WingScreenShared

/// Bộ hiển thị khung hình: macOS 14+ dùng AVSampleBufferVideoRenderer,
/// macOS 12–13 dùng trực tiếp AVSampleBufferDisplayLayer.
protocol FrameRenderer: AnyObject {
    var status: AVQueuedSampleBufferRenderingStatus { get }
    var requiresFlushToResumeDecoding: Bool { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer)
    func flush()
}

extension AVSampleBufferDisplayLayer: FrameRenderer {}

@available(macOS 14.0, *)
extension AVSampleBufferVideoRenderer: FrameRenderer {}

/// Đưa khung hình nén vào bộ hiển thị (giải mã phần cứng).
final class VideoSink {
    private let renderer: FrameRenderer
    private var format: CMVideoFormatDescription?
    private var waitingForKey = true
    private let lock = NSLock()

    var onNeedKeyframe: (() -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    init(renderer: FrameRenderer) {
        self.renderer = renderer
    }

    func setFormat(_ ps: ParameterSets) {
        guard let fmt = ps.makeFormatDescription() else { return }
        lock.lock(); format = fmt; lock.unlock()
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        onVideoSize?(CGSize(width: Int(dims.width), height: Int(dims.height)))
    }

    func reset() {
        lock.lock(); format = nil; waitingForKey = true; lock.unlock()
        renderer.flush()
    }

    func enqueue(_ payload: Data) {
        guard payload.count > 1 else { return }
        let isKey = payload.first == 1

        lock.lock()
        let fmt = format
        let skip = waitingForKey && !isKey
        lock.unlock()

        if skip { return }
        guard let fmt else { onNeedKeyframe?(); return }

        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            lock.lock(); waitingForKey = true; lock.unlock()
            onNeedKeyframe?()
            if !isKey { return }
        }
        lock.lock(); waitingForKey = false; lock.unlock()

        let length = payload.count - 1
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: length, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: length,
                                                 flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        payload.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!.advanced(by: 1), blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: length)
        }

        var sample: CMSampleBuffer?
        var size = length
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: fmt, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr,
              let sample else { return }

        // Hiển thị ngay khi giải mã xong, không theo đồng hồ phát
        if let arr = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample)
    }
}

/// View toàn màn hình: hiển thị video và bắt chuột/bàn phím để gửi về máy chính.
final class StreamView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private(set) var sink: VideoSink!
    private let statusLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var videoSize = CGSize(width: 16, height: 10)
    private var cursorHidden = false

    var onInput: ((InputEvent) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer = CALayer()
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        displayLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(displayLayer)

        if #available(macOS 14.0, *) {
            sink = VideoSink(renderer: displayLayer.sampleBufferRenderer)
        } else {
            sink = VideoSink(renderer: displayLayer)
        }
        sink.onVideoSize = { [weak self] size in
            DispatchQueue.main.async { self?.videoSize = size }
        }

        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 22, weight: .medium)
        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8),
        ])
        showStatus(tr("WingScreen\n\nThoát: ⌃⌥⌘X", "WingScreen\n\nQuit: ⌃⌥⌘X"))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// nil = ẩn thông báo và con trỏ (đang có hình từ máy chính)
    func showStatus(_ text: String?) {
        if let text {
            statusLabel.stringValue = text + tr("\n\nThoát: ⌃⌥⌘X   ·   Giới thiệu: ⌃⌥⌘I\nGiữ ⌥ Option khi mở app để đổi vai trò máy này", "\n\nQuit: ⌃⌥⌘X   ·   About: ⌃⌥⌘I\nHold ⌥ Option while opening the app to change this computer's role")
            statusLabel.isHidden = false
            if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        } else {
            statusLabel.isHidden = true
            // Con trỏ của máy chính đã được vẽ sẵn trong video
            if !cursorHidden { NSCursor.hide(); cursorHidden = true }
        }
    }

    // MARK: Toạ độ

    private func normalized(_ event: NSEvent) -> (Double, Double) {
        let p = convert(event.locationInWindow, from: nil)
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard rect.width > 0, rect.height > 0 else { return (0, 0) }
        let x = (p.x - rect.minX) / rect.width
        let y = 1 - (p.y - rect.minY) / rect.height   // đổi gốc sang góc trên-trái
        return (min(max(x, 0), 1), min(max(y, 0), 1))
    }

    // MARK: Chuột

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    private func sendMove(_ e: NSEvent) {
        let (x, y) = normalized(e)
        onInput?(.move(x: x, y: y))
    }

    private func sendButton(_ e: NSEvent, index: Int, down: Bool) {
        let (x, y) = normalized(e)
        onInput?(.button(index: index, down: down, clicks: e.clickCount, x: x, y: y))
    }

    override func mouseMoved(with e: NSEvent) { sendMove(e) }
    override func mouseDragged(with e: NSEvent) { sendMove(e) }
    override func rightMouseDragged(with e: NSEvent) { sendMove(e) }
    override func otherMouseDragged(with e: NSEvent) { sendMove(e) }
    override func mouseDown(with e: NSEvent) {
        // Ẩn lại con trỏ sau khi đóng cửa sổ Giới thiệu (đang có hình thì con trỏ đã nằm trong video)
        if statusLabel.isHidden && !cursorHidden { NSCursor.hide(); cursorHidden = true }
        sendButton(e, index: 0, down: true)
    }
    override func mouseUp(with e: NSEvent) { sendButton(e, index: 0, down: false) }
    override func rightMouseDown(with e: NSEvent) { sendButton(e, index: 1, down: true) }
    override func rightMouseUp(with e: NSEvent) { sendButton(e, index: 1, down: false) }
    override func otherMouseDown(with e: NSEvent) { sendButton(e, index: e.buttonNumber, down: true) }
    override func otherMouseUp(with e: NSEvent) { sendButton(e, index: e.buttonNumber, down: false) }

    override func scrollWheel(with e: NSEvent) {
        onInput?(.scroll(dx: Double(e.scrollingDeltaX), dy: Double(e.scrollingDeltaY),
                         precise: e.hasPreciseScrollingDeltas))
    }

    // MARK: Bàn phím

    private func flags(_ e: NSEvent) -> UInt64 {
        UInt64(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)
    }

    private func isQuitShortcut(_ e: NSEvent) -> Bool {
        let m = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return e.keyCode == 7 && m.contains([.control, .option, .command])   // ⌃⌥⌘X
    }

    private func isAboutShortcut(_ e: NSEvent) -> Bool {
        let m = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return e.keyCode == 34 && m.contains([.control, .option, .command])  // ⌃⌥⌘I
    }

    override func keyDown(with e: NSEvent) {
        if isQuitShortcut(e) { NSApp.terminate(nil); return }
        if isAboutShortcut(e) {
            if cursorHidden { NSCursor.unhide(); cursorHidden = false }   // để bấm được cửa sổ Giới thiệu
            showAboutPanel()
            return
        }
        onInput?(.key(code: e.keyCode, down: true, flags: flags(e)))
    }

    override func keyUp(with e: NSEvent) {
        onInput?(.key(code: e.keyCode, down: false, flags: flags(e)))
    }

    override func flagsChanged(with e: NSEvent) {
        onInput?(.modifier(code: e.keyCode, flags: flags(e)))
    }

    // Chuyển cả tổ hợp ⌘ + phím sang máy chính thay vì xử lý tại chỗ
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.type == .keyDown else { return false }
        keyDown(with: e)
        return true
    }
}
