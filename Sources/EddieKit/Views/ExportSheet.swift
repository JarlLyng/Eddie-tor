import IAMJARLDesignTokens
import SwiftUI

/// What the save panel asks besides the file name: the kind of file, and the marked range if there is one.
@MainActor @Observable
final class ExportOptions {
    var codec = Exporter.Codec.h264
    var onlyInOut = true

    /// The part of the project to export: between in and out when they're set and wanted, else all of it.
    func range(of project: Project) -> ClosedRange<Double>? {
        guard onlyInOut, project.inPoint != nil || project.outPoint != nil else { return nil }
        let start = project.inPoint ?? 0
        let end = project.outPoint ?? project.duration
        return end > start ? start...end : nil
    }
}

/// One export at a time, started once the save panel closes, shown in a sheet with its progress and, when
/// it's done, Show in Finder and Share.
@MainActor @Observable
final class ExportJob {
    enum State: Equatable {
        case idle
        case exporting(Double)
        case done(URL)
        case failed(String)
    }

    var state = State.idle
    var showsSheet = false {
        didSet { if !showsSheet, !isExporting { state = .idle } }
    }
    @ObservationIgnored private var task: Task<Void, Never>?
    /// A finished video is what the first-run tip is for, so the first one closes it for good.
    @ObservationIgnored private let remembersFirstExport: Bool

    init(remembersFirstExport: Bool) {
        self.remembersFirstExport = remembersFirstExport
    }

    var isExporting: Bool { if case .exporting = state { true } else { false } }

    func start(_ project: Project, to url: URL, codec: Exporter.Codec, range: ClosedRange<Double>?) {
        guard !isExporting else { return }
        state = .exporting(0)
        showsSheet = true
        task = Task {
            do {
                try await Exporter.export(project, to: url, codec: codec, range: range) { progress in
                    Task { @MainActor in if case .exporting = self.state { self.state = .exporting(progress) } }
                }
                state = .done(url)
                if remembersFirstExport { UserDefaults.standard.set(true, forKey: FirstRunHint.dismissedKey) }
            } catch is CancellationError {
                state = .idle
                showsSheet = false
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Stops the export and leaves no file.
    func cancel() { task?.cancel() }

    /// Waits for the export started last; for the self test.
    func finish() async { await task?.value }
}

/// ⌘E: the save panel straight away, with the few choices an export has below the file name.
@MainActor
enum ExportPanel {
    static func run(_ editor: Editor) {
        let options = ExportOptions()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        let base = editor.fileURL?.deletingPathExtension().lastPathComponent ?? editor.suggestedName ?? String(localized: "Edwell Video")
        panel.nameFieldStringValue = "\(base).mp4"
        panel.directoryURL = FileManager.default.userHomeDirectory.appendingPathComponent("Movies")
        panel.prompt = String(localized: "Export")
        let accessory = NSHostingView(rootView: ExportOptionsView(options: options, project: editor.project))
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if editor.isPlaying { editor.pause() }
        editor.exportJob.start(editor.project, to: url, codec: options.codec, range: options.range(of: editor.project))
    }
}

/// Under the save panel's file name: what will be exported, and the two choices.
private struct ExportOptionsView: View {
    @Bindable var options: ExportOptions
    let project: Project

    var body: some View {
        let size = project.aspect.renderSize
        let range = options.range(of: project)
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
            Text("\(project.aspect.label) · \(Int(size.width))×\(Int(size.height)) · \(project.fps) fps")
                .foregroundStyle(Tokens.Palette.Text.secondary)
            Picker("Type", selection: $options.codec) {
                ForEach(Exporter.Codec.allCases) { Text($0.label).tag($0) }
            }
            .fixedSize()
            if project.inPoint != nil || project.outPoint != nil {
                Toggle("Only between in and out points", isOn: $options.onlyInOut)
            }
            LabeledContent("Duration", value: timecode(range.map { $0.upperBound - $0.lowerBound } ?? project.duration, fps: project.fps))
                .fixedSize()
        }
        .padding(Tokens.Spacing.lg)
    }
}

/// The export's progress, then the finished file with Show in Finder and Share.
struct ExportProgressView: View {
    @Environment(Editor.self) private var editor
    @Environment(Store.self) private var store

    var body: some View {
        let job = editor.exportJob
        VStack(alignment: .leading, spacing: Tokens.Spacing.lg) {
            switch job.state {
            case .idle:
                EmptyView()
            case .exporting(let progress):
                Text("Export Video").ijFont(.xl, weight: .semibold)
                ProgressView(value: progress) { Text("Exporting… \(Int(progress * 100)) %") }
            case .done(let url):
                Text("Your video is ready").ijFont(.xl, weight: .semibold)
                Label("Done: \(url.lastPathComponent)", systemImage: "checkmark.circle.fill").foregroundStyle(Tokens.Palette.State.success)
            case .failed(let message):
                Text("Export Video").ijFont(.xl, weight: .semibold)
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Tokens.Palette.State.error)
            }

            if case .trial(let days) = store.access {
                Text("\(days) days left of your trial").ijFont(.sm).foregroundStyle(Tokens.Palette.Text.secondary)
            }

            HStack {
                if case .done(let url) = job.state {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(SecondaryButtonStyle())
                    ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
                        .buttonStyle(SecondaryButtonStyle())
                }
                Spacer()
                // While exporting, Cancel stops the export and leaves no file; after, Close closes the sheet.
                if job.isExporting {
                    Button("Cancel") { job.cancel() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(SecondaryButtonStyle())
                } else {
                    Button("Close") { job.showsSheet = false }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PrimaryButtonStyle())
                }
            }
        }
        .padding(Tokens.Spacing.xxl)
        .frame(width: 460)
        .interactiveDismissDisabled(job.isExporting)
    }
}
