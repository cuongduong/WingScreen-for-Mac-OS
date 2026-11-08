import Foundation
import Network
import CoreMedia

// MARK: - Hằng số

public let kServiceType = "_wingscreen._tcp"
public let kDefaultPort: UInt16 = 52020

/// Loại gói tin. Khung gói: [4 byte độ dài big-endian][1 byte loại][payload]
public enum MsgType: UInt8 {
    case hello = 1            // Receiver -> Sender: thông tin màn hình (JSON Hello)
    case format = 2           // Sender -> Receiver: tham số codec (SPS/PPS/VPS)
    case frame = 3            // Sender -> Receiver: [1 byte keyframe][dữ liệu AVCC]
    case input = 4            // Receiver -> Sender: sự kiện chuột/bàn phím (JSON InputEvent)
    case requestKeyframe = 5  // Receiver -> Sender: xin keyframe khi giải mã lỗi
}

public struct Hello: Codable {
    public var name: String
    public var pointWidth: Int
    public var pointHeight: Int
    public var scale: Double
    public var refreshRate: Int

    public init(name: String, pointWidth: Int, pointHeight: Int, scale: Double, refreshRate: Int) {
        self.name = name
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.scale = scale
        self.refreshRate = refreshRate
    }
}

/// Toạ độ x, y được chuẩn hoá 0...1, gốc ở góc trên-trái.
public enum InputEvent: Codable {
    case move(x: Double, y: Double)
    case button(index: Int, down: Bool, clicks: Int, x: Double, y: Double)
    case scroll(dx: Double, dy: Double, precise: Bool)
    case key(code: UInt16, down: Bool, flags: UInt64)
    case modifier(code: UInt16, flags: UInt64)
}

public func encodeJSON<T: Encodable>(_ value: T) -> Data {
    (try? JSONEncoder().encode(value)) ?? Data()
}

/// - wiredOnly: chỉ dùng đường có dây (cáp Thunderbolt Bridge, LAN), không dùng Wi‑Fi
public func makeTCPParameters(connectionTimeout: Int = 6, wiredOnly: Bool = false) -> NWParameters {
    let tcp = NWProtocolTCP.Options()
    tcp.noDelay = true
    tcp.enableKeepalive = true
    tcp.keepaliveIdle = 10        // chỉ coi là mất kết nối khi im lặng ~10 + 3×5 = 25 giây
    tcp.keepaliveInterval = 5
    tcp.keepaliveCount = 3
    tcp.connectionTimeout = connectionTimeout
    let params = NWParameters(tls: nil, tcp: tcp)
    if wiredOnly {
        params.prohibitedInterfaceTypes = [.wifi, .cellular]
    }
    // Không dùng AWDL (Wi‑Fi ngang hàng của AirDrop): rất chập chờn và làm giật Wi‑Fi chính.
    // Kết nối đi qua Wi‑Fi/LAN thường hoặc cáp Thunderbolt (Thunderbolt Bridge).
    params.includePeerToPeer = false
    params.serviceClass = .interactiveVideo
    return params
}

/// Ghi log vào ~/Library/Logs/WingScreen.log (mở bằng app Console hoặc menu "Mở log")
public func wsLog(_ text: String) {
    let line = "\(wsLogDateFormatter.string(from: Date())) \(text)\n"
    print(line, terminator: "")
    wsLogQueue.async {
        let url = wsLogURL
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(Data(line.utf8))
            try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
    }
}

public let wsLogURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/WingScreen.log")
private let wsLogQueue = DispatchQueue(label: "wingscreen.log")
private let wsLogDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    return f
}()

// MARK: - Tham số codec

public enum Codec: UInt8 { case h264 = 0, hevc = 1 }

public struct ParameterSets {
    public var codec: Codec
    public var sets: [Data]

    public init?(formatDescription fmt: CMFormatDescription, hevc: Bool) {
        var count = 0
        var status: OSStatus = hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard status == noErr, count > 0 else { return nil }

        var result: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let ptr else { return nil }
            result.append(Data(bytes: ptr, count: size))
        }
        codec = hevc ? .hevc : .h264
        sets = result
    }

    public init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 2, let c = Codec(rawValue: b[0]) else { return nil }
        var idx = 2
        var result: [Data] = []
        for _ in 0..<Int(b[1]) {
            guard idx + 4 <= b.count else { return nil }
            let len = Int(b[idx]) << 24 | Int(b[idx + 1]) << 16 | Int(b[idx + 2]) << 8 | Int(b[idx + 3])
            idx += 4
            guard idx + len <= b.count else { return nil }
            result.append(Data(b[idx..<(idx + len)]))
            idx += len
        }
        codec = c
        sets = result
    }

    public func encoded() -> Data {
        var d = Data([codec.rawValue, UInt8(sets.count)])
        for s in sets {
            d.append(contentsOf: bigEndian32(s.count))
            d.append(s)
        }
        return d
    }

    public func makeFormatDescription() -> CMVideoFormatDescription? {
        let buffers: [UnsafeMutablePointer<UInt8>] = sets.map { d in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(d.count, 1))
            d.copyBytes(to: p, count: d.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let sizes = sets.map { $0.count }

        var fmt: CMFormatDescription?
        let status: OSStatus
        switch codec {
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                parameterSetPointers: pointers, parameterSetSizes: sizes,
                nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fmt)
        }
        return status == noErr ? fmt : nil
    }
}

@inline(__always)
func bigEndian32(_ n: Int) -> [UInt8] {
    [UInt8((n >> 24) & 0xff), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)]
}

// MARK: - Kết nối có đóng khung

public final class FramedConnection {
    public let connection: NWConnection
    private let queue: DispatchQueue

    public var onReady: (() -> Void)?
    public var onMessage: ((MsgType, Data) -> Void)?
    public var onClose: ((Error?) -> Void)?

    private var closed = false
    /// Đã từng kết nối thành công chưa
    public private(set) var wasReady = false
    /// Đường mạng đang dùng (ví dụ "bridge0 (wiredEthernet)")
    public private(set) var via = "?"
    /// Đang đi qua Wi‑Fi
    public private(set) var viaWiFi = false
    private var viable = true
    private let lock = NSLock()
    private var _inFlight = 0

    /// Số gói đang chờ gửi (dùng để bỏ khung hình khi mạng chậm)
    public var inFlight: Int {
        lock.lock(); defer { lock.unlock() }
        return _inFlight
    }

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let iface = self.connection.currentPath?.availableInterfaces.first
                self.wasReady = true
                self.via = iface.map { "\($0.name) (\($0.type))" } ?? "?"
                self.viaWiFi = iface?.type == .wifi
                wsLog(tr("Đã kết nối \(self.connection.endpoint) qua \(self.via)", "Connected to \(self.connection.endpoint) via \(self.via)"))
                self.onReady?()
                self.readHeader()
            case .failed(let e), .waiting(let e):
                wsLog(tr("Kết nối \(self.connection.endpoint) lỗi: \(e)", "Connection to \(self.connection.endpoint) failed: \(e)"))
                self.finish(e)
            case .cancelled:
                self.finish(nil)
            default:
                break
            }
        }
        // Đường mạng biến mất (ví dụ rút cáp): đóng sau 2 giây nếu không hồi phục,
        // để bên nhận nối lại ngay qua đường khác thay vì chờ keepalive (~25 giây).
        connection.viabilityUpdateHandler = { [weak self] viable in
            guard let self, self.wasReady else { return }
            self.viable = viable
            guard !viable else { return }
            wsLog(tr("Đường mạng \(self.via) tạm mất", "Network path \(self.via) lost"))
            self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.closed, !self.viable else { return }
                wsLog(tr("Đường mạng \(self.via) không hồi phục — đóng kết nối", "Network path \(self.via) did not recover — closing connection"))
                self.finish(nil)
            }
        }
        connection.start(queue: queue)
    }

    public func cancel() {
        queue.async { self.finish(nil) }
    }

    private func finish(_ error: Error?) {
        if closed { return }
        closed = true
        let reason = error.map { ": \($0)" } ?? ""
        wsLog(tr("Đóng kết nối \(connection.endpoint)\(reason)", "Closed connection \(connection.endpoint)\(reason)"))
        connection.cancel()
        onClose?(error)
    }

    public func send(_ type: MsgType, _ payload: Data = Data()) {
        var packet = Data(bigEndian32(payload.count))
        packet.append(type.rawValue)
        packet.append(payload)

        lock.lock(); _inFlight += 1; lock.unlock()
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock(); self._inFlight -= 1; self.lock.unlock()
            if let error { self.queue.async { self.finish(error) } }
        })
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error { self.finish(error); return }
            guard let data, data.count == 5 else { self.finish(nil); return }
            let b = [UInt8](data)
            let len = Int(b[0]) << 24 | Int(b[1]) << 16 | Int(b[2]) << 8 | Int(b[3])
            let type = MsgType(rawValue: b[4])

            if len == 0 {
                if let type { self.onMessage?(type, Data()) }
                self.readHeader()
                return
            }
            guard len < 64 * 1024 * 1024 else { self.finish(nil); return }

            self.connection.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] body, _, _, error in
                guard let self else { return }
                if let error { self.finish(error); return }
                guard let body, body.count == len else { self.finish(nil); return }
                if let type { self.onMessage?(type, body) }
                self.readHeader()
            }
        }
    }
}
