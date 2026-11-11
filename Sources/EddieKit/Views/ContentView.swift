import IAMJARLDesignTokens
import SwiftUI

struct ContentView: View {
    @Environment(Editor.self) private var editor
    @Environment(Store.self) private var store
    /// Export was asked for before it was open, so it carries on once the trial starts or the purchase goes through.
    @ViewState private var exportAfterPurchase = false

    var body: some View {
        @Bindable var editor = editor
        @Bindable var store = store
        @Bindable var job = editor.exportJob
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
        .background(Tokens.Palette.Background.app)
        .navigationTitle(editor.windowTitle)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { editor.showMedia.toggle() } label: { Label("Media", systemImage: "sidebar.left") }
                    .help("Show or hide your media (Y)")
            }
            ToolbarItem(placement: .navigation) {
                Button { editor.showImportPanel() } label: { Label("Import", systemImage: "plus") }
                    .help("Import video, audio or images (⌘I)")
            }
            ToolbarItem(placement: .principal) {
                Picker("Format", selection: editor.aspectBinding) {
                    ForEach(AspectRatio.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Aspect ratio")
            }
            if store.offersPurchase {
                PurchaseToolbarItem()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { editor.showExport = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export to MP4 (⌘E)")
                    .disabled(editor.project.clips.isEmpty)
            }
        }
        // Export goes straight to the save panel; before the trial or the purchase, the purchase sheet comes first.
        .onChange(of: editor.showExport) { _, asked in
            guard asked else { return }
            editor.showExport = false
            guard !editor.project.clips.isEmpty, !job.isExporting else { return }
            if store.access.canExport {
                ExportPanel.run(editor)
            } else {
                exportAfterPurchase = true
                store.showsPurchase = true
            }
        }
        .onChange(of: store.access.canExport) { _, open in
            guard open, exportAfterPurchase else { return }
            exportAfterPurchase = false
            store.showsPurchase = false
            DispatchQueue.main.async { ExportPanel.run(editor) }
        }
        .onChange(of: store.showsPurchase) { _, showing in if !showing { exportAfterPurchase = false } }
        .sheet(isPresented: $job.showsSheet) { ExportProgressView() }
        .sheet(isPresented: $store.showsPurchase) { PurchaseView() }
        .alert("Oops", isPresented: Binding(get: { editor.errorMessage != nil }, set: { if !$0 { editor.errorMessage = nil } })) {
            Button("OK") { editor.errorMessage = nil }
        } message: {
            Text(editor.errorMessage ?? "")
        }
        .onAppear { editor.installKeyMonitor() }
    }
}
