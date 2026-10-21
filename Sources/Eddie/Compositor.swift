import AVFoundation
import CoreImage
import CoreText
import AppKit

/// Everything the compositor needs to draw one clip. Built by `CompositionBuilder`.
struct RenderLayer: @unchecked Sendable {
    enum Content {
        case video(trackID: CMPersistentTrackID, transform: CGAffineTransform)
        case image(URL)
        case title(TitleStyle)
    }

    var content: Content
    var start: CMTime
    var end: CMTime
    var scale: Double
    var offsetX: Double
    var offsetY: Double
    var fill: Bool
    var fadeIn: Double
    var fadeOut: Double
    /// Draw order: lower first. (group, track, start)
    var z: (Int, Int, Double)

    func opacity(at t: Double) -> Double {
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

    init(timeRange: CMTimeRange, layers: [RenderLayer], background: RGBA) {
        self.timeRange = timeRange
        self.layers = layers
        self.background = background
        var ids: [NSValue] = []
        for layer in layers {
            if case .video(let id, _) = layer.content { ids.append(NSNumber(value: id)) }
        }
        self.requiredSourceTrackIDs = ids
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
            request.finish(with: NSError(domain: "Eddie", code: 1, userInfo: [NSLocalizedDescriptionKey: "Kunne ikke rendere billede"]))
            return
        }
        let size = request.renderContext.size
        let frame = CGRect(origin: .zero, size: size)
        let t = request.compositionTime.seconds
        let bg = instruction.background

        var image = CIImage(color: CIColor(red: bg.r, green: bg.g, blue: bg.b)).cropped(to: frame)
        for layer in instruction.layers where layer.start.seconds <= t + 1e-6 && t < layer.end.seconds {
            guard var layerImage = content(of: layer, request: request, canvas: size) else { continue }
            let opacity = layer.opacity(at: t)
            if opacity <= 0 { continue }
            if opacity < 1 { layerImage = layerImage.withOpacity(opacity) }
            image = layerImage.composited(over: image)
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
            guard let text = TitleRenderer.image(style, canvas: canvas) else { return nil }
            // CoreImage is y-up; the style's y is measured from the top.
            let x = style.x * canvas.width - text.extent.width / 2
            let y = (1 - style.y) * canvas.height - text.extent.height / 2
            return text.transformed(by: CGAffineTransform(translationX: x.rounded(), y: y.rounded()))
        }
    }

    private func place(_ source: CIImage, layer: RenderLayer, canvas: CGSize) -> CIImage {
        let w = source.extent.width, h = source.extent.height
        guard w > 0, h > 0 else { return source }
        let fit = min(canvas.width / w, canvas.height / h)
        let fill = max(canvas.width / w, canvas.height / h)
        let s = (layer.fill ? fill : fit) * layer.scale
        let tx = (canvas.width - w * s) / 2 + layer.offsetX * canvas.width
        let ty = (canvas.height - h * s) / 2 - layer.offsetY * canvas.height
        return source.transformed(by: CGAffineTransform(scaleX: s, y: s).concatenating(CGAffineTransform(translationX: tx, y: ty)))
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

enum TitleRenderer {
    private static let cache = NSCache<NSString, CIImage>()

    static func image(_ style: TitleStyle, canvas: CGSize) -> CIImage? {
        let key = "\(style.hashValue)-\(Int(canvas.width))x\(Int(canvas.height))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = render(style, canvas: canvas) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    static func font(_ style: TitleStyle) -> CTFont {
        var attributes: [CFString: Any] = [kCTFontFamilyNameAttribute: style.fontFamily]
        if style.bold {
            attributes[kCTFontTraitsAttribute] = [kCTFontSymbolicTrait: CTFontSymbolicTraits.traitBold.rawValue]
        }
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateWithFontDescriptor(descriptor, style.size, nil)
    }

    private static func render(_ style: TitleStyle, canvas: CGSize) -> CIImage? {
        let text = style.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, style.size > 0 else { return nil }

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
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
        return CIImage(cgImage: cg)
    }
}
