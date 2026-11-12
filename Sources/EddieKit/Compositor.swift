import AVFoundation
import CoreImage
import CoreText
import AppKit

struct LayerEffect: Sendable {
    var kind: TransitionKind
    var duration: Double
    /// Paired effects are the two halves of a transition between neighbouring clips on the main track.
    var paired: Bool
}

/// Everything the compositor needs to draw one clip. Built by `CompositionBuilder`.
struct RenderLayer: @unchecked Sendable {
    enum Content {
        case video(trackID: CMPersistentTrackID, transform: CGAffineTransform)
        case image(URL)
        case title(TitleStyle)
    }

    var content: Content
    var clipID: UUID
    var start: CMTime
    var end: CMTime
    var scale: Double
    var offsetX: Double
    var offsetY: Double
    var fill: Bool
    var rotation: Double
    var opacity: Double
    var flipH: Bool
    var flipV: Bool
    var crop: (left: Double, right: Double, top: Double, bottom: Double)
    var feather: Double
    /// Title fades. Video and image clips use transitions instead.
    var fadeIn: Double
    var fadeOut: Double
    var inEffect: LayerEffect?
    var outEffect: LayerEffect?
    /// Draw order: lower first. (group, track, start)
    var z: (Int, Int, Double)

    func fadeOpacity(at t: Double) -> Double {
        let s = start.seconds, e = end.seconds
        var o = 1.0
        if fadeIn > 0 { o = min(o, (t - s) / fadeIn) }
        if fadeOut > 0 { o = min(o, (e - t) / fadeOut) }
        return min(max(o, 0), 1)
    }
}

final class EddieInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let layers: [RenderLayer]
    let background: RGBA
    /// Only in the preview; export draws every fade.
    let pausedTitle: PausedTitle?

    init(timeRange: CMTimeRange, layers: [RenderLayer], background: RGBA, pausedTitle: PausedTitle?) {
        self.timeRange = timeRange
        self.layers = layers
        self.background = background
        self.pausedTitle = pausedTitle
        var ids: [NSValue] = []
        for layer in layers {
            if case .video(let id, _) = layer.content { ids.append(NSNumber(value: id)) }
        }
        self.requiredSourceTrackIDs = ids
    }
}

/// The selected title while the preview is paused. Its paused frame is drawn without the title's fades, so a
/// title added at the playhead (where its fade-in starts from nothing) shows while the user types and places it.
/// Playback, every other frame and export are drawn as they are.
final class PausedTitle: @unchecked Sendable {
    private let lock = NSLock()
    private var clipID: UUID?
    private var time: Double = 0

    func set(_ clipID: UUID?, at time: Double) {
        lock.lock(); defer { lock.unlock() }
        self.clipID = clipID
        self.time = time
    }

    func shows(_ clipID: UUID, at t: Double, within tolerance: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return clipID == self.clipID && abs(t - time) <= tolerance
    }
}

/// Custom compositor so preview and export draw exactly the same frame:
/// clips are scaled to fit or fill the frame, stacked by track, and titles are drawn on top.
final class EddieCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "eddie.compositor", qos: .userInitiated)
    // No colour management: frames pass through untouched, as in most editors.
    private let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool { render(request) }
        }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let instruction = request.videoCompositionInstruction as? EddieInstruction,
              let output = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "Eddie", code: 1, userInfo: [NSLocalizedDescriptionKey: String(localized: "Couldn't render the frame")]))
            return
        }
        let size = request.renderContext.size
        let frame = CGRect(origin: .zero, size: size)
        let t = request.compositionTime.seconds
        let frameDuration = request.renderContext.videoComposition.frameDuration.seconds
        let bg = instruction.background

        var image = CIImage(color: CIColor(red: bg.r, green: bg.g, blue: bg.b)).cropped(to: frame)
        for layer in instruction.layers where layer.start.seconds <= t + 1e-6 && t < layer.end.seconds {
            guard var layerImage = content(of: layer, request: request, canvas: size) else { continue }
            var opacity = layer.opacity
            if case .title = layer.content,
               instruction.pausedTitle?.shows(layer.clipID, at: t, within: frameDuration / 2) != true {
                opacity *= layer.fadeOpacity(at: t)
            }
            if opacity <= 0 { continue }
            if opacity < 1 { layerImage = layerImage.withOpacity(opacity) }
            image = Transitions.composite(layerImage, layer: layer, at: t, over: image, frame: frame)
        }

        let bufferWidth = CGFloat(CVPixelBufferGetWidth(output))
        let bufferHeight = CGFloat(CVPixelBufferGetHeight(output))
        let scale = bufferWidth / size.width
        if abs(scale - 1) > 0.001 { image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) }
        context.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: bufferWidth, height: bufferHeight), colorSpace: nil)
        request.finish(withComposedVideoFrame: output)
    }

    private func content(of layer: RenderLayer, request: AVAsynchronousVideoCompositionRequest, canvas: CGSize) -> CIImage? {
        switch layer.content {
        case .video(let trackID, let transform):
            guard let buffer = request.sourceFrame(byTrackID: trackID) else { return nil }
            let source = CIImage(cvPixelBuffer: buffer).oriented(orientation(for: transform)).movedToOrigin()
            return place(source, layer: layer, canvas: canvas)
        case .image(let url):
            guard let source = ImageCache.image(url) else { return nil }
            return place(source, layer: layer, canvas: canvas)
        case .title(let style):
            guard let title = TitleRenderer.image(style, canvas: canvas) else { return nil }
            let size = title.image.extent.size
            // x is the text's left edge, centre or right edge; the margin around the text doesn't count.
            let anchor = style.x * canvas.width
            let x = switch style.align {
            case .left: anchor - title.margin
            case .center: anchor - size.width / 2
            case .right: anchor - size.width + title.margin
            }
            // CoreImage is y-up; the style's y is measured from the top.
            let y = (1 - style.y) * canvas.height - size.height / 2
            return title.image.transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
        }
    }

    /// Flip, crop and feather in source space, then scale to fit or fill, move, and rotate around the picture's centre.
    private func place(_ source: CIImage, layer: RenderLayer, canvas: CGSize) -> CIImage? {
        let w = source.extent.width, h = source.extent.height
        guard w > 0, h > 0 else { return nil }
        let fit = min(canvas.width / w, canvas.height / h)
        let fill = max(canvas.width / w, canvas.height / h)
        let s = (layer.fill ? fill : fit) * layer.scale

        var image = source
        if layer.flipH || layer.flipV {
            image = image.transformed(by: CGAffineTransform(scaleX: layer.flipH ? -1 : 1, y: layer.flipV ? -1 : 1)
                .concatenating(CGAffineTransform(translationX: layer.flipH ? w : 0, y: layer.flipV ? h : 0)))
        }
        let c = layer.crop
        if c.left + c.right + c.top + c.bottom > 0 || layer.feather > 0 {
            let rect = CGRect(x: w * c.left, y: h * c.bottom,
                              width: w * (1 - c.left - c.right), height: h * (1 - c.top - c.bottom))
            guard rect.width > 1, rect.height > 1 else { return nil }
            if layer.feather > 0 {
                let mask = CIImage(color: .white).cropped(to: rect)
                    .applyingGaussianBlur(sigma: layer.feather / s)
                    .cropped(to: source.extent)
                image = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask,
                ])
            } else {
                image = image.cropped(to: rect)
            }
        }

        let tx = (canvas.width - w * s) / 2 + layer.offsetX * canvas.width
        let ty = (canvas.height - h * s) / 2 - layer.offsetY * canvas.height
        var transform = CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: tx, y: ty))
        if layer.rotation != 0 {
            let cx = tx + w * s / 2, cy = ty + h * s / 2
            transform = transform
                .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
                .concatenating(CGAffineTransform(rotationAngle: -layer.rotation * .pi / 180))
                .concatenating(CGAffineTransform(translationX: cx, y: cy))
        }
        return image.transformed(by: transform)
    }

    /// Maps a track's preferredTransform (e.g. a phone held upright) to the orientation CoreImage needs.
    private func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
        case (0, 1, -1, 0): .right
        case (0, -1, 1, 0): .left
        case (-1, 0, 0, -1): .down
        default: .up
        }
    }
}

/// How a clip enters or leaves. Progress runs 0 → 1 over the effect's duration.
enum Transitions {
    static func composite(_ image: CIImage, layer: RenderLayer, at t: Double, over below: CIImage, frame: CGRect) -> CIImage {
        if let effect = layer.inEffect, effect.duration > 0 {
            let p = (t - layer.start.seconds) / effect.duration
            if p < 1 { return enter(image, effect: effect, progress: max(p, 0), over: below, frame: frame) }
        }
        if let effect = layer.outEffect, effect.duration > 0 {
            let remaining = (layer.end.seconds - t) / effect.duration
            if remaining < 1 { return leave(image, effect: effect, progress: 1 - max(remaining, 0), over: below, frame: frame) }
        }
        return image.composited(over: below)
    }

    private static func enter(_ image: CIImage, effect: LayerEffect, progress p: Double, over below: CIImage, frame: CGRect) -> CIImage {
        switch effect.kind {
        case .crossDissolve:
            return image.withOpacity(p).composited(over: below)
        case .dipToBlack, .dipToWhite:
            let solid = solidColor(effect.kind, frame: frame)
            if effect.paired {
                // First half: the outgoing clip fades to the colour. Second half: this clip fades up from it.
                if p < 0.5 { return solid.withOpacity(p * 2).composited(over: below) }
                return solid.withOpacity(2 - p * 2).composited(over: image.composited(over: solid))
            }
            // As in Rush: the colour holds for the first half, the picture comes up in the second.
            return tint(image, toward: effect.kind, amount: p < 0.5 ? 1 : 2 - p * 2).composited(over: below)
        default:
            let v = effect.kind.pushVector ?? .zero
            let e = 1 - smooth(p)
            // Enters from the side opposite to the direction of movement. Screen y points down, CoreImage y up.
            let moved = image.transformed(by: CGAffineTransform(translationX: -v.dx * e * frame.width, y: v.dy * e * frame.height))
            return moved.composited(over: below)
        }
    }

    private static func leave(_ image: CIImage, effect: LayerEffect, progress p: Double, over below: CIImage, frame: CGRect) -> CIImage {
        switch effect.kind {
        case .crossDissolve:
            // When paired, the incoming clip on top does the dissolve.
            return (effect.paired ? image : image.withOpacity(1 - p)).composited(over: below)
        case .dipToBlack, .dipToWhite:
            // The picture goes in the first half, the colour holds for the second.
            return (effect.paired ? image : tint(image, toward: effect.kind, amount: min(p * 2, 1))).composited(over: below)
        default:
            let v = effect.kind.pushVector ?? .zero
            let e = smooth(p)
            let moved = image.transformed(by: CGAffineTransform(translationX: v.dx * e * frame.width, y: -v.dy * e * frame.height))
            return moved.composited(over: below)
        }
    }

    private static func solidColor(_ kind: TransitionKind, frame: CGRect) -> CIImage {
        CIImage(color: kind == .dipToWhite ? .white : .black).cropped(to: frame)
    }

    /// Paints the colour over the picture only where the picture is, so overlays dip on their own.
    private static func tint(_ image: CIImage, toward kind: TransitionKind, amount: Double) -> CIImage {
        guard amount > 0 else { return image }
        let color = CIImage(color: kind == .dipToWhite ? .white : .black).cropped(to: image.extent).withOpacity(min(amount, 1))
        return color.applyingFilter("CISourceAtopCompositing", parameters: [kCIInputBackgroundImageKey: image])
    }

    private static func smooth(_ p: Double) -> Double { p * p * (3 - 2 * p) }
}

extension CIImage {
    func movedToOrigin() -> CIImage {
        transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    func withOpacity(_ alpha: Double) -> CIImage {
        // Images are premultiplied, so every channel is scaled.
        let a = CGFloat(alpha)
        return applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
        ])
    }
}

enum ImageCache {
    private static let cache = NSCache<NSURL, CIImage>()

    static func image(_ url: URL) -> CIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let loaded = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
        // Render once to a bitmap so the file isn't decoded again for every frame.
        let flat = CIContext(options: [.workingColorSpace: NSNull()])
        let image: CIImage
        if let cg = flat.createCGImage(loaded, from: loaded.extent) {
            image = CIImage(cgImage: cg)
        } else {
            image = loaded
        }
        let result = image.movedToOrigin()
        cache.setObject(result, forKey: url as NSURL)
        return result
    }
}

/// A rendered title and the empty room around its text (for the shadow and the box).
final class RenderedTitle {
    let image: CIImage
    let margin: CGFloat
    init(image: CIImage, margin: CGFloat) { self.image = image; self.margin = margin }
}

enum TitleRenderer {
    private static let cache = NSCache<NSString, RenderedTitle>()

    static func image(_ style: TitleStyle, canvas: CGSize) -> RenderedTitle? {
        let key = "\(style.hashValue)-\(Int(canvas.width))x\(Int(canvas.height))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let title = render(style, canvas: canvas) else { return nil }
        cache.setObject(title, forKey: key)
        return title
    }

    private static let weightAxis = 0x7767_6874 // 'wght'

    /// The family at the style's weight: exactly, along the weight axis of a variable font,
    /// or the nearest face the family has.
    static func font(_ style: TitleStyle) -> CTFont {
        let family = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: style.fontFamily] as CFDictionary)
        let base = CTFontCreateWithFontDescriptor(family, style.size, nil)
        if let axes = CTFontCopyVariationAxes(base) as? [[CFString: Any]],
           let axis = axes.first(where: { ($0[kCTFontVariationAxisIdentifierKey] as? NSNumber)?.intValue == weightAxis }) {
            let low = (axis[kCTFontVariationAxisMinimumValueKey] as? NSNumber)?.doubleValue ?? 100
            let high = (axis[kCTFontVariationAxisMaximumValueKey] as? NSNumber)?.doubleValue ?? 900
            let variation = [NSNumber(value: weightAxis): NSNumber(value: min(max(style.weight, low), high))]
            let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontVariationAttribute: variation] as CFDictionary)
            return CTFontCreateCopyWithAttributes(base, style.size, nil, descriptor)
        }
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: style.fontFamily,
            kCTFontTraitsAttribute: [kCTFontWeightTrait: coreTextWeight(style.weight)],
        ] as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, style.size, nil)
    }

    /// CSS-style weights (100–900) on CoreText's −1…1 weight trait.
    private static func coreTextWeight(_ weight: Double) -> Double {
        let table: [(Double, Double)] = [(100, -0.8), (200, -0.6), (300, -0.4), (400, 0), (500, 0.23),
                                         (600, 0.3), (700, 0.4), (800, 0.56), (900, 0.62)]
        let w = min(max(weight, 100), 900)
        for (a, b) in zip(table, table.dropFirst()) where w <= b.0 {
            return a.1 + (b.1 - a.1) * (w - a.0) / (b.0 - a.0)
        }
        return 0.62
    }

    private static func render(_ style: TitleStyle, canvas: CGSize) -> RenderedTitle? {
        let text = style.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, style.size > 0 else { return nil }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = switch style.align {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        if style.lineHeight != 1 { paragraph.lineHeightMultiple = style.lineHeight }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): style.color.cgColor,
            .paragraphStyle: paragraph,
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let maxWidth = canvas.width * 0.9
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let textWidth = ceil(suggested.width) + 2
        let textHeight = ceil(suggested.height) + 2

        let padding = style.background ? style.size * 0.3 : 0
        let shadowRoom = style.shadow ? style.size * 0.2 : 0
        let margin = ceil(padding + shadowRoom)
        let width = Int(textWidth + margin * 2), height = Int(textHeight + margin * 2)

        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        if style.background {
            let box = CGRect(x: shadowRoom, y: shadowRoom, width: CGFloat(width) - shadowRoom * 2, height: CGFloat(height) - shadowRoom * 2)
            let radius = style.size * 0.2
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(style.backgroundColor.cgColor)
            ctx.fillPath()
        }
        if style.shadow {
            ctx.setShadow(offset: CGSize(width: 0, height: -style.size * 0.04), blur: style.size * 0.12,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.75))
        }
        let path = CGPath(rect: CGRect(x: margin, y: margin, width: textWidth, height: textHeight), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)

        guard let cg = ctx.makeImage() else { return nil }
        return RenderedTitle(image: CIImage(cgImage: cg), margin: margin)
    }
}
