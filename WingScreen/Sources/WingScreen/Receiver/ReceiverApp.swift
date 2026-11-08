import AppKit
import WingScreenShared

// Chế độ màn hình phụ.
//   Kết nối tới IP cụ thể: --host 192.168.1.10 (mặc định tự tìm qua Bonjour)
//   Thoát: ⌃⌥⌘X (Control + Option + Command + X)

final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class ReceiverController: NSObject, ModeController {
    private var window: KeyWindow!
    private var streamView: StreamView!
    private var client: Client!
    private var activity: NSObjectProtocol?

    func start() {
        guard let screen = NSScreen.main else { NSApp.terminate(nil); return }
        NSApp.setActivationPolicy(.regular)

        streamView = StreamView(frame: CGRect(origin: .zero, size: screen.frame.size))
        window = KeyWindow(contentRect: screen.frame, styleMask: [.borderless],
                           backing: .buffered, defer: false, screen: screen)
        window.backgroundColor = .black
        window.contentView = streamView
        window.isReleasedWhenClosed = false
        window.acceptsMouseMovedEvents = true
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(streamView)

        NSApp.activate(ignoringOtherApps: true)
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]

        // Không cho màn hình máy phụ tự tắt
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
            reason: tr("WingScreen đang hiển thị màn hình phụ", "WingScreen is showing an extra display"))

        let hello = Hello(name: Host.current().localizedName ?? "Mac",
                          pointWidth: Int(screen.frame.width),
                          pointHeight: Int(screen.frame.height),
                          scale: Double(screen.backingScaleFactor),
                          refreshRate: max(screen.maximumFramesPerSecond, 60))

        let args = CommandLine.arguments
        var host: String?
        if let i = args.firstIndex(of: "--host"), i + 1 < args.count { host = args[i + 1] }

        client = Client(hello: hello, manualHost: host, sink: streamView.sink)
        client.onStatus = { [weak self] text in
            let line = text.replacingOccurrences(of: "\n", with: " ")
            wsLog(tr("[Màn hình phụ] \(line)", "[Display] \(line)"))
            DispatchQueue.main.async { self?.streamView.showStatus(text) }
        }
        client.onConnectedVideo = { [weak self] in
            DispatchQueue.main.async { self?.streamView.showStatus(nil) }
        }
        streamView.onInput = { [weak self] event in self?.client.sendInput(event) }
        client.start()
    }
}
