import AppKit

/// Help › Send Feedback…: a draft in the user's mail app, addressed to support, with the version of Edwell
/// and of macOS filled in. The app sends nothing; the user sees all of it, edits it and sends it or not.
/// The app collects no usage data, so this is how anyone hears what's wrong.
enum Feedback {
    static let address = "support@iamjarl.com"

    /// What makes a report actionable, and nothing more.
    struct Facts {
        var version: String
        var build: String
        var system: String
    }

    static var current: Facts {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        return Facts(version: info["CFBundleShortVersionString"] as? String ?? "?",
                     build: info["CFBundleVersion"] as? String ?? "?",
                     system: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion), \(chip)")
    }

    static func subject(_ facts: Facts) -> String {
        String(localized: "Edwell \(facts.version) feedback")
    }

    /// Room to write first, then the facts below a signature line.
    static func body(_ facts: Facts) -> String {
        "\n\n\n--\nEdwell \(facts.version) (\(facts.build))\nmacOS \(facts.system)\n"
    }

    static func url(_ facts: Facts) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        // Everything outside the unreserved set is encoded here: `queryItems` leaves `&`, `=` and `+`
        // alone, which would cut a value short.
        components.percentEncodedQueryItems = [
            URLQueryItem(name: "subject", value: encode(subject(facts))),
            URLQueryItem(name: "body", value: encode(body(facts))),
        ]
        return components.url!
    }

    @MainActor static func compose(editor: Editor) {
        let facts = current
        if !NSWorkspace.shared.open(url(facts)) {
            editor.errorMessage = String(localized: "No mail app opened. Write to \(address) and mention Edwell \(facts.version) and macOS \(facts.system).")
        }
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func encode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? s
    }
}

/// Edwell › About Edwell: the standard panel with the version from the bundle, the copyright and two lines
/// of credits, the same in a `swift build` run as in the store build.
enum About {
    static let copyright = "© 2026 IAMJARL"

    @MainActor static func show() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Edwell",
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): copyright,
            .credits: credits,
        ])
        NSApp.activate()
    }

    static var credits: NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ]
        let lines = [
            String(localized: "Questions, or something not working? Write to \(Feedback.address), or choose Send Feedback… in the Help menu."),
            String(localized: "Titles use the Outfit typeface, under the SIL Open Font License."),
        ]
        let text = NSMutableAttributedString(string: lines.joined(separator: "\n\n"), attributes: attributes)
        if let range = text.string.range(of: Feedback.address) {
            text.addAttribute(.link, value: Feedback.url(Feedback.current), range: NSRange(range, in: text.string))
        }
        return text
    }
}
