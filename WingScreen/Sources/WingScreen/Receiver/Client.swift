import Foundation
import Network
import WingScreenShared

/// Tìm và kết nối tới máy chính, nhận video, gửi sự kiện điều khiển.
///
/// Mặc định kết nối bình thường (thường là Wi‑Fi). Khi đang chạy Wi‑Fi, app thử đường cáp
/// (Thunderbolt Bridge / LAN) sau 3 giây rồi cứ 10 giây một lần; có cáp là tự chuyển sang.
/// Rút cáp thì kết nối qua cáp mất và app tự nối lại bằng Wi‑Fi.
final class Client {
    private let hello: Hello
    private let manualHost: String?
    private let sink: VideoSink
    private let queue = DispatchQueue(label: "wingscreen.client", qos: .userInteractive)
    private var browser: NWBrowser?
    private var conn: FramedConnection?
    private var endpoint: NWEndpoint?
    private var probe: FramedConnection?
    private var probeTimer: DispatchSourceTimer?
    private var gotVideo = false

    /// Lần thử cáp đầu tiên sau khi kết nối Wi‑Fi, và khoảng cách giữa các lần thử sau đó (giây)
    private let firstProbeDelay = 3
    private let probeInterval = 10

    var onStatus: ((String) -> Void)?
    var onConnectedVideo: (() -> Void)?

    init(hello: Hello, manualHost: String?, sink: VideoSink) {
        self.hello = hello
        self.manualHost = manualHost
        self.sink = sink
        sink.onNeedKeyframe = { [weak self] in
            self?.queue.async { self?.conn?.send(.requestKeyframe) }
        }
    }

    func start() {
        queue.async {
            if let host = self.manualHost {
                self.connect(.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: kDefaultPort)!))
            } else {
                self.browse()
            }
        }
    }

    private func browse() {
        onStatus?(tr("Đang tìm máy chính trong mạng…\n(Mở WingScreen ở chế độ Máy chính trên Mac hoặc Windows)", "Looking for the main computer on the network…\n(Open WingScreen as Main computer on a Mac or Windows PC)"))
        let b = NWBrowser(for: .bonjour(type: kServiceType, domain: nil), using: makeTCPParameters())
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.conn == nil, let first = results.first else { return }
            self.browser?.cancel()
            self.browser = nil
            self.connect(first.endpoint)
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed(let e) = state {
                self?.onStatus?(tr("Lỗi tìm kiếm: \(e.localizedDescription)", "Discovery error: \(e.localizedDescription)"))
                self?.browser = nil
                self?.retryLater()
            }
        }
        b.start(queue: queue)
        browser = b
    }

    // MARK: Kết nối

    private func connect(_ endpoint: NWEndpoint) {
        self.endpoint = endpoint
        onStatus?(tr("Đang kết nối tới máy chính…", "Connecting to the main computer…"))
        gotVideo = false
        let c = FramedConnection(connection: NWConnection(to: endpoint, using: makeTCPParameters()), queue: queue)
        c.onReady = { [weak self, weak c] in
            guard let self, let c else { return }
            c.send(.hello, encodeJSON(self.hello))
            self.onStatus?(tr("Đã kết nối qua \(self.describe(c)), đang chờ hình ảnh…", "Connected via \(self.describe(c)), waiting for video…"))
            self.updateProbing()
        }
        c.onClose = { [weak self, weak c] error in
            guard let self, let c, self.conn === c else { return }   // kết nối cũ đã được thay thế
            self.conn = nil
            self.lost(error)
        }
        install(c)
        c.start()
    }

    /// Gắn kết nối làm kết nối chính (nhận video).
    private func install(_ c: FramedConnection) {
        c.onMessage = { [weak self, weak c] type, data in
            guard let self, let c, self.conn === c else { return }
            self.handle(type, data)
        }
        conn = c
    }

    private func lost(_ error: Error?) {
        stopProbing()
        sink.reset()
        let reason = error.map { ": \($0.localizedDescription)" } ?? ""
        onStatus?(tr("Mất kết nối\(reason). Đang thử lại…", "Connection lost\(reason). Reconnecting…"))
        retryLater()
    }

    private func retryLater() {
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.conn == nil, self.browser == nil else { return }
            self.start()
        }
    }

    private func describe(_ c: FramedConnection) -> String {
        c.viaWiFi ? "Wi‑Fi" : tr("cáp / mạng có dây [\(c.via)]", "cable / wired network [\(c.via)]")
    }

    // MARK: Tự chuyển sang cáp

    private func updateProbing() {
        if conn?.viaWiFi == true {
            guard probeTimer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + .seconds(firstProbeDelay), repeating: .seconds(probeInterval))
            t.setEventHandler { [weak self] in self?.probeWired() }
            t.resume()
            probeTimer = t
        } else {
            stopProbing()
        }
    }

    private func stopProbing() {
        probeTimer?.cancel()
        probeTimer = nil
        probe?.cancel()
        probe = nil
    }

    /// Thử mở kết nối mới chỉ qua cáp. Thành công thì chuyển sang dùng nó;
    /// máy chính sẽ tự bỏ kết nối Wi‑Fi cũ và giữ nguyên màn hình ảo.
    private func probeWired() {
        guard probe == nil, let current = conn, current.viaWiFi, let endpoint else { return }
        let p = FramedConnection(connection: NWConnection(to: endpoint,
                                                          using: makeTCPParameters(connectionTimeout: 3, wiredOnly: true)),
                                 queue: queue)
        p.onReady = { [weak self, weak p] in
            guard let self, let p else { return }
            wsLog(tr("Phát hiện đường cáp (\(p.via)) — chuyển kết nối sang cáp", "Cable link found (\(p.via)) — switching to it"))
            self.probe = nil
            let old = self.conn
            self.install(p)
            p.onClose = { [weak self, weak p] error in
                guard let self, let p, self.conn === p else { return }
                self.conn = nil
                self.lost(error)
            }
            old?.cancel()
            self.sink.reset()
            self.gotVideo = false
            p.send(.hello, encodeJSON(self.hello))
            self.onStatus?(tr("Đã chuyển sang cáp, đang chờ hình ảnh…", "Switched to the cable, waiting for video…"))
            self.updateProbing()
        }
        p.onClose = { [weak self, weak p] _ in
            guard let self, let p, self.probe === p else { return }
            self.probe = nil                                      // chưa có cáp, thử lại lần sau
        }
        probe = p
        p.start()
    }

    // MARK: Dữ liệu

    private func handle(_ type: MsgType, _ data: Data) {
        switch type {
        case .format:
            if let ps = ParameterSets(data: data) { sink.setFormat(ps) }
        case .frame:
            sink.enqueue(data)
            if !gotVideo {
                gotVideo = true
                onConnectedVideo?()
            }
        default:
            break
        }
    }

    func sendInput(_ event: InputEvent) {
        let payload = encodeJSON(event)
        queue.async { self.conn?.send(.input, payload) }
    }
}
