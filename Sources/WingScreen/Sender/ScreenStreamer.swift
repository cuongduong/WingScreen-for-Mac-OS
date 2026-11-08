import Foundation
import ScreenCaptureKit
import VideoToolbox
import CoreMedia
import WingScreenShared

enum StreamError: LocalizedError {
    case displayNotFound
    var errorDescription: String? { tr("Không tìm thấy màn hình ảo trong danh sách ScreenCaptureKit (kiểm tra quyền Ghi màn hình)", "The virtual display isn't visible to ScreenCaptureKit (check the Screen Recording permission)") }
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
    private var lastPixelBuffer: CVPixelBuffer?   // chỉ dùng trên captureQueue
    private var pendingDrop = false               // có khung bị bỏ do mạng chậm
    private var timer: DispatchSourceTimer?

    /// Số gói tối đa cho phép đang chờ gửi trước khi bỏ khung hình
    private let maxInFlight = 3

    init(displayID: CGDirectDisplayID, width: Int, height: Int, config: SenderConfig, connection: FramedConnection) {
        self.displayID = displayID
        self.width = width
        self.height = height
        self.config = config
        self.conn = connection
        self.encoder = VideoEncoder(width: width, height: height, fps: config.fps,
                                    bitrateMbps: config.bitrateMbps, hevc: config.hevc)
        super.init()
        encoder.onParameterSets = { [weak self] data in self?.conn.send(.format, data) }
        encoder.onFrame = { [weak self] data in self?.conn.send(.frame, data) }
    }

    func start() async throws {
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
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // NV12 — đưa thẳng vào encoder
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = 5
        cfg.showsCursor = true
        if #available(macOS 13.0, *) {
            cfg.capturesAudio = false
        }

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)
        try await s.startCapture()
        stream = s
        startTimer()
    }

    func stop() async {
        timer?.cancel()
        timer = nil
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
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastPixelBuffer = pixelBuffer
        encode(pixelBuffer, allowDrop: true)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print(tr("[WingScreen] Luồng quay dừng: \(error.localizedDescription)", "[WingScreen] Capture stream stopped: \(error.localizedDescription)"))
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

    var onParameterSets: ((Data) -> Void)?
    var onFrame: ((Data) -> Void)?

    init(width: Int, height: Int, fps: Int, bitrateMbps: Double, hevc: Bool) {
        self.hevc = hevc

        var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
        if !hevc {
            spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true
        }

        var s: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &s)
        guard status == noErr, let s else {
            print(tr("[WingScreen] Không tạo được bộ mã hoá: \(status)", "[WingScreen] Couldn't create the encoder: \(status)"))
            return
        }

        func set(_ key: CFString, _ value: Any) {
            let st = VTSessionSetProperty(s, key: key, value: value as AnyObject)
            if st != noErr { print(tr("[WingScreen] Bỏ qua thuộc tính \(key): \(st)", "[WingScreen] Skipping property \(key): \(st)")) }
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
            guard status == noErr, let sampleBuffer, let self else { return }
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
        onFrame?(data)
    }
}
