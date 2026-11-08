import AppKit
import WingScreenShared

/// Nội dung cửa sổ "Giới thiệu", đọc từ Resources/about.json (sao chép từ about.json khi build)
/// và Info.plist (phiên bản, ngày build).
struct AboutInfo {
    var name = "WingScreen"
    var version = ""
    var buildDate = ""
    var description = ""
    var author = ""
    var organization = ""
    var website = ""
    var email = ""
    var copyright = ""
    var notes: [String] = []

    static func load() -> AboutInfo {
        var a = AboutInfo()
        let info = Bundle.main.infoDictionary ?? [:]
        a.version = info["CFBundleShortVersionString"] as? String ?? ""
        a.buildDate = info["WSBuildDate"] as? String ?? ""

        if let url = Bundle.main.url(forResource: "about", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            // Tiếng Anh: dùng trường "<khoá>_en" nếu có (ví dụ description_en, notes_en)
            func str(_ key: String) -> String {
                if !isVietnamese, let en = (json[key + "_en"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !en.isEmpty {
                    return en
                }
                return (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            if !str("name").isEmpty { a.name = str("name") }
            if a.version.isEmpty { a.version = str("version") }
            a.description = str("description")
            a.author = str("author")
            a.organization = str("organization")
            a.website = str("website")
            a.email = str("email")
            a.copyright = str("copyright")
            let notesEN = (json["notes_en"] as? [String] ?? []).filter { !$0.isEmpty }
            a.notes = !isVietnamese && !notesEN.isEmpty ? notesEN : (json["notes"] as? [String] ?? []).filter { !$0.isEmpty }
        }
        return a
    }

    /// Phần nội dung (credits) hiển thị dưới tên app
    func credits() -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 4
        let normal: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: center,
        ]
        let dim = normal.merging([.foregroundColor: NSColor.secondaryLabelColor]) { $1 }

        let out = NSMutableAttributedString()
        func line(_ text: String, _ attrs: [NSAttributedString.Key: Any]) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: attrs)) }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }
        func link(_ label: String, _ text: String, _ url: String) {
            if out.length > 0 { out.append(NSAttributedString(string: "\n", attributes: normal)) }
            out.append(NSAttributedString(string: label, attributes: normal))
            var attrs = normal
            if let u = URL(string: url) { attrs[.link] = u }
            out.append(NSAttributedString(string: text, attributes: attrs))
        }

        if !description.isEmpty { line(description, normal) }
        if !author.isEmpty { line(tr("Tác giả: \(author)", "Author: \(author)"), normal) }
        if !organization.isEmpty { line(organization, normal) }
        if !website.isEmpty {
            let url = website.contains("://") ? website : "https://\(website)"
            link("Website: ", website, url)
        }
        if !email.isEmpty { link("Email: ", email, "mailto:\(email)") }
        for n in notes { line(n, dim) }
        return out
    }
}

/// Hiện cửa sổ Giới thiệu chuẩn của macOS
func showAboutPanel() {
    let a = AboutInfo.load()
    NSApp.activate(ignoringOtherApps: true)
    var options: [NSApplication.AboutPanelOptionKey: Any] = [
        .applicationName: a.name,
        .applicationVersion: a.version.isEmpty ? "—" : a.version,
        .credits: a.credits(),
    ]
    // Hiện thành "Phiên bản 2.0 (ngày build)"
    options[.version] = a.buildDate.isEmpty ? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") : a.buildDate
    if !a.copyright.isEmpty {
        // Khoá "Copyright" có từ macOS 10.13, ghi đè NSHumanReadableCopyright
        options[NSApplication.AboutPanelOptionKey(rawValue: "Copyright")] = a.copyright
    }
    NSApp.orderFrontStandardAboutPanel(options: options)
}
