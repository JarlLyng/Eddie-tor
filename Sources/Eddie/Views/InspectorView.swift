import SwiftUI

struct InspectorView: View {
    @Environment(Editor.self) private var editor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editor.selectedClip == nil ? "Projekt" : "Klip").font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            if let clip = editor.selectedClip {
                ClipInspector(clip: clip).id(clip.id)
            } else {
                ProjectInspector()
            }
        }
    }
}

private struct ProjectInspector: View {
    @Environment(Editor.self) private var editor

    var body: some View {
        Form {
            Section("Format") {
                Picker("Billedformat", selection: editor.projectBinding(\.aspect)) {
                    ForEach(AspectRatio.allCases) { aspect in
                        Text("\(aspect.label)  (\(Int(aspect.renderSize.width))×\(Int(aspect.renderSize.height)))").tag(aspect)
                    }
                }
                Picker("Billeder pr. sekund", selection: editor.projectBinding(\.fps)) {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0)").tag($0) }
                }
                ColorPicker("Baggrundsfarve", selection: Binding(
                    get: { editor.project.background.color },
                    set: { color in editor.edit(coalesce: "background") { $0.background = RGBA(color) } }
                ), supportsOpacity: false)
            }
            Section("Overblik") {
                LabeledContent("Varighed", value: timecode(editor.project.duration, fps: editor.project.fps))
                LabeledContent("Klip", value: "\(editor.project.clips.count)")
                LabeledContent("Medier", value: "\(editor.project.media.count)")
            }
            Section("Genveje") {
                shortcut("Afspil / pause", "Mellemrum")
                shortcut("Del klip", "S  eller  ⌘B")
                shortcut("Slet klip", "⌫")
                shortcut("Tilføj tekst", "T")
                shortcut("Et billede frem / tilbage", "→  ←")
                shortcut("Et sekund frem / tilbage", "⇧→  ⇧←")
                shortcut("Zoom", "+  −")
                shortcut("Fortryd", "⌘Z")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ action: String, _ keys: String) -> some View {
        LabeledContent(action) { Text(keys).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
    }
}

private struct ClipInspector: View {
    @Environment(Editor.self) private var editor
    let clip: Clip

    private static let fontFamilies = NSFontManager.shared.availableFontFamilies

    var body: some View {
        Form {
            Section {
                LabeledContent("Type", value: kindName)
                if let media = editor.project.media(clip.mediaID) {
                    LabeledContent("Fil") { Text(media.name).lineLimit(1).truncationMode(.middle) }
                }
                LabeledContent("Start") {
                    TextField("", value: startBinding, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing).frame(width: 80)
                    Text("sek").foregroundStyle(.secondary)
                }
                LabeledContent("Varighed") {
                    TextField("", value: durationBinding, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing).frame(width: 80)
                    Text("sek").foregroundStyle(.secondary)
                }
            }

            if clip.kind == .title { titleSection }

            if clip.kind == .video || clip.kind == .image {
                Section("Billede") {
                    Picker("Tilpasning", selection: editor.binding(clip.id, \.fill, fallback: clip.fill)) {
                        Text("Udfyld rammen").tag(true)
                        Text("Vis hele billedet").tag(false)
                    }
                    slider("Størrelse", \.scale, 0.1...3, percent: true)
                    slider("Vandret", \.offsetX, -1...1, percent: true)
                    slider("Lodret", \.offsetY, -1...1, percent: true)
                    Button("Nulstil placering") {
                        editor.updateClip(clip.id) { $0.scale = 1; $0.offsetX = 0; $0.offsetY = 0 }
                    }
                    Text("Tip: træk i preview for at flytte billedet.").font(.caption).foregroundStyle(.secondary)
                }
            }

            if clip.kind == .audio || (clip.kind == .video && editor.project.media(clip.mediaID)?.hasAudio == true) {
                Section("Lyd") {
                    slider("Lydstyrke", \.volume, 0...2, percent: true)
                    Toggle("Slå lyd fra", isOn: Binding(
                        get: { editor.selectedClip?.volume == 0 },
                        set: { muted in editor.updateClip(clip.id) { $0.volume = muted ? 0 : 1 } }
                    ))
                }
            }

            Section(clip.kind == .audio ? "Fade" : "Fade ind og ud") {
                slider("Fade ind", \.fadeIn, 0...3, unit: "s")
                slider("Fade ud", \.fadeOut, 0...3, unit: "s")
            }

            Section {
                Button("Del ved afspilningshoved") { editor.splitAtPlayhead() }
                Button("Dupliker") { editor.duplicateSelection() }
                Button("Slet klip", role: .destructive) { editor.deleteSelection() }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private var titleSection: some View {
        Section("Tekst") {
            TextEditor(text: editor.binding(clip.id, \Clip.title!.text, fallback: clip.title?.text ?? ""))
                .font(.body)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
            Picker("Skrifttype", selection: editor.binding(clip.id, \Clip.title!.fontFamily, fallback: "Helvetica Neue")) {
                ForEach(Self.fontFamilies, id: \.self) { Text($0).tag($0) }
            }
            Toggle("Fed", isOn: editor.binding(clip.id, \Clip.title!.bold, fallback: true))
            slider("Størrelse", \Clip.title!.size, 20...300, unit: "px")
            ColorPicker("Farve", selection: colorBinding(\Clip.title!.color))
            Toggle("Skygge", isOn: editor.binding(clip.id, \Clip.title!.shadow, fallback: true))
            Toggle("Baggrund", isOn: editor.binding(clip.id, \Clip.title!.background, fallback: false))
            if clip.title?.background == true {
                ColorPicker("Baggrundsfarve", selection: colorBinding(\Clip.title!.backgroundColor))
            }
        }
        Section("Placering") {
            slider("Vandret", \Clip.title!.x, 0...1, percent: true)
            slider("Lodret", \Clip.title!.y, 0...1, percent: true)
            HStack {
                Button("Top") { setTitleY(0.12) }
                Button("Midt") { setTitleY(0.5) }
                Button("Bund") { setTitleY(0.82) }
            }
            Text("Tip: træk i preview for at flytte teksten.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var kindName: String {
        switch clip.kind {
        case .video: "Video"
        case .image: "Billede"
        case .audio: "Lyd"
        case .title: "Tekst"
        }
    }

    private func setTitleY(_ y: Double) {
        editor.updateClip(clip.id) { $0.title?.x = 0.5; $0.title?.y = y }
    }

    private var startBinding: Binding<Double> {
        Binding(
            get: { editor.selectedClip?.start ?? clip.start },
            set: { value in
                guard let current = editor.selectedClip else { return }
                let start = editor.freeStart(current.group, track: current.track, desired: max(0, value),
                                             duration: current.duration, excluding: current.id)
                editor.updateClip(clip.id) { $0.start = start }
            }
        )
    }

    private var durationBinding: Binding<Double> {
        Binding(
            get: { editor.selectedClip?.duration ?? clip.duration },
            set: { value in
                guard let current = editor.selectedClip else { return }
                var limit = Double.infinity
                if current.hasMediaTiming, let media = editor.project.media(current.mediaID) {
                    limit = media.duration - current.sourceIn
                }
                let next = editor.project.clips
                    .filter { $0.group == current.group && $0.track == current.track && $0.start >= current.end - 1e-6 && $0.id != current.id }
                    .map(\.start).min()
                if let next { limit = min(limit, next - current.start) }
                let duration = min(max(value, 1 / Double(editor.project.fps)), limit)
                editor.updateClip(clip.id) { $0.duration = duration }
            }
        )
    }

    private func colorBinding(_ keyPath: WritableKeyPath<Clip, RGBA>) -> Binding<Color> {
        let value = editor.binding(clip.id, keyPath, fallback: .white)
        return Binding(get: { value.wrappedValue.color }, set: { value.wrappedValue = RGBA($0) })
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<Clip, Double>, _ range: ClosedRange<Double>,
                        percent: Bool = false, unit: String = "") -> some View {
        let value = editor.binding(clip.id, keyPath, fallback: clip[keyPath: keyPath])
        return LabeledContent(title) {
            HStack {
                Slider(value: value, in: range)
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded())) %" : String(format: "%.1f \(unit)", value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }
}
