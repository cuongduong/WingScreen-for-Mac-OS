import AppKit

/// Vai trò của máy: phát (máy chính) hoặc nhận (màn hình phụ)
enum AppMode: String {
    case sender, receiver
}

let kModeKey = "appMode"

/// Mỗi chế độ là một controller có hàm start()
protocol ModeController: AnyObject {
    func start()
}

/// Mở lại app và hiện hộp chọn vai trò.
func relaunchToChooseMode() {
    UserDefaults.standard.removeObject(forKey: kModeKey)
    let config = NSWorkspace.OpenConfiguration()
    config.arguments = ["--choose"]
    config.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
