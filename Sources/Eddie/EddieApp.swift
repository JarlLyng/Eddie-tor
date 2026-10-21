import SwiftUI
import AVFoundation

@main
enum Main {
    static func main() {
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let dir = CommandLine.arguments.dropFirst(i + 1).first ?? NSTemporaryDirectory()
            SelfTest.run(outputDirectory: URL(fileURLWithPath: dir))
        } else {
            EddieApp.main()
        }
    }
}

struct EddieApp: App {
    @ViewState private var editor = Editor()
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("Eddie", id: "main") {
            ContentView()
                .environment(editor)
                .preferredColorScheme(.dark)
                .onAppear { delegate.editor = editor }
        }
        .defaultSize(width: 1400, height: 900)
        .commands { EddieCommands(editor: editor) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var editor: Editor?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Debug aid: EDDIE_SNAPSHOT=/path.png saves a picture of the window a few seconds after launch.
        guard let path = ProcessInfo.processInfo.environment["EDDIE_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView?.superview,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
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

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in editor?.open(url) }
    }
}

struct EddieCommands: Commands {
    let editor: Editor

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nyt projekt") { editor.newProject() }.keyboardShortcut("n")
            Button("Åbn…") { editor.open() }.keyboardShortcut("o")
        }
        CommandGroup(replacing: .saveItem) {
            Button("Gem") { editor.save() }.keyboardShortcut("s")
            Button("Gem som…") { editor.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("Importer medier…") { editor.showImportPanel() }.keyboardShortcut("i")
            Button("Eksporter video…") { editor.showExport = true }.keyboardShortcut("e")
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Fortryd") { editor.undo() }.keyboardShortcut("z").disabled(!editor.canUndo)
            Button("Annuller fortryd") { editor.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!editor.canRedo)
        }
        CommandMenu("Klip") {
            Button("Afspil / pause") { editor.togglePlay() }
            Button("Del ved afspilningshoved  (S)") { editor.splitAtPlayhead() }.keyboardShortcut("b")
            Button("Dupliker") { editor.duplicateSelection() }.keyboardShortcut("d")
            Button("Slet  (⌫)") { editor.deleteSelection() }
            Divider()
            Button("Tilføj tekst  (T)") { editor.addTitle() }
            Divider()
            Button("Zoom ind") { editor.pps = min(editor.pps * 1.4, 600) }.keyboardShortcut("+")
            Button("Zoom ud") { editor.pps = max(editor.pps / 1.4, 4) }.keyboardShortcut("-")
        }
    }
}
