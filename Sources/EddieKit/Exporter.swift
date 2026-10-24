import Accelerate
import AVFoundation
import VideoToolbox

/// MP4 export at a bitrate of its own instead of an export preset's: the finished frames come from the same
/// compositor as the preview, through an `AVAssetReader`, and go into an `AVAssetWriter` set to that bitrate.
enum Exporter {
    enum Codec: String, CaseIterable, Identifiable {
        case h264, hevc
        var id: String { rawValue }
        var label: String {
            self == .h264 ? String(localized: "H.264 (plays everywhere)") : String(localized: "HEVC (smaller file)")
        }

        var type: AVVideoCodecType { self == .h264 ? .h264 : .hevc }

        var profile: String {
            self == .h264 ? AVVideoProfileLevelH264HighAutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel as String
        }

        /// Bits per second for calm 1080p at 30 fps. HEVC gives the same picture for about 60 % of that.
        var calmRate: Double { self == .h264 ? 20_000_000 : 12_000_000 }
    }

    /// What an export was given, for the self test and the session test.
    struct Settings {
        var bitrate: Int
        var motion: Double
    }

    static let audioBitrate = 320_000

    /// The video bitrate: the codec's rate for calm 1080p at 30 fps, scaled by the frame's area, by the frame
    /// rate (60 fps gets 1.5 times as much: twice the frames, each closer to the one before) and by how much
    /// the picture moves, up to 1.5 times for fast motion. Rounded to 0.1 Mbit/s.
    static func bitrate(codec: Codec, size: CGSize, fps: Int, motion: Double) -> Int {
        let area = Double(size.width * size.height) / (1920 * 1080)
        let rate = pow(Double(fps) / 30, 0.585)
        let movement = 1 + 0.5 * min(max((motion - calmMotion) / (fastMotion - calmMotion), 0), 1)
        return Int((codec.calmRate * area * rate * movement / 100_000).rounded()) * 100_000
    }

    /// Motion below this is calm (a still, a talking head, a slow stream); above `fastMotion` it gets the most.
    static let calmMotion = 0.01
    static let fastMotion = 0.05

    @discardableResult
    static func export(_ project: Project, to url: URL, codec: Codec, range: ClosedRange<Double>? = nil,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> Settings {
        let result = try await CompositionBuilder.build(project)
        let timeRange = range.map { CMTimeRange(start: CompositionBuilder.time($0.lowerBound), end: CompositionBuilder.time($0.upperBound)) }
            ?? CMTimeRange(start: .zero, duration: result.composition.duration)
        let size = project.aspect.renderSize
        let motion = await motion(of: result, in: timeRange, fps: project.fps)
        try Task.checkCancellation()
        let settings = Settings(bitrate: bitrate(codec: codec, size: size, fps: project.fps, motion: motion), motion: motion)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: settings.bitrate,
            AVVideoExpectedSourceFrameRateKey: project.fps,
            AVVideoMaxKeyFrameIntervalKey: project.fps * 2,
            AVVideoProfileLevelKey: codec.profile,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if codec == .h264 { compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC }
        let video: [String: Any] = [
            AVVideoCodecKey: codec.type,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
        try await write(result, range: timeRange, video: video, to: url, progress: progress)
        return settings
    }

    /// How much the picture moves: the mean difference in brightness between neighbouring frames, at
    /// `samples` points spread over the range, on half-size renders of the finished frame (any smaller and
    /// fine detail such as grain or leaves averages away). It's moving detail that scores, the thing that
    /// costs bits: a still is 0, a calm stream stays under `calmMotion`, and so does a smooth picture
    /// panning fast, while fine texture on the move reaches `fastMotion`.
    static func motion(of result: BuildResult, in range: CMTimeRange, fps: Int, samples: Int = 12) async -> Double {
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = CMTime(value: 1, timescale: CMTimeScale(fps))
        guard range.duration > frame else { return 0 }
        var times: [CMTime] = []
        for i in 0..<samples {
            let t = range.start + CMTimeMultiplyByFloat64(range.duration - frame, multiplier: (Double(i) + 0.5) / Double(samples))
            times += [t, t + frame]
        }
        var luma: [CMTime: [Float]] = [:]
        for await image in generator.images(for: times) {
            if let cg = try? image.image { luma[image.requestedTime] = grey(cg) }
        }
        var differences: [Double] = []
        for i in stride(from: 0, to: times.count, by: 2) {
            guard let a = luma[times[i]], let b = luma[times[i + 1]], a.count == b.count, !a.isEmpty else { continue }
            differences.append(Double(vDSP.meanMagnitude(vDSP.subtract(a, b))) / 255)
        }
        return differences.isEmpty ? 0 : differences.reduce(0, +) / Double(differences.count)
    }

    private static func grey(_ image: CGImage) -> [Float] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height)
        guard let ctx = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return [] }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return vDSP.integerToFloatingPoint(pixels, floatingPointType: Float.self)
    }

    /// Reads the finished frames and the mixed sound for the range and writes them as MP4. Cancelling the
    /// task stops it and leaves no file.
    private static func write(_ result: BuildResult, range: CMTimeRange, video: [String: Any], to url: URL,
                              progress: @escaping @Sendable (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: url)
        let composition = result.composition
        let reader = try AVAssetReader(asset: composition)
        reader.timeRange = range

        let frames = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await composition.loadTracks(withMediaType: .video),
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        frames.videoComposition = result.videoComposition
        frames.alwaysCopiesSampleData = false
        reader.add(frames)

        // Muted tracks and silent clips aren't in the composition; with no sound left, the file has none.
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        var sound: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
            ])
            output.audioMix = result.audioMix
            output.alwaysCopiesSampleData = false
            reader.add(output)
            sound = output
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: video)
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)
        let audioInput = sound.map { _ in
            AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: audioBitrate,
            ])
        }
        if let audioInput {
            audioInput.expectsMediaDataInRealTime = false
            writer.add(audioInput)
        }

        guard reader.startReading() else { throw reader.error ?? ExportError.failed }
        guard writer.startWriting() else { throw writer.error ?? ExportError.failed }
        writer.startSession(atSourceTime: range.start)

        let start = range.start.seconds, length = max(range.duration.seconds, 1e-6)
        // Once per thousandth, not once per frame: an export runs many times faster than real time.
        let reported = Reported()
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await pump(frames, into: videoInput, label: "video") { time in
                        let done = min(max((time.seconds - start) / length, 0), 0.99)
                        let step = Int(done * 1000)
                        guard step != reported.step else { return }
                        reported.step = step
                        progress(done)
                    }
                }
                if let sound, let audioInput {
                    group.addTask { await pump(sound, into: audioInput, label: "audio") }
                }
            }
        } onCancel: {
            // The pumps run dry and stop; the writer is cancelled once nothing is appending any more.
            reader.cancelReading()
        }

        if Task.isCancelled || reader.status != .completed || writer.status == .failed {
            let error = Task.isCancelled ? CancellationError() : (reader.error ?? writer.error ?? ExportError.failed)
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        writer.endSession(atSourceTime: range.end)
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw writer.error ?? ExportError.failed
        }
        progress(1)
    }

    /// Moves samples from a reader output into a writer input until the output runs dry, as fast as the
    /// writer takes them. `sample` sees each one's time.
    private static func pump(_ output: AVAssetReaderOutput, into input: AVAssetWriterInput, label: String,
                             sample: (@Sendable (CMTime) -> Void)? = nil) async {
        let queue = DispatchQueue(label: "eddie.export.\(label)")
        let state = PumpState(output: output, input: input)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: queue) {
                guard !state.finished else { return }
                let output = state.output, input = state.input
                let finish = {
                    state.finished = true
                    input.markAsFinished()
                    done.resume()
                }
                // When the input is full, the block returns and is called again once it has room.
                while input.isReadyForMoreMediaData {
                    guard let buffer = output.copyNextSampleBuffer() else { return finish() }
                    sample?(CMSampleBufferGetPresentationTimeStamp(buffer))
                    guard input.append(buffer) else { return finish() }
                }
            }
        }
    }

    /// Touched only on the pump's own queue.
    private final class PumpState: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        var finished = false
        init(output: AVAssetReaderOutput, input: AVAssetWriterInput) { self.output = output; self.input = input }
    }

    /// The last progress reported, touched only on the video pump's queue.
    private final class Reported: @unchecked Sendable {
        var step = -1
    }

    enum ExportError: LocalizedError {
        case failed
        var errorDescription: String? { String(localized: "The video couldn't be exported.") }
    }
}
