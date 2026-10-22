import AppKit
import Foundation

/// The Ambient Session edit, as it was done in Rush (see docs/rush-reference.md): the whole recording on V1
/// with a 0.5 s dip to black and a 0.5 s sound fade at each end, and the title "Ambient / Session NNN"
/// from 11.2 to 50.8 s, left-aligned, in a new colour each session. Trimming is left to the user (Q and W),
/// because where a session starts and ends differs every time.
enum AmbientSession {
    /// The colours Rush used for sessions 001 to 011, in order.
    static let colors: [RGBA] = [
        "F10000", "2BCB00", "0019CB", "03A8A1", "A6A301", "623435", "2595A6", "D41717", "AAB50E", "0E49B5", "D622CE",
    ].map(rgba)

    static let titleStart = 11.233
    static let titleEnd = 50.767
    static let dip = 0.5

    static var recordingsFolder: URL {
        FileManager.default.userHomeDirectory
            .appendingPathComponent("Movies")
    }

    /// "Ambient session 012 - RAW.mov" → 12.
    static func number(from url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let match = name.range(of: #"(?i)session\s*(\d+)"#, options: .regularExpression) else { return nil }
        return Int(name[match].filter(\.isNumber))
    }

    /// Sessions 1 to 11 keep Rush's colours. After that each hue turns by the golden angle from the one
    /// before, so neighbouring sessions always differ and no colour repeats soon.
    static func color(for number: Int) -> RGBA {
        if (1...colors.count).contains(number) { return colors[number - 1] }
        let last = NSColor(srgbRed: colors.last!.r, green: colors.last!.g, blue: colors.last!.b, alpha: 1)
        let steps = Double(max(number - colors.count, 1))
        var hue = last.hueComponent + steps * 137.508 / 360
        hue -= hue.rounded(.down)
        let color = NSColor(hue: hue, saturation: 0.85, brightness: 0.8, alpha: 1).usingColorSpace(.sRGB)!
        return RGBA(r: color.redComponent, g: color.greenComponent, b: color.blueComponent, a: 1)
    }

    /// "Outfit" from the design system unless Rush's Soleil Extra Bold happens to be installed.
    static var titleFont: String {
        let installed = NSFontManager.shared.availableMembers(ofFontFamily: "Soleil") ?? []
        let hasExtraBold = installed.contains { ($0[0] as? String) == "SoleilXb" }
        return hasExtraBold ? "Soleil" : BundledFonts.outfit
    }

    static func displayName(_ number: Int?) -> String {
        number.map { String(format: "Ambient session %03d", $0) } ?? "Ambient session"
    }

    static func project(for recording: MediaItem) -> Project {
        let number = number(from: recording.url)
        var project = Project()
        project.aspect = .landscape
        project.fps = 30
        project.media = [recording]

        var video = Clip(kind: .video, track: 0, start: 0, duration: recording.duration, mediaID: recording.id)
        video.transitionIn = Transition(kind: .dipToBlack, duration: dip)
        video.transitionOut = Transition(kind: .dipToBlack, duration: dip)
        video.fadeIn = dip
        video.fadeOut = dip

        let title = TitleStyle(
            text: "Ambient\nSession " + (number.map { String(format: "%03d", $0) } ?? "000"),
            fontFamily: titleFont, weight: 800, size: 177,
            color: color(for: number ?? colors.count + 1), shadow: false,
            align: .left, lineHeight: 0.77, x: 0.0213, y: 0.467)
        let titleClip = Clip(kind: .title, track: 0, start: titleStart, duration: titleEnd - titleStart, title: title)

        project.clips = [video, titleClip]
        return project
    }

    private static func rgba(_ hex: String) -> RGBA {
        let v = Int(hex, radix: 16)!
        return RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: 1)
    }
}
