import IAMJARLDesignTokens
import SwiftUI

struct MediaBinView: View {
    @Environment(Editor.self) private var editor
    @ViewState private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Medier").ijFont(.base, weight: .semibold)
                Spacer()
                Button { editor.showImportPanel() } label: { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Tokens.Palette.Text.primary)
                    .help("Importer medier")
            }
            .padding(.horizontal, Tokens.Spacing.md)
            .padding(.vertical, Tokens.Spacing.sm)
            Divider()

            if editor.project.media.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(Tokens.Palette.Text.secondary)
                    Text("Træk video, lyd eller billeder hertil").ijFont(.sm).multilineTextAlignment(.center)
                    Button("Importer…") { editor.showImportPanel() }.buttonStyle(PrimaryButtonStyle())
                    Button("Ny Ambient Session…") { editor.newAmbientSession() }.buttonStyle(SecondaryButtonStyle())
                        .help("Vælg optagelsen; fades og titel sættes op som i Rush (⇧⌘N)")
                }
                .foregroundStyle(Tokens.Palette.Text.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Tokens.Spacing.lg)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 10) {
                        ForEach(editor.project.media) { media in
                            MediaTile(media: media)
                        }
                    }
                    .padding(Tokens.Spacing.sm)
                }
                Text("Dobbeltklik eller træk ned på tidslinjen")
                    .ijFont(.xs).foregroundStyle(Tokens.Palette.Text.secondary)
                    .padding(.vertical, Tokens.Spacing.xs)
            }
        }
        .background(dropTargeted ? Tokens.Palette.primarySubtle : Color.clear)
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
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            ZStack(alignment: .bottomTrailing) {
                thumbnail
                    .frame(height: 64)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                if media.kind != .image {
                    Text(timecode(media.duration, fps: editor.project.fps))
                        .ijFont(.xs)
                        .monospacedDigit()
                        .foregroundStyle(Tokens.Palette.Text.primary)
                        .padding(.horizontal, Tokens.Spacing.xs)
                        .background(Tokens.Palette.Background.app.opacity(0.75), in: RoundedRectangle(cornerRadius: Tokens.Radius.sm))
                        .padding(Tokens.Spacing.xs)
                }
            }
            Text(media.name)
                .ijFont(.xs)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(FileManager.default.fileExists(atPath: media.url.path) ? Tokens.Palette.Text.primary : Tokens.Palette.State.error)
        }
        .contentShape(Rectangle())
        .draggable(media.id.uuidString) {
            thumbnail.frame(width: 80, height: 50).clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sm))
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
                Rectangle().fill(Tokens.clipFill)
                Image(systemName: media.kind == .audio ? "waveform" : media.kind == .image ? "photo" : "film")
                    .foregroundStyle(Tokens.Palette.Text.secondary)
            }
        }
    }
}
