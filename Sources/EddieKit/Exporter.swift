import AVFoundation

enum Exporter {
    enum Codec: String, CaseIterable, Identifiable {
        case h264 = "H.264 (passer overalt)"
        case hevc = "HEVC (mindre fil)"
        var id: String { rawValue }
        var preset: String { self == .h264 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetHEVCHighestQuality }
    }

    static func export(_ project: Project, to url: URL, codec: Codec, range: ClosedRange<Double>? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        let result = try await CompositionBuilder.build(project)
        guard let session = AVAssetExportSession(asset: result.composition, presetName: codec.preset) else {
            throw NSError(domain: "Eddie", code: 2, userInfo: [NSLocalizedDescriptionKey: "Eksport understøttes ikke på denne Mac"])
        }
        session.videoComposition = result.videoComposition
        session.audioMix = result.audioMix
        session.shouldOptimizeForNetworkUse = true
        if let range {
            session.timeRange = CMTimeRange(start: CompositionBuilder.time(range.lowerBound), end: CompositionBuilder.time(range.upperBound))
        }
        try? FileManager.default.removeItem(at: url)

        let watcher = Task {
            for await state in session.states(updateInterval: 0.2) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: url, as: .mp4)
        progress(1)
    }
}
