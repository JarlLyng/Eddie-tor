import AVFoundation
import AppKit
import UniformTypeIdentifiers

/// `Eddie --selftest <dir>`: generates test media, builds a project with every clip type,
/// exports it and saves frames as PNG so the result can be checked without the UI.
enum SelfTest {
    static func run(outputDirectory dir: URL) -> Never {
        Task {
            do {
                try await perform(dir)
                print("SELFTEST OK")
                exit(0)
            } catch {
                print("SELFTEST FAILED: \(error)")
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func perform(_ dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let landscape = dir.appendingPathComponent("landscape.mov")
        let rotated = dir.appendingPathComponent("rotated.mov")
        let image = dir.appendingPathComponent("image.png")
        let tone = dir.appendingPathComponent("tone.m4a")

        try await writeVideo(to: landscape, seconds: 3, transform: .identity)
        // Like an iPhone held upright: landscape pixels plus a 90° rotation.
        try await writeVideo(to: rotated, seconds: 3, transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0))
        try writeImage(to: image)
        try writeTone(to: tone, seconds: 6)

        var project = Project()
        project.aspect = .portrait
        for url in [landscape, rotated, image, tone] {
            guard let item = await MediaLoader.load(url) else { throw err("Kunne ikke indlæse \(url.lastPathComponent)") }
            project.media.append(item)
            print("media", item.name, item.kind, item.duration, item.width, "x", item.height)
        }
        let m = project.media
        project.clips = [
            Clip(kind: .video, track: 0, start: 0, duration: 3, mediaID: m[0].id),
            Clip(kind: .video, track: 0, start: 3, duration: 3, mediaID: m[1].id, fill: false),
            Clip(kind: .image, track: 1, start: 1, duration: 1.5, mediaID: m[2].id, scale: 0.4, offsetY: -0.3),
            Clip(kind: .title, track: 0, start: 0.5, duration: 4, fadeIn: 0.25, fadeOut: 0.25,
                 title: TitleStyle(text: "Hej Eddie\nanden linje", background: true)),
            Clip(kind: .audio, track: 0, start: 0, duration: 6, mediaID: m[3].id, volume: 0.5, fadeOut: 1),
        ]

        let data = try JSONEncoder().encode(project)
        guard try JSONDecoder().decode(Project.self, from: data) == project else { throw err("JSON round trip") }
        try data.write(to: dir.appendingPathComponent("demo.eddie"))

        let output = dir.appendingPathComponent("selftest.mp4")
        try await Exporter.export(project, to: output, codec: .h264) { _ in }

        let result = AVURLAsset(url: output)
        let duration = try await result.load(.duration).seconds
        let video = try await result.loadTracks(withMediaType: .video)
        let audio = try await result.loadTracks(withMediaType: .audio)
        let size = try await video.first?.load(.naturalSize) ?? .zero
        print("export duration \(duration) size \(size) videoTracks \(video.count) audioTracks \(audio.count)")
        guard abs(duration - 6) < 0.1, size == CGSize(width: 1080, height: 1920), video.count == 1, audio.count == 1 else {
            throw err("Uventet eksport")
        }

        for t in [0.25, 1.5, 4.0, 5.9] {
            try await saveFrame(of: result, at: t, to: dir.appendingPathComponent(String(format: "frame-%.2f.png", t)))
        }
        try await saveFrame(of: AVURLAsset(url: rotated), at: 0.5, to: dir.appendingPathComponent("reference-rotated.png"))

        // Every aspect ratio must build and render.
        for aspect in AspectRatio.allCases {
            var p = project
            p.aspect = aspect
            let url = dir.appendingPathComponent("aspect-\(aspect.rawValue).mp4")
            try await Exporter.export(p, to: url, codec: .hevc) { _ in }
            let s = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first?.load(.naturalSize)
            print("aspect \(aspect.label): \(s ?? .zero)")
            try await saveFrame(of: AVURLAsset(url: url), at: 1.5, to: dir.appendingPathComponent("aspect-\(aspect.rawValue).png"))
        }

        // A project with only a title and no media still exports.
        var titleOnly = Project()
        titleOnly.clips = [Clip(kind: .title, track: 0, start: 0, duration: 2, title: TitleStyle(text: "Kun tekst"))]
        try await Exporter.export(titleOnly, to: dir.appendingPathComponent("title-only.mp4"), codec: .h264) { _ in }
        print("title-only export ok")

        try await MainActor.run { try editingTests(media: m) }
        print("editing tests ok")
    }

    @MainActor
    private static func editingTests(media: [MediaItem]) throws {
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw err("Redigering: \(message)") } }
        let editor = Editor(persist: false)
        editor.edit { $0.media = media }
        let video = media[0], tone = media[3]

        // Appending puts clips back to back on V1.
        editor.add(video)
        editor.add(video)
        let v1 = editor.project.clips.filter { $0.group == .visual }.sorted { $0.start < $1.start }
        try check(v1.count == 2 && v1[0].start == 0 && abs(v1[1].start - 3) < 1e-9, "tilføj i forlængelse")

        // Dropping onto an occupied spot slides to the next free one.
        try check(editor.freeStart(.visual, track: 0, desired: 1, duration: 2) == 6, "fri plads")

        // Splitting keeps the source position continuous.
        editor.selection = v1[0].id
        editor.seek(0)
        editor.currentTime = 1.2
        editor.splitAtPlayhead()
        let parts = editor.project.clips.filter { $0.mediaID == video.id }.sorted { $0.start < $1.start }
        try check(parts.count == 3, "del giver tre klip")
        try check(abs(parts[0].duration - 1.2) < 1e-9 && abs(parts[1].start - 1.2) < 1e-9 && abs(parts[1].sourceIn - 1.2) < 1e-9
                  && abs(parts[1].end - 3) < 1e-9, "del bevarer timing")

        // Undo and redo.
        editor.undo()
        try check(editor.project.clips.filter { $0.mediaID == video.id }.count == 2, "fortryd del")
        editor.redo()
        try check(editor.project.clips.filter { $0.mediaID == video.id }.count == 3, "gentag del")

        // Titles and music.
        editor.currentTime = 0.5
        editor.addTitle()
        try check(editor.selectedClip?.kind == .title && editor.selectedClip?.start == 0.5, "tilføj tekst")
        editor.add(tone)
        try check(editor.selectedClip?.group == .audio && editor.selectedClip?.track == 0, "musik på lydspor")

        // Coalesced edits make one undo step.
        let id = editor.selectedClip!.id
        let before = editor.project
        for v in stride(from: 0.9, through: 0.3, by: -0.1) { editor.updateClip(id, coalesce: "volume") { $0.volume = v } }
        editor.undo()
        try check(editor.project == before, "samlet fortryd for skyder")

        // Delete.
        editor.selection = id
        editor.deleteSelection()
        try check(!editor.project.clips.contains { $0.id == id } && editor.selection == nil, "slet")
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "SelfTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func saveFrame(of asset: AVAsset, at seconds: Double, to url: URL) async throws {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (cg, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }

    /// 1920×1080 frames whose colour changes each second, with a white marker in the top-left
    /// and a yellow one in the top-right corner so rotation and mirroring are visible.
    private static func writeVideo(to url: URL, seconds: Int, transform: CGAffineTransform) async throws {
        try? FileManager.default.removeItem(at: url)
        let width = 1920, height = 1080, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let colors: [CGColor] = [
            CGColor(srgbRed: 0.8, green: 0.2, blue: 0.2, alpha: 1),
            CGColor(srgbRed: 0.2, green: 0.7, blue: 0.3, alpha: 1),
            CGColor(srgbRed: 0.2, green: 0.3, blue: 0.8, alpha: 1),
        ]
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.setFillColor(colors[(frame / fps) % colors.count])
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 40, y: height - 240, width: 200, height: 200))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: width - 140, y: height - 140, width: 100, height: 100))
            // A bar moving left to right shows time passing.
            ctx.setFillColor(.black)
            ctx.fill(CGRect(x: frame * (width / (seconds * fps)), y: 100, width: 20, height: 300))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? err("video") }
    }

    private static func writeImage(to url: URL) throws {
        let ctx = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.8, blue: 0.1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
        ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 250, y: 150, width: 300, height: 300))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func writeTone(to url: URL, seconds: Double) throws {
        try? FileManager.default.removeItem(at: url)
        let rate = 44100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ])
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            samples[i] = Float(0.5 * sin(2 * Double.pi * 440 * Double(i) / rate))
        }
        try file.write(from: buffer)
    }
}
