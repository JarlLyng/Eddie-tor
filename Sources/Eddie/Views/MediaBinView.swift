import SwiftUI

struct MediaBinView: View {
    @Environment(Editor.self) private var editor
    @ViewState private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Medier").font(.headline)
                Spacer()
                Button { editor.showImportPanel() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .help("Importer medier")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()

            if editor.project.media.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("Træk video, lyd eller billeder hertil").multilineTextAlignment(.center)
                    Button("Importer…") { editor.showImportPanel() }
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 10) {
                        ForEach(editor.project.media) { media in
                            MediaTile(media: media)
                        }
                    }
                    .padding(10)
                }
                Text("Dobbeltklik eller træk ned på tidslinjen")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            }
        }
        .background(dropTargeted ? Color.accentColor.opacity(0.15) : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            editor.importMedia(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }
}

private struct MediaTile: View {
    @Environment(Editor.self) private var editor
    let media: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .frame(height: 64)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if media.kind != .image {
                    Text(timecode(media.duration, fps: editor.project.fps))
                        .font(.system(size: 9).monospacedDigit())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                        .padding(3)
                }
            }
            Text(media.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(FileManager.default.fileExists(atPath: media.url.path) ? .primary : Color.red)
        }
        .contentShape(Rectangle())
        .draggable(media.id.uuidString) {
            thumbnail.frame(width: 80, height: 50).clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .onTapGesture(count: 2) { editor.add(media) }
        .contextMenu {
            Button("Tilføj til tidslinjen") { editor.add(media) }
            Button("Tilføj ved afspilningshoved") { editor.add(media, at: editor.currentTime) }
            Button("Vis i Finder") { NSWorkspace.shared.activateFileViewerSelecting([media.url]) }
            Divider()
            Button("Fjern fra projektet", role: .destructive) { editor.removeMedia(media.id) }
        }
        .help(media.url.path)
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = editor.cache.thumbnails[media.id] {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Rectangle().fill(media.kind == .audio ? Color.green.opacity(0.25) : Color.gray.opacity(0.25))
                Image(systemName: media.kind == .audio ? "waveform" : media.kind == .image ? "photo" : "film")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
