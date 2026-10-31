import IAMJARLDesignTokens
import SwiftUI

private let rulerHeight: CGFloat = 24
private let headerWidth: CGFloat = 96

struct TimelinePanel: View {
    @Environment(Editor.self) private var editor
    @ViewState private var scrollTarget = ScrollTarget()
    @ViewState private var scrollOffset: CGFloat = 0
    @ViewState private var visibleWidth: CGFloat = 800
    @AppStorage(FirstRunHint.dismissedKey) private var hintDismissed = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !hintDismissed {
                FirstRunHint { hintDismissed = true }
                Divider()
            }
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: 0) {
                    headers
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            TimelineContent(width: contentWidth)
                                .modifier(ScrollHooks(target: scrollTarget, offset: $scrollOffset))
                        }
                        .modifier(TimelineScrolling(target: scrollTarget, offset: $scrollOffset, width: $visibleWidth, proxy: proxy))
                    }
                }
            }
            .background(Tokens.Palette.Background.app)
        }
        .onChange(of: scrollOffset) { updateViewport() }
        .onChange(of: visibleWidth) { updateViewport() }
        .onChange(of: editor.currentTime) { _, time in followPlayhead(time) }
        .onChange(of: editor.zoomToFitRequest) { zoomToFit() }
    }

    private func updateViewport() {
        editor.viewport = Double(scrollOffset)...Double(scrollOffset + visibleWidth)
    }

    private func scroll(to x: CGFloat) {
        scrollTarget = ScrollTarget(x: x, serial: scrollTarget.serial + 1)
    }

    private var contentWidth: CGFloat {
        max(CGFloat(editor.project.duration + 20) * editor.pps, visibleWidth)
    }

    /// Pages the timeline along while playing, like Rush does.
    private func followPlayhead(_ time: Double) {
        guard editor.isPlaying else { return }
        let x = time * editor.pps
        if x > scrollOffset + visibleWidth - 30 || x < scrollOffset {
            scroll(to: max(0, x - 40))
        }
    }

    private func zoomToFit() {
        let duration = max(editor.project.duration, 5)
        editor.pps = min(max(Double(visibleWidth - 40) / duration, 4), 600)
        scroll(to: 0)
    }

    private var toolbar: some View {
        @Bindable var editor = editor
        return HStack(spacing: Tokens.Spacing.md) {
            Button { editor.togglePlay() } label: { Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill") }
                .help("Play / pause (Space, J K L)")
            Text("\(timecode(editor.currentTime, fps: editor.project.fps))  /  \(timecode(editor.project.duration, fps: editor.project.fps))")
                .ijFont(.sm, design: .monospaced)
                .foregroundStyle(Tokens.Palette.Text.secondary)
            Divider().frame(height: 18)
            Button { editor.splitAtPlayhead() } label: { Image(systemName: "scissors") }
                .help("Split the clip at the playhead (S)")
            Button { editor.duplicateSelection() } label: { Image(systemName: "plus.square.on.square") }
                .help("Duplicate (D)")
                .disabled(editor.selection == nil)
            Button { editor.deleteSelection() } label: { Image(systemName: "trash") }
                .help("Delete the selected clip (⌫)")
                .disabled(editor.selection == nil)
            Button { editor.addTitle() } label: { Image(systemName: "textformat") }
                .help("Add a title (G)")
            Button { editor.applyDefaultTransition() } label: { Image(systemName: "rectangle.righthalf.inset.filled.arrow.right") }
                .help("Add a transition (⌘D)")
            Menu {
                Button("Video Track") { editor.addTrack(.visual) }
                Button("Audio Track") { editor.addTrack(.audio) }
                Button("Title Track") { editor.addTrack(.title) }
            } label: { Image(systemName: "rectangle.stack.badge.plus").foregroundStyle(Tokens.Palette.Text.primary) }
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add a track")
            Divider().frame(height: 18)
            Button { editor.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help("Undo (⌘Z)").disabled(!editor.canUndo)
            Button { editor.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("Redo (⇧⌘Z)").disabled(!editor.canRedo)
            Divider().frame(height: 18)
            Toggle(isOn: $editor.snapping) { activeIcon("arrow.right.and.line.vertical.and.arrow.left", editor.snapping) }
                .toggleStyle(.button)
                .help("Snap to edges and the playhead (⌘Y)")
            Toggle(isOn: $editor.loopPlayback) { activeIcon("repeat", editor.loopPlayback) }
                .toggleStyle(.button)
                .help("Loop playback, between in and out if they're set (⌘L)")
            Toggle(isOn: editor.projectBinding(\.magneticMain)) { activeIcon("rectangle.compress.vertical", editor.project.magneticMain) }
                .toggleStyle(.button)
                .help("Magnetic main track: clips on V1 always sit without gaps")
            Spacer()
            Button { editor.pps = max(editor.pps / 1.4, 4) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out (−)")
            Slider(value: Binding(get: { log(editor.pps) }, set: { editor.pps = exp($0) }), in: log(4)...log(600))
                .frame(width: 140)
            Button { editor.pps = min(editor.pps * 1.4, 600) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in (=)")
            Button("Fit") { zoomToFit() }
                .help("Show the whole timeline (\\)")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Tokens.Palette.Text.primary)
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, Tokens.Spacing.xs)
    }

    /// Icons take the text colour; a switched-on tool takes the accent.
    private func activeIcon(_ name: String, _ active: Bool) -> some View {
        Image(systemName: name).foregroundStyle(active ? Tokens.Palette.primary : Tokens.Palette.Text.primary)
    }

    private var headers: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: rulerHeight)
            ForEach(editor.rows) { row in
                TrackHeader(row: row)
                    .frame(width: headerWidth, height: row.height)
            }
        }
        .frame(width: headerWidth)
    }
}

/// Where the timeline was last asked to scroll. The serial lets the same place be asked for twice.
private struct ScrollTarget: Equatable {
    var x: CGFloat = 0
    var serial = 0
}

/// macOS 15 reads and sets the horizontal scroll with `ScrollPosition` and `onScrollGeometryChange`.
/// macOS 14 has neither, so there a geometry reader in the content reports the offset and a
/// `ScrollViewReader` scrolls to an anchor placed at the target. `EDDIE_LEGACY_SCROLL=1` takes the
/// macOS 14 path on a newer Mac, to try it there.
private let legacyScrolling: Bool = {
    if #available(macOS 15, *) { return ProcessInfo.processInfo.environment["EDDIE_LEGACY_SCROLL"] != nil }
    return true
}()
private let scrollSpace = "timelineScroll"
private let scrollAnchor = "timelineScrollTarget"

/// On the horizontal scroll view: reports the visible width and scrolls to the target.
private struct TimelineScrolling: ViewModifier {
    let target: ScrollTarget
    @Binding var offset: CGFloat
    @Binding var width: CGFloat
    let proxy: ScrollViewProxy

    func body(content: Content) -> some View {
        if #available(macOS 15, *), !legacyScrolling {
            content.modifier(ScrollPositionTracking(target: target, offset: $offset, width: $width))
        } else {
            content
                .coordinateSpace(.named(scrollSpace))
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.size.width, initial: true) { _, w in width = w }
                    }
                }
                .onChange(of: target) {
                    // Once the anchor has moved to the target.
                    DispatchQueue.main.async { proxy.scrollTo(scrollAnchor, anchor: .leading) }
                }
        }
    }
}

@available(macOS 15, *)
private struct ScrollPositionTracking: ViewModifier {
    let target: ScrollTarget
    @Binding var offset: CGFloat
    @Binding var width: CGFloat
    @ViewState private var position = ScrollPosition(edge: .leading)

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, x in offset = x }
            .onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.width } action: { _, w in width = w }
            .onChange(of: target) { position.scrollTo(x: target.x) }
    }
}

/// Inside the scrolled content, for macOS 14 only: the offset, and the anchor `TimelineScrolling` scrolls to.
private struct ScrollHooks: ViewModifier {
    let target: ScrollTarget
    @Binding var offset: CGFloat

    func body(content: Content) -> some View {
        if legacyScrolling {
            content
                .background {
                    GeometryReader { geometry in
                        Color.clear.onChange(of: geometry.frame(in: .named(scrollSpace)).minX, initial: true) { _, x in offset = -x }
                    }
                }
                .overlay(alignment: .topLeading) {
                    Color.clear.frame(width: 1, height: 1).id(scrollAnchor).padding(.leading, target.x).allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

private struct TrackHeader: View {
    @Environment(Editor.self) private var editor
    let row: TrackRow

    var body: some View {
        let flags = editor.project.flags(row.group, row.index)
        HStack(spacing: 2) {
            Text(row.label)
                .ijFont(.xs, weight: .semibold)
                .foregroundStyle(row.group == .visual && row.index == 0 && editor.project.magneticMain ? Tokens.Palette.primary : Tokens.Palette.Text.secondary)
                .frame(width: 22, alignment: .leading)
                .help(row.group == .visual && row.index == 0 ? "Main track" : "")
            Spacer(minLength: 0)
            if row.group != .audio {
                flagButton(\.hidden, active: flags.hidden, on: "eye.slash.fill", off: "eye", help: "Hide track")
            }
            if row.group != .title {
                flagButton(\.muted, active: flags.muted, on: "speaker.slash.fill", off: "speaker.wave.2", help: "Mute track")
            }
            flagButton(\.locked, active: flags.locked, on: "lock.fill", off: "lock.open", help: "Lock track")
        }
        .padding(.horizontal, Tokens.Spacing.xs)
        .background(Tokens.Palette.Background.card)
        .overlay(alignment: .bottom) { Rectangle().fill(Tokens.Palette.Border.subtle).frame(height: 1) }
    }

    private func flagButton(_ flag: WritableKeyPath<TrackFlags, Bool>, active: Bool, on: String, off: String, help: LocalizedStringKey) -> some View {
        Button { editor.toggleFlag(row, flag) } label: {
            Image(systemName: active ? on : off)
                .font(.caption)
                .foregroundStyle(active ? Tokens.Palette.primary : Tokens.Palette.Text.secondary)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private struct TimelineContent: View {
    @Environment(Editor.self) private var editor
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            RulerView(width: width)
                .frame(width: width, height: rulerHeight)
            ForEach(editor.rows) { row in
                TrackLane(row: row)
                    .frame(width: width, height: row.height)
            }
        }
        .overlay(alignment: .topLeading) { PlayheadView() }
        .frame(width: width, alignment: .topLeading)
        .coordinateSpace(.named("timeline"))
    }
}

private struct RulerView: View {
    @Environment(Editor.self) private var editor
    let width: CGFloat

    var body: some View {
        let pps = editor.pps
        let inPoint = editor.project.inPoint, outPoint = editor.project.outPoint
        let duration = editor.project.duration
        Canvas { ctx, size in
            if inPoint != nil || outPoint != nil {
                let a = (inPoint ?? 0) * pps, b = (outPoint ?? duration) * pps
                ctx.fill(Path(CGRect(x: a, y: 0, width: max(b - a, 1), height: size.height)), with: .color(Tokens.Palette.primarySubtle))
                for x in [inPoint, outPoint].compactMap({ $0 }).map({ $0 * pps }) {
                    ctx.fill(Path(CGRect(x: x - 1, y: 0, width: 2, height: size.height)), with: .color(Tokens.Palette.primary))
                }
            }
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
                ctx.stroke(path, with: .color(Tokens.Palette.Text.tertiary), lineWidth: 1)
                if isMajor {
                    let label = major < 1
                        ? String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
                        : String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
                    ctx.draw(Text(label).font(.caption).foregroundColor(Tokens.Palette.Text.secondary), at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
            }
        }
        .background(Tokens.Palette.Background.card)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            editor.scrub(to: value.location.x / pps)
        })
        .help("In and out points: I and O")
    }
}

/// The playhead: a handle in the ruler and a line through every track. The handle and the line can be
/// grabbed anywhere, over clips too; where the line sits on a cut, it wins over the clips' trim handles.
private struct PlayheadView: View {
    @Environment(Editor.self) private var editor
    @ViewState private var hovering = false
    @ViewState private var dragging = false

    var body: some View {
        // At 0:00 the line and the handle would be half outside the timeline, so they stay just inside it.
        let x = max(editor.currentTime * editor.pps, Tokens.Focus.width / 2)
        let handleX = max(x - PlayheadHandle.width / 2, 0)
        let lineWidth = hovering || dragging ? Tokens.Focus.width + 1 : Tokens.Focus.width
        ZStack(alignment: .topLeading) {
            // A rim in the background colour keeps the line clear over clips of any colour.
            Rectangle().fill(Tokens.Palette.Background.app)
                .frame(width: lineWidth + 2)
                .offset(x: x - lineWidth / 2 - 1)
            Rectangle().fill(Tokens.Palette.primary)
                .frame(width: lineWidth)
                .offset(x: x - lineWidth / 2)
            PlayheadHandle(tip: x - handleX)
                .fill(Tokens.Palette.primary)
                .overlay { PlayheadHandle(tip: x - handleX).stroke(Tokens.Palette.Background.app, lineWidth: 1) }
                .frame(width: PlayheadHandle.width, height: rulerHeight - Tokens.Spacing.xs)
                .offset(x: handleX, y: Tokens.Spacing.xs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .overlay {
            Color.clear
                .contentShape(PlayheadGrabArea(line: x, handle: handleX))
                .onHover { inside in
                    hovering = inside
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline"))
                    .onChanged { value in
                        dragging = true
                        editor.scrub(to: value.location.x / editor.pps)
                    }
                    .onEnded { _ in dragging = false })
                .help("Drag to move the playhead")
        }
    }
}

/// The playhead's handle in the ruler: a tab that points down at the line. `tip` is where the line is,
/// measured from the handle's left edge; it is off centre only at the very start of the timeline.
private struct PlayheadHandle: Shape {
    static let width = Tokens.Spacing.md + Tokens.Focus.width
    var tip: CGFloat

    func path(in rect: CGRect) -> Path {
        let shoulder = rect.height * 0.55
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: shoulder))
        path.addLine(to: CGPoint(x: min(max(tip, rect.minX), rect.maxX), y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: shoulder))
        path.closeSubpath()
        return path
    }
}

/// Where the playhead takes the mouse: its handle, and a strip along the line through the tracks.
private struct PlayheadGrabArea: Shape {
    var line: CGFloat
    var handle: CGFloat

    func path(in rect: CGRect) -> Path {
        let strip = Tokens.Spacing.sm
        var path = Path()
        path.addRect(CGRect(x: handle, y: rect.minY, width: PlayheadHandle.width, height: rulerHeight))
        path.addRect(CGRect(x: line - strip / 2, y: rect.minY, width: strip, height: rect.height))
        return path
    }
}

private struct TrackLane: View {
    @Environment(Editor.self) private var editor
    let row: TrackRow
    @ViewState private var targeted = false

    var body: some View {
        let flags = editor.project.flags(row.group, row.index)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(targeted ? Tokens.Palette.primarySubtle : Tokens.Palette.Background.muted)
                .overlay(alignment: .bottom) { Rectangle().fill(Tokens.Palette.Border.subtle).frame(height: 1) }
                .onTapGesture(coordinateSpace: .local) { location in
                    editor.selection = nil
                    if editor.isPlaying { editor.pause() }
                    editor.seek(location.x / editor.pps)
                }
            ForEach(editor.clips(in: row)) { clip in
                ClipView(clip: clip, row: row)
                    .frame(width: max(clip.duration * editor.pps, 3), height: row.height - 6)
                    .offset(x: clip.start * editor.pps, y: 3)
                    .opacity(flags.hidden || (flags.muted && row.group == .audio) ? 0.45 : 1)
                    .allowsHitTesting(!flags.locked)
            }
            if flags.locked {
                LockedPattern().allowsHitTesting(false)
            }
        }
        .dropDestination(for: TimelineDrop.self) { items, location in
            guard !flags.locked else { return false }
            let time = location.x / editor.pps
            let files = items.compactMap { if case .file(let url) = $0 { url } else { nil } }
            let ids = items.compactMap { if case .media(let id) = $0 { id } else { nil } }
            if !files.isEmpty { Task { await editor.dropFiles(files, at: time, row: row) } }
            return editor.dropMedia(ids, at: time, row: row) || !files.isEmpty
        } isTargeted: { targeted = $0 && !flags.locked }
    }
}

/// What a track takes: a tile from the media bin (its id as text) or files from Finder.
private enum TimelineDrop: Transferable {
    case media(String)
    case file(URL)

    static var transferRepresentation: some TransferRepresentation {
        // Files first, in case Finder also offers a file's path as text.
        ProxyRepresentation(importing: { (url: URL) in TimelineDrop.file(url) })
        ProxyRepresentation(importing: { (id: String) in TimelineDrop.media(id) })
    }
}

/// The only help a first run gets, above the timeline: where media goes, the two moves that matter and
/// that export is the last step. It stays until it's closed or the first export is done. No tour.
struct FirstRunHint: View {
    static let dismissedKey = "firstRunHintDismissed"
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "lightbulb")
            Text("Drag video, photos or music onto the timeline. Split with S, add a title with G, then export with ⌘E.")
                .lineLimit(2)
            Spacer(minLength: Tokens.Spacing.sm)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Hide this tip")
        }
        .ijFont(.sm)
        .foregroundStyle(Tokens.Palette.Text.primary)
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, Tokens.Spacing.sm)
        .background(Tokens.Palette.Background.card)
    }
}

/// Diagonal stripes over a locked track.
private struct LockedPattern: View {
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 10
            }
            ctx.stroke(path, with: .color(Tokens.Palette.Border.subtle), lineWidth: 2)
        }
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
            RoundedRectangle(cornerRadius: Tokens.Radius.sm).fill(selected ? Tokens.Palette.primarySubtle : Tokens.clipFill)
            // The thumbnail strip can be wider than the clip; pin it left so the label stays put.
            content
                .frame(width: max(width, 3), height: row.height - 6, alignment: .bottomLeading)
                .clipped()
            // The name stays in view while a long clip is scrolled past.
            label.offset(x: max(0, min(editor.viewport.lowerBound - clip.start * editor.pps, width - 160)))
        }
        .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .overlay(alignment: .leading) { transitionMarker(clip.transitionIn, leading: true) }
        .overlay(alignment: .trailing) { transitionMarker(clip.transitionOut, leading: false) }
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.sm)
            .strokeBorder(borderColor(selected: selected), lineWidth: selected ? Tokens.Focus.width : 1))
        .overlay(alignment: .leading) { if width > 24 { handle(.trimStart, selected: selected) } }
        .overlay(alignment: .trailing) { if width > 24 { handle(.trimEnd, selected: selected) } }
        .contentShape(Rectangle())
        .onTapGesture { editor.selection = clip.id }
        .gesture(drag(.move))
        .contextMenu {
            if isMissing, let media {
                Button("Find \(media.name)…") { editor.locateMedia(media) }
                Divider()
            }
            Button("Split at Playhead  (S)") { editor.selection = clip.id; editor.splitAtPlayhead() }
            Button("Duplicate  (D)") { editor.selection = clip.id; editor.duplicateSelection() }
            Button("Copy  (⌘C)") { editor.selection = clip.id; editor.copySelection() }
            Button("Cut  (⌘X)") { editor.selection = clip.id; editor.cutSelection() }
            if clip.kind != .audio {
                Button("Add Transition  (⌘D)") { editor.selection = clip.id; editor.applyDefaultTransition() }
            }
            if clip.kind == .video, !clip.audioDetached, media?.hasAudio == true {
                Button("Separate Audio  (E)") { editor.selection = clip.id; editor.separateAudio() }
            }
            Divider()
            Button("Delete", role: .destructive) { editor.selection = clip.id; editor.deleteSelection() }
        }
        .help(name)
    }

    private var media: MediaItem? { editor.project.media(clip.mediaID) }

    private var name: String {
        if clip.kind == .title { return clip.title?.text ?? String(localized: "Title") }
        return media?.name ?? String(localized: "Missing file")
    }

    private var isMissing: Bool {
        clip.kind != .title && media.map({ MediaAccess.canRead($0.url) }) != true
    }

    private func borderColor(selected: Bool) -> Color {
        if selected { return Tokens.Palette.primary }
        return isMissing ? Tokens.Palette.State.error : Tokens.Palette.Border.default
    }

    /// The part of the clip that is on screen, in points from the clip's left edge, with a little to spare.
    private var visibleSpan: (start: CGFloat, end: CGFloat) {
        let left = clip.start * editor.pps
        let width = clip.duration * editor.pps
        let start = max(0, editor.viewport.lowerBound - left - 300)
        let end = min(width, editor.viewport.upperBound - left + 300)
        return (start, max(start, end))
    }

    /// Frames and waveform are drawn only where the clip is on screen, so an hour-long clip costs
    /// no more than a short one.
    @ViewBuilder private var content: some View {
        let height = row.height - 6
        let span = visibleSpan
        // Seconds of source per point, for the waveform.
        let sourcePerPoint = clip.speed / editor.pps
        switch clip.kind {
        case .video, .image:
            if span.end > span.start {
                ZStack(alignment: .bottomLeading) {
                    if let tile = editor.cache.tile(for: clip.mediaID, height: height) {
                        // Start on a whole tile so the frames don't slide while scrolling.
                        let first = (span.start / tile.size.width).rounded(.down) * tile.size.width
                        Rectangle()
                            .fill(ImagePaint(image: Image(nsImage: tile)))
                            .frame(width: span.end - first, height: height)
                            .offset(x: first)
                            .opacity(0.75)
                    }
                    if clip.kind == .video, !clip.audioDetached, let peaks = editor.cache.waveforms[clip.mediaID ?? UUID()] {
                        WaveformView(peaks: peaks, sourceIn: clip.sourceIn + span.start * sourcePerPoint,
                                     duration: (span.end - span.start) * sourcePerPoint, volume: clip.volume)
                            .frame(width: span.end - span.start, height: height * 0.35)
                            .background(Tokens.Palette.Background.app.opacity(0.6))
                            .offset(x: span.start)
                    }
                }
            }
        case .audio:
            if span.end > span.start, let peaks = editor.cache.waveforms[clip.mediaID ?? UUID()] {
                WaveformView(peaks: peaks, sourceIn: clip.sourceIn + span.start * sourcePerPoint,
                             duration: (span.end - span.start) * sourcePerPoint, volume: clip.volume)
                    // `body` aligns `content` to the bottom, so this already fills the area under the label.
                    .frame(width: span.end - span.start, height: height - Tokens.Spacing.lg)
                    .offset(x: span.start)
            }
        case .title:
            EmptyView()
        }
    }

    private var label: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: icon).font(.caption2)
            Text(name).lineLimit(1)
            if clip.hasMediaTiming, abs(clip.speed - 1) > 0.001 {
                Text("\(Int((clip.speed * 100).rounded())) %")
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, Tokens.Spacing.xs)
                    .background(Tokens.Palette.Background.muted, in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            }
            if clip.audioDetached { Image(systemName: "speaker.slash").font(.caption2) }
        }
        .ijFont(.xs, weight: .semibold)
        .foregroundStyle(isMissing ? Tokens.Palette.State.error : Tokens.Palette.Text.primary)
        .padding(.horizontal, Tokens.Spacing.xs)
        .background(Tokens.Palette.Background.app.opacity(0.75), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
        .padding(Tokens.Spacing.xs / 2)
    }

    private var icon: String {
        switch clip.kind {
        case .video: "film"
        case .image: "photo"
        case .audio: "music.note"
        case .title: "textformat"
        }
    }

    @ViewBuilder private func transitionMarker(_ transition: Transition?, leading: Bool) -> some View {
        if let transition, clip.kind != .title {
            let width = min(transition.duration, clip.duration / 2) * editor.pps
            ZStack {
                Tokens.Palette.primarySubtle
                Image(systemName: "rectangle.righthalf.inset.filled.arrow.right")
                    .font(.caption2)
                    .foregroundStyle(Tokens.Palette.primary)
            }
            .frame(width: max(width, 6))
            .overlay(alignment: leading ? .trailing : .leading) { Rectangle().fill(Tokens.Palette.primary).frame(width: 1) }
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
            .onTapGesture {
                editor.selection = clip.id
                editor.inspectorTab = .transitions
            }
            .help(transition.kind.label)
        }
    }

    private func handle(_ mode: Mode, selected: Bool) -> some View {
        Rectangle()
            .fill(selected || hoveringHandle ? Tokens.Palette.primary.opacity(0.5) : Color.clear)
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
                editor.floating = mode == .move && editor.project.isMagnetic(updated) ? origin.id : nil
                editor.interact { project in
                    if let i = project.clips.firstIndex(where: { $0.id == origin.id }) { project.clips[i] = updated }
                }
            }
            .onEnded { _ in
                guard let origin else { return }
                if mode == .move, let current = editor.project.clips.first(where: { $0.id == origin.id }),
                   !editor.project.isMagnetic(current) {
                    // Off the main track clips never overlap: slide to the next free spot.
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
        let magnetic = editor.project.isMagnetic(o)
        let neighbours = editor.project.clips.filter { $0.group == o.group && $0.track == o.track && $0.id != o.id }
        let speed = max(o.speed, 0.05)

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
            let track = min(max(o.track + steps * row.downwardStep, 0), count - 1)
            if !editor.isLocked(o.group, track) { c.track = track }

        case .trimStart where magnetic:
            // Ripple trim: the clip's position stays, its content and length change, and the rest follows.
            var delta = dt
            if o.hasMediaTiming { delta = max(delta, -o.sourceIn / speed) }
            delta = min(delta, o.duration - minimum)
            c.duration = o.duration - delta
            if o.hasMediaTiming { c.sourceIn = o.sourceIn + delta * speed }

        case .trimStart:
            var start = o.start + dt
            if let s = editor.snap(start, excluding: o.id) { start = s }
            var lower = neighbours.filter { $0.end <= o.start + 1e-6 }.map(\.end).max() ?? 0
            if o.hasMediaTiming { lower = max(lower, o.start - o.sourceIn / speed) }
            start = min(max(start, lower), o.end - minimum)
            c.start = start
            c.duration = o.end - start
            if o.hasMediaTiming { c.sourceIn = o.sourceIn + (start - o.start) * speed }

        case .trimEnd:
            var end = o.end + dt
            if let s = editor.snap(end, excluding: o.id) { end = s }
            var upper = Double.infinity
            if !magnetic { upper = neighbours.filter { $0.start >= o.end - 1e-6 }.map(\.start).min() ?? .infinity }
            if o.hasMediaTiming, let media { upper = min(upper, o.start + (media.duration - o.sourceIn) / speed) }
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
            ctx.fill(path, with: .color(Tokens.Palette.Text.secondary))
        }
        .allowsHitTesting(false)
    }
}
