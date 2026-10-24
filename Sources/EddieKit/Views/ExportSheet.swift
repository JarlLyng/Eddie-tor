import IAMJARLDesignTokens
import SwiftUI

/// Export, or the trial and the purchase when export isn't open yet. Once the trial starts or the
/// purchase goes through, the same sheet turns into the export settings.
struct ExportSheet: View {
    @Environment(Store.self) private var store

    var body: some View {
        if store.access.canExport {
            ExportSettings()
        } else {
            PurchaseView()
        }
    }
}

private struct ExportSettings: View {
    @Environment(Editor.self) private var editor
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var codec = Exporter.Codec.h264
    @ViewState private var state = ExportState.idle
    @ViewState private var onlyInOut = true
    @ViewState private var job: Task<Void, Never>?

    enum ExportState {
        case idle
        case exporting(Double)
        case done(URL)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            Text("Export Video").ijFont(.xl, weight: .semibold)

            let size = editor.project.aspect.renderSize
            Grid(alignment: .leading, horizontalSpacing: Tokens.Spacing.lg, verticalSpacing: Tokens.Spacing.sm) {
                GridRow { Text("Format").foregroundStyle(Tokens.Palette.Text.secondary); Text("\(editor.project.aspect.label) · \(Int(size.width))×\(Int(size.height)) · \(editor.project.fps) fps") }
                GridRow { Text("Duration").foregroundStyle(Tokens.Palette.Text.secondary); Text(timecode(exportRange.map { $0.upperBound - $0.lowerBound } ?? editor.project.duration, fps: editor.project.fps)) }
                if hasInOut {
                    GridRow {
                        Text("Range").foregroundStyle(Tokens.Palette.Text.secondary)
                        Toggle("Only between in and out points", isOn: $onlyInOut).disabled(isExporting)
                    }
                }
                GridRow {
                    Text("Codec").foregroundStyle(Tokens.Palette.Text.secondary)
                    Picker("", selection: $codec) {
                        ForEach(Exporter.Codec.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .disabled(isExporting)
                }
            }

            switch state {
            case .idle:
                EmptyView()
            case .exporting(let progress):
                ProgressView(value: progress) { Text("Exporting… \(Int(progress * 100)) %") }
            case .done(let url):
                Label("Done: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(Tokens.Palette.State.success)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tokens.Palette.State.error)
            }

            if case .trial(let days) = store.access {
                Text("\(days) days left of your trial").ijFont(.sm).foregroundStyle(Tokens.Palette.Text.secondary)
            }

            HStack {
                if case .done(let url) = state {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                // While exporting, Cancel stops the export and leaves no file; otherwise it closes the sheet.
                Button(isDone ? "Close" : "Cancel") {
                    if isExporting { job?.cancel() } else { dismiss() }
                }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(SecondaryButtonStyle())
                if !isDone {
                    Button("Export…") { chooseAndExport() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isExporting || editor.project.clips.isEmpty)
                }
            }
        }
        .padding(Tokens.Spacing.xxl)
        .frame(width: 460)
    }

    private var hasInOut: Bool { editor.project.inPoint != nil || editor.project.outPoint != nil }

    private var exportRange: ClosedRange<Double>? {
        guard hasInOut, onlyInOut else { return nil }
        let start = editor.project.inPoint ?? 0
        let end = editor.project.outPoint ?? editor.project.duration
        return end > start ? start...end : nil
    }

    private var isExporting: Bool { if case .exporting = state { true } else { false } }
    private var isDone: Bool { if case .done = state { true } else { false } }

    private func chooseAndExport() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let base = editor.fileURL?.deletingPathExtension().lastPathComponent ?? editor.suggestedName ?? String(localized: "Edwell Video")
        panel.nameFieldStringValue = "\(base).mp4"
        panel.directoryURL = FileManager.default.userHomeDirectory.appendingPathComponent("Movies")
        guard panel.runModal() == .OK, let url = panel.url else { return }

        if editor.isPlaying { editor.pause() }
        state = .exporting(0)
        let project = editor.project
        let codec = codec
        let range = exportRange
        job = Task {
            do {
                try await Exporter.export(project, to: url, codec: codec, range: range) { progress in
                    Task { @MainActor in if case .exporting = state { state = .exporting(progress) } }
                }
                state = .done(url)
                // A finished video is what the first-run tip was for.
                UserDefaults.standard.set(true, forKey: FirstRunHint.dismissedKey)
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
