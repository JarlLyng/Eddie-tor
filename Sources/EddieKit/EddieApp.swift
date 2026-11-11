import IAMJARLDesignTokens
import SwiftUI
import AVFoundation
import ScreenCaptureKit

/// The entry point, shared by the Edwell app and the `Eddie` executable that `swift build` makes.
public enum Launcher {
    public static func run() {
        BundledFonts.register()
        if let i = CommandLine.arguments.firstIndex(of: "--session-test") {
            SessionTest.run(arguments: Array(CommandLine.arguments.dropFirst(i + 1)))
        } else if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let dir = CommandLine.arguments.dropFirst(i + 1).first ?? NSTemporaryDirectory()
            SelfTest.run(outputDirectory: URL(fileURLWithPath: dir))
        } else {
            EddieApp.main()
        }
    }

    /// For the command-line tests: keeps the main queue on the main thread, as it is in the app, until the test
    /// exits. `dispatchMain()` hands the main queue to another thread, and then `MainActor.assumeIsolated` on
    /// it fails wherever the Swift runtime uses its older check (a binary stamped with the macOS 14 SDK, as
    /// `swift build` makes, or macOS 14 itself).
    static func runMainQueue() -> Never {
        RunLoop.main.add(NSMachPort(), forMode: .default)
        while true { RunLoop.main.run() }
    }
}

struct EddieApp: App {
    // Debug runs with EDDIE_SNAPSHOT never touch the user's autosave.
    @ViewState private var editor = Editor(persist: ProcessInfo.processInfo.environment["EDDIE_SNAPSHOT"] == nil)
    @ViewState private var store = Store()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Edwell", id: "main") {
            ContentView()
                .environment(editor)
                .environment(store)
                .tint(Tokens.Palette.primary)
                .onAppear {
                    delegate.editor = editor
                    delegate.openPending()
                }
        }
        .defaultSize(width: 1400, height: 900)
        .commands { EddieCommands(editor: editor, store: store) }

        Window("Keyboard Shortcuts", id: ShortcutsView.windowID) {
            ShortcutsView().tint(Tokens.Palette.primary)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var editor: Editor?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug aid: EDDIE_SNAPSHOT=/path.png saves a picture of the window a few seconds after launch.
        guard let path = ProcessInfo.processInfo.environment["EDDIE_SNAPSHOT"] else { return }
        if let appearance = ProcessInfo.processInfo.environment["EDDIE_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
        if let project = ProcessInfo.processInfo.environment["EDDIE_OPEN"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let editor = self.editor else { return }
                editor.open(URL(fileURLWithPath: project))
                editor.selection = editor.project.clips.first { $0.kind == .image }?.id
                editor.inspectorTab = .position
                // EDDIE_ADD_TITLE=seconds: moves the playhead there and presses G.
                if let time = ProcessInfo.processInfo.environment["EDDIE_ADD_TITLE"].flatMap(Double.init) {
                    editor.seek(time)
                    editor.addTitle()
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }) else { return }
            Task { @MainActor in
                await Self.snapshot(window, to: URL(fileURLWithPath: path))
                if let editor = self.editor, let item = editor.player.currentItem {
                    print("player item status \(item.status.rawValue) error \(String(describing: item.error)) duration \(item.duration.seconds)")
                    // Also save what the preview player renders at 1.5 s.
                    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    item.add(output)
                    editor.seek(1.5)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        let time = CMTime(seconds: 1.5, preferredTimescale: 600)
                        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else {
                            print("preview frame: none"); return
                        }
                        let image = CIImage(cvPixelBuffer: buffer)
                        let rep = NSBitmapImageRep(ciImage: image)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".preview.png"))
                        print("preview frame: \(CVPixelBufferGetWidth(buffer))x\(CVPixelBufferGetHeight(buffer))")
                    }
                }
            }
        }
    }

    /// Writes the window as the window server shows it, through ScreenCaptureKit; an app may capture its own
    /// windows without screen-recording permission. Drawing the views with `cacheDisplay` can't show Liquid
    /// Glass: the selected segment of the toolbar's format picker came out as a blank white pill.
    @MainActor static func snapshot(_ window: NSWindow, to url: URL) async {
        do {
            guard #available(macOS 14.4, *) else { throw CocoaError(.featureUnsupported) }
            let content = try await SCShareableContent.currentProcess
            guard let shared = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                throw CocoaError(.featureUnsupported)
            }
            let filter = SCContentFilter(desktopIndependentWindow: shared)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        } catch {
            print("snapshot: ScreenCaptureKit failed (\(error)), drawing the views instead")
            guard let view = window.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    /// Files from Finder or the Dock: a project opens, media is imported. On a cold launch they can
    /// arrive before the window has handed over the editor, so they wait for it.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingURLs += urls
        Task { @MainActor in openPending() }
    }

    private var pendingURLs: [URL] = []

    @MainActor func openPending() {
        guard let editor, !pendingURLs.isEmpty else { return }
        let urls = pendingURLs
        pendingURLs = []
        if let project = urls.first(where: { Editor.projectExtensions.contains($0.pathExtension.lowercased()) }) {
            editor.open(project)
        } else {
            editor.importMedia(urls)
        }
    }
}

struct EddieCommands: Commands {
    let editor: Editor
    let store: Store

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Edwell") { About.show() }
        }
        // Instead of the default item, which only says help isn't available.
        CommandGroup(replacing: .help) {
            ShortcutsMenuItem()
            Button("Send Feedback…") { Feedback.compose(editor: editor) }
        }
        CommandGroup(after: .appInfo) {
            if store.access != .unlocked {
                Button("Buy Edwell…") { store.showsPurchase = true }
            }
            if !store.localBuild {
                Button("Restore Purchases") {
                    store.showsPurchase = true
                    Task { await store.restore() }
                }
            }
        }
        CommandGroup(replacing: .newItem) {
            // The owner's Ambient Session template stays out of sight: hold ⌥ in the File menu (⌥⌘N).
            // Menus have alternates from macOS 15; on 14 the template isn't there.
            if #available(macOS 15, *) {
                Button("New Project") { editor.newProject() }
                    .keyboardShortcut("n")
                    .modifierKeyAlternate(.option) {
                        Button("New Ambient Session…") { editor.newAmbientSession() }
                    }
            } else {
                Button("New Project") { editor.newProject() }.keyboardShortcut("n")
            }
            Button("Open…") { editor.open() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Save") { editor.save() }.keyboardShortcut("s")
            Button("Save As…") { editor.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Import Media…") { editor.showImportPanel() }.keyboardShortcut("i")
            Button("Export Video…") { editor.showExport = true }.keyboardShortcut("e")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { editor.undo() }.keyboardShortcut("z").disabled(!editor.canUndo)
            Button("Redo") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.canRedo)
        }
        // Single-key shortcuts (S, D, G …) are handled by the editor's key monitor so they never
        // interfere with typing; the menus only show them as hints.
        CommandMenu("Clip") {
            Button("Play / Pause  (Space)") { editor.togglePlay() }
            Divider()
            Button("Split at Playhead  (S)") { editor.splitAtPlayhead() }
            Button("Trim Start to Playhead  (Q)") { editor.trimToPlayhead(start: true) }
            Button("Trim End to Playhead  (W)") { editor.trimToPlayhead(start: false) }
            Button("Duplicate  (D)") { editor.duplicateSelection() }
            Button("Detach Audio  (E)") { editor.separateAudio() }
            Button("Delete  (⌫)") { editor.deleteSelection() }
            Divider()
            Button("Add Title  (G)") { editor.addTitle() }
            Button("Add Transition") { editor.applyDefaultTransition() }.keyboardShortcut("d")
            Divider()
            Button("Set In Point  (I)") { editor.markIn() }
            Button("Set Out Point  (O)") { editor.markOut() }
            Button("Clear In and Out  (⌥X)") { editor.clearInOut(in: true, out: true) }
        }
        CommandGroup(before: .toolbar) {
            ForEach(InspectorTab.allCases) { tab in
                Button(tab.label) { editor.inspectorTab = tab }
                    .keyboardShortcut(KeyEquivalent(Character(String(tab.rawValue))))
            }
            Divider()
            Toggle("Snap", isOn: Binding(get: { editor.snapping }, set: { editor.snapping = $0 })).keyboardShortcut("y")
            Toggle("Loop Playback", isOn: Binding(get: { editor.loopPlayback }, set: { editor.loopPlayback = $0 })).keyboardShortcut("l")
            Toggle("Large Preview  (`)", isOn: Binding(get: { editor.monitorMaximized }, set: { editor.monitorMaximized = $0 }))
            Toggle("Show Media  (Y)", isOn: Binding(get: { editor.showMedia }, set: { editor.showMedia = $0 }))
            Divider()
            Button("Zoom In  (=)") { editor.pps = min(editor.pps * 1.4, 600) }
            Button("Zoom Out  (−)") { editor.pps = max(editor.pps / 1.4, 4) }
            Button("Zoom to Fit  (\\)") { editor.zoomToFitRequest += 1 }
            Divider()
        }
    }
}
