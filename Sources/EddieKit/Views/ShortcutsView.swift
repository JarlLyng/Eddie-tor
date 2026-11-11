import IAMJARLDesignTokens
import SwiftUI

/// Help › Keyboard Shortcuts: Rush's keys, in a window of their own rather than in the inspector.
struct ShortcutsView: View {
    static let windowID = "shortcuts"

    var body: some View {
        Form {
            Section("Play") {
                shortcut("Play / pause", String(localized: "Space"))
                shortcut("Rewind / stop / forward", "J  K  L")
                shortcut("One frame back / forward", "←  →")
                shortcut("Previous / next clip edge", "↑  ↓")
            }
            Section("Edit") {
                shortcut("Split clip", "S")
                shortcut("Trim start / end to playhead", "Q  W")
                shortcut("Duplicate", "D")
                shortcut("New title", "G")
                shortcut("Detach audio", "E")
                shortcut("Delete", "⌫")
                shortcut("Add transition", "⌘D")
                shortcut("Copy / cut / paste", "⌘C  ⌘X  ⌘V")
                shortcut("Stop typing", "esc")
            }
            Section("In and Out") {
                shortcut("In / out point", "I  O")
                shortcut("Go to in / out", "⇧I  ⇧O")
                shortcut("Clear in / out / both", "⌥I  ⌥O  ⌥X")
            }
            Section("View") {
                shortcut("Zoom in / out / fit", "=  −  \\")
                shortcut("Snap / loop", "⌘Y  ⌘L")
                shortcut("Tools", "⌘1 ⌘2 ⌘4 ⌘5 ⌘6")
                shortcut("Large preview / media", "`  Y")
                shortcut("Export", "⌘E")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 640)
    }

    private func shortcut(_ action: LocalizedStringKey, _ keys: String) -> some View {
        LabeledContent(action) { Text(keys).ijFont(.sm, design: .monospaced).foregroundStyle(Tokens.Palette.Text.secondary) }
    }
}

/// The Help menu's way to the window; menus can't open a window without a view's `openWindow`.
struct ShortcutsMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Keyboard Shortcuts") { openWindow(id: ShortcutsView.windowID) }
            .keyboardShortcut("/", modifiers: .command)
    }
}
