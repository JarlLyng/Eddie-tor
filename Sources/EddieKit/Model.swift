import AppKit
import SwiftUI

enum AspectRatio: String, Codable, CaseIterable, Identifiable, Sendable {
    case landscape, portrait, square, vertical45

    var id: String { rawValue }

    var label: String {
        switch self {
        case .landscape: "16:9"
        case .portrait: "9:16"
        case .square: "1:1"
        case .vertical45: "4:5"
        }
    }

    var renderSize: CGSize {
        switch self {
        case .landscape: CGSize(width: 1920, height: 1080)
        case .portrait: CGSize(width: 1080, height: 1920)
        case .square: CGSize(width: 1080, height: 1080)
        case .vertical45: CGSize(width: 1080, height: 1350)
        }
    }

    var ratio: CGFloat { renderSize.width / renderSize.height }

    /// The format closest to a picture's shape, so the first clip in a new project isn't cropped to a
    /// format nobody chose. 4:3 counts as 16:9, 3:4 as 4:5. Nil for something without a picture.
    static func fitting(width: Double, height: Double) -> AspectRatio? {
        guard width > 0, height > 0 else { return nil }
        switch width / height {
        case 1.15...: return .landscape
        case 0.9..<1.15: return .square
        case 0.68..<0.9: return .vertical45
        default: return .portrait
        }
    }
}

struct RGBA: Codable, Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double

    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let black = RGBA(r: 0, g: 0, b: 0, a: 1)

    init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum MediaKind: String, Codable, Sendable {
    case video, audio, image
}

struct MediaItem: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var url: URL
    var kind: MediaKind
    /// Seconds. 0 for still images.
    var duration: Double
    var width: Double
    var height: Double
    var hasAudio: Bool
    /// A security-scoped bookmark, so the sandboxed app can read the file again after a relaunch (`MediaAccess`).
    var bookmark: Data? = nil
    /// Where the file was relative to the project file's folder when it was saved, for media moved with it.
    var relativePath: String? = nil

    var name: String { url.lastPathComponent }
}

enum ClipKind: String, Codable, Sendable {
    case video, image, audio, title
}

/// Clips of the same group share tracks: video and images both live on the visual tracks.
enum TrackGroup: String, Sendable {
    case title, visual, audio
}

enum TextAlign: String, Codable, CaseIterable, Identifiable, Sendable {
    case left, center, right
    var id: String { rawValue }
}

struct TitleStyle: Codable, Hashable, Sendable {
    var text = String(localized: "Your text")
    var fontFamily = "Helvetica Neue"
    /// 100 (thin) to 900 (black). Variable fonts get exactly this weight; others the nearest one they have.
    var weight: Double = 700
    /// Font size in pixels of the rendered frame.
    var size: Double = 90
    var color = RGBA.white
    var shadow = true
    var background = false
    var backgroundColor = RGBA(r: 0, g: 0, b: 0, a: 0.6)
    var align = TextAlign.center
    /// Multiple of the font's own line height.
    var lineHeight: Double = 1
    /// Normalised 0...1 from the top-left corner. Vertically the centre of the text box; horizontally its
    /// left edge, centre or right edge, following `align`.
    var x: Double = 0.5
    var y: Double = 0.8

    init(text: String = String(localized: "Your text"), fontFamily: String = "Helvetica Neue", weight: Double = 700, size: Double = 90,
         color: RGBA = .white, shadow: Bool = true, background: Bool = false,
         backgroundColor: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6), align: TextAlign = .center, lineHeight: Double = 1,
         x: Double = 0.5, y: Double = 0.8) {
        self.text = text; self.fontFamily = fontFamily; self.weight = weight; self.size = size
        self.color = color; self.shadow = shadow; self.background = background; self.backgroundColor = backgroundColor
        self.align = align; self.lineHeight = lineHeight; self.x = x; self.y = y
    }

    private enum CodingKeys: String, CodingKey {
        case text, fontFamily, weight, bold, size, color, shadow, background, backgroundColor, align, lineHeight, x, y
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TitleStyle()
        text = try c.value(.text, d.text)
        fontFamily = try c.value(.fontFamily, d.fontFamily)
        // Version 1 files had a bold switch instead of a weight.
        let bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? true
        weight = try c.value(.weight, bold ? 700 : 400)
        size = try c.value(.size, d.size)
        color = try c.value(.color, d.color)
        shadow = try c.value(.shadow, d.shadow)
        background = try c.value(.background, d.background)
        backgroundColor = try c.value(.backgroundColor, d.backgroundColor)
        align = try c.value(.align, d.align)
        lineHeight = try c.value(.lineHeight, d.lineHeight)
        x = try c.value(.x, d.x)
        y = try c.value(.y, d.y)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(weight, forKey: .weight)
        try c.encode(size, forKey: .size)
        try c.encode(color, forKey: .color)
        try c.encode(shadow, forKey: .shadow)
        try c.encode(background, forKey: .background)
        try c.encode(backgroundColor, forKey: .backgroundColor)
        try c.encode(align, forKey: .align)
        try c.encode(lineHeight, forKey: .lineHeight)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
    }
}

struct Clip: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var kind: ClipKind
    var track: Int
    /// Position on the timeline in seconds.
    var start: Double
    var duration: Double

    var mediaID: UUID?
    /// Offset into the source media in seconds.
    var sourceIn: Double = 0

    var volume: Double = 1
    var fadeIn: Double = 0
    var fadeOut: Double = 0

    var scale: Double = 1
    /// Normalised to the frame size; positive y moves down.
    var offsetX: Double = 0
    var offsetY: Double = 0
    var fill = true

    var title: TitleStyle?

    /// Playback speed; 2 is twice as fast. `duration` is the time on the timeline,
    /// so the clip uses `duration * speed` seconds of its source.
    var speed: Double = 1
    var maintainPitch = true
    /// The clip's audio has been moved to its own clip on an audio track.
    var audioDetached = false

    /// Degrees, clockwise.
    var rotation: Double = 0
    var opacity: Double = 1
    var flipH = false
    var flipV = false
    /// Fractions (0...1) of the source cut away from each edge.
    var cropLeft: Double = 0
    var cropRight: Double = 0
    var cropTop: Double = 0
    var cropBottom: Double = 0
    /// Soft edge in pixels of the rendered frame.
    var feather: Double = 0

    var transitionIn: Transition?
    var transitionOut: Transition?

    var end: Double { start + duration }
    var sourceDuration: Double { duration * speed }

    var group: TrackGroup {
        switch kind {
        case .video, .image: .visual
        case .title: .title
        case .audio: .audio
        }
    }

    var hasMediaTiming: Bool { kind == .video || kind == .audio }
}

enum TransitionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case crossDissolve, dipToBlack, dipToWhite, pushLeft, pushRight, pushUp, pushDown

    var id: String { rawValue }

    var label: String {
        switch self {
        case .crossDissolve: String(localized: "Cross Dissolve")
        case .dipToBlack: String(localized: "Dip to Black")
        case .dipToWhite: String(localized: "Dip to White")
        case .pushLeft: String(localized: "Push Left")
        case .pushRight: String(localized: "Push Right")
        case .pushUp: String(localized: "Push Up")
        case .pushDown: String(localized: "Push Down")
        }
    }

    /// Direction the picture moves, in screen terms (y down).
    var pushVector: CGVector? {
        switch self {
        case .pushLeft: CGVector(dx: -1, dy: 0)
        case .pushRight: CGVector(dx: 1, dy: 0)
        case .pushUp: CGVector(dx: 0, dy: -1)
        case .pushDown: CGVector(dx: 0, dy: 1)
        default: nil
        }
    }
}

struct Transition: Codable, Hashable, Sendable {
    var kind: TransitionKind = .crossDissolve
    var duration: Double = 0.5
}

struct TrackFlags: Codable, Hashable, Sendable {
    var hidden = false
    var muted = false
    var locked = false
}

struct Project: Codable, Equatable, Sendable {
    var version = 2
    var aspect: AspectRatio = .portrait
    /// Set once the user picks a format. Until then the first video or photo on the timeline sets it.
    var aspectChosen = false
    var fps = 30
    var background = RGBA.black
    var titleTracks = 2
    var visualTracks = 3
    var audioTracks = 2
    var media: [MediaItem] = []
    var clips: [Clip] = []
    /// Like Rush: clips on V1 always sit back to back from the start, so deleting or trimming closes the gap.
    var magneticMain = true
    /// Keyed by `TrackRow.id`.
    var trackFlags: [String: TrackFlags] = [:]
    var inPoint: Double?
    var outPoint: Double?

    var duration: Double { clips.map(\.end).max() ?? 0 }

    func flags(_ group: TrackGroup, _ index: Int) -> TrackFlags {
        trackFlags[TrackRow(group: group, index: index).id] ?? TrackFlags()
    }

    func isMagnetic(_ clip: Clip) -> Bool {
        magneticMain && clip.group == .visual && clip.track == 0
    }

    func media(_ id: UUID?) -> MediaItem? {
        guard let id else { return nil }
        return media.first { $0.id == id }
    }

    func trackCount(_ group: TrackGroup) -> Int {
        switch group {
        case .title: titleTracks
        case .visual: visualTracks
        case .audio: audioTracks
        }
    }
}

struct TrackRow: Identifiable, Hashable {
    let group: TrackGroup
    let index: Int

    var id: String { "\(group.rawValue)\(index)" }

    var label: String {
        switch group {
        case .title: "T\(index + 1)"
        case .visual: "V\(index + 1)"
        case .audio: "A\(index + 1)"
        }
    }

    var height: CGFloat {
        switch group {
        case .title: 34
        case .visual: 56
        case .audio: 46
        }
    }

    /// Visual and title rows are drawn with the highest track on top, audio rows the other way round,
    /// so dragging a clip down moves it to a lower visual track but a higher audio track.
    var downwardStep: Int { group == .audio ? 1 : -1 }
}

func timecode(_ seconds: Double, fps: Int) -> String {
    let s = max(0, seconds)
    let whole = Int(s)
    let frames = Int(((s - Double(whole)) * Double(fps)).rounded(.down))
    let h = whole / 3600, m = (whole / 60) % 60, sec = whole % 60
    if h > 0 { return String(format: "%d:%02d:%02d:%02d", h, m, sec, frames) }
    return String(format: "%02d:%02d:%02d", m, sec, frames)
}

/// SwiftUI's `@State` is a macro in the macOS 27 SDK whose plugin ships only with Xcode.
/// Using the underlying property wrapper under another name lets Eddie build with the Command Line Tools alone.
typealias ViewState = SwiftUI.State

// Decoding fills in defaults for keys missing from files saved by earlier versions.
extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

extension Clip {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Clip(kind: .video, track: 0, start: 0, duration: 0)
        id = try c.value(.id, d.id)
        kind = try c.decode(ClipKind.self, forKey: .kind)
        track = try c.value(.track, 0)
        start = try c.value(.start, 0)
        duration = try c.value(.duration, 0)
        mediaID = try c.decodeIfPresent(UUID.self, forKey: .mediaID)
        sourceIn = try c.value(.sourceIn, d.sourceIn)
        volume = try c.value(.volume, d.volume)
        fadeIn = try c.value(.fadeIn, d.fadeIn)
        fadeOut = try c.value(.fadeOut, d.fadeOut)
        scale = try c.value(.scale, d.scale)
        offsetX = try c.value(.offsetX, d.offsetX)
        offsetY = try c.value(.offsetY, d.offsetY)
        fill = try c.value(.fill, d.fill)
        title = try c.decodeIfPresent(TitleStyle.self, forKey: .title)
        speed = try c.value(.speed, d.speed)
        maintainPitch = try c.value(.maintainPitch, d.maintainPitch)
        audioDetached = try c.value(.audioDetached, d.audioDetached)
        rotation = try c.value(.rotation, d.rotation)
        opacity = try c.value(.opacity, d.opacity)
        flipH = try c.value(.flipH, d.flipH)
        flipV = try c.value(.flipV, d.flipV)
        cropLeft = try c.value(.cropLeft, d.cropLeft)
        cropRight = try c.value(.cropRight, d.cropRight)
        cropTop = try c.value(.cropTop, d.cropTop)
        cropBottom = try c.value(.cropBottom, d.cropBottom)
        feather = try c.value(.feather, d.feather)
        transitionIn = try c.decodeIfPresent(Transition.self, forKey: .transitionIn)
        transitionOut = try c.decodeIfPresent(Transition.self, forKey: .transitionOut)
    }
}

extension Project {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Project()
        version = try c.value(.version, d.version)
        aspect = try c.value(.aspect, d.aspect)
        fps = try c.value(.fps, d.fps)
        background = try c.value(.background, d.background)
        titleTracks = try c.value(.titleTracks, d.titleTracks)
        visualTracks = try c.value(.visualTracks, d.visualTracks)
        audioTracks = try c.value(.audioTracks, d.audioTracks)
        media = try c.value(.media, d.media)
        clips = try c.value(.clips, d.clips)
        // A file from before the flag keeps its format once it has a picture in it.
        aspectChosen = try c.value(.aspectChosen, clips.contains { $0.group == .visual })
        magneticMain = try c.value(.magneticMain, d.magneticMain)
        trackFlags = try c.value(.trackFlags, d.trackFlags)
        inPoint = try c.decodeIfPresent(Double.self, forKey: .inPoint)
        outPoint = try c.decodeIfPresent(Double.self, forKey: .outPoint)
    }
}
