import AppKit
import WingScreenShared

// WingScreen — một app, hai vai trò.
//   Lần đầu mở: hỏi máy này là "Máy chính (phát)" hay "Màn hình phụ (nhận)".
//   Giữ phím ⌥ Option khi mở app (hoặc chạy với --choose) để chọn lại.
//   Ép vai trò từ dòng lệnh: --sender  hoặc  --receiver

final class LauncherDelegate: NSObject, NSApplicationDelegate {
    private var controller: ModeController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let mode = decideMode() else {
            NSApp.terminate(nil)
            return
        }
        let c: ModeController
        switch mode {
        case .sender: c = SenderController()
        case .receiver: c = ReceiverController()
        }
        controller = c
        c.start()
    }

    private func decideMode() -> AppMode? {
        let args = CommandLine.arguments
        if args.contains("--sender") { return .sender }
        if args.contains("--receiver") { return .receiver }
        let forceChoose = args.contains("--choose") || NSEvent.modifierFlags.contains(.option)
        if !forceChoose,
           let raw = UserDefaults.standard.string(forKey: kModeKey),
           let mode = AppMode(rawValue: raw) {
            return mode
        }
        return askMode()
    }

    /// Hộp chọn vai trò. Có ô chọn ngôn ngữ: đổi ngôn ngữ thì hộp thoại hiện lại bằng ngôn ngữ mới.
    private func askMode() -> AppMode? {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        var remember = true
        while true {
            let alert = NSAlert()
            alert.messageText = tr("WingScreen — máy này dùng để làm gì?", "WingScreen — what is this computer for?")
            alert.informativeText = tr("""
            • Máy chính: tạo thêm một màn hình và phát hình sang máy khác.
            • Màn hình phụ: dùng màn hình máy này làm màn hình mở rộng cho máy chính.

            Giữ phím ⌥ Option khi mở app để chọn lại.
            """, """
            • Main computer: add a display to this Mac and stream it to another computer.
            • Extra display: use this computer's screen as an extended display for the main computer.

            Hold ⌥ Option while opening the app to choose again.
            """)
            alert.addButton(withTitle: tr("Máy chính (phát)", "Main computer (send)"))
            alert.addButton(withTitle: tr("Màn hình phụ (nhận)", "Extra display (receive)"))
            alert.addButton(withTitle: tr("Thoát", "Quit"))

            // Ô chọn ngôn ngữ + "Ghi nhớ lựa chọn"
            let languageLabel = NSTextField(labelWithString: tr("Ngôn ngữ / Language:", "Language / Ngôn ngữ:"))
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            for lang in AppLanguage.allCases {
                popup.addItem(withTitle: lang.title)
                popup.lastItem?.representedObject = lang.rawValue
            }
            popup.selectItem(at: AppLanguage.allCases.firstIndex(of: appLanguageSetting) ?? 0)
            let picker = LanguagePickerTarget()
            popup.target = picker
            popup.action = #selector(LanguagePickerTarget.changed(_:))
            let row = NSStackView(views: [languageLabel, popup])
            row.orientation = .horizontal
            row.spacing = 8
            let rememberBox = NSButton(checkboxWithTitle: tr("Ghi nhớ lựa chọn", "Remember my choice"), target: nil, action: nil)
            rememberBox.state = remember ? .on : .off
            let stack = NSStackView(views: [row, rememberBox])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.setFrameSize(stack.fittingSize)
            alert.accessoryView = stack

            // Giữ `picker` sống suốt lúc hộp thoại mở (popup chỉ giữ tham chiếu yếu tới target)
            let response = withExtendedLifetime(picker) { alert.runModal() }
            alert.window.orderOut(nil)
            remember = rememberBox.state == .on
            if response == LanguagePickerTarget.languageChanged { continue }   // hiện lại bằng ngôn ngữ mới

            let mode: AppMode
            switch response {
            case .alertFirstButtonReturn: mode = .sender
            case .alertSecondButtonReturn: mode = .receiver
            default: return nil
            }
            if remember {
                UserDefaults.standard.set(mode.rawValue, forKey: kModeKey)
            } else {
                UserDefaults.standard.removeObject(forKey: kModeKey)
            }
            return mode
        }
    }
}

/// Nhận sự kiện đổi ngôn ngữ trong hộp chọn vai trò
final class LanguagePickerTarget: NSObject {
    static let languageChanged = NSApplication.ModalResponse(rawValue: 7001)

    @objc func changed(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let lang = AppLanguage(rawValue: raw), lang != appLanguageSetting else { return }
        appLanguageSetting = lang
        NSApp.stopModal(withCode: Self.languageChanged)
    }
}

let app = NSApplication.shared
let launcher = LauncherDelegate()
app.delegate = launcher
app.run()
