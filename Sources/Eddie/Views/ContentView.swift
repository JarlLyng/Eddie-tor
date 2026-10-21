import SwiftUI

struct ContentView: View {
    @Environment(Editor.self) private var editor

    var body: some View {
        @Bindable var editor = editor
        VSplitView {
            HSplitView {
                if editor.showMedia && !editor.monitorMaximized {
                    MediaBinView()
                        .frame(minWidth: 200, idealWidth: 250, maxWidth: 420)
                }
                PreviewPanel()
                    .frame(minWidth: 420, maxWidth: .infinity)
                if !editor.monitorMaximized {
                    InspectorView()
                        .frame(minWidth: 280, idealWidth: 310, maxWidth: 440)
                }
            }
            .frame(minHeight: 320, idealHeight: 520)
            TimelinePanel()
                .frame(minHeight: 220, idealHeight: 340)
        }
        .navigationTitle(editor.windowTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { editor.showImportPanel() } label: { Label("Importer", systemImage: "plus") }
                    .help("Importer video, lyd eller billeder (⌘I)")
            }
            ToolbarItem(placement: .principal) {
                Picker("Format", selection: editor.projectBinding(\.aspect)) {
                    ForEach(AspectRatio.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Billedformat")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { editor.showExport = true } label: { Label("Eksporter", systemImage: "square.and.arrow.up") }
                    .help("Eksporter til MP4 (⌘E)")
                    .disabled(editor.project.clips.isEmpty)
            }
        }
        .sheet(isPresented: $editor.showExport) { ExportSheet() }
        .alert("Hov", isPresented: Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.errorMessage = nil } })) {
            Button("OK") { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage ?? "")
        }
        .onAppear { editor.installKeyMonitor() }
    }
}
