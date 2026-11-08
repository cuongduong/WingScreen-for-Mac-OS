import AppKit
import ApplicationServices
import ServiceManagement
import WingScreenShared

// MARK: - Cấu hình (lưu trong UserDefaults, chỉnh từ menu trên thanh menu)
// Tham số dòng lệnh (nếu có) sẽ ghi đè và được lưu lại:
//   --fps 60 --bitrate 40 --hevc --scale 1.5 --port 52020

struct SenderConfig {
    var fps = 60
    var bitrateMbps = 30.0
    var hevc = false
    var scale: Double? = nil      // nil = tự động theo máy phụ
    var port = kDefaultPort

    private static let defaults = UserDefaults.standard

    static func load() -> SenderConfig {
        let d = defaults
        var c = SenderConfig()
        if d.object(forKey: "fps") != nil { c.fps = d.integer(forKey: "fps") }
        if d.object(forKey: "bitrate") != nil { c.bitrateMbps = d.double(forKey: "bitrate") }
        c.hevc = d.bool(forKey: "hevc")
        let s = d.double(forKey: "scale")
        c.scale = s > 0 ? s : nil
        if d.object(forKey: "port") != nil, let p = UInt16(exactly: d.integer(forKey: "port")), p > 0 { c.port = p }
        return c
    }

    func save() {
        let d = SenderConfig.defaults
        d.set(fps, forKey: "fps")
        d.set(bitrateMbps, forKey: "bitrate")
        d.set(hevc, forKey: "hevc")
        d.set(scale ?? 0, forKey: "scale")
        d.set(Int(port), forKey: "port")
    }

    /// Áp dụng tham số dòng lệnh. Trả về true nếu có tham số nào.
    mutating func apply(arguments args: [String]) -> Bool {
        var changed = false
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--fps": if let v = next().flatMap(Int.init) { fps = max(10, min(v, 120)); changed = true }
            case "--bitrate": if let v = next().flatMap(Double.init) { bitrateMbps = max(2, v); changed = true }
            case "--hevc": hevc = true; changed = true
            case "--scale": if let v = next().flatMap(Double.init) { scale = v > 0 ? v : nil; changed = true }
            case "--port": if let v = next().flatMap(UInt16.init) { port = v; changed = true }
            default: break
            }
            i += 1
        }
        return changed
    }
}

// MARK: - Chế độ máy chính (biểu tượng trên thanh menu)

final class SenderController: NSObject, ModeController, NSMenuDelegate {
    private var config: SenderConfig
    private var statusItem: NSStatusItem!
    private var statusText = tr("Đang khởi động…", "Starting…")
    private var server: Server!

    override init() {
        var c = SenderConfig.load()
        if c.apply(arguments: CommandLine.arguments) { c.save() }
        config = c
        super.init()
    }

    func start() {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarIcon()
        let menu = NSMenu()
        menu.delegate = self          // dựng lại menu mỗi lần mở để luôn đúng trạng thái
        menu.autoenablesItems = false
        statusItem.menu = menu

        requestPermissions()

        server = Server(config: config) { [weak self] text in
            DispatchQueue.main.async { self?.statusText = text }
            wsLog(tr("[Máy chính] \(text)", "[Main] \(text)"))
        }
        server.start()
    }

    /// Icon thanh menu: dùng Resources/MenuBarIcon.png nếu có, không thì dùng biểu tượng hệ thống.
    /// Đổi biểu tượng hệ thống: thay tên SF Symbol bên dưới (tra tên trong app "SF Symbols" của Apple).
    private func menuBarIcon() -> NSImage? {
        if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true                       // tự đổi màu theo nền sáng/tối
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: "WingScreen")
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabled(statusText))
        menu.addItem(.separator())

        // Độ phân giải luồng video
        let scaleMenu = NSMenu()
        let scales: [(Double?, String)] = [
            (nil, tr("Tự động (theo máy phụ)", "Auto (match the extra display)")),
            (2.0, tr("Cao — Retina 2x", "High — Retina 2x")),
            (1.5, tr("Vừa — 1.5x", "Medium — 1.5x")),
            (1.0, tr("Thấp — 1x (nhẹ mạng, chữ kém nét)", "Low — 1x (light on network, softer text)")),
        ]
        for (value, title) in scales {
            scaleMenu.addItem(item(title, checked: config.scale == value, action: #selector(setScale(_:)), value: value))
        }
        menu.addItem(submenu(tr("Độ phân giải video", "Video resolution"), scaleMenu))

        // Bitrate
        let bitrateMenu = NSMenu()
        let bitrates: [(Double, String)] = [
            (10, tr("10 Mbps — Wi‑Fi yếu", "10 Mbps — weak Wi‑Fi")),
            (20, "20 Mbps — Wi‑Fi"),
            (30, tr("30 Mbps — mặc định", "30 Mbps — default")),
            (50, tr("50 Mbps — cáp Thunderbolt / LAN", "50 Mbps — Thunderbolt cable / LAN")),
            (80, tr("80 Mbps — cáp Thunderbolt, nét nhất", "80 Mbps — Thunderbolt cable, sharpest")),
        ]
        for (value, title) in bitrates {
            bitrateMenu.addItem(item(title, checked: config.bitrateMbps == value, action: #selector(setBitrate(_:)), value: value))
        }
        menu.addItem(submenu("Bitrate: \(Int(config.bitrateMbps)) Mbps", bitrateMenu))

        // FPS
        let fpsMenu = NSMenu()
        for value in [30, 60] {
            fpsMenu.addItem(item(tr("\(value) khung hình/giây", "\(value) frames per second"), checked: config.fps == value, action: #selector(setFPS(_:)), value: value))
        }
        menu.addItem(submenu(tr("Khung hình/giây: \(config.fps)", "Frame rate: \(config.fps) fps"), fpsMenu))

        menu.addItem(item(tr("Dùng HEVC (H.265) — nét hơn ở cùng bitrate", "Use HEVC (H.265) — sharper at the same bitrate"), checked: config.hevc, action: #selector(toggleHEVC)))

        menu.addItem(.separator())

        // Khởi động cùng máy (macOS 13+)
        if #available(macOS 13.0, *) {
            let loginStatus = SMAppService.mainApp.status
            var loginTitle = tr("Khởi động cùng máy", "Launch at login")
            if loginStatus == .requiresApproval { loginTitle += tr(" (cần duyệt trong Login Items)", " (needs approval in Login Items)") }
            menu.addItem(item(loginTitle, checked: loginStatus == .enabled, action: #selector(toggleLaunchAtLogin)))
        }

        // Địa chỉ IP để kết nối thủ công
        let ips = localIPv4Addresses()
        if !ips.isEmpty {
            menu.addItem(.separator())
            menu.addItem(disabled(tr("Địa chỉ máy này (cổng \(config.port)):", "This computer's addresses (port \(config.port)):")))
            for ip in ips { menu.addItem(disabled("   " + ip)) }
        }

        menu.addItem(.separator())
        // Ngôn ngữ / Language
        let langMenu = NSMenu()
        for lang in AppLanguage.allCases {
            langMenu.addItem(item(lang.title, checked: appLanguageSetting == lang, action: #selector(setLanguage(_:)), value: lang.rawValue))
        }
        menu.addItem(submenu(tr("Ngôn ngữ / Language", "Language / Ngôn ngữ"), langMenu))
        menu.addItem(item(tr("Mở cài đặt Màn hình…", "Open Displays settings…"), checked: false, action: #selector(openDisplaySettings)))
        menu.addItem(item(tr("Mở log…", "Open log…"), checked: false, action: #selector(openLog)))
        menu.addItem(item(tr("Đổi vai trò máy này…", "Change this computer's role…"), checked: false, action: #selector(changeMode)))
        menu.addItem(item(tr("Giới thiệu \(AboutInfo.load().name)…", "About \(AboutInfo.load().name)…"), checked: false, action: #selector(showAbout)))
        let quit = NSMenuItem(title: tr("Thoát WingScreen", "Quit WingScreen"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func item(_ title: String, checked: Bool, action: Selector, value: Any? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.state = checked ? .on : .off
        i.representedObject = value
        return i
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.submenu = sub
        return i
    }

    // MARK: Hành động

    @objc private func setScale(_ sender: NSMenuItem) {
        config.scale = sender.representedObject as? Double
        applyConfig()
    }

    @objc private func setBitrate(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        config.bitrateMbps = v
        applyConfig()
    }

    @objc private func setFPS(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Int else { return }
        config.fps = v
        applyConfig()
    }

    @objc private func toggleHEVC() {
        config.hevc.toggle()
        applyConfig()
    }

    /// Lưu cài đặt; nếu đang có máy phụ kết nối thì kết nối lại để áp dụng (mất ~2 giây).
    private func applyConfig() {
        config.save()
        server.update(config: config)
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                // Khi tự khởi động, app cần biết vai trò mà không hỏi
                UserDefaults.standard.set(AppMode.sender.rawValue, forKey: kModeKey)
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = tr("Không bật được Khởi động cùng máy", "Couldn't enable Launch at login")
            alert.informativeText = tr("\(error.localizedDescription)\n\nHãy chép WingScreen.app vào thư mục Applications rồi thử lại.", "\(error.localizedDescription)\n\nMove WingScreen.app to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openDisplaySettings() {
        let urls = ["x-apple.systempreferences:com.apple.Displays-Settings.extension",   // macOS 13+
                    "x-apple.systempreferences:com.apple.preference.displays"]          // macOS 12
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    @objc private func setLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let lang = AppLanguage(rawValue: raw) else { return }
        appLanguageSetting = lang                // menu dựng lại bằng ngôn ngữ mới ở lần mở sau
        statusText = tr("Đã đổi ngôn ngữ", "Language changed")
    }

    @objc private func changeMode() {
        relaunchToChooseMode()
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(wsLogURL)
    }

    @objc private func showAbout() {
        showAboutPanel()
    }

    private func requestPermissions() {
        // Quyền Trợ năng: để điều khiển chuột/bàn phím từ máy phụ
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            print(tr("[WingScreen] Cần cấp quyền Trợ năng (Accessibility) để điều khiển từ máy phụ.", "[WingScreen] Accessibility permission is needed to control this Mac from the extra display."))
        }
        // Quyền Ghi màn hình: để quay màn hình ảo
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            print(tr("[WingScreen] Cần cấp quyền Ghi màn hình (Screen Recording), sau đó mở lại app.", "[WingScreen] Screen Recording permission is needed — grant it, then reopen the app."))
        }
    }
}

func localIPv4Addresses() -> [String] {
    var result: [String] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let ifa = ptr.pointee
        guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let name = String(cString: ifa.ifa_name)
        if name == "lo0" { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            result.append("\(String(cString: host))  (\(name))")
        }
    }
    return result
}
