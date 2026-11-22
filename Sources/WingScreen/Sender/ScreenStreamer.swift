import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import CoreVideo
import CGVirtualDisplayKit
import WingScreenShared

enum StreamError: LocalizedError {
    case displayNotFound
    var errorDescription: String? { tr("Không tìm thấy màn hình ảo trong danh sách ScreenCaptureKit (kiểm tra quyền Ghi màn hình)", "The virtual display isn't visible to ScreenCaptureKit (check the Screen Recording permission)") }
}

/// Chế độ chẩn đoán (tìm nguyên nhân treo máy), đặt bằng Terminal rồi mở lại app:
///   defaults write vn.wingscreen.WingScreen diag -int N     (xoá: defaults delete vn.wingscreen.WingScreen diag)
///   1 = chỉ tạo màn hình ảo · 2 = quay nhưng không nén · 3 = quay BGRA + nén bằng CPU · 4 = quay NV12 + nén bằng CPU
enum Diag {
    static let mode = UserDefaults.standard.integer(forKey: "diag")
    static var softwareEncoder: Bool { mode == 3 || mode == 4 }
}

/// Quay màn hình ảo bằng ScreenCaptureKit và mã hoá phần cứng H.264/HEVC.
final class ScreenStreamer: NSObject, SCStreamOutput, SCStreamDelegate {
    private let displayID: CGDirectDisplayID
    private let width: Int
    private let height: Int
    private let config: SenderConfig
    private let conn: FramedConnection
    private let encoder: VideoEncoder

    private let captureQueue = DispatchQueue(label: "wingscreen.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var displayStream: NSObject?          // CGDisplayStream (máy cũ / dự phòng)
    private var lastPixelBuffer: CVPixelBuffer?   // chỉ dùng trên captureQueue
    private var pendingDrop = false               // có khung bị bỏ do mạng chậm
    private var timer: DispatchSourceTimer?
    private var capturedFrames = 0                // chỉ dùng trên captureQueue
    private var scCallbacks = 0                   // số lần ScreenCaptureKit gọi về (kể cả khung trống)
    private var lastCountLog = Date()

    /// Gọi khi người dùng bấm "Stop Sharing" của macOS
    var onUserStopped: (() -> Void)?

    /// Số gói tối đa cho phép đang chờ gửi trước khi bỏ khung hình
    private let maxInFlight = 3

    init(displayID: CGDirectDisplayID, width: Int, height: Int, config: SenderConfig, connection: FramedConnection) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.config = config
        self.conn = connection
        self.encoder = VideoEncoder(width: width, height: height, fps: config.fps,
                                    bitrateMbps: config.bitrateMbps, hevc: config.hevc,
                                    lowLatency: !config.useCompat && !Diag.softwareEncoder,
                                    software: Diag.softwareEncoder)
        super.init()
        encoder.onParameterSets = { [weak self] data in self?.conn.send(.format, data) }
        encoder.onFrame = { [weak self] data in self?.conn.send(.frame, data) }
    }

    func start() async throws {
        // Máy cũ (macOS 12): ScreenCaptureKit có thể không gửi khung hình nào từ màn hình ảo -> dùng CGDisplayStream
        if config.useCompat || Diag.mode == 5 {
            if startDisplayStream() {
                startTimer()
                return
            }
            wsLog(tr("CGDisplayStream không chạy được — thử ScreenCaptureKit", "CGDisplayStream didn't start — trying ScreenCaptureKit"))
        }

        var scDisplay: SCDisplay?
        for _ in 0..<20 {   // màn hình mới có thể mất vài trăm ms mới xuất hiện
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scDisplay else { throw StreamError.displayNotFound }

        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        cfg.width = width
        cfg.height = height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.fps))
        cfg.pixelFormat = Diag.mode == 3 ? kCVPixelFormatType_32BGRA
                                         : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // NV12 — đưa thẳng vào encoder
        if Diag.mode != 0 {
            wsLog(tr("[Chẩn đoán \(Diag.mode)] đang bật", "[Diagnostic \(Diag.mode)] enabled"))
        }
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = config.useCompat ? 3 : 5
        cfg.showsCursor = true
        if #available(macOS 13.0, *) {
            cfg.capturesAudio = false
        }

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await s.startCapture()
        stream = s
        wsLog(tr("Đang quay bằng ScreenCaptureKit", "Capturing with ScreenCaptureKit"))
        startTimer()

        // Dự phòng: sau 3 giây vẫn chưa có khung hình nào -> chuyển sang CGDisplayStream
        captureQueue.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.capturedFrames == 0, self.displayStream == nil, let old = self.stream else { return }
            wsLog(tr("ScreenCaptureKit chưa gửi khung hình nào sau 3 giây (\(self.scCallbacks) lần gọi về) — chuyển sang CGDisplayStream",
                     "ScreenCaptureKit sent no frames in 3 seconds (\(self.scCallbacks) callbacks) — switching to CGDisplayStream"))
            self.stream = nil
            Task { try? await old.stopCapture() }
            if !self.startDisplayStream() {
                wsLog(tr("Không quay được màn hình ảo bằng cả hai cách", "Couldn't capture the virtual display either way"))
            }
        }
    }

    /// Quay bằng CGDisplayStream (gọi được từ mọi luồng)
    private func startDisplayStream() -> Bool {
        guard let ds = WSStartDisplayStream(displayID, width, height, Double(config.fps), captureQueue, { [weak self] surface in
            self?.handleSurface(surface)
        }) else { return false }
        displayStream = ds
        wsLog(tr("Đang quay bằng CGDisplayStream", "Capturing with CGDisplayStream"))
        return true
    }

    private func handleSurface(_ surface: IOSurfaceRef) {
        var out: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface, nil, &out) == kCVReturnSuccess,
              let pixelBuffer = out?.takeRetainedValue() else { return }
        deliver(pixelBuffer)
    }

    func stop() async {
        timer?.cancel()
        timer = nil
        if let ds = displayStream { WSStopDisplayStream(ds) }
        displayStream = nil
        try? await stream?.stopCapture()
        stream = nil
        captureQueue.sync {
            lastPixelBuffer = nil
            encoder.invalidate()
        }
    }

    func requestKeyframe() {
        captureQueue.async {
            self.encoder.forceKeyframe()
            if let pb = self.lastPixelBuffer { self.encode(pb, allowDrop: false) }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        scCallbacks += 1
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        deliver(pixelBuffer)
    }

    /// Nhận một khung hình đã quay (trên captureQueue) và đưa vào bộ nén
    private func deliver(_ pixelBuffer: CVPixelBuffer) {
        capturedFrames += 1
        if capturedFrames == 1 {
            let source = displayStream != nil ? "CGDisplayStream" : "ScreenCaptureKit"
            wsLog(tr("Đã nhận khung hình đầu tiên (\(source))", "Got the first frame (\(source))"))
        } else if Date().timeIntervalSince(lastCountLog) > 5 {
            lastCountLog = Date()
            wsLog(tr("Đã quay \(capturedFrames) khung hình", "Captured \(capturedFrames) frames"))
        }
        if Diag.mode == 2 { return }          // chẩn đoán: quay nhưng không nén
        lastPixelBuffer = pixelBuffer
        encode(pixelBuffer, allowDrop: true)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if let e = error as? SCStreamError, e.code == .userStopped {
            // Người dùng bấm "Stop Sharing" trên thanh menu của macOS -> dừng chia sẻ hẳn
            wsLog(tr("Người dùng đã bấm Stop Sharing", "User pressed Stop Sharing"))
            onUserStopped?()
            return
        }
        wsLog(tr("[WingScreen] Luồng quay dừng: \(error.localizedDescription)", "[WingScreen] Capture stream stopped: \(error.localizedDescription)"))
        conn.cancel()
    }

    // MARK: Mã hoá

    private func encode(_ pixelBuffer: CVPixelBuffer, allowDrop: Bool) {
        if allowDrop && conn.inFlight > maxInFlight {
            // Mạng không theo kịp: bỏ khung này TRƯỚC khi mã hoá (không làm hỏng chuỗi P-frame)
            pendingDrop = true
            return
        }
        pendingDrop = false
        encoder.encode(pixelBuffer, pts: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    /// Khi màn hình đứng yên, ScreenCaptureKit không gửi khung mới.
    /// Nếu khung cuối từng bị bỏ, gửi lại để máy phụ không bị kẹt ảnh cũ.
    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: captureQueue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        t.setEventHandler { [weak self] in
            guard let self, self.pendingDrop, self.conn.inFlight <= self.maxInFlight,
                  let pb = self.lastPixelBuffer else { return }
            self.encode(pb, allowDrop: true)
        }
        t.resume()
        timer = t
    }
}

/// Bộ mã hoá phần cứng VideoToolbox, chế độ độ trễ thấp.
final class VideoEncoder {
    private var session: VTCompressionSession?
    private let hevc: Bool
    private var forceKey = true
    private var loggedEncodeError = false
    private var loggedFirstOutput = false

    var onParameterSets: ((Data) -> Void)?
    var onFrame: ((Data) -> Void)?

    init(width: Int, height: Int, fps: Int, bitrateMbps: Double, hevc: Bool, lowLatency: Bool = true, software: Bool = false) {
        self.hevc = hevc

        // Thử lần lượt: phần cứng + độ trễ thấp -> phần cứng thường -> để macOS tự chọn (có thể là phần mềm).
        // Máy Intel đời cũ (thường chạy macOS 12) không hỗ trợ chế độ độ trễ thấp: trước đây tạo bộ nén thất bại
        // mà không báo gì, máy phụ đứng mãi ở "đang chờ hình ảnh".
        let codec = hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        let codecName = hevc ? "HEVC" : "H.264"
        var attempts: [(String, [CFString: Any])] = []
        if software {
            attempts.append((tr("CPU (phần mềm)", "CPU (software)"),
                             [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false]))
        }
        if !hevc && lowLatency && !software {
            attempts.append((tr("phần cứng, độ trễ thấp", "hardware, low latency"),
                             [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                              kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true]))
        }
        attempts.append((tr("phần cứng", "hardware"),
                         [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]))
        attempts.append((tr("tự chọn (có thể bằng CPU)", "automatic (may use the CPU)"), [:]))

        var created: VTCompressionSession?
        for (label, spec) in attempts {
            var s: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width), height: Int32(height),
                codecType: codec,
                encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil,
                compressionSessionOut: &s)
            if status == noErr, let s {
                wsLog(tr("Bộ nén \(codecName) \(width)×\(height): \(label)",
                         "\(codecName) encoder \(width)×\(height): \(label)"))
                created = s
                break
            }
            wsLog(tr("Không tạo được bộ nén (\(label)): lỗi \(status)", "Couldn't create the encoder (\(label)): error \(status)"))
        }
        guard let s = created else {
            wsLog(tr("Không có bộ nén video nào chạy được ở \(width)×\(height) — thử giảm Độ phân giải hoặc tắt HEVC",
                     "No video encoder works at \(width)×\(height) — try a lower Resolution or turn off HEVC"))
            return
        }

        func set(_ key: CFString, _ value: Any) {
            let st = VTSessionSetProperty(s, key: key, value: value as AnyObject)
            if st != noErr { wsLog(tr("Bỏ qua thuộc tính bộ nén \(key): \(st)", "Skipping encoder property \(key): \(st)")) }
        }
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_ProfileLevel,
            hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, Int(bitrateMbps * 1_000_000))
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 4)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 4)
        VTCompressionSessionPrepareToEncodeFrames(s)
        session = s
    }

    func forceKeyframe() { forceKey = true }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let session else { return }
        var props: CFDictionary?
        if forceKey {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            forceKey = false
        }
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props,
                                        infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            guard status == noErr, let sampleBuffer else {
                if status != noErr && !self.loggedEncodeError {
                    self.loggedEncodeError = true
                    wsLog(tr("Bộ nén báo lỗi khi nén khung hình: \(status)", "The encoder failed to encode a frame: \(status)"))
                }
                return
            }
            self.output(sampleBuffer)
        }
    }

    private func output(_ sb: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [NSDictionary]
        let notSync = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false
        let isKey = !notSync

        if isKey, let fmt = CMSampleBufferGetFormatDescription(sb),
           let ps = ParameterSets(formatDescription: fmt, hevc: hevc) {
            onParameterSets?(ps.encoded())
        }

        guard let block = CMSampleBufferGetDataBuffer(sb) else { return }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length + 1)
        data[0] = isKey ? 1 : 0
        data.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length,
                                           destination: raw.baseAddress!.advanced(by: 1))
        }
        if !loggedFirstOutput {
            loggedFirstOutput = true
            wsLog(tr("Bộ nén đã ra khung hình đầu tiên (\(length) byte)", "The encoder produced its first frame (\(length) bytes)"))
        }
        onFrame?(data)
    }
}

// Các trạng thái của ScreenStreamer chỉ được đụng tới trên captureQueue -> an toàn khi dùng trong closure @Sendable
extension ScreenStreamer: @unchecked Sendable {}
