import AVFoundation

struct BuildResult: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix
    /// The composition's media and its length; stills and titles live in the video composition, but
    /// their ends set the length too. If it is unchanged, the player can keep its item and just swap in
    /// the new video composition and audio mix. An item of the old length would stop the preview there.
    let structureKey: [String]
}

enum BuildError: LocalizedError {
    case trackCreation
    var errorDescription: String? { String(localized: "Couldn't build the timeline") }
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
        var pitch: AVAudioTimePitchAlgorithm?
    }

    /// `pausedTitle` is for the preview player only.
    static func build(_ project: Project, pausedTitle: PausedTitle? = nil) async throws -> BuildResult {
        let composition = AVMutableComposition()
        var videoSlots: [Slot] = []
        var audioSlots: [Slot] = []
        var layers: [RenderLayer] = []
        var structureKey: [String] = []

        func slot(in slots: inout [Slot], type: AVMediaType, from start: CMTime, pitch: AVAudioTimePitchAlgorithm?) throws -> Int {
            if let i = slots.firstIndex(where: { $0.end <= start && $0.pitch == pitch }) { return i }
            guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw BuildError.trackCreation
            }
            var mix: AVMutableAudioMixInputParameters?
            if type == .audio {
                mix = AVMutableAudioMixInputParameters(track: track)
                if let pitch { mix?.audioTimePitchAlgorithm = pitch }
            }
            slots.append(Slot(track: track, end: .zero, mix: mix, pitch: pitch))
            return slots.count - 1
        }

        /// Inserts a source range at `start`, stretched to `duration` when the clip's speed isn't 1.
        func insert(_ source: AVAssetTrack, range: CMTimeRange, at start: CMTime, duration: CMTime,
                    into slots: inout [Slot], type: AVMediaType, pitch: AVAudioTimePitchAlgorithm? = nil) throws -> Int {
            let i = try slot(in: &slots, type: type, from: start, pitch: pitch)
            if start > slots[i].end {
                slots[i].track.insertEmptyTimeRange(CMTimeRange(start: slots[i].end, end: start))
            }
            try slots[i].track.insertTimeRange(range, of: source, at: start)
            if duration != range.duration {
                slots[i].track.scaleTimeRange(CMTimeRange(start: start, duration: range.duration), toDuration: duration)
            }
            slots[i].end = slots[i].track.timeRange.end
            structureKey.append("\(type.rawValue)|\((source.asset as? AVURLAsset)?.url.path ?? "")|\(source.trackID)|\(start.value)|\(range.start.value)|\(range.duration.value)|\(duration.value)|\(pitch?.rawValue ?? "")")
            return i
        }

        // On the magnetic main track a transition at the start of a clip overlaps the previous clip;
        // both halves are drawn, the incoming clip on top.
        var pairedIn: [UUID: Double] = [:]
        var pairedOut: [UUID: (TransitionKind, Double)] = [:]
        let main = project.clips.filter { project.isMagnetic($0) }.sorted { $0.start < $1.start }
        for (a, b) in zip(main, main.dropFirst()) {
            let overlap = a.end - b.start
            if let transition = b.transitionIn, overlap > 0.001 {
                pairedIn[b.id] = overlap
                pairedOut[a.id] = (transition.kind, overlap)
            }
        }

        func effects(_ clip: Clip) -> (LayerEffect?, LayerEffect?) {
            var enter: LayerEffect?, leave: LayerEffect?
            if let t = clip.transitionIn {
                if let overlap = pairedIn[clip.id] {
                    enter = LayerEffect(kind: t.kind, duration: overlap, paired: true)
                } else {
                    enter = LayerEffect(kind: t.kind, duration: min(t.duration, clip.duration / 2), paired: false)
                }
            }
            if let (kind, overlap) = pairedOut[clip.id] {
                leave = LayerEffect(kind: kind, duration: overlap, paired: true)
            } else if let t = clip.transitionOut {
                leave = LayerEffect(kind: t.kind, duration: min(t.duration, clip.duration / 2), paired: false)
            }
            return (enter, leave)
        }

        func applyVolume(_ clip: Clip, slot: Slot, start: CMTime, duration: CMTime) {
            guard let mix = slot.mix else { return }
            let volume = Float(clip.volume)
            let seconds = duration.seconds
            // Transitions on the main track cross-fade the sound as well.
            let fadeIn = min(max(clip.fadeIn, pairedIn[clip.id] ?? 0), seconds / 2)
            let fadeOut = min(max(clip.fadeOut, pairedOut[clip.id]?.1 ?? 0), seconds / 2)
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
            let (enter, leave) = effects(clip)
            return RenderLayer(
                content: content, clipID: clip.id, start: start, end: start + duration,
                scale: clip.scale, offsetX: clip.offsetX, offsetY: clip.offsetY, fill: clip.fill,
                rotation: clip.rotation, opacity: clip.opacity, flipH: clip.flipH, flipV: clip.flipV,
                crop: (clip.cropLeft, clip.cropRight, clip.cropTop, clip.cropBottom), feather: clip.feather,
                fadeIn: clip.kind == .title ? clip.fadeIn : 0, fadeOut: clip.kind == .title ? clip.fadeOut : 0,
                inEffect: enter, outEffect: leave,
                z: (clip.group == .title ? 1 : 0, clip.track, clip.start))
        }

        for clip in project.clips.sorted(by: { $0.start < $1.start }) {
            let start = time(clip.start)
            let duration = time(clip.duration)
            guard duration > .zero else { continue }
            let flags = project.flags(clip.group, clip.track)

            switch clip.kind {
            case .title:
                if let style = clip.title, !flags.hidden {
                    layers.append(layer(clip, content: .title(style), start: start, duration: duration))
                }

            case .image:
                guard !flags.hidden, let media = project.media(clip.mediaID),
                      MediaAccess.canRead(media.url) else { continue }
                layers.append(layer(clip, content: .image(media.url), start: start, duration: duration))

            case .video, .audio:
                guard let media = project.media(clip.mediaID), MediaAccess.canRead(media.url) else { continue }
                let asset = AssetCache.asset(media.url)
                let assetDuration = try await asset.load(.duration)
                let speed = max(clip.speed, 0.05)
                let sourceStart = time(clip.sourceIn)
                let sourceDuration = min(time(clip.duration * speed), assetDuration - sourceStart)
                guard sourceDuration > .zero else { continue }
                let range = CMTimeRange(start: sourceStart, duration: sourceDuration)
                let timelineDuration = speed == 1 ? sourceDuration : time(sourceDuration.seconds / speed)

                if clip.kind == .video, !flags.hidden, let source = try await asset.loadTracks(withMediaType: .video).first {
                    let i = try insert(source, range: range, at: start, duration: timelineDuration, into: &videoSlots, type: .video)
                    let transform = try await source.load(.preferredTransform)
                    layers.append(layer(clip, content: .video(trackID: videoSlots[i].track.trackID, transform: transform),
                                        start: start, duration: timelineDuration))
                }
                let wantsAudio = clip.kind == .audio || !clip.audioDetached
                if wantsAudio, !flags.muted, clip.volume > 0, let source = try await asset.loadTracks(withMediaType: .audio).first {
                    let pitch: AVAudioTimePitchAlgorithm = clip.maintainPitch || speed == 1 ? .spectral : .varispeed
                    let i = try insert(source, range: range, at: start, duration: timelineDuration,
                                       into: &audioSlots, type: .audio, pitch: pitch)
                    applyVolume(clip, slot: audioSlots[i], start: start, duration: timelineDuration)
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
        structureKey.append("length|\(total.value)/\(total.timescale)")

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
            instructions.append(EddieInstruction(timeRange: range, layers: active, background: project.background,
                                                 pausedTitle: pausedTitle))
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

    /// Drops an asset that may have failed to load, after the user gave access to its file.
    static func forget(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        assets[url] = nil
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
