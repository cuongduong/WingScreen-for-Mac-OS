import Foundation

/// Ngôn ngữ giao diện / interface language.
/// "auto" = theo ngôn ngữ của macOS (tiếng Việt nếu máy dùng tiếng Việt, ngược lại tiếng Anh).
public enum AppLanguage: String, CaseIterable {
    case auto, en, vi

    /// Tên hiển thị trong menu chọn ngôn ngữ
    public var title: String {
        switch self {
        case .auto: return tr("Tự động (theo hệ thống)", "Automatic (system language)")
        case .en: return "English"
        case .vi: return "Tiếng Việt"
        }
    }
}

public let kLanguageKey = "language"

/// Ngôn ngữ người dùng đã chọn (lưu trong UserDefaults). Đổi giá trị là áp dụng ngay.
public var appLanguageSetting: AppLanguage {
    get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: kLanguageKey) ?? "") ?? .auto }
    set {
        UserDefaults.standard.set(newValue.rawValue, forKey: kLanguageKey)
        reloadLanguage()
    }
}

private var useVietnamese: Bool = computeUseVietnamese()

private func computeUseVietnamese() -> Bool {
    switch appLanguageSetting {
    case .vi: return true
    case .en: return false
    case .auto: return (Locale.preferredLanguages.first ?? "").lowercased().hasPrefix("vi")
    }
}

/// Tính lại ngôn ngữ (sau khi đổi cài đặt)
public func reloadLanguage() {
    useVietnamese = computeUseVietnamese()
}

/// Giao diện đang dùng tiếng Việt
public var isVietnamese: Bool { useVietnamese }

/// Chọn chuỗi theo ngôn ngữ: tr("tiếng Việt", "English")
@inline(__always)
public func tr(_ vi: String, _ en: String) -> String {
    useVietnamese ? vi : en
}
