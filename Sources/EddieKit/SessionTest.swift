import AVFoundation
import AppKit

/// `Eddie --session-test <recording> <dir> [rush.mp4] [--full]`: builds the Ambient Session template for a real
/// recording, trims it the way Rush did for session 011, exports it and compares the result with Rush's video.
/// Without `--full` only the first minute is exported.
enum SessionTest {
    static func run(arguments: [String]) -> Never {
        Task {
            do {
                try await perform(arguments)
                print("SESSION TEST OK")
                exit(0)
            } catch {
                print("SESSION TEST FAILED: \(error)")
                exit(1)
            }
        }
        dispatchMain()
    }

    private static func perform(_ args: [String]) async throws {
        let recording = URL(fileURLWithPath: args[0])
        let dir = URL(fileURLWithPath: args[1])
        let rush = args.count > 2 && !args[2].hasPrefix("--") ? URL(fileURLWithPath: args[2]) : nil
        let full = args.contains("--full")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var clock = Date()
        guard let media = await MediaLoader.load(recording) else { throw fail("kunne ikke læse optagelsen") }
        print(String(format: "loaded %@: %.1f s, %.0fx%.0f, audio %@ (%.2f s)",
                     media.name, media.duration, media.width, media.height, media.hasAudio ? "yes" : "no", -clock.timeIntervalSinceNow))

        var project = AmbientSession.project(for: media)
        print("title", project.clips[1].title!.text.replacingOccurrences(of: "\n", with: " / "),
              "font", project.clips[1].title!.fontFamily, "colour", project.clips[1].title!.color)
        // Rush's trim for session 011: source 212.967 s to 4069.300 s.
        if let i = project.clips.firstIndex(where: { $0.kind == .video }) {
            project.clips[i].sourceIn = 212.967
            project.clips[i].duration = 4069.3 - 212.967
        }
        Editor.packMain(&project)
        try JSONEncoder().encode(project).write(to: dir.appendingPathComponent("session.eddie"))

        clock = Date()
        _ = try await CompositionBuilder.build(project)
        print(String(format: "composition built in %.2f s", -clock.timeIntervalSinceNow))

        let output = dir.appendingPathComponent(full ? "session-full.mp4" : "session-first-minute.mp4")
        clock = Date()
        let tenths = Tenths()
        let settings = try await Exporter.export(project, to: output, codec: .h264, range: full ? nil : 0...60) { p in
            if tenths.passed(p) { print(String(format: "  export %.0f %%", p * 100)) }
        }
        print(String(format: "motion %.4f, target %.1f Mbit/s video, %.0f kbit/s audio",
                     settings.motion, Double(settings.bitrate) / 1e6, Double(Exporter.audioBitrate) / 1e3))
        let seconds = -clock.timeIntervalSinceNow
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.doubleValue ?? 0
        let video = try await asset.loadTracks(withMediaType: .video).first
        let audio = try await asset.loadTracks(withMediaType: .audio).first
        let videoRate = try await video?.load(.estimatedDataRate) ?? 0
        let audioRate = try await audio?.load(.estimatedDataRate) ?? 0
        print(String(format: "exported %.2f s of video in %.1f s (%.2fx real time); %.1f Mbit/s video, %.0f kbit/s audio, %.0f MB",
                     duration, seconds, duration / seconds, videoRate / 1e6, audioRate / 1e3, bytes / 1e6))

        if let rush {
            let asset = AVURLAsset(url: rush)
            let video = try await asset.loadTracks(withMediaType: .video).first?.load(.estimatedDataRate) ?? 0
            let audio = try await asset.loadTracks(withMediaType: .audio).first?.load(.estimatedDataRate) ?? 0
            print(String(format: "rush: %.1f Mbit/s video, %.0f kbit/s audio", video / 1e6, audio / 1e3))
        }

        // Same moments in Eddie's and Rush's results.
        let times = full ? [0.2, 0.6, 20, 1800, 3855.9, 3856.2] : [0.2, 0.6, 11.0, 12.0, 20, 50.5, 51.0]
        for t in times where t < duration {
            let eddie = try await frame(asset, t)
            let e = measure(eddie)
            var line = String(format: "t=%7.2f  eddie: brightness %.2f title %@", t, e.brightness, e.title)
            if let rush {
                let r = measure(try await frame(AVURLAsset(url: rush), t))
                line += String(format: "  | rush: brightness %.2f title %@", r.brightness, r.title)
            }
            print(line)
            try save(eddie, to: dir.appendingPathComponent(String(format: "eddie-%07.2f.jpg", t)))
        }
    }

    /// True once for every tenth of the export.
    private final class Tenths: @unchecked Sendable {
        private let lock = NSLock()
        private var last = 0
        func passed(_ progress: Double) -> Bool {
            lock.lock(); defer { lock.unlock() }
            let tenth = Int(progress * 10)
            guard tenth > last else { return false }
            last = tenth
            return true
        }
    }

    private static func fail(_ message: String) -> NSError {
        NSError(domain: "SessionTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func frame(_ asset: AVAsset, _ seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    private static func save(_ image: CGImage, to url: URL) throws {
        try NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])!.write(to: url)
    }

    /// Mean brightness, and the box around the title's pixels: saturated, bright and far from grey.
    private static func measure(_ image: CGImage) -> (brightness: Double, title: String) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var minX = w, minY = h, maxX = 0, maxY = 0, count = 0, sum = 0
        var r = 0, g = 0, b = 0
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let pr = Int(data[i]), pg = Int(data[i + 1]), pb = Int(data[i + 2])
                sum += pr + pg + pb
                // The session 011 magenta: strong red and blue, little green.
                if pr > 170, pb > 160, pg < 90 {
                    count += 1; r += pr; g += pg; b += pb
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        let brightness = Double(sum) / Double(w * h * 3 * 255)
        guard count > 500 else { return (brightness, "none") }
        return (brightness, String(format: "x %d–%d y %d–%d #%02X%02X%02X (%d px)", minX, maxX, minY, maxY, r / count, g / count, b / count, count))
    }
}
