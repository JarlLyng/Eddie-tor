import AVFoundation
import AppKit
import UniformTypeIdentifiers

enum MediaLoader {
    /// Reads a picked or dropped file and bookmarks it while the app has access (`MediaAccess`).
    static func load(_ url: URL) async -> MediaItem? {
        guard var item = await read(url) else { return nil }
        item.bookmark = MediaAccess.bookmark(for: url)
        return item
    }

    private static func read(_ url: URL) async -> MediaItem? {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }

        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  var width = props[kCGImagePropertyPixelWidth] as? Double,
                  var height = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
            if let orientation = props[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                swap(&width, &height)
            }
            return MediaItem(url: url, kind: .image, duration: 0, width: width, height: height, hasAudio: false)
        }

        guard type.conforms(to: .audiovisualContent) else { return nil }
        let asset = AssetCache.asset(url)
        do {
            let duration = try await asset.load(.duration).seconds
            let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            if let video = try await asset.loadTracks(withMediaType: .video).first {
                let (size, transform) = try await video.load(.naturalSize, .preferredTransform)
                let upright = CGRect(origin: .zero, size: size).applying(transform)
                return MediaItem(url: url, kind: .video, duration: duration,
                                 width: abs(upright.width), height: abs(upright.height), hasAudio: hasAudio)
            }
            if hasAudio {
                return MediaItem(url: url, kind: .audio, duration: duration, width: 0, height: 0, hasAudio: true)
            }
        } catch {
            NSLog("Edwell: couldn't read \(url.lastPathComponent): \(error)")
        }
        return nil
    }

    static func thumbnail(_ media: MediaItem) async -> NSImage? {
        switch media.kind {
        case .video:
            let generator = AVAssetImageGenerator(asset: AssetCache.asset(media.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 320, height: 320)
            let at = CMTime(seconds: min(1, media.duration / 2), preferredTimescale: 600)
            guard let (image, _) = try? await generator.image(at: at) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        case .image:
            guard let source = CGImageSourceCreateWithURL(media.url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 320,
                  ] as CFDictionary) else { return nil }
            return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        case .audio:
            return nil
        }
    }

    static let waveformRate = 50.0

    /// Peak levels (0...1), `waveformRate` values per second.
    static func waveform(_ url: URL) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
              let reader = try? AVAssetReader(asset: asset) else { return [] }
        let sampleRate = 8000.0
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ])
        reader.add(output)
        guard reader.startReading() else { return [] }

        let bucket = Int(sampleRate / waveformRate)
        var peaks: [Float] = []
        var peak: UInt16 = 0
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var data = [Int16](repeating: 0, count: length / 2)
            data.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for value in data {
                peak = max(peak, value.magnitude)
                count += 1
                if count == bucket {
                    peaks.append(Float(peak) / 32768)
                    peak = 0
                    count = 0
                }
            }
        }
        return peaks
    }
}

/// Thumbnails and waveforms, kept out of the project so they don't end up in undo history or the saved file.
@MainActor @Observable
final class MediaCache {
    var thumbnails: [UUID: NSImage] = [:]
    var waveforms: [UUID: [Float]] = [:]
    @ObservationIgnored private var pending = Set<UUID>()
    @ObservationIgnored private var tiles: [String: NSImage] = [:]

    /// The thumbnail scaled to a timeline row's height, for repeating along a clip.
    func tile(for id: UUID?, height: CGFloat) -> NSImage? {
        guard let id, let thumb = thumbnails[id], height > 0 else { return nil }
        let key = "\(id)-\(Int(height))"
        if let hit = tiles[key] { return hit }
        let width = max((height * thumb.size.width / max(thumb.size.height, 1)).rounded(), 20)
        let tile = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            thumb.draw(in: rect)
            return true
        }
        tiles[key] = tile
        return tile
    }

    func prepare(_ items: [MediaItem]) {
        for media in items where !pending.contains(media.id) {
            pending.insert(media.id)
            Task.detached(priority: .utility) {
                let thumbnail = await MediaLoader.thumbnail(media)
                let waveform = media.hasAudio ? await MediaLoader.waveform(media.url) : []
                await MainActor.run {
                    if let thumbnail { self.thumbnails[media.id] = thumbnail }
                    if !waveform.isEmpty { self.waveforms[media.id] = waveform }
                }
            }
        }
    }
}
