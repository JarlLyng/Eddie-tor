import IAMJARLDesignTokens
import SwiftUI

struct InspectorView: View {
    @Environment(Editor.self) private var editor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editor.selectedClip == nil ? "Projekt" : "Klip").ijFont(.base, weight: .semibold)
                Spacer()
            }
            .padding(.horizontal, Tokens.Spacing.md)
            .padding(.vertical, Tokens.Spacing.sm)
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
                Toggle("Magnetisk hovedspor (V1)", isOn: editor.projectBinding(\.magneticMain))
            }
            Section("Overblik") {
                LabeledContent("Varighed", value: timecode(editor.project.duration, fps: editor.project.fps))
                if editor.project.inPoint != nil || editor.project.outPoint != nil {
                    LabeledContent("Ind / ud", value: "\(timecode(editor.project.inPoint ?? 0, fps: editor.project.fps)) – \(timecode(editor.project.outPoint ?? editor.project.duration, fps: editor.project.fps))")
                }
                LabeledContent("Klip", value: "\(editor.project.clips.count)")
                LabeledContent("Medier", value: "\(editor.project.media.count)")
            }
            Section("Genveje (som i Rush)") {
                shortcut("Afspil / pause", "Mellemrum")
                shortcut("Spol tilbage / stop / frem", "J  K  L")
                shortcut("Et billede tilbage / frem", "←  →")
                shortcut("Forrige / næste klip", "↑  ↓")
                shortcut("Del klip", "S")
                shortcut("Trim start / slut til hoved", "Q  W")
                shortcut("Dupliker", "D")
                shortcut("Ny tekst", "G")
                shortcut("Adskil lyd", "E")
                shortcut("Slet", "⌫")
                shortcut("Tilføj overgang", "⌘D")
                shortcut("Kopiér / klip ud / sæt ind", "⌘C  ⌘X  ⌘V")
                shortcut("Ind- / udpunkt", "I  O")
                shortcut("Gå til ind / ud", "⇧I  ⇧O")
                shortcut("Ryd ind / ud / begge", "⌥I  ⌥O  ⌥X")
                shortcut("Zoom ind / ud / hele", "=  −  \\")
                shortcut("Snap / gentag", "⌘Y  ⌘L")
                shortcut("Værktøjer", "⌘1 ⌘2 ⌘4 ⌘5 ⌘6")
                shortcut("Stort preview / medier", "`  Y")
                shortcut("Eksporter", "⌘E")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func shortcut(_ action: String, _ keys: String) -> some View {
        LabeledContent(action) { Text(keys).ijFont(.sm, design: .monospaced).foregroundStyle(Tokens.Palette.Text.secondary) }
    }
}

private struct ClipInspector: View {
    @Environment(Editor.self) private var editor
    let clip: Clip

    private static let fontFamilies = NSFontManager.shared.availableFontFamilies

    var body: some View {
        let current = editor.selectedClip ?? clip
        let tabs = InspectorTab.available(for: current, hasAudio: editor.project.media(clip.mediaID)?.hasAudio == true)
        let tab = tabs.contains(editor.inspectorTab) ? editor.inspectorTab : tabs[0]
        VStack(spacing: 0) {
            Picker("", selection: Binding(get: { tab }, set: { editor.inspectorTab = $0 })) {
                ForEach(tabs) { t in
                    Image(systemName: t.icon).help("\(t.label) (⌘\(t.rawValue))").tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Tokens.Spacing.md)
            .padding(.top, Tokens.Spacing.sm)
            Text(tab.label).ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary).padding(.top, Tokens.Spacing.xs)

            Form {
                Section {
                    LabeledContent("Type", value: kindName)
                    if let media = editor.project.media(clip.mediaID) {
                        LabeledContent("Fil") { Text(media.name).lineLimit(1).truncationMode(.middle) }
                    }
                    LabeledContent("Start") {
                        TextField("", value: startBinding, format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing).frame(width: 80)
                            .disabled(editor.project.isMagnetic(current))
                        Text("sek").foregroundStyle(Tokens.Palette.Text.secondary)
                    }
                    LabeledContent("Varighed") {
                        TextField("", value: Binding(get: { editor.selectedClip?.duration ?? clip.duration },
                                                     set: { editor.setDuration(clip.id, $0) }),
                                  format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing).frame(width: 80)
                        Text("sek").foregroundStyle(Tokens.Palette.Text.secondary)
                    }
                }

                switch tab {
                case .text: titleSections
                case .transitions: transitionSections(current)
                case .speed: speedSection(current)
                case .audio: audioSection(current)
                case .position: positionSections
                }

                Section {
                    Button("Del ved afspilningshoved  (S)") { editor.splitAtPlayhead() }
                    Button("Dupliker  (D)") { editor.duplicateSelection() }
                    Button("Slet klip", role: .destructive) { editor.deleteSelection() }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Text

    @ViewBuilder private var titleSections: some View {
        Section("Tekst") {
            TextEditor(text: editor.binding(clip.id, \Clip.title!.text, fallback: clip.title?.text ?? ""))
                .ijFont(.base)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(Tokens.Spacing.xs)
                .background(Tokens.Palette.Background.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
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
            Text("Tip: træk i preview for at flytte teksten.").ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary)
        }
    }

    // MARK: Transitions

    @ViewBuilder private func transitionSections(_ current: Clip) -> some View {
        if current.kind == .title {
            Section("Fade") {
                slider("Fade ind", \.fadeIn, 0...3, unit: "s")
                slider("Fade ud", \.fadeOut, 0...3, unit: "s")
            }
        } else {
            Section {
                transitionPicker("Ved start", \.transitionIn, current: current)
            } header: {
                Text("Start")
            } footer: {
                if editor.project.isMagnetic(current) {
                    Text("På hovedsporet glider klippet ind over klippet før, så overgangen bliver mellem de to.")
                        .ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary)
                }
            }
            Section("Slut") {
                transitionPicker("Ved slut", \.transitionOut, current: current)
            }
        }
    }

    @ViewBuilder private func transitionPicker(_ title: String, _ keyPath: WritableKeyPath<Clip, Transition?>, current: Clip) -> some View {
        let transition = current[keyPath: keyPath]
        Picker(title, selection: Binding<TransitionKind?>(
            get: { transition?.kind },
            set: { kind in
                editor.updateClip(clip.id) { c in
                    if let kind {
                        c[keyPath: keyPath] = Transition(kind: kind, duration: c[keyPath: keyPath]?.duration ?? Editor.defaultTransition.duration)
                    } else {
                        c[keyPath: keyPath] = nil
                    }
                }
            }
        )) {
            Text("Ingen").tag(TransitionKind?.none)
            ForEach(TransitionKind.allCases) { Text($0.label).tag(TransitionKind?.some($0)) }
        }
        if let transition {
            let value = Binding<Double>(
                get: { editor.selectedClip?[keyPath: keyPath]?.duration ?? transition.duration },
                set: { d in editor.updateClip(clip.id, coalesce: "\(keyPath)") { $0[keyPath: keyPath]?.duration = d } }
            )
            LabeledContent("Varighed") {
                HStack {
                    Slider(value: value, in: 0.1...3)
                    Text(String(format: "%.1f s", value.wrappedValue))
                        .ijFont(.xs).monospacedDigit().foregroundStyle(Tokens.Palette.Text.secondary).frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    // MARK: Speed

    @ViewBuilder private func speedSection(_ current: Clip) -> some View {
        let percent = Binding<Double>(
            get: { (editor.selectedClip?.speed ?? clip.speed) * 100 },
            set: { editor.setSpeed(clip.id, $0 / 100) }
        )
        Section("Hastighed") {
            LabeledContent("Hastighed") {
                HStack {
                    Slider(value: percent, in: 10...400)
                    TextField("", value: percent, format: .number.precision(.fractionLength(0)))
                        .multilineTextAlignment(.trailing).frame(width: 50)
                    Text("%").foregroundStyle(Tokens.Palette.Text.secondary)
                }
            }
            HStack {
                ForEach([25, 50, 100, 200, 400], id: \.self) { p in
                    Button("\(p) %") { editor.setSpeed(clip.id, Double(p) / 100) }
                }
            }
            Toggle("Bevar tonehøjde", isOn: editor.binding(clip.id, \.maintainPitch, fallback: true))
            LabeledContent("Kildelængde", value: String(format: "%.2f s", current.sourceDuration))
            Text("Klippet bliver kortere eller længere, så den samme del af optagelsen vises. Op til 1000 % kan skrives i feltet.")
                .ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary)
        }
    }

    // MARK: Audio

    @ViewBuilder private func audioSection(_ current: Clip) -> some View {
        Section("Lyd") {
            slider("Lydstyrke", \.volume, 0...2, percent: true)
            Toggle("Slå lyd fra", isOn: Binding(
                get: { editor.selectedClip?.volume == 0 },
                set: { muted in editor.updateClip(clip.id) { $0.volume = muted ? 0 : 1 } }
            ))
            slider("Fade ind", \.fadeIn, 0...3, unit: "s")
            slider("Fade ud", \.fadeOut, 0...3, unit: "s")
            if current.kind == .video {
                Button("Adskil lyd til eget spor  (E)") { editor.separateAudio() }
            }
        }
    }

    // MARK: Position

    @ViewBuilder private var positionSections: some View {
        Section("Størrelse og placering") {
            Picker("Tilpasning", selection: editor.binding(clip.id, \.fill, fallback: clip.fill)) {
                Text("Udfyld rammen").tag(true)
                Text("Vis hele billedet").tag(false)
            }
            slider("Størrelse", \.scale, 0.1...3, percent: true)
            slider("Vandret", \.offsetX, -1...1, percent: true)
            slider("Lodret", \.offsetY, -1...1, percent: true)
            slider("Rotation", \.rotation, -180...180, unit: "°")
            slider("Opacitet", \.opacity, 0...1, percent: true)
            HStack {
                Toggle("Spejl vandret", isOn: editor.binding(clip.id, \.flipH, fallback: false))
                Toggle("Spejl lodret", isOn: editor.binding(clip.id, \.flipV, fallback: false))
            }
            Text("Tip: træk i preview for at flytte billedet.").ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary)
        }
        Section("Beskæring") {
            slider("Venstre", \.cropLeft, 0...0.5, percent: true)
            slider("Højre", \.cropRight, 0...0.5, percent: true)
            slider("Top", \.cropTop, 0...0.5, percent: true)
            slider("Bund", \.cropBottom, 0...0.5, percent: true)
            slider("Blød kant", \.feather, 0...100, unit: "px")
        }
        Section {
            Button("Nulstil størrelse, placering og beskæring") {
                editor.updateClip(clip.id) { c in
                    c.scale = 1; c.offsetX = 0; c.offsetY = 0; c.rotation = 0; c.opacity = 1
                    c.flipH = false; c.flipV = false
                    c.cropLeft = 0; c.cropRight = 0; c.cropTop = 0; c.cropBottom = 0; c.feather = 0
                }
            }
        }
    }

    // MARK: Helpers

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
                guard let current = editor.selectedClip, !editor.project.isMagnetic(current) else { return }
                let start = editor.freeStart(current.group, track: current.track, desired: max(0, value),
                                             duration: current.duration, excluding: current.id)
                editor.updateClip(clip.id) { $0.start = start }
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
                    .ijFont(.xs)
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Palette.Text.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
        }
    }
}
