import SwiftUI

private let rulerHeight: CGFloat = 24
private let headerWidth: CGFloat = 54

struct TimelinePanel: View {
    @Environment(Editor.self) private var editor
    @ViewState private var scroll = ScrollPosition(edge: .leading)
    @ViewState private var scrollOffset: CGFloat = 0
    @ViewState private var visibleWidth: CGFloat = 800

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    headers
                    ScrollView(.horizontal) {
                        TimelineContent(width: contentWidth)
                    }
                    .scrollPosition($scroll)
                    .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in scrollOffset = x }
                    .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, w in visibleWidth = w }
                }
            }
            .background(Color(white: 0.11))
        }
        .onChange(of: editor.currentTime) { _, time in followPlayhead(time) }
    }

    private var contentWidth: CGFloat {
        max(CGFloat(editor.project.duration + 20) * editor.pps, visibleWidth)
    }

    /// Pages the timeline along while playing, like Rush does.
    private func followPlayhead(_ time: Double) {
        guard editor.isPlaying else { return }
        let x = time * editor.pps
        if x > scrollOffset + visibleWidth - 30 || x < scrollOffset {
            scroll.scrollTo(x: max(0, x - 40))
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { editor.togglePlay() } label: { Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill") }
                .help("Afspil / pause (mellemrum)")
            Text("\(timecode(editor.currentTime, fps: editor.project.fps))  /  \(timecode(editor.project.duration, fps: editor.project.fps))")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
            Divider().frame(height: 18)
            Button { editor.splitAtPlayhead() } label: { Image(systemName: "scissors") }
                .help("Del klip ved afspilningshovedet (S)")
            Button { editor.deleteSelection() } label: { Image(systemName: "trash") }
                .help("Slet valgt klip (⌫)")
                .disabled(editor.selection == nil)
            Button { editor.addTitle() } label: { Image(systemName: "textformat") }
                .help("Tilføj tekst (T)")
            Menu {
                Button("Videospor") { editor.addTrack(.visual) }
                Button("Lydspor") { editor.addTrack(.audio) }
                Button("Tekstspor") { editor.addTrack(.title) }
            } label: { Image(systemName: "rectangle.stack.badge.plus") }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Tilføj spor")
            Divider().frame(height: 18)
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Fortryd (⌘Z)").disabled(!editor.canUndo)
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("Annuller fortryd (⇧⌘Z)").disabled(!editor.canRedo)
            Spacer()
            Button { editor.pps = max(editor.pps / 1.4, 4) } label: { Image(systemName: "minus.magnifyingglass") }
            Slider(value: Binding(get: { log(editor.pps) }, set: { editor.pps = exp($0) }), in: log(4)...log(600))
                .frame(width: 140)
            Button { editor.pps = min(editor.pps * 1.4, 600) } label: { Image(systemName: "plus.magnifyingglass") }
            Button("Tilpas") {
                let duration = max(editor.project.duration, 5)
                editor.pps = min(max(Double(visibleWidth - 40) / duration, 4), 600)
                scroll.scrollTo(x: 0)
            }
            .help("Vis hele tidslinjen")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var headers: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            ForEach(editor.rows) { row in
                HStack(spacing: 4) {
                    Image(systemName: row.group == .title ? "textformat" : row.group == .visual ? "film" : "speaker.wave.2")
                        .font(.system(size: 10))
                    Text(row.label).font(.caption.bold())
                }
                .foregroundStyle(.secondary)
                .frame(width: headerWidth, height: row.height)
                .background(Color(white: 0.15))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1) }
            }
        }
        .frame(width: headerWidth)
    }
}

private struct TimelineContent: View {
    @Environment(Editor.self) private var editor
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                RulerView(width: width)
                    .frame(width: width, height: rulerHeight)
                ForEach(editor.rows) { row in
                    TrackLane(row: row)
                        .frame(width: width, height: row.height)
                }
            }
            PlayheadView()
        }
        .frame(width: width, alignment: .topLeading)
        .coordinateSpace(.named("timeline"))
    }
}

private struct RulerView: View {
    @Environment(Editor.self) private var editor
    let width: CGFloat

    var body: some View {
        let pps = editor.pps
        Canvas { ctx, size in
            let major = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { $0 * pps >= 70 } ?? 600
            let minor = major / (major >= 10 ? 5 : 4)
            let ticks = Int(Double(size.width) / (minor * pps)) + 1
            for i in 0...ticks {
                let t = Double(i) * minor
                let x = t * pps
                let isMajor = abs(t / major - (t / major).rounded()) < 0.001
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x, y: size.height - (isMajor ? 10 : 5)))
                ctx.stroke(path, with: .color(.gray), lineWidth: 1)
                if isMajor {
                    let label = major < 1
                        ? String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                        : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
                    ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(.gray), at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
            }
        }
        .background(Color(white: 0.14))
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            if editor.isPlaying { editor.pause() }
            editor.seek(value.location.x / pps)
        })
    }
}

private struct PlayheadView: View {
    @Environment(Editor.self) private var editor

    var body: some View {
        let x = editor.currentTime * editor.pps
        VStack(spacing: 0) {
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .frame(height: rulerHeight - 6, alignment: .bottom)
            Rectangle().fill(Color.red).frame(width: 1.5)
        }
        .frame(width: 12)
        .offset(x: x - 6, y: 4)
        .allowsHitTesting(false)
    }
}

private struct TrackLane: View {
    @Environment(Editor.self) private var editor
    let row: TrackRow
    @ViewState private var targeted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(targeted ? Color.accentColor.opacity(0.18) : Color(white: row.group == .visual ? 0.13 : 0.12))
                .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.5)).frame(height: 1) }
                .onTapGesture(coordinateSpace: .local) { location in
                    editor.selection = nil
                    if editor.isPlaying { editor.pause() }
                    editor.seek(location.x / editor.pps)
                }
            ForEach(editor.clips(in: row)) { clip in
                ClipView(clip: clip, row: row)
                    .frame(width: max(clip.duration * editor.pps, 3), height: row.height - 6)
                    .offset(x: clip.start * editor.pps, y: 3)
            }
        }
        .dropDestination(for: String.self) { ids, location in
            editor.dropMedia(ids, at: location.x / editor.pps, row: row)
        } isTargeted: { targeted = $0 }
    }
}

private struct ClipView: View {
    @Environment(Editor.self) private var editor
    let clip: Clip
    let row: TrackRow
    @ViewState private var origin: Clip?
    @ViewState private var hoveringHandle = false

    enum Mode { case move, trimStart, trimEnd }

    var body: some View {
        let selected = editor.selection == clip.id
        let width = clip.duration * editor.pps
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5).fill(color.opacity(0.75))
            // The thumbnail strip can be wider than the clip; pin it left so the label stays put.
            content
                .frame(width: max(width, 3), height: row.height - 6, alignment: .bottomLeading)
                .clipped()
            label
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(selected ? Color.yellow : Color.black.opacity(0.35), lineWidth: selected ? 2 : 1))
        .overlay(alignment: .leading) { if width > 24 { handle(.trimStart, selected: selected) } }
        .overlay(alignment: .trailing) { if width > 24 { handle(.trimEnd, selected: selected) } }
        .contentShape(Rectangle())
        .onTapGesture { editor.selection = clip.id }
        .gesture(drag(.move))
        .contextMenu {
            Button("Del ved afspilningshoved") { editor.selection = clip.id; editor.splitAtPlayhead() }
            Button("Dupliker") { editor.selection = clip.id; editor.duplicateSelection() }
            Divider()
            Button("Slet", role: .destructive) { editor.selection = clip.id; editor.deleteSelection() }
        }
        .help(name)
    }

    private var media: MediaItem? { editor.project.media(clip.mediaID) }

    private var name: String {
        if clip.kind == .title { return clip.title?.text ?? "Tekst" }
        return media?.name ?? "Mangler fil"
    }

    private var color: Color {
        if clip.kind != .title, media.map({ FileManager.default.fileExists(atPath: $0.url.path) }) != true { return .red }
        return switch clip.kind {
        case .video: Color(red: 0.22, green: 0.42, blue: 0.82)
        case .image: Color(red: 0.55, green: 0.35, blue: 0.80)
        case .audio: Color(red: 0.20, green: 0.62, blue: 0.40)
        case .title: Color(red: 0.88, green: 0.55, blue: 0.18)
        }
    }

    @ViewBuilder private var content: some View {
        let height = row.height - 6
        switch clip.kind {
        case .video, .image:
            ZStack(alignment: .bottom) {
                if let thumb = editor.cache.thumbnails[clip.mediaID ?? UUID()] {
                    let tileWidth = max(height * thumb.size.width / max(thumb.size.height, 1), 20)
                    let count = min(Int(clip.duration * editor.pps / tileWidth) + 1, 60)
                    HStack(spacing: 0) {
                        ForEach(0..<count, id: \.self) { _ in
                            Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: tileWidth, height: height).clipped()
                        }
                    }
                    .opacity(0.75)
                }
                if clip.kind == .video, let peaks = editor.cache.waveforms[clip.mediaID ?? UUID()] {
                    WaveformView(peaks: peaks, sourceIn: clip.sourceIn, duration: clip.duration, volume: clip.volume)
                        .frame(height: height * 0.35)
                        .background(Color.black.opacity(0.35))
                }
            }
        case .audio:
            if let peaks = editor.cache.waveforms[clip.mediaID ?? UUID()] {
                WaveformView(peaks: peaks, sourceIn: clip.sourceIn, duration: clip.duration, volume: clip.volume)
                    .padding(.top, 14)
            }
        case .title:
            EmptyView()
        }
    }

    private var label: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9))
            Text(name).lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.black.opacity(clip.kind == .title ? 0 : 0.45), in: RoundedRectangle(cornerRadius: 3))
        .padding(3)
    }

    private var icon: String {
        switch clip.kind {
        case .video: "film"
        case .image: "photo"
        case .audio: "music.note"
        case .title: "textformat"
        }
    }

    private func handle(_ mode: Mode, selected: Bool) -> some View {
        Rectangle()
            .fill(Color.white.opacity(selected || hoveringHandle ? 0.35 : 0.001))
            .frame(width: 7)
            .contentShape(Rectangle())
            .onHover { inside in
                hoveringHandle = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(drag(mode))
    }

    private func drag(_ mode: Mode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("timeline"))
            .onChanged { value in
                if origin == nil {
                    origin = clip
                    editor.selection = clip.id
                    editor.beginInteraction()
                }
                guard let origin else { return }
                let updated = apply(mode, to: origin, dx: value.translation.width, dy: value.translation.height)
                editor.interact { project in
                    if let i = project.clips.firstIndex(where: { $0.id == origin.id }) { project.clips[i] = updated }
                }
            }
            .onEnded { _ in
                guard let origin else { return }
                if mode == .move, let current = editor.project.clips.first(where: { $0.id == origin.id }) {
                    // Never leave clips on top of each other: slide to the next free spot.
                    let start = editor.freeStart(current.group, track: current.track, desired: current.start,
                                                 duration: current.duration, excluding: current.id)
                    editor.interact { project in
                        if let i = project.clips.firstIndex(where: { $0.id == origin.id }) { project.clips[i].start = start }
                    }
                }
                editor.endInteraction()
                self.origin = nil
            }
    }

    private func apply(_ mode: Mode, to o: Clip, dx: CGFloat, dy: CGFloat) -> Clip {
        var c = o
        let dt = dx / editor.pps
        let minimum = 1 / Double(editor.project.fps)
        let neighbours = editor.project.clips.filter { $0.group == o.group && $0.track == o.track && $0.id != o.id }

        switch mode {
        case .move:
            var start = max(0, o.start + dt)
            if let s = editor.snap(start, excluding: o.id) {
                start = s
            } else if let s = editor.snap(start + o.duration, excluding: o.id) {
                start = s - o.duration
            }
            c.start = max(0, start)
            let steps = Int((dy / row.height).rounded())
            let count = editor.project.trackCount(o.group)
            c.track = min(max(o.track + steps * row.downwardStep, 0), count - 1)

        case .trimStart:
            var start = o.start + dt
            if let s = editor.snap(start, excluding: o.id) { start = s }
            var lower = neighbours.filter { $0.end <= o.start + 1e-6 }.map(\.end).max() ?? 0
            if o.hasMediaTiming { lower = max(lower, o.start - o.sourceIn) }
            start = min(max(start, lower), o.end - minimum)
            c.start = start
            c.duration = o.end - start
            if o.hasMediaTiming { c.sourceIn = o.sourceIn + (start - o.start) }

        case .trimEnd:
            var end = o.end + dt
            if let s = editor.snap(end, excluding: o.id) { end = s }
            var upper = neighbours.filter { $0.start >= o.end - 1e-6 }.map(\.start).min() ?? .infinity
            if o.hasMediaTiming, let media { upper = min(upper, o.start + media.duration - o.sourceIn) }
            end = max(min(end, upper), o.start + minimum)
            c.duration = end - o.start
        }
        return c
    }
}

struct WaveformView: View {
    let peaks: [Float]
    let sourceIn: Double
    let duration: Double
    var volume: Double = 1

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty, size.width > 0 else { return }
            let rate = MediaLoader.waveformRate
            let first = sourceIn * rate
            let perPixel = duration * rate / Double(size.width)
            let mid = size.height / 2
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                let a = Int(first + Double(x) * perPixel)
                let b = max(a + 1, Int(first + Double(x + 2) * perPixel))
                guard a < peaks.count else { break }
                let peak = peaks[a..<min(b, peaks.count)].max() ?? 0
                let h = max(1, CGFloat(min(Double(peak) * volume, 1)) * size.height / 2)
                path.addRect(CGRect(x: x, y: mid - h, width: 1.2, height: h * 2))
                x += 2
            }
            ctx.fill(path, with: .color(.white.opacity(0.75)))
        }
        .allowsHitTesting(false)
    }
}
