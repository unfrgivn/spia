import Foundation

/// What the owner is about to record: their words and the evidence that goes with them.
public struct FindingDraft: Sendable {
    public var title: String
    public var text: String
    public var photos: [Data]
    public var clips: [URL]
    public var sounds: [URL]

    public init(
        title: String,
        text: String = "",
        photos: [Data] = [],
        clips: [URL] = [],
        sounds: [URL] = []
    ) {
        self.title = title
        self.text = text
        self.photos = photos
        self.clips = clips
        self.sounds = sounds
    }

    public var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && photos.isEmpty && clips.isEmpty && sounds.isEmpty
    }
}

public enum FindingError: Error, Equatable, CustomStringConvertible {
    case empty

    public var description: String {
        "Write what you found, or attach a photo, clip, or sound."
    }
}

extension Garage {
    @discardableResult
    public func addFinding(
        _ draft: FindingDraft, to session: DiagnosticSession
    ) async throws -> TimelineEntry {
        guard !draft.isEmpty else { throw FindingError.empty }
        let entry = makeFinding(
            text: draft.text,
            title: draft.title,
            session: session)
        var created: [Attachment] = []
        do {
            for photo in draft.photos {
                created.append(try attachPhoto(photo, to: entry))
            }
            for clip in draft.clips {
                created.append(try await attachClip(at: clip, to: entry))
            }
            for sound in draft.sounds {
                created.append(try await attachSound(at: sound, to: entry))
            }
            try context.save()
            return entry
        } catch {
            for attachment in created {
                try? delete(attachment)
            }
            context.delete(entry)
            try? context.save()
            throw error
        }
    }

    /// The entry itself, appended to the session but not yet saved.
    @discardableResult
    func makeFinding(text: String, title: String, session: DiagnosticSession) -> TimelineEntry {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = TimelineEntry(
            kind: .finding,
            title: name.isEmpty ? "Finding" : name,
            body: body)
        entry.vehicle = session.vehicle
        append(entry, to: session)
        return entry
    }
}
