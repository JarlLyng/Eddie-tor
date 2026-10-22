import AppKit
import CoreText

/// Faces that ship with Eddie, so a project looks the same on any Mac.
/// Outfit (OFL-1.1) comes from the IAMJARL design system; its licence is in `Resources/Fonts`.
enum BundledFonts {
    /// The family name of Outfit's variable font, which is named after its default instance.
    static let outfit = "Outfit Thin"

    static func register() {
        guard let dir = fontsDirectory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where ["woff2", "woff", "ttf", "otf"].contains(file.pathExtension.lowercased()) {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }

    /// The name shown in the font menu.
    static func displayName(_ family: String) -> String {
        family == outfit ? "Outfit" : family
    }

    /// Inside the app: Contents/Resources/Fonts. Built with `swift build`: the repository's Resources/Fonts.
    private static var fontsDirectory: URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fonts")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
    }
}
