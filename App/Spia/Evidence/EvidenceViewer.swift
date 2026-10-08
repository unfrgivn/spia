import AVKit
import SpiaStore
import SwiftUI

struct EvidenceViewer: View {
    let attachment: Attachment
    let files: SpiaFiles
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            switch attachment.kind {
            case .photo:
                LocalImage(url: files.url(for: attachment.path))
                    .scaledToFit()
            case .clip:
                if let player {
                    VideoPlayer(player: player)
                        .onAppear { player.play() }
                        .onDisappear { player.pause() }
                }
            case .sound:
                Image(systemName: "waveform")
                    .font(.system(size: 48))
                    .foregroundStyle(Palette.accent)
            }
        }
        .padding()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            if attachment.kind == .clip {
                player = AVPlayer(url: files.url(for: attachment.path))
            }
        }
    }
}
