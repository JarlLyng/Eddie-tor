import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The inspector's tools, numbered like Rush's ⌘1–⌘6 (⌘3 is colour, which Eddie doesn't have yet).
enum InspectorTab: Int, CaseIterable, Identifiable {
    case text = 1, transitions = 2, speed = 4, audio = 5, position = 6

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .text: String(localized: "Text")
        case .transitions: String(localized: "Transitions")
        case .speed: String(localized: "Speed")
        case .audio: String(localized: "Audio")
        case .position: String(localized: "Position")
        }
    }

    var icon: String {
        switch self {
        case .text: "textformat"
        case .transitions: "rectangle.righthalf.inset.filled.arrow.right"
        case .speed: "gauge.with.dots.needle.67percent"
        case .audio: "speaker.wave.2"
        case .position: "crop.rotate"
        }
    }

    static func available(for clip: Clip, hasAudio: Bool) -> [InspectorTab] {
        switch clip.kind {
        case .title: [.text, .transitions]
        case .image: [.transitions, .position]
        case .audio: [.speed, .audio]
        case .video: hasAudio && !clip.audioDetached ? [.transitions, .speed, .audio, .position] : [.transitions, .speed, .position]
        }
    }
}

@MainActor @Observable
final class Editor {
    private(set) var project = Project()
    var selection: UUID?
    var currentTime: Double = 0
    private(set) var isPlaying = false
    /// Timeline zoom in points per second.
    var pps: Double = 60
    private(set) var fileURL: URL?
    /// The name offered when an unsaved project is saved or exported.
    private(set) var suggestedName: String?
    private(set) var isDirty = false
    var showExport = false
    var errorMessage: String?

    var inspectorTab: InspectorTab = .position
    var snapping = true
    var loopPlayback = false
    var showMedia = true
    var monitorMaximized = false
    /// The part of the timeline in view, in points. Clips draw their frames and waveform only here.
    var viewport: ClosedRange<Double> = 0...2000
    /// Bumped to ask the timeline to zoom so the whole sequence fits.
    var zoomToFitRequest = 0
    /// The main-track clip being dragged; it keeps the mouse position while the others make room.
    var floating: UUID?

    let cache = MediaCache()
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var shuttleRate: Double = 0
    @ObservationIgnored private var clipboard: [Clip] = []
    @ObservationIgnored private var undoStack: [Project] = []
    @ObservationIgnored private var redoStack: [Project] = []
    @ObservationIgnored private var lastCoalesce: (key: String, date: Date)?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var installedStructure: [String]?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var interacting = false

    /// Declared in App/Edwell/Info.plist with the extensions below; `.eddie` is what projects were saved as
    /// before the app became Edwell, so those files open as the same type.
    static let projectType = UTType(exportedAs: "com.iamjarl.edwell.project", conformingTo: .json)
    static let projectExtensions = ["edwell", "eddie"]
    static let defaultTransition = Transition(kind: .crossDissolve, duration: 0.5)

    /// `persist: false` skips the autosave file and never stops to ask the user anything (used by the
    /// self test and snapshot runs).
    @ObservationIgnored private let persist: Bool
    @ObservationIgnored private let access = MediaAccess()
    /// A bookmark to the project file, so after a relaunch the sandboxed app can still save to it.
    @ObservationIgnored private var fileBookmark: Data?
    @ObservationIgnored private var fileScope: URL?

    init(persist: Bool = true) {
        self.persist = persist
        player.actionAtItemEnd = .pause
        player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTick(time) }
        }
        if persist { restoreAutosave() }
        scheduleRebuild(delay: 0)
    }

    // MARK: - Derived

    var rows: [TrackRow] {
        (0..<project.titleTracks).reversed().map { TrackRow(group: .title, index: $0) }
            + (0..<project.visualTracks).reversed().map { TrackRow(group: .visual, index: $0) }
            + (0..<project.audioTracks).map { TrackRow(group: .audio, index: $0) }
    }

    var selectedClip: Clip? {
        guard let selection else { return nil }
        return project.clips.first { $0.id == selection }
    }

    var windowTitle: String {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Untitled")
        return isDirty ? String(localized: "\(name) (edited)") : name
    }

    /// Sorted by start so a clip that overlaps its neighbour in a transition is drawn on top.
    func clips(in row: TrackRow) -> [Clip] {
        project.clips.filter { $0.group == row.group && $0.track == row.index }.sorted { $0.start < $1.start }
    }

    func isLocked(_ group: TrackGroup, _ index: Int) -> Bool { project.flags(group, index).locked }

    func isLocked(_ clip: Clip) -> Bool { isLocked(clip.group, clip.track) }

    /// The longest the clip can be on the timeline: limited by its source and, off the main track, by the next clip.
    func maxDuration(_ clip: Clip) -> Double {
        var limit = Double.infinity
        if clip.hasMediaTiming, let media = project.media(clip.mediaID) {
            limit = (media.duration - clip.sourceIn) / max(clip.speed, 0.05)
        }
        if !project.isMagnetic(clip) {
            let next = project.clips
                .filter { $0.group == clip.group && $0.track == clip.track && $0.id != clip.id && $0.start >= clip.end - 1e-6 }
                .map(\.start).min()
            if let next { limit = min(limit, next - clip.start) }
        }
        return limit
    }

    // MARK: - Editing with undo

    /// Applies a change as one undo step. Changes with the same `coalesce` key in quick succession
    /// (typing, dragging a slider) are merged into a single step.
    func edit(coalesce key: String? = nil, rebuild: Bool = true, _ change: (inout Project) -> Void) {
        let now = Date()
        if let key, let last = lastCoalesce, last.key == key, now.timeIntervalSince(last.date) < 1.5 {
            // Same gesture: keep the existing undo point.
        } else {
            pushUndo()
        }
        lastCoalesce = key.map { ($0, now) }
        change(&project)
        Self.packMain(&project)
        didChange(rebuild: rebuild)
    }

    func updateClip(_ id: UUID, coalesce key: String? = nil, _ change: (inout Clip) -> Void) {
        guard project.clips.contains(where: { $0.id == id }) else { return }
        edit(coalesce: key.map { "\(id)-\($0)" }) { project in
            if let i = project.clips.firstIndex(where: { $0.id == id }) { change(&project.clips[i]) }
        }
    }

    func binding<T>(_ id: UUID, _ keyPath: WritableKeyPath<Clip, T>, fallback: T) -> Binding<T> {
        Binding(
            get: { self.project.clips.first { $0.id == id }?[keyPath: keyPath] ?? fallback },
            set: { value in self.updateClip(id, coalesce: "\(keyPath)") { $0[keyPath: keyPath] = value } }
        )
    }

    func projectBinding<T>(_ keyPath: WritableKeyPath<Project, T>) -> Binding<T> {
        Binding(
            get: { self.project[keyPath: keyPath] },
            set: { value in self.edit(coalesce: "\(keyPath)") { $0[keyPath: keyPath] = value } }
        )
    }

    /// Live changes during a drag: one undo step for the whole gesture, preview rebuilt when it ends
    /// (or along the way with `livePreview`, for changes that don't move clips in time).
    func beginInteraction() {
        guard !interacting else { return }
        interacting = true
        pushUndo()
        lastCoalesce = nil
    }

    func interact(livePreview: Bool = false, _ change: (inout Project) -> Void) {
        change(&project)
        Self.packMain(&project, floating: floating)
        if livePreview { scheduleRebuild(delay: 0.03) }
    }

    func endInteraction() {
        guard interacting else { return }
        interacting = false
        Self.packMain(&project, floating: floating, commit: true)
        floating = nil
        if undoStack.last == project {
            undoStack.removeLast()
        } else {
            didChange()
        }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        lastCoalesce = nil
        didChange()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        lastCoalesce = nil
        didChange()
    }

    private func pushUndo() {
        undoStack.append(project)
        if undoStack.count > 300 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func didChange(rebuild: Bool = true) {
        if let clip = selectedClip, isLocked(clip) { selection = nil }
        if let selection, !project.clips.contains(where: { $0.id == selection }) { self.selection = nil }
        isDirty = true
        if rebuild { scheduleRebuild() }
        scheduleAutosave()
    }

    // MARK: - Magnetic main track

    /// Lays the clips on V1 out back to back from 0, overlapping where a clip starts with a transition.
    /// A clip being dragged (`floating`) keeps its position and gets the slot nearest its centre;
    /// with `commit` it is moved into that slot.
    nonisolated static func packMain(_ project: inout Project, floating: UUID? = nil, commit: Bool = false) {
        guard project.magneticMain else { return }
        let main = project.clips.indices.filter { project.isMagnetic(project.clips[$0]) }
        var order = main.filter { project.clips[$0].id != floating }.sorted { project.clips[$0].start < project.clips[$1].start }

        if let floating, let f = main.first(where: { project.clips[$0].id == floating }) {
            let centre = project.clips[f].start + project.clips[f].duration / 2
            var cursor = 0.0
            var slot = order.count
            for (n, i) in order.enumerated() {
                if cursor + project.clips[i].duration / 2 > centre { slot = n; break }
                cursor += project.clips[i].duration
            }
            order.insert(f, at: slot)
        }

        var cursor = 0.0
        for (n, i) in order.enumerated() {
            var overlap = 0.0
            if n > 0, let transition = project.clips[i].transitionIn {
                let previous = project.clips[order[n - 1]]
                overlap = min(transition.duration, previous.duration / 2, project.clips[i].duration / 2)
            }
            let start = max(0, cursor - overlap)
            if project.clips[i].id != floating || commit { project.clips[i].start = start }
            cursor = start + project.clips[i].duration
        }
    }

    /// Where to put a clip dropped at `time` on the main track so it lands before or after the clip under it.
    func mainInsertionStart(at time: Double, excluding: UUID? = nil) -> Double {
        let main = project.clips.filter { project.isMagnetic($0) && $0.id != excluding }
        guard let hit = main.first(where: { $0.start <= time && time < $0.end }) else { return time }
        return time < hit.start + hit.duration / 2 ? hit.start - 0.0001 : hit.start + 0.0001
    }

    // MARK: - Timeline operations

    /// The first start time at or after `desired` where a clip of `duration` fits on the track.
    func freeStart(_ group: TrackGroup, track: Int, desired: Double, duration: Double, excluding: UUID? = nil) -> Double {
        let others = project.clips
            .filter { $0.group == group && $0.track == track && $0.id != excluding }
            .sorted { $0.start < $1.start }
        var start = max(0, desired)
        var moved = true
        while moved {
            moved = false
            for other in others where start < other.end - 1e-6 && start + duration > other.start + 1e-6 {
                start = other.end
                moved = true
            }
        }
        return start
    }

    func trackEnd(_ group: TrackGroup, track: Int) -> Double {
        project.clips.filter { $0.group == group && $0.track == track }.map(\.end).max() ?? 0
    }

    /// Where a new clip goes: inserted on the main track, or the next free spot on other tracks.
    private func placement(for clip: Clip, at time: Double?) -> Double {
        if project.isMagnetic(clip) {
            return time.map { mainInsertionStart(at: $0) } ?? trackEnd(.visual, track: 0)
        }
        return freeStart(clip.group, track: clip.track, desired: time ?? trackEnd(clip.group, track: clip.track), duration: clip.duration)
    }

    /// Adds media to the timeline. Without a time it is appended to the end of the first track, as in Rush.
    func add(_ media: MediaItem, at time: Double? = nil, track: Int = 0) {
        let kind: ClipKind = switch media.kind {
        case .video: .video
        case .image: .image
        case .audio: .audio
        }
        var clip = Clip(kind: kind, track: track, start: 0, duration: media.kind == .image ? 4 : media.duration, mediaID: media.id)
        guard !isLocked(clip) else {
            errorMessage = String(localized: "Track \(TrackRow(group: clip.group, index: track).label) is locked.")
            return
        }
        clip.start = placement(for: clip, at: time)
        edit { $0.clips.append(clip) }
        selection = clip.id
    }

    func dropMedia(_ ids: [String], at time: Double, row: TrackRow) -> Bool {
        var placed = false
        var cursor = max(0, time)
        for idString in ids {
            guard let id = UUID(uuidString: idString), let media = project.media(id) else { continue }
            let group: TrackGroup = media.kind == .audio ? .audio : .visual
            let track = group == row.group ? row.index : 0
            add(media, at: cursor, track: track)
            cursor = selectedClip?.end ?? cursor
            placed = true
        }
        return placed
    }

    func addTitle() {
        let duration = 3.0
        var best: (track: Int, start: Double)?
        for track in 0..<project.titleTracks where !isLocked(.title, track) {
            let start = freeStart(.title, track: track, desired: currentTime, duration: duration)
            if best == nil || start < best!.start - 0.01 { best = (track, start) }
        }
        guard let best else { errorMessage = String(localized: "All title tracks are locked."); return }
        let clip = Clip(kind: .title, track: best.track, start: best.start, duration: duration,
                        fadeIn: 0.25, fadeOut: 0.25, title: TitleStyle())
        edit { $0.clips.append(clip) }
        selection = clip.id
        inspectorTab = .text
    }

    /// Splits the selected clip at the playhead, or every clip under the playhead if none is selected.
    func splitAtPlayhead() {
        let t = currentTime
        let under = project.clips.filter { $0.start + 0.01 < t && t < $0.end - 0.01 && !isLocked($0) }
        let targets = under.filter { $0.id == selection }.isEmpty ? under : under.filter { $0.id == selection }
        guard !targets.isEmpty else { NSSound.beep(); return }
        var newSelection: UUID?
        edit { project in
            for target in targets {
                guard let i = project.clips.firstIndex(where: { $0.id == target.id }) else { continue }
                var right = target
                right.id = UUID()
                right.start = t
                right.duration = target.end - t
                right.fadeIn = 0
                right.transitionIn = nil
                if target.hasMediaTiming { right.sourceIn = target.sourceIn + (t - target.start) * target.speed }
                project.clips[i].duration = t - target.start
                project.clips[i].fadeOut = 0
                project.clips[i].transitionOut = nil
                project.clips.append(right)
                if target.id == selection { newSelection = right.id }
            }
        }
        if let newSelection { selection = newSelection }
    }

    /// Q and W in Rush: trims the start or end of the clip under the playhead to the playhead.
    /// On the main track the rest of the sequence follows.
    func trimToPlayhead(start trimStart: Bool) {
        let t = currentTime
        let under = project.clips.filter { $0.start + 0.01 < t && t < $0.end - 0.01 && !isLocked($0) }
        guard let target = under.first(where: { $0.id == selection }) ?? under.first(where: { project.isMagnetic($0) }) ?? under.first else {
            NSSound.beep(); return
        }
        updateClip(target.id) { clip in
            if trimStart {
                let delta = t - clip.start
                clip.start = t
                clip.duration -= delta
                if clip.hasMediaTiming { clip.sourceIn += delta * clip.speed }
            } else {
                clip.duration = t - clip.start
            }
        }
        selection = target.id
        if trimStart, let clip = selectedClip { seek(clip.start) }
    }

    func deleteSelection() {
        guard let clip = selectedClip, !isLocked(clip) else { return }
        edit { $0.clips.removeAll { $0.id == clip.id } }
    }

    func duplicateSelection() {
        guard var clip = selectedClip, !isLocked(clip) else { return }
        let original = clip
        clip.id = UUID()
        clip.start = project.isMagnetic(clip)
            ? original.start + 0.0001
            : freeStart(clip.group, track: clip.track, desired: original.end, duration: clip.duration)
        edit { $0.clips.append(clip) }
        selection = clip.id
    }

    func copySelection() {
        guard let clip = selectedClip else { return }
        clipboard = [clip]
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    func paste() {
        guard var clip = clipboard.first else { NSSound.beep(); return }
        clip.id = UUID()
        if clip.track >= project.trackCount(clip.group) || isLocked(clip) { clip.track = 0 }
        guard !isLocked(clip) else { NSSound.beep(); return }
        clip.start = placement(for: clip, at: currentTime)
        edit { $0.clips.append(clip) }
        selection = clip.id
    }

    /// E in Rush: moves the sound of a video clip to its own clip on a free audio track.
    func separateAudio() {
        guard let video = selectedClip, video.kind == .video, !video.audioDetached, !isLocked(video),
              project.media(video.mediaID)?.hasAudio == true else { NSSound.beep(); return }
        let free = (0..<project.audioTracks).first { track in
            !isLocked(.audio, track) && freeStart(.audio, track: track, desired: video.start, duration: video.duration) == video.start
        }
        var audio = Clip(kind: .audio, track: free ?? project.audioTracks, start: video.start, duration: video.duration, mediaID: video.mediaID)
        audio.sourceIn = video.sourceIn
        audio.volume = video.volume
        audio.fadeIn = video.fadeIn
        audio.fadeOut = video.fadeOut
        audio.speed = video.speed
        audio.maintainPitch = video.maintainPitch
        edit { project in
            if free == nil { project.audioTracks += 1 }
            project.clips.append(audio)
            if let i = project.clips.firstIndex(where: { $0.id == video.id }) { project.clips[i].audioDetached = true }
        }
    }

    /// ⌘D in Rush: puts the default transition at the start of the selected clip,
    /// or at the cut nearest the playhead on the main track.
    func applyDefaultTransition() {
        var target = selectedClip
        if target == nil || target?.kind == .audio {
            target = project.clips.filter { project.isMagnetic($0) }.min { abs($0.start - currentTime) < abs($1.start - currentTime) }
        }
        guard let target, target.kind != .audio, !isLocked(target) else { NSSound.beep(); return }
        updateClip(target.id) { $0.transitionIn = $0.transitionIn ?? Self.defaultTransition }
        selection = target.id
        inspectorTab = .transitions
    }

    /// Changes speed while keeping the same part of the source, so the clip gets shorter or longer.
    func setSpeed(_ id: UUID, _ speed: Double) {
        guard let clip = project.clips.first(where: { $0.id == id }) else { return }
        let speed = min(max(speed, 0.1), 10)
        var updated = clip
        updated.speed = speed
        updated.duration = clip.sourceDuration / speed
        updated.duration = min(updated.duration, maxDuration(updated))
        updateClip(id, coalesce: "speed") { $0 = updated }
    }

    func setDuration(_ id: UUID, _ duration: Double) {
        guard let clip = project.clips.first(where: { $0.id == id }) else { return }
        let value = min(max(duration, 1 / Double(project.fps)), maxDuration(clip))
        updateClip(id) { $0.duration = value }
    }

    func addTrack(_ group: TrackGroup) {
        edit { project in
            switch group {
            case .title: project.titleTracks = min(project.titleTracks + 1, 6)
            case .visual: project.visualTracks = min(project.visualTracks + 1, 8)
            case .audio: project.audioTracks = min(project.audioTracks + 1, 8)
            }
        }
    }

    func toggleFlag(_ row: TrackRow, _ flag: WritableKeyPath<TrackFlags, Bool>) {
        edit { project in
            var flags = project.flags(row.group, row.index)
            flags[keyPath: flag].toggle()
            project.trackFlags[row.id] = flags
        }
    }

    func removeMedia(_ id: UUID) {
        edit { project in
            project.media.removeAll { $0.id == id }
            project.clips.removeAll { $0.mediaID == id }
        }
    }

    /// Snaps a time to the playhead or a clip edge if it is within a few points.
    func snap(_ time: Double, excluding: UUID?) -> Double? {
        guard snapping else { return nil }
        let threshold = 8 / pps
        var candidates = [0, currentTime]
        for clip in project.clips where clip.id != excluding {
            candidates.append(clip.start)
            candidates.append(clip.end)
        }
        let best = candidates.min { abs($0 - time) < abs($1 - time) }
        if let best, abs(best - time) <= threshold { return best }
        return nil
    }

    // MARK: - In and out points

    func markIn() {
        let t = currentTime
        edit(rebuild: false) { project in
            project.inPoint = t
            if let out = project.outPoint, out <= t { project.outPoint = nil }
        }
    }

    func markOut() {
        let t = currentTime
        edit(rebuild: false) { project in
            project.outPoint = t
            if let i = project.inPoint, i >= t { project.inPoint = nil }
        }
    }

    func clearInOut(in clearIn: Bool, out clearOut: Bool) {
        edit(rebuild: false) { project in
            if clearIn { project.inPoint = nil }
            if clearOut { project.outPoint = nil }
        }
    }

    // MARK: - Import

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.message = String(localized: "Choose video, audio or images")
        guard panel.runModal() == .OK else { return }
        importMedia(panel.urls)
    }

    func importMedia(_ urls: [URL], thenAddToTimeline: Bool = false) {
        Task {
            let added = await load(urls)
            if thenAddToTimeline { added.forEach { add($0) } }
        }
    }

    /// Files dragged from Finder straight onto a track: imported, then placed where they were dropped,
    /// like tiles from the media bin. The quickest way in on a first run.
    func dropFiles(_ urls: [URL], at time: Double, row: TrackRow) async {
        let added = await load(urls)
        _ = dropMedia(added.map(\.id.uuidString), at: time, row: row)
    }

    /// Adds the files to the project's media, each once, and returns them in order, including any that
    /// were there already.
    @discardableResult
    func load(_ urls: [URL]) async -> [MediaItem] {
        var added: [MediaItem] = []
        for url in urls {
            if let existing = project.media.first(where: { $0.url == url }) {
                added.append(existing)
            } else if let item = await MediaLoader.load(url) {
                added.append(item)
            }
        }
        let new = added.filter { item in !project.media.contains { $0.id == item.id } }
        if !new.isEmpty { edit { $0.media.append(contentsOf: new) } }
        cache.prepare(new)
        if added.count < urls.count {
            errorMessage = String(localized: "Some files couldn't be opened. Edwell works with video, audio and images.")
        }
        return added
    }

    // MARK: - Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard project.duration > 0 else { return }
        if currentTime >= project.duration - 0.05 { seek(project.inPoint ?? 0) }
        shuttleRate = 1
        player.rate = 1
        isPlaying = true
    }

    func pause() {
        shuttleRate = 0
        player.pause()
        isPlaying = false
        let t = player.currentTime().seconds
        if t.isFinite { currentTime = min(max(t, 0), project.duration) }
    }

    /// J and L: each press doubles the speed in that direction, up to 8×. K stops.
    func shuttle(forward: Bool) {
        guard project.duration > 0 else { return }
        if forward {
            shuttleRate = shuttleRate > 0 ? min(shuttleRate * 2, 8) : 1
            if currentTime >= project.duration - 0.05 { seek(0) }
        } else {
            shuttleRate = shuttleRate < 0 ? max(shuttleRate * 2, -8) : -1
            if !(player.currentItem?.canPlayReverse ?? false) {
                pause()
                step(frames: -project.fps)
                return
            }
        }
        player.rate = Float(shuttleRate)
        isPlaying = true
    }

    func seek(_ time: Double) {
        currentTime = min(max(0, time), max(project.duration, 0))
        player.seek(to: CompositionBuilder.time(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        if isPlaying { pause() }
        seek(currentTime + Double(frames) / Double(project.fps))
    }

    /// ↑ and ↓: jump to the previous or next cut on any track.
    func jumpToEdit(forward: Bool) {
        if isPlaying { pause() }
        let points = Set(project.clips.flatMap { [$0.start, $0.end] } + [0, project.duration]).sorted()
        if forward {
            seek(points.first { $0 > currentTime + 0.001 } ?? project.duration)
        } else {
            seek(points.last { $0 < currentTime - 0.001 } ?? 0)
        }
    }

    private func playerTick(_ time: CMTime) {
        guard isPlaying, time.isValid else { return }
        currentTime = time.seconds
        if loopPlayback, shuttleRate > 0 {
            let start = project.inPoint ?? 0
            let end = project.outPoint ?? project.duration
            if end > start, currentTime >= end - 0.5 / Double(project.fps) {
                seek(start)
                player.rate = Float(shuttleRate)
                return
            }
        }
        if (shuttleRate > 0 && currentTime >= project.duration - 0.001) || (shuttleRate < 0 && currentTime <= 0.001) || player.rate == 0 {
            pause()
        }
    }

    private func scheduleRebuild(delay: Double = 0.12) {
        rebuildTask?.cancel()
        let snapshot = project
        rebuildTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            do {
                let result = try await CompositionBuilder.build(snapshot)
                guard !Task.isCancelled else { return }
                self?.install(result)
            } catch {
                NSLog("Edwell: couldn't build the preview: \(error)")
            }
        }
    }

    /// Returns once the preview player has the project as it is now (for the self test).
    func previewReady() async {
        while let task = rebuildTask {
            await task.value
            if task == rebuildTask { return }
        }
    }

    private func install(_ result: BuildResult) {
        if let item = player.currentItem, installedStructure == result.structureKey {
            item.videoComposition = result.videoComposition
            item.audioMix = result.audioMix
        } else {
            let item = AVPlayerItem(asset: result.composition)
            item.videoComposition = result.videoComposition
            item.audioMix = result.audioMix
            item.seekingWaitsForVideoCompositionRendering = true
            player.replaceCurrentItem(with: item)
            installedStructure = result.structureKey
        }
        if isPlaying {
            player.rate = Float(shuttleRate)
        } else {
            // Shows the new frame while paused.
            player.seek(to: CompositionBuilder.time(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
        }
    }

    // MARK: - Files

    func newProject() {
        guard confirmDiscard() else { return }
        pause()
        replaceProject(Project(), url: nil)
    }

    /// Starts a new project from an Ambient Session recording, set up as in Rush. The owner's own weekly
    /// job, so it's kept out of sight: hold ⌥ in the File menu and New Project turns into it.
    func newAmbientSession() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.message = String(localized: "Choose the session recording")
        // The sandbox hides the folder from fileExists; the panel itself falls back when it isn't there.
        panel.directoryURL = AmbientSession.recordingsFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard let recording = await MediaLoader.load(url), recording.kind == .video else {
                errorMessage = String(localized: "\(url.lastPathComponent) couldn't be opened as a video.")
                return
            }
            startAmbientSession(with: recording)
        }
    }

    func startAmbientSession(with recording: MediaItem) {
        pause()
        replaceProject(AmbientSession.project(for: recording), url: nil)
        suggestedName = AmbientSession.displayName(AmbientSession.number(from: recording.url))
        isDirty = true
        selection = project.clips.first { $0.kind == .video }?.id
    }

    func open() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.projectType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            let project = try JSONDecoder().decode(Project.self, from: Data(contentsOf: url))
            pause()
            replaceProject(project, url: url)
            // Typically a project from before bookmarks, or from another Mac: ask for its media once.
            if persist, !unreadableMedia.isEmpty {
                DispatchQueue.main.async { self.askForMissingMedia() }
            }
        } catch {
            errorMessage = String(localized: "The project couldn't be opened: \(error.localizedDescription)")
        }
    }

    // MARK: - Missing media

    /// Media the app can't read now: moved, deleted, on a drive that isn't connected, or, in the sandbox,
    /// never picked on this Mac. Their clips are left out of preview and export until they are found.
    var unreadableMedia: [MediaItem] {
        project.media.filter { !MediaAccess.canRead($0.url) }
    }

    private func askForMissingMedia() {
        let missing = unreadableMedia
        guard !missing.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = missing.count == 1
            ? String(localized: "Edwell can't read \(missing[0].name)")
            : String(localized: "Edwell can't read \(missing.count) of the project's media files")
        alert.informativeText = String(localized: "They have been moved or deleted, are on a drive that isn't connected, or Edwell hasn't been allowed to open them on this Mac. Find them once and the project remembers them when you save.")
        alert.addButton(withTitle: String(localized: "Find…"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { locateMedia() }
    }

    /// Asks where missing media is: the file itself, or a folder that holds several of them.
    func locateMedia(_ only: MediaItem? = nil) {
        let items = only.map { [$0] } ?? unreadableMedia
        guard let first = items.first else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = items.count > 1
        panel.allowedContentTypes = [.audiovisualContent, .image]
        panel.prompt = String(localized: "Find")
        panel.message = items.count == 1
            ? String(localized: "Find \(first.name)")
            : String(localized: "Choose the folder with the project's media. Edwell finds the ones inside it.")
        panel.directoryURL = first.url.deletingLastPathComponent()
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        relink(items, in: picked)
    }

    /// Points the items at the files found in what the user picked, as one undo step. Saving the
    /// project keeps their new bookmarks.
    func relink(_ items: [MediaItem], in picked: URL) {
        let found = MediaAccess.locate(items, in: picked, projectURL: fileURL)
        let left = items.count - found.count
        if left > 0 {
            errorMessage = left == 1 && items.count == 1
                ? String(localized: "\(items[0].name) wasn't found in \(picked.lastPathComponent).")
                : String(localized: "\(left) of \(items.count) media files weren't found in \(picked.lastPathComponent).")
        }
        guard !found.isEmpty else { return }
        found.forEach { AssetCache.forget($0.url) }
        edit { project in
            for item in found {
                if let i = project.media.firstIndex(where: { $0.id == item.id }) { project.media[i] = item }
            }
        }
        cache.prepare(found)
    }

    @discardableResult
    func save() -> Bool {
        guard let fileURL else { return saveAs() }
        return write(to: fileURL)
    }

    @discardableResult
    func saveAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.projectType]
        panel.nameFieldStringValue = suggestedFileName
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    /// What Save As suggests: always `.edwell`, also for a project opened from an old `.eddie` file.
    var suggestedFileName: String {
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? suggestedName ?? String(localized: "My Project")
        return "\(name).\(Self.projectExtensions[0])"
    }

    /// Saves to a file the user picked (or the self test chose). Each media item gets its place relative
    /// to the project, for media that moves with it.
    func write(to url: URL) -> Bool {
        do {
            var saved = project
            for i in saved.media.indices {
                saved.media[i].relativePath = MediaAccess.relativePath(of: saved.media[i].url, from: url.deletingLastPathComponent())
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(saved).write(to: url, options: .atomic)
            if url != fileURL || fileBookmark == nil { fileBookmark = MediaAccess.bookmark(for: url) }
            fileURL = url
            isDirty = false
            UserDefaults.standard.set(url.path, forKey: "lastProjectPath")
            return true
        } catch {
            errorMessage = String(localized: "The project couldn't be saved: \(error.localizedDescription)")
            return false
        }
    }

    private func confirmDiscard() -> Bool {
        guard isDirty, !project.clips.isEmpty || !project.media.isEmpty else { return true }
        let alert = NSAlert()
        let name = fileURL?.lastPathComponent ?? String(localized: "the project")
        alert.messageText = String(localized: "Do you want to save the changes to \(name)?")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func replaceProject(_ new: Project, url: URL?) {
        access.release()
        fileScope?.stopAccessingSecurityScopedResource()
        fileScope = nil
        project = new
        project.media = access.reach(new.media, projectURL: url)
        Self.packMain(&project)
        fileURL = url
        fileBookmark = url.flatMap(MediaAccess.bookmark)
        suggestedName = nil
        isDirty = false
        selection = nil
        undoStack.removeAll()
        redoStack.removeAll()
        currentTime = 0
        installedStructure = nil
        cache.prepare(project.media.filter { MediaAccess.canRead($0.url) })
        scheduleRebuild(delay: 0)
        scheduleAutosave()
    }

    // The working state is autosaved continuously so nothing is lost if the app quits.
    private static var autosaveURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eddie", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("autosave.eddie")
    }

    private func scheduleAutosave() {
        guard persist else { return }
        autosaveTask?.cancel()
        let snapshot = project, url = fileURL, bookmark = fileBookmark, dirty = isDirty
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.autosaveURL, options: .atomic)
            UserDefaults.standard.set(url?.path, forKey: "autosaveFilePath")
            UserDefaults.standard.set(bookmark, forKey: "autosaveFileBookmark")
            UserDefaults.standard.set(dirty, forKey: "autosaveDirty")
        }
    }

    private func restoreAutosave() {
        guard let data = try? Data(contentsOf: Self.autosaveURL),
              let saved = try? JSONDecoder().decode(Project.self, from: data) else { return }
        var url = UserDefaults.standard.string(forKey: "autosaveFilePath").map { URL(fileURLWithPath: $0) }
        fileBookmark = UserDefaults.standard.data(forKey: "autosaveFileBookmark")
        if url != nil, let bookmark = fileBookmark, let found = MediaAccess.resolve(bookmark) {
            url = found.url
            if found.scoped { fileScope = found.url }
            if found.stale { fileBookmark = MediaAccess.bookmark(for: found.url) ?? bookmark }
        }
        project = saved
        project.media = access.reach(saved.media, projectURL: url)
        Self.packMain(&project)
        fileURL = url
        isDirty = UserDefaults.standard.bool(forKey: "autosaveDirty")
        cache.prepare(project.media.filter { MediaAccess.canRead($0.url) })
    }

    // MARK: - Keyboard

    /// Rush's single-key shortcuts. They work anywhere except while typing in a text field;
    /// shortcuts with ⌘ that don't clash with text editing live in the menus instead.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, NSApp.keyWindow?.attachedSheet == nil else { return event }
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            return handleKey(event) ? nil : event
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if flags.contains(.control) { return false }
        if flags.contains(.command) {
            switch event.keyCode {
            case 126: seek(0); return true                          // ⌘↑ sequence start
            case 125: seek(project.duration); return true           // ⌘↓ sequence end
            default: break
            }
            switch (key, flags.contains(.shift)) {
            case ("c", false): copySelection()
            case ("x", false): cutSelection()
            case ("v", false): paste()
            case ("a", true): selection = nil
            default: return false
            }
            return true
        }

        let shift = flags.contains(.shift), option = flags.contains(.option)
        switch event.keyCode {
        case 49: togglePlay()                                       // space
        case 51, 117: deleteSelection()                             // delete
        case 123: step(frames: shift ? -project.fps : -1)           // ←
        case 124: step(frames: shift ? project.fps : 1)             // →
        case 126: jumpToEdit(forward: false)                        // ↑
        case 125: jumpToEdit(forward: true)                         // ↓
        case 115: seek(0)                                           // home
        case 119: seek(project.duration)                            // end
        default:
            switch key {
            case "s": splitAtPlayhead()
            case "d": duplicateSelection()
            case "g": addTitle()
            case "e": separateAudio()
            case "q": trimToPlayhead(start: true)
            case "w": trimToPlayhead(start: false)
            case "j": shuttle(forward: false)
            case "k": pause()
            case "l": shuttle(forward: true)
            case "i":
                if option { clearInOut(in: true, out: false) } else if shift { if let t = project.inPoint { seek(t) } } else { markIn() }
            case "o":
                if option { clearInOut(in: false, out: true) } else if shift { if let t = project.outPoint { seek(t) } } else { markOut() }
            case "x" where option: clearInOut(in: true, out: true)
            case "=", "+": pps = min(pps * 1.4, 600)
            case "-": pps = max(pps / 1.4, 4)
            case "\\": zoomToFitRequest += 1
            case "`": monitorMaximized.toggle()
            case "y": showMedia.toggle()
            default: return false
            }
        }
        return true
    }
}
