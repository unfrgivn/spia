import Foundation
import SpiaAssist

extension Garage {
    /// A finding with its evidence loaded for the model.
    public func finding(_ entry: TimelineEntry) -> DiagnosisRequest.Finding {
        let attachments = entry.attachments.sorted { $0.addedAt < $1.addedAt }
        var photos: [ImageInput] = []
        var clips: [DiagnosisRequest.Clip] = []
        var sounds: [TimeInterval] = []
        for attachment in attachments {
            switch attachment.kind {
            case .photo:
                if let data = try? Data(contentsOf: files.url(for: attachment.path)) {
                    photos.append(ImageInput(mediaType: attachment.mediaType, data: data))
                }
            case .clip:
                let frames = attachment.framePaths.compactMap { path -> ImageInput? in
                    guard let data = try? Data(contentsOf: files.url(for: path)) else { return nil }
                    return ImageInput(mediaType: "image/jpeg", data: data)
                }
                if !frames.isEmpty, let duration = attachment.duration {
                    clips.append(.init(duration: duration, frames: frames))
                }
            case .sound:
                if let duration = attachment.duration { sounds.append(duration) }
            }
        }
        return .init(
            title: entry.title, text: entry.body, date: entry.date,
            photos: photos, clips: clips, sounds: sounds)
    }

    /// The evidence's identity for the inputs hash: attachment ids, oldest first.
    public func evidenceKey(_ entry: TimelineEntry) -> String {
        entry.attachments.sorted { $0.addedAt < $1.addedAt }.map(\.id.uuidString).joined(
            separator: ",")
    }
}
