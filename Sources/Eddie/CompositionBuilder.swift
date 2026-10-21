import AVFoundation

struct BuildResult: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix
    /// Changes only when clips are added, moved or trimmed. If it is unchanged, the player can keep
    /// its item and just swap in the new video composition and audio mix.
    let structureKey: [String]
}

enum BuildError: LocalizedError {
    case trackCreation
    var errorDescription: String? { "Kunne ikke bygge tidslinjen" }
}

/// Turns a `Project` into something AVFoundation can play and export.
///
/// Clips are packed onto as few composition tracks as possible, regardless of which timeline track they sit on;
/// stacking order is handled by `EddieCompositor`. A black filler track always spans the whole project so
/// stretches with only titles or images still have frames.
enum CompositionBuilder {
    static let timescale: CMTimeScale = 600

    static func time(_ seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * Double(timescale)).rounded()), timescale: timescale)
    }

    private struct Slot {
        let track: AVMutableCompositionTrack
        var end: CMTime
        var mix: AVMutableAudioMixInputParameters?
    }

    static func build(_ project: Project) async throws -> BuildResult {
        let composition = AVMutableComposition()
        var videoSlots: [Slot] = []
        var audioSlots: [Slot] = []
        var layers: [RenderLayer] = []
        var structureKey: [String] = []

        func slot(in slots: inout [Slot], type: AVMediaType, from start: CMTime) throws -> Int {
            if let i = slots.firstIndex(where: { $0.end <= start }) { return i }
            guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw BuildError.trackCreation
            }
            slots.append(Slot(track: track, end: .zero, mix: type == .audio ? AVMutableAudioMixInputParameters(track: track) : nil))
            return slots.count - 1
        }

        func insert(_ source: AVAssetTrack, range: CMTimeRange, at start: CMTime, into slots: inout [Slot], type: AVMediaType) throws -> Int {
            let i = try slot(in: &slots, type: type, from: start)
            if start > slots[i].end {
                slots[i].track.insertEmptyTimeRange(CMTimeRange(start: slots[i].end, end: start))
            }
            try slots[i].track.insertTimeRange(range, of: source, at: start)
            slots[i].end = slots[i].track.timeRange.end
            return i
        }

        func applyVolume(_ clip: Clip, slot: Slot, start: CMTime, duration: CMTime) {
            guard let mix = slot.mix else { return }
            let volume = Float(clip.volume)
            let seconds = duration.seconds
            let fadeIn = min(clip.fadeIn, seconds / 2), fadeOut = min(clip.fadeOut, seconds / 2)
            if fadeIn > 0 {
                mix.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume, timeRange: CMTimeRange(start: start, duration: time(fadeIn)))
            } else {
                mix.setVolume(volume, at: start)
            }
            if fadeOut > 0 {
                let fadeDuration = time(fadeOut)
                mix.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                  timeRange: CMTimeRange(start: start + duration - fadeDuration, duration: fadeDuration))
            }
        }

        func layer(_ clip: Clip, content: RenderLayer.Content, start: CMTime, duration: CMTime) -> RenderLayer {
            RenderLayer(
                content: content, start: start, end: start + duration,
                scale: clip.scale, offsetX: clip.offsetX, offsetY: clip.offsetY, fill: clip.fill,
                fadeIn: clip.fadeIn, fadeOut: clip.fadeOut,
                z: (clip.group == .title ? 1 : 0, clip.track, clip.start))
        }

        for clip in project.clips.sorted(by: { $0.start < $1.start }) {
            let start = time(clip.start)
            var duration = time(clip.duration)
            guard duration > .zero else { continue }

            switch clip.kind {
            case .title:
                if let style = clip.title {
                    layers.append(layer(clip, content: .title(style), start: start, duration: duration))
                }

            case .image:
                guard let media = project.media(clip.mediaID), FileManager.default.fileExists(atPath: media.url.path) else { continue }
                layers.append(layer(clip, content: .image(media.url), start: start, duration: duration))

            case .video, .audio:
                guard let media = project.media(clip.mediaID), FileManager.default.fileExists(atPath: media.url.path) else { continue }
                let asset = AssetCache.asset(media.url)
                let assetDuration = try await asset.load(.duration)
                let sourceStart = time(clip.sourceIn)
                duration = min(duration, assetDuration - sourceStart)
                guard duration > .zero else { continue }
                let range = CMTimeRange(start: sourceStart, duration: duration)
                structureKey.append("\(clip.mediaID!)|\(start.value)|\(duration.value)|\(sourceStart.value)|\(clip.kind)")

                if clip.kind == .video, let source = try await asset.loadTracks(withMediaType: .video).first {
                    let i = try insert(source, range: range, at: start, into: &videoSlots, type: .video)
                    let transform = try await source.load(.preferredTransform)
                    layers.append(layer(clip, content: .video(trackID: videoSlots[i].track.trackID, transform: transform),
                                        start: start, duration: duration))
                }
                if let source = try await asset.loadTracks(withMediaType: .audio).first {
                    let i = try insert(source, range: range, at: start, into: &audioSlots, type: .audio)
                    applyVolume(clip, slot: audioSlots[i], start: start, duration: duration)
                }
            }
        }

        // The filler decides the composition's length, so every instruction below is covered by media.
        var total = max(time(1), composition.duration)
        for l in layers { total = max(total, l.end) }
        let filler = try await BlackFiller.shared.asset()
        guard let fillerSource = try await filler.loadTracks(withMediaType: .video).first,
              let fillerTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw BuildError.trackCreation
        }
        let fillerRange = try await fillerSource.load(.timeRange)
        try fillerTrack.insertTimeRange(fillerRange, of: fillerSource, at: .zero)
        fillerTrack.scaleTimeRange(CMTimeRange(start: .zero, duration: fillerRange.duration), toDuration: total)
        total = composition.duration

        // One instruction per stretch where the set of visible clips is constant.
        var bounds = Set<CMTimeValue>([0, total.convertScale(timescale, method: .default).value])
        for l in layers {
            bounds.insert(l.start.value)
            bounds.insert(l.end.value)
        }
        let edges = bounds.sorted().filter { $0 <= total.convertScale(timescale, method: .default).value }
        var instructions: [EddieInstruction] = []
        for (a, b) in zip(edges, edges.dropFirst()) where b > a {
            var range = CMTimeRange(start: CMTime(value: a, timescale: timescale), end: CMTime(value: b, timescale: timescale))
            if b == edges.last { range = CMTimeRange(start: range.start, end: total) }
            let active = layers
                .filter { $0.start < range.end && $0.end > range.start }
                .sorted { $0.z < $1.z }
            instructions.append(EddieInstruction(timeRange: range, layers: active, background: project.background))
        }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = EddieCompositor.self
        videoComposition.renderSize = project.aspect.renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(project.fps))
        videoComposition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        videoComposition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        videoComposition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        videoComposition.instructions = instructions

        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = audioSlots.compactMap(\.mix)

        return BuildResult(composition: composition, videoComposition: videoComposition, audioMix: audioMix, structureKey: structureKey)
    }
}

enum AssetCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var assets: [URL: AVURLAsset] = [:]

    static func asset(_ url: URL) -> AVURLAsset {
        lock.lock(); defer { lock.unlock() }
        if let hit = assets[url] { return hit }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        assets[url] = asset
        return asset
    }
}

/// A one second black clip, written once and stretched to the project's length.
actor BlackFiller {
    static let shared = BlackFiller()
    private var cached: AVURLAsset?

    func asset() async throws -> AVURLAsset {
        if let cached { return cached }
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Eddie", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("black-v1.mov")
        if !FileManager.default.fileExists(atPath: url.path) {
            try await write(to: url)
        }
        let asset = AVURLAsset(url: url)
        cached = asset
        return asset
    }

    private func write(to url: URL) async throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        let side = 64
        let writer = try AVAssetWriter(outputURL: temp, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
            // Opaque alpha in every BGRA pixel.
            let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            for i in stride(from: 3, to: CVPixelBufferGetDataSize(buffer), by: 4) { bytes[i] = 255 }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 30, timescale: 30))
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? BuildError.trackCreation }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: temp, to: url)
    }
}
