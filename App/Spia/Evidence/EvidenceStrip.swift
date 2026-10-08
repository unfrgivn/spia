import AVFoundation
import Observation
import SpiaStore
import SwiftUI

@MainActor
@Observable final class SoundPlayer {
    private var player: AVAudioPlayer?
    var isPlaying = false

    func toggle(url: URL) {
        if isPlaying {
            player?.stop()
            isPlaying = false
            return
        }
        guard let player = try? AVAudioPlayer(contentsOf: url) else { return }
        self.player = player
        player.play()
        isPlaying = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(player.duration))
            guard let self, self.player === player else { return }
            isPlaying = false
        }
    }

    func stop() {
        player?.stop()
        isPlaying = false
    }
}

struct EvidenceStrip: View {
    let attachments: [Attachment]
    let files: SpiaFiles
    @State private var viewer: Attachment?
    @State private var soundPlayer = SoundPlayer()

    var body: some View {
        if attachments.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments.sorted { $0.addedAt < $1.addedAt }) { attachment in
                        tile(attachment)
                    }
                }
            }
            .sheet(item: $viewer) { attachment in
                EvidenceViewer(attachment: attachment, files: files)
            }
            .onDisappear { soundPlayer.stop() }
        }
    }

    @ViewBuilder private func tile(_ attachment: Attachment) -> some View {
        switch attachment.kind {
        case .photo:
            Button {
                viewer = attachment
            } label: {
                LocalImage(url: files.url(for: attachment.path))
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Photo")
            .accessibilityHint("Opens the photo")
        case .clip:
            Button {
                viewer = attachment
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    if let frame = attachment.framePaths.first {
                        LocalImage(url: files.url(for: frame))
                    } else {
                        Image(systemName: "film")
                            .font(.title2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Image(systemName: "play.fill")
                        .padding(6)
                        .background(.ultraThinMaterial, in: Circle())
                    duration(attachment.duration)
                        .padding(4)
                }
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clip, \(Self.time(attachment.duration ?? 0))")
            .accessibilityHint("Plays the clip")
        case .sound:
            HStack(spacing: 7) {
                Image(systemName: "waveform")
                duration(attachment.duration)
                Button {
                    soundPlayer.toggle(url: files.url(for: attachment.path))
                } label: {
                    Image(systemName: soundPlayer.isPlaying ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(soundPlayer.isPlaying ? "Stop" : "Play")
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(Palette.card, in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sound, \(Self.time(attachment.duration ?? 0))")
        }
    }

    private func duration(_ value: TimeInterval?) -> some View {
        Text(Self.time(value ?? 0))
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.black.opacity(0.65), in: Capsule())
            .foregroundStyle(.white)
    }

    private static func time(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        return "\(whole / 60):\(String(format: "%02d", whole % 60))"
    }
}
