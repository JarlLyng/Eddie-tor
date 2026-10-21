import AVFoundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class Editor {
    private(set) var project = Project()
    var selection: UUID?
    var currentTime: Double = 0
    private(set) var isPlaying = false
    /// Timeline zoom in points per second.
    var pps: Double = 60
    private(set) var fileURL: URL?
    private(set) var isDirty = false
    var showExport = false
    var errorMessage: String?

    let cache = MediaCache()
    @ObservationIgnored let player = AVPlayer()
    @ObservationIgnored private var undoStack: [Project] = []
    @ObservationIgnored private var redoStack: [Project] = []
    @ObservationIgnored private var lastCoalesce: (key: String, date: Date)?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var installedStructure: [String]?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var interacting = false

    static let projectType = UTType(exportedAs: "dk.eddie-tor.project", conformingTo: .json)

    /// `persist: false` skips the autosave file (used by the self test).
    @ObservationIgnored private let persist: Bool

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
        let name = fileURL?.deletingPathExtension().lastPathComponent ?? "Uden navn"
        return isDirty ? "\(name) — redigeret" : name
    }

    func clips(in row: TrackRow) -> [Clip] {
        project.clips.filter { $0.group == row.group && $0.track == row.index }
    }

    // MARK: - Editing with undo

    /// Applies a change as one undo step. Changes with the same `coalesce` key in quick succession
    /// (typing, dragging a slider) are merged into a single step.
    func edit(coalesce key: String? = nil, _ change: (inout Project) -> Void) {
        let now = Date()
        if let key, let last = lastCoalesce, last.key == key, now.timeIntervalSince(last.date) < 1.5 {
            // Same gesture: keep the existing undo point.
        } else {
            pushUndo()
        }
        lastCoalesce = key.map { ($0, now) }
        change(&project)
        didChange()
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
        if livePreview { scheduleRebuild(delay: 0.03) }
    }

    func endInteraction() {
        guard interacting else { return }
        interacting = false
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

    private func didChange() {
        if let selection, !project.clips.contains(where: { $0.id == selection }) { self.selection = nil }
        isDirty = true
        scheduleRebuild()
        scheduleAutosave()
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

    /// Adds media to the timeline. Without a time it is appended to the end of the first track, as in Rush.
    func add(_ media: MediaItem, at time: Double? = nil, track: Int = 0) {
        let kind: ClipKind = switch media.kind {
        case .video: .video
        case .image: .image
        case .audio: .audio
        }
        var clip = Clip(kind: kind, track: track, start: 0, duration: media.kind == .image ? 4 : media.duration, mediaID: media.id)
        let desired = time ?? trackEnd(clip.group, track: track)
        clip.start = freeStart(clip.group, track: track, desired: desired, duration: clip.duration)
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
        var clip = Clip(kind: .title, track: 0, start: 0, duration: duration, fadeIn: 0.25, fadeOut: 0.25, title: TitleStyle())
        clip.start = freeStart(.title, track: 0, desired: currentTime, duration: duration)
        if clip.start > currentTime + 0.01, project.titleTracks > 1 {
            let other = freeStart(.title, track: 1, desired: currentTime, duration: duration)
            if other < clip.start { clip.track = 1; clip.start = other }
        }
        edit { $0.clips.append(clip) }
        selection = clip.id
    }

    /// Splits the selected clip at the playhead, or every clip under the playhead if none is selected.
    func splitAtPlayhead() {
        let t = currentTime
        let under = project.clips.filter { $0.start + 0.01 < t && t < $0.end - 0.01 }
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
                if target.hasMediaTiming { right.sourceIn = target.sourceIn + (t - target.start) }
                project.clips[i].duration = t - target.start
                project.clips[i].fadeOut = 0
                project.clips.append(right)
                if target.id == selection { newSelection = right.id }
            }
        }
        if let newSelection { selection = newSelection }
    }

    func deleteSelection() {
        guard let selection else { return }
        edit { $0.clips.removeAll { $0.id == selection } }
    }

    func duplicateSelection() {
        guard var clip = selectedClip else { return }
        clip.id = UUID()
        clip.start = freeStart(clip.group, track: clip.track, desired: clip.end, duration: clip.duration)
        edit { $0.clips.append(clip) }
        selection = clip.id
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

    func removeMedia(_ id: UUID) {
        edit { project in
            project.media.removeAll { $0.id == id }
            project.clips.removeAll { $0.mediaID == id }
        }
    }

    /// Snaps a time to the playhead or a clip edge if it is within a few points.
    func snap(_ time: Double, excluding: UUID?) -> Double? {
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

    // MARK: - Import

    func showImportPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .image]
        panel.message = "Vælg video, lyd eller billeder"
        guard panel.runModal() == .OK else { return }
        importMedia(panel.urls)
    }

    func importMedia(_ urls: [URL], thenAddToTimeline: Bool = false) {
        Task {
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
            if thenAddToTimeline { added.forEach { add($0) } }
            if added.count < urls.count {
                errorMessage = "Nogle filer kunne ikke åbnes. Eddie kan bruge video, lyd og billeder."
            }
        }
    }

    // MARK: - Playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard project.duration > 0 else { return }
        if currentTime >= project.duration - 0.05 { seek(0) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        currentTime = player.currentTime().seconds.isFinite ? player.currentTime().seconds : currentTime
    }

    func seek(_ time: Double) {
        currentTime = min(max(0, time), max(project.duration, 0))
        player.seek(to: CompositionBuilder.time(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        if isPlaying { pause() }
        seek(currentTime + Double(frames) / Double(project.fps))
    }

    private func playerTick(_ time: CMTime) {
        guard isPlaying, time.isValid else { return }
        currentTime = time.seconds
        if currentTime >= project.duration - 0.001 || player.rate == 0 {
            isPlaying = false
            player.pause()
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
                NSLog("Eddie: kunne ikke bygge preview: \(error)")
            }
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
            player.play()
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
        } catch {
            errorMessage = "Projektet kunne ikke åbnes: \(error.localizedDescription)"
        }
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
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? "Mit projekt.eddie"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        return write(to: url)
    }

    private func write(to url: URL) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: url, options: .atomic)
            fileURL = url
            isDirty = false
            UserDefaults.standard.set(url.path, forKey: "lastProjectPath")
            return true
        } catch {
            errorMessage = "Projektet kunne ikke gemmes: \(error.localizedDescription)"
            return false
        }
    }

    private func confirmDiscard() -> Bool {
        guard isDirty, !project.clips.isEmpty || !project.media.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Vil du gemme ændringerne i \(fileURL?.lastPathComponent ?? "projektet")?"
        alert.addButton(withTitle: "Gem")
        alert.addButton(withTitle: "Annuller")
        alert.addButton(withTitle: "Gem ikke")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    private func replaceProject(_ new: Project, url: URL?) {
        project = new
        fileURL = url
        isDirty = false
        selection = nil
        undoStack.removeAll()
        redoStack.removeAll()
        currentTime = 0
        installedStructure = nil
        cache.prepare(new.media)
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
        let snapshot = project, url = fileURL, dirty = isDirty
        autosaveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: Self.autosaveURL, options: .atomic)
            UserDefaults.standard.set(url?.path, forKey: "autosaveFilePath")
            UserDefaults.standard.set(dirty, forKey: "autosaveDirty")
        }
    }

    private func restoreAutosave() {
        guard let data = try? Data(contentsOf: Self.autosaveURL),
              let saved = try? JSONDecoder().decode(Project.self, from: data) else { return }
        project = saved
        fileURL = UserDefaults.standard.string(forKey: "autosaveFilePath").map { URL(fileURLWithPath: $0) }
        isDirty = UserDefaults.standard.bool(forKey: "autosaveDirty")
        cache.prepare(saved.media)
    }

    // MARK: - Keyboard

    /// Space, arrows and delete work anywhere except while typing in a text field.
    func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            let modifiers = event.modifierFlags.intersection([.command, .option, .control])
            guard modifiers.isEmpty else { return event }
            let shift = event.modifierFlags.contains(.shift)
            switch event.keyCode {
            case 49: togglePlay()                                   // space
            case 51, 117: deleteSelection()                         // delete, forward delete
            case 123: step(frames: shift ? -project.fps : -1)       // left
            case 124: step(frames: shift ? project.fps : 1)         // right
            case 115: seek(0)                                       // home
            case 119: seek(project.duration)                        // end
            default:
                switch event.charactersIgnoringModifiers {
                case "s": splitAtPlayhead()
                case "t": addTitle()
                case "+": pps = min(pps * 1.4, 600)
                case "-": pps = max(pps / 1.4, 4)
                default: return event
                }
            }
            return nil
        }
    }
}
