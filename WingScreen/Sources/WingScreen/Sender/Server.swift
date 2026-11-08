import Foundation
import Network
import WingScreenShared

/// Lắng nghe kết nối từ máy phụ (Bonjour + cổng cố định), mỗi lúc phục vụ 1 máy.
final class Server {
    private var config: SenderConfig          // chỉ truy cập trên queue
    private let status: (String) -> Void
    private let queue = DispatchQueue(label: "wingscreen.net", qos: .userInteractive)
    private var listener: NWListener?
    private var session: Session?
    private let park = ScreenPark()

    init(config: SenderConfig, status: @escaping (String) -> Void) {
        self.config = config
        self.status = status
    }

    func start() {
        do {
            let listener = try NWListener(using: makeTCPParameters(), on: NWEndpoint.Port(rawValue: config.port)!)
            listener.service = NWListener.Service(name: Host.current().localizedName ?? "WingScreen", type: kServiceType)
            listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.status(tr("Đang chờ máy phụ kết nối…", "Waiting for an extra display to connect…"))
                case .failed(let e): self?.status(tr("Lỗi mạng: \(e.localizedDescription)", "Network error: \(e.localizedDescription)"))
                default: break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            status(tr("Không mở được cổng \(config.port): \(error.localizedDescription)", "Couldn't open port \(config.port): \(error.localizedDescription)"))
        }
    }

    /// Đổi cài đặt. Nếu đang có máy phụ, ngắt kết nối để nó tự nối lại với cài đặt mới.
    func update(config newConfig: SenderConfig) {
        queue.async {
            self.config = newConfig
            if let session = self.session {
                self.status(tr("Đang áp dụng cài đặt mới…", "Applying new settings…"))
                session.disconnect()
            }
        }
    }

    private var pending: NWConnection?    // kết nối mới chờ phiên cũ dọn xong

    private func accept(_ conn: NWConnection) {
        wsLog(tr("Kết nối đến từ \(conn.endpoint)", "Incoming connection from \(conn.endpoint)"))
        if let current = session {
            // Thường là máy phụ nối lại sau khi mạng chập: bỏ phiên cũ, phục vụ kết nối mới
            // ngay khi màn hình ảo cũ đã gỡ xong (tránh 2 màn hình ảo trùng nhau).
            pending?.cancel()
            pending = conn
            current.disconnect()
            return
        }
        startSession(conn)
    }

    private func startSession(_ conn: NWConnection) {
        let framed = FramedConnection(connection: conn, queue: queue)
        let s = Session(connection: framed, config: config, queue: queue, park: park, status: status)
        s.onEnd = { [weak self] in
            self?.queue.async {
                guard let self else { return }
                self.session = nil
                if let next = self.pending {
                    self.pending = nil
                    self.startSession(next)
                } else {
                    self.status(tr("Đang chờ máy phụ kết nối…", "Waiting for an extra display to connect…"))
                }
            }
        }
        session = s
        s.start()
    }
}

/// Một phiên kết nối: tạo màn hình ảo, quay + mã hoá, nhận điều khiển.
final class Session {
    private let conn: FramedConnection
    private let config: SenderConfig
    private let queue: DispatchQueue
    private let status: (String) -> Void
    var onEnd: (() -> Void)?

    private var screen: VirtualScreen?       // chỉ truy cập trên main thread
    private var screenKey = ""               // chỉ truy cập trên main thread
    private let park: ScreenPark
    private var streamer: ScreenStreamer?    // truy cập trên queue
    private var injector: InputInjector?     // truy cập trên queue
    private var ended = false
    private let decoder = JSONDecoder()

    /// Giới hạn khung hình của H.264 level 5.2 (4096×2304) — vượt quá thì bộ nén không chạy
    private static let maxPixels = 4096.0 * 2304.0
    private static let maxWidth = 4096.0

    init(connection: FramedConnection, config: SenderConfig, queue: DispatchQueue, park: ScreenPark,
         status: @escaping (String) -> Void) {
        self.conn = connection
        self.config = config
        self.queue = queue
        self.park = park
        self.status = status
    }

    func start() {
        conn.onMessage = { [weak self] type, data in self?.handle(type, data) }
        conn.onClose = { [weak self] _ in self?.stop() }
        conn.start()
    }

    func disconnect() {
        conn.cancel()
    }

    private func handle(_ type: MsgType, _ data: Data) {
        switch type {
        case .hello:
            guard let hello = try? decoder.decode(Hello.self, from: data) else { return }
            DispatchQueue.main.async { self.setup(hello) }
        case .input:
            if let event = try? decoder.decode(InputEvent.self, from: data) {
                injector?.handle(event)
            }
        case .requestKeyframe:
            streamer?.requestKeyframe()
        default:
            break
        }
    }

    private func setup(_ hello: Hello) {
        guard screen == nil, !ended else { return }

        // Màn hình ảo dùng HiDPI khi máy phụ có scale > 1 (Retina 2x, hoặc Windows 125%/150%/200%),
        // còn "scale" chỉ quyết định độ phân giải luồng video.
        let hiDPI = hello.scale > 1.01
        let refresh = Double(min(config.fps, max(hello.refreshRate, 30)))

        // Máy phụ nối lại ngay (mạng chập, chuyển sang cáp, đổi cài đặt) -> dùng lại màn hình ảo cũ,
        // các cửa sổ đang mở trên đó giữ nguyên chỗ.
        let key = "\(hello.name)|\(hello.pointWidth)x\(hello.pointHeight)|\(hiDPI)|\(refresh)"
        let reused = park.take(key: key)
        if reused != nil { wsLog(tr("Dùng lại màn hình ảo cũ", "Reusing the previous virtual display")) }
        guard let vs = reused ?? VirtualScreen(name: "\(hello.name) (WingScreen)",
                                               pointWidth: hello.pointWidth,
                                               pointHeight: hello.pointHeight,
                                               hiDPI: hiDPI,
                                               refreshRate: refresh) else {
            status(tr("Không tạo được màn hình ảo", "Couldn't create the virtual display"))
            conn.cancel()
            return
        }
        screen = vs
        screenKey = key

        // Kích thước luồng video, tự hạ nếu vượt giới hạn bộ nén
        let w = Double(hello.pointWidth), h = Double(hello.pointHeight)
        var scale = config.scale ?? hello.scale
        var capped = false
        if w * h * scale * scale > Session.maxPixels {
            scale = (Session.maxPixels * 0.98 / (w * h)).squareRoot()   // chừa biên cho làm tròn macroblock
            capped = true
        }
        if w * scale > Session.maxWidth {
            scale = Session.maxWidth / w
            capped = true
        }
        let pw = Int((w * scale).rounded()) & ~1   // số chẵn cho bộ nén 4:2:0
        let ph = Int((h * scale).rounded()) & ~1

        var text = tr("Đã kết nối: \(hello.name) — video \(pw)×\(ph), \(Int(config.bitrateMbps)) Mbps, \(config.fps) fps", "Connected: \(hello.name) — video \(pw)×\(ph), \(Int(config.bitrateMbps)) Mbps, \(config.fps) fps")
        if config.hevc { text += ", HEVC" }
        if capped { text += tr(" (đã tự giảm độ phân giải)", " (resolution reduced automatically)") }
        status(text)

        let streamer = ScreenStreamer(displayID: vs.displayID, width: pw, height: ph, config: config, connection: conn)
        let injector = InputInjector(displayID: vs.displayID)
        queue.async {
            self.streamer = streamer
            self.injector = injector
        }

        Task {
            // Đợi macOS đăng ký màn hình mới rồi chọn đúng chế độ HiDPI
            if reused == nil {
                try? await Task.sleep(nanoseconds: 400_000_000)
                await MainActor.run { vs.selectMode() }
            }
            do {
                try await streamer.start()
            } catch {
                self.status(tr("Lỗi quay màn hình: \(error.localizedDescription)", "Screen capture error: \(error.localizedDescription)"))
                self.conn.cancel()
            }
        }
    }

    /// Gọi trên queue mạng khi kết nối đóng.
    private func stop() {
        guard !ended else { return }
        ended = true
        injector?.releaseAll()
        injector = nil
        let s = streamer
        streamer = nil
        Task {
            await s?.stop()
            await MainActor.run {
                // Chưa gỡ ngay: giữ màn hình ảo vài giây phòng khi máy phụ nối lại
                if let screen = self.screen { self.park.park(screen, key: self.screenKey) }
                self.screen = nil
            }
            self.onEnd?()
        }
    }
}

/// Giữ lại màn hình ảo một lúc sau khi máy phụ ngắt kết nối. Nếu máy phụ nối lại ngay
/// (mạng chập, chuyển sang cáp, đổi cài đặt) thì dùng lại, cửa sổ không bị dồn về màn hình chính.
/// Chỉ dùng trên main thread.
final class ScreenPark {
    static let holdSeconds = 15.0
    private var parked: (screen: VirtualScreen, key: String, token: Int)?
    private var counter = 0

    func park(_ screen: VirtualScreen, key: String) {
        counter += 1
        let token = counter
        parked = (screen, key, token)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdSeconds) { [weak self] in
            guard let self, let p = self.parked, p.token == token else { return }
            self.parked = nil                       // giải phóng -> màn hình ảo biến mất
            wsLog(tr("Đã gỡ màn hình ảo (máy phụ không nối lại)", "Removed the virtual display (the extra display didn't reconnect)"))
        }
    }

    /// Lấy màn hình đang giữ nếu khớp; không khớp thì gỡ nó đi để tạo màn hình mới.
    func take(key: String) -> VirtualScreen? {
        guard let p = parked else { return nil }
        parked = nil
        return p.key == key ? p.screen : nil
    }
}
