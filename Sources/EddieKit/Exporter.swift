import AVFoundation

enum Exporter {
    enum Codec: String, CaseIterable, Identifiable {
        case h264, hevc
        var id: String { rawValue }
        var label: String {
            self == .h264 ? String(localized: "H.264 (plays everywhere)") : String(localized: "HEVC (smaller file)")
        }
        var preset: String { self == .h264 ? AVAssetExportPresetHighestQuality : AVAssetExportPresetHEVCHighestQuality }
    }

    static func export(_ project: Project, to url: URL, codec: Codec, range: ClosedRange<Double>? = nil, progress: @escaping @Sendable (Double) -> Void) async throws {
        let result = try await CompositionBuilder.build(project)
        guard let session = AVAssetExportSession(asset: result.composition, presetName: codec.preset) else {
            throw NSError(domain: "Eddie", code: 2, userInfo: [NSLocalizedDescriptionKey: String(localized: "Export isn't supported on this Mac")])
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
