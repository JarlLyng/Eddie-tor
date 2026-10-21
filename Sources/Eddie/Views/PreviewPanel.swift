import AVFoundation
import SwiftUI

struct PreviewPanel: View {
    @Environment(Editor.self) private var editor
    @ViewState private var dragOrigin: Clip?

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                let size = fittedSize(in: geo.size)
                PlayerView(player: editor.player)
                    .frame(width: size.width, height: size.height)
                    .overlay(selectionOutline(size: size))
                    .gesture(moveGesture(size: size))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .background(Color(white: 0.08))
            .padding(.bottom, 1)

            HStack(spacing: 14) {
                Button { editor.seek(0) } label: { Image(systemName: "backward.end.fill") }
                Button { editor.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                Button { editor.togglePlay() } label: {
                    Image(systemName: editor.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                Button { editor.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                Button { editor.seek(editor.project.duration) } label: { Image(systemName: "forward.end.fill") }
            }
            .buttonStyle(.borderless)
            .padding(.vertical, 8)
        }
    }

    private func fittedSize(in space: CGSize) -> CGSize {
        let ratio = editor.project.aspect.ratio
        let available = CGSize(width: max(space.width - 24, 10), height: max(space.height - 24, 10))
        if available.width / available.height > ratio {
            return CGSize(width: available.height * ratio, height: available.height)
        }
        return CGSize(width: available.width, height: available.width / ratio)
    }

    /// Shows which clip a drag in the preview will move.
    @ViewBuilder private func selectionOutline(size: CGSize) -> some View {
        if let clip = editor.selectedClip, clip.start <= editor.currentTime, editor.currentTime < clip.end, clip.kind != .audio {
            Rectangle()
                .strokeBorder(Color.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .allowsHitTesting(false)
        }
    }

    /// Dragging in the preview moves the selected title or picture.
    private func moveGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragOrigin == nil {
                    guard let clip = editor.selectedClip, clip.kind != .audio else { return }
                    dragOrigin = clip
                    editor.beginInteraction()
                }
                guard let origin = dragOrigin else { return }
                let dx = value.translation.width / size.width
                let dy = value.translation.height / size.height
                editor.interact(livePreview: true) { project in
                    guard let i = project.clips.firstIndex(where: { $0.id == origin.id }) else { return }
                    if origin.kind == .title, let style = origin.title {
                        project.clips[i].title?.x = min(max(style.x + dx, 0), 1)
                        project.clips[i].title?.y = min(max(style.y + dy, 0), 1)
                    } else {
                        project.clips[i].offsetX = origin.offsetX + dx
                        project.clips[i].offsetY = origin.offsetY + dy
                    }
                }
            }
            .onEnded { _ in
                if dragOrigin != nil { editor.endInteraction() }
                dragOrigin = nil
            }
    }
}

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerNSView {
        let view = PlayerNSView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: PlayerNSView, context: Context) {
        view.playerLayer.player = player
    }
}

final class PlayerNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}
