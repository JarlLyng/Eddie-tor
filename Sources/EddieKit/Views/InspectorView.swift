import IAMJARLDesignTokens
import SwiftUI

struct InspectorView: View {
    @Environment(Editor.self) private var editor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editor.selectedClip == nil ? "Project" : "Clip").ijFont(.base, weight: .semibold)
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
                Picker("Aspect Ratio", selection: editor.projectBinding(\.aspect)) {
                    ForEach(AspectRatio.allCases) { aspect in
                        Text("\(aspect.label)  (\(Int(aspect.renderSize.width))×\(Int(aspect.renderSize.height)))").tag(aspect)
                    }
                }
                Picker("Frame Rate", selection: editor.projectBinding(\.fps)) {
                    ForEach([24, 25, 30, 50, 60], id: \.self) { Text("\($0)").tag($0) }
                }
                ColorPicker("Background Color", selection: Binding(
                    get: { editor.project.background.color },
                    set: { color in editor.edit(coalesce: "background") { $0.background = RGBA(color) } }
                ), supportsOpacity: false)
                Toggle("Magnetic Main Track (V1)", isOn: editor.projectBinding(\.magneticMain))
            }
            Section("Overview") {
                LabeledContent("Duration", value: timecode(editor.project.duration, fps: editor.project.fps))
                if editor.project.inPoint != nil || editor.project.outPoint != nil {
                    LabeledContent("In / Out", value: "\(timecode(editor.project.inPoint ?? 0, fps: editor.project.fps)) – \(timecode(editor.project.outPoint ?? editor.project.duration, fps: editor.project.fps))")
                }
                LabeledContent("Clips", value: "\(editor.project.clips.count)")
                LabeledContent("Media", value: "\(editor.project.media.count)")
            }
            Section("Shortcuts") {
                shortcut("Play / pause", String(localized: "Space"))
                shortcut("Rewind / stop / forward", "J  K  L")
                shortcut("One frame back / forward", "←  →")
                shortcut("Previous / next clip edge", "↑  ↓")
                shortcut("Split clip", "S")
                shortcut("Trim start / end to playhead", "Q  W")
                shortcut("Duplicate", "D")
                shortcut("New title", "G")
                shortcut("Separate audio", "E")
                shortcut("Delete", "⌫")
                shortcut("Add transition", "⌘D")
                shortcut("Copy / cut / paste", "⌘C  ⌘X  ⌘V")
                shortcut("In / out point", "I  O")
                shortcut("Go to in / out", "⇧I  ⇧O")
                shortcut("Clear in / out / both", "⌥I  ⌥O  ⌥X")
                shortcut("Zoom in / out / fit", "=  −  \\")
                shortcut("Snap / loop", "⌘Y  ⌘L")
                shortcut("Tools", "⌘1 ⌘2 ⌘4 ⌘5 ⌘6")
                shortcut("Large preview / media", "`  Y")
                shortcut("Export", "⌘E")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private func shortcut(_ action: LocalizedStringKey, _ keys: String) -> some View {
        LabeledContent(action) { Text(keys).ijFont(.sm, design: .monospaced).foregroundStyle(Tokens.Palette.Text.secondary) }
    }
}

private struct ClipInspector: View {
    @Environment(Editor.self) private var editor
    let clip: Clip

    private static let fontFamilies = NSFontManager.shared.availableFontFamilies
    private static let weights: [(Double, LocalizedStringKey)] = [
        (100, "Thin"), (200, "Extra Light"), (300, "Light"), (400, "Regular"), (500, "Medium"),
        (600, "Semibold"), (700, "Bold"), (800, "Extra Bold"), (900, "Black"),
    ]

    /// The clip as it is now. Looked up by its id, not through the selection, which may have moved on to another
    /// clip when this inspector draws for the last time.
    private var current: Clip { editor.project.clips.first { $0.id == clip.id } ?? clip }

    var body: some View {
        let (tabs, tab) = editor.inspectorTabs(for: clip)
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
                        LabeledContent("File") { Text(media.name).lineLimit(1).truncationMode(.middle) }
                    }
                    LabeledContent("Start") {
                        TextField("", value: startBinding, format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing).frame(width: 80)
                            .disabled(editor.project.isMagnetic(current))
                        Text("sec").foregroundStyle(Tokens.Palette.Text.secondary)
                    }
                    LabeledContent("Duration") {
                        TextField("", value: Binding(get: { current.duration },
                                                     set: { editor.setDuration(clip.id, $0) }),
                                  format: .number.precision(.fractionLength(0...2)))
                            .multilineTextAlignment(.trailing).frame(width: 80)
                        Text("sec").foregroundStyle(Tokens.Palette.Text.secondary)
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
                    Button("Split at Playhead  (S)") { editor.splitAtPlayhead() }
                    Button("Duplicate  (D)") { editor.duplicateSelection() }
                    Button("Delete Clip", role: .destructive) { editor.deleteSelection() }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: Text

    @ViewBuilder private var titleSections: some View {
        Section("Text") {
            TextEditor(text: editor.binding(clip.id, \Clip.title!.text, fallback: clip.title?.text ?? ""))
                .ijFont(.base)
                .frame(minHeight: 60)
                .scrollContentBackground(.hidden)
                .padding(Tokens.Spacing.xs)
                .background(Tokens.Palette.Background.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            Picker("Font", selection: editor.binding(clip.id, \Clip.title!.fontFamily, fallback: "Helvetica Neue")) {
                ForEach(Self.fontFamilies, id: \.self) { Text(BundledFonts.displayName($0)).tag($0) }
            }
            Picker("Weight", selection: editor.binding(clip.id, \Clip.title!.weight, fallback: 700)) {
                ForEach(Self.weights, id: \.0) { Text($0.1).tag($0.0) }
            }
            slider("Size", \Clip.title!.size, 20...300, unit: "px")
            Picker("Alignment", selection: editor.binding(clip.id, \Clip.title!.align, fallback: .center)) {
                Image(systemName: "text.alignleft").help("Left").tag(TextAlign.left)
                Image(systemName: "text.aligncenter").help("Center").tag(TextAlign.center)
                Image(systemName: "text.alignright").help("Right").tag(TextAlign.right)
            }
            .pickerStyle(.segmented)
            slider("Line Spacing", \Clip.title!.lineHeight, 0.6...2, percent: true)
            ColorPicker("Color", selection: colorBinding(\Clip.title!.color))
            Toggle("Shadow", isOn: editor.binding(clip.id, \Clip.title!.shadow, fallback: true))
            Toggle("Background", isOn: editor.binding(clip.id, \Clip.title!.background, fallback: false))
            if clip.title?.background == true {
                ColorPicker("Background Color", selection: colorBinding(\Clip.title!.backgroundColor))
            }
        }
        Section("Position") {
            slider("Horizontal", \Clip.title!.x, 0...1, percent: true)
            slider("Vertical", \Clip.title!.y, 0...1, percent: true)
            HStack {
                Button("Top") { setTitleY(0.12) }
                Button("Middle") { setTitleY(0.5) }
                Button("Bottom") { setTitleY(0.82) }
            }
            Text("Horizontal is the left edge, center or right edge of the text, depending on the alignment.")
                .ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary)
            Text("Tip: drag in the preview to move the text.").ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary)
        }
    }

    // MARK: Transitions

    @ViewBuilder private func transitionSections(_ current: Clip) -> some View {
        if current.kind == .title {
            Section("Fade") {
                slider("Fade In", \.fadeIn, 0...3, unit: "s")
                slider("Fade Out", \.fadeOut, 0...3, unit: "s")
            }
        } else {
            Section {
                transitionPicker("At Start", \.transitionIn, current: current)
            } header: {
                Text("Start")
            } footer: {
                if editor.project.isMagnetic(current) {
                    Text("On the main track the clip slides over the clip before it, so the transition is between the two.")
                        .ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary)
                }
            }
            Section("End") {
                transitionPicker("At End", \.transitionOut, current: current)
            }
        }
    }

    @ViewBuilder private func transitionPicker(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<Clip, Transition?>, current: Clip) -> some View {
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
            Text("None").tag(TransitionKind?.none)
            ForEach(TransitionKind.allCases) { Text($0.label).tag(TransitionKind?.some($0)) }
        }
        if let transition {
            let value = Binding<Double>(
                get: { self.current[keyPath: keyPath]?.duration ?? transition.duration },
                set: { d in editor.updateClip(clip.id, coalesce: "\(keyPath)") { $0[keyPath: keyPath]?.duration = d } }
            )
            LabeledContent("Duration") {
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
            get: { self.current.speed * 100 },
            set: { editor.setSpeed(clip.id, $0 / 100) }
        )
        Section("Speed") {
            LabeledContent("Speed") {
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
            Toggle("Preserve Pitch", isOn: editor.binding(clip.id, \.maintainPitch, fallback: true))
            LabeledContent("Source Length", value: String(format: "%.2f s", current.sourceDuration))
            Text("The clip gets shorter or longer, so the same part of the recording plays. You can type up to 1000 % in the field.")
                .ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary)
        }
    }

    // MARK: Audio

    @ViewBuilder private func audioSection(_ current: Clip) -> some View {
        Section("Audio") {
            slider("Volume", \.volume, 0...2, percent: true)
            Toggle("Mute", isOn: Binding(
                get: { self.current.volume == 0 },
                set: { muted in editor.updateClip(clip.id) { $0.volume = muted ? 0 : 1 } }
            ))
            slider("Fade In", \.fadeIn, 0...3, unit: "s")
            slider("Fade Out", \.fadeOut, 0...3, unit: "s")
            if current.kind == .video {
                Button("Separate Audio to Its Own Track  (E)") { editor.separateAudio() }
            }
        }
    }

    // MARK: Position

    @ViewBuilder private var positionSections: some View {
        Section("Size and Position") {
            Picker("Scaling", selection: editor.binding(clip.id, \.fill, fallback: clip.fill)) {
                Text("Fill the Frame").tag(true)
                Text("Show the Whole Picture").tag(false)
            }
            slider("Size", \.scale, 0.1...3, percent: true)
            slider("Horizontal", \.offsetX, -1...1, percent: true)
            slider("Vertical", \.offsetY, -1...1, percent: true)
            slider("Rotation", \.rotation, -180...180, unit: "°")
            slider("Opacity", \.opacity, 0...1, percent: true)
            HStack {
                Toggle("Flip Horizontally", isOn: editor.binding(clip.id, \.flipH, fallback: false))
                Toggle("Flip Vertically", isOn: editor.binding(clip.id, \.flipV, fallback: false))
            }
            Text("Tip: drag in the preview to move the picture.").ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary)
        }
        Section("Crop") {
            slider("Left", \.cropLeft, 0...0.5, percent: true)
            slider("Right", \.cropRight, 0...0.5, percent: true)
            slider("Top", \.cropTop, 0...0.5, percent: true)
            slider("Bottom", \.cropBottom, 0...0.5, percent: true)
            slider("Feather", \.feather, 0...100, unit: "px")
        }
        Section {
            Button("Reset Size, Position and Crop") {
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
        case .video: String(localized: "Video")
        case .image: String(localized: "Image")
        case .audio: String(localized: "Audio")
        case .title: String(localized: "Title")
        }
    }

    private func setTitleY(_ y: Double) {
        editor.updateClip(clip.id) { c in
            guard let align = c.title?.align else { return }
            c.title?.x = align == .left ? 0.05 : align == .right ? 0.95 : 0.5
            c.title?.y = y
        }
    }

    private var startBinding: Binding<Double> {
        Binding(
            get: { current.start },
            set: { value in
                let current = self.current
                guard !editor.project.isMagnetic(current) else { return }
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

    private func slider(_ title: LocalizedStringKey, _ keyPath: WritableKeyPath<Clip, Double>, _ range: ClosedRange<Double>,
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
