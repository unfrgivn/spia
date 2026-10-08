import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum MediaError: Error, Equatable, CustomStringConvertible {
    case unreadable
    case tooLong(seconds: Int, limit: Int)
    case noVehicle

    public var description: String {
        switch self {
        case .unreadable: return "That recording isn't a sound or video Spia can read."
        case let .tooLong(seconds, limit):
            let minutes = seconds / 60
            let remainder = seconds % 60
            let length =
                minutes == 0
                ? "\(remainder) seconds"
                : "\(minutes) minute\(minutes == 1 ? "" : "s") \(remainder) seconds"
            return "That recording is \(length); the limit is \(limit) seconds."
        case .noVehicle: return "This finding doesn't belong to a car."
        }
    }
}

/// Clips and sounds as the owner recorded them, with what the app needs to show and send them.
public enum MediaPreparation {
    public static let maximumSeconds = 60

    public static func duration(at url: URL) async throws -> TimeInterval {
        do {
            let duration = try await AVURLAsset(url: url).load(.duration)
            guard duration.isNumeric, duration.seconds.isFinite else { throw MediaError.unreadable }
            let seconds = duration.seconds
            guard seconds >= 0 else { throw MediaError.unreadable }
            if seconds > Double(maximumSeconds) {
                throw MediaError.tooLong(seconds: Int(seconds.rounded()), limit: maximumSeconds)
            }
            return seconds
        } catch let error as MediaError { throw error } catch { throw MediaError.unreadable }
    }

    /// Frames spread from the start to the end of a clip whose `duration` is already known, as
    /// JPEGs with the long edge at most `maxPixels`. The last is taken just before the end,
    /// where a generator is otherwise prone to fail.
    public static func frames(
        at url: URL, duration: TimeInterval, count: Int = 3, maxPixels: Int = 2000
    ) async throws -> [Data] {
        guard count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixels, height: maxPixels)
        let end = max(duration - 0.05, 0)
        let seconds = (0..<count).map { index -> TimeInterval in
            if index == count - 1 { return end }
            return duration * Double(index) / Double(max(count - 1, 1))
        }
        var images: [Data] = []
        for second in seconds {
            do {
                let result = try await generator.image(
                    at: CMTime(seconds: second, preferredTimescale: 600))
                images.append(try PhotoPreparation.jpeg(result.image))
            } catch { throw MediaError.unreadable }
        }
        return images
    }

    /// The registered type for the file's extension. Apple names some with a vendor prefix
    /// (`.m4a` is `audio/x-m4a`); those yield to the standard `fallback`.
    public static func mediaType(for url: URL, fallback: String) -> String {
        guard !url.pathExtension.isEmpty,
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType,
            !mime.contains("/x-")
        else { return fallback }
        return mime
    }
}

extension Garage {
    @discardableResult
    public func attachPhoto(_ data: Data, to entry: TimelineEntry) throws -> Attachment {
        guard let vehicle = entry.vehicle else { throw MediaError.noVehicle }
        let prepared = try PhotoPreparation.jpeg(from: data)
        let path = files.findingPath(vehicle: vehicle.id, name: "\(UUID().uuidString).jpg")
        try store(prepared, at: path)
        let attachment = Attachment(kind: .photo, path: path, mediaType: "image/jpeg")
        entry.attachments.append(attachment)
        try context.save()
        return attachment
    }

    @discardableResult
    public func attachClip(at url: URL, to entry: TimelineEntry) async throws -> Attachment {
        guard let vehicle = entry.vehicle else { throw MediaError.noVehicle }
        let duration = try await MediaPreparation.duration(at: url)
        let frames = try await MediaPreparation.frames(at: url, duration: duration)
        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension.lowercased()
        let path = files.findingPath(vehicle: vehicle.id, name: "\(id.uuidString).\(ext)")
        try copy(url, to: path)
        let framePaths = try frames.enumerated().map { index, data -> String in
            let framePath = files.findingPath(
                vehicle: vehicle.id, name: "\(id.uuidString)-\(index + 1).jpg")
            try store(data, at: framePath)
            return framePath
        }
        let attachment = Attachment(
            kind: .clip, path: path,
            mediaType: MediaPreparation.mediaType(for: url, fallback: "video/quicktime"),
            duration: duration, framePaths: framePaths)
        entry.attachments.append(attachment)
        try context.save()
        return attachment
    }

    @discardableResult
    public func attachSound(at url: URL, to entry: TimelineEntry) async throws -> Attachment {
        guard let vehicle = entry.vehicle else { throw MediaError.noVehicle }
        let duration = try await MediaPreparation.duration(at: url)
        let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension.lowercased()
        let path = files.findingPath(vehicle: vehicle.id, name: "\(UUID().uuidString).\(ext)")
        try copy(url, to: path)
        let attachment = Attachment(
            kind: .sound, path: path,
            mediaType: MediaPreparation.mediaType(for: url, fallback: "audio/mp4"),
            duration: duration)
        entry.attachments.append(attachment)
        try context.save()
        return attachment
    }

    public func delete(_ attachment: Attachment) throws {
        let paths = [attachment.path] + attachment.framePaths
        context.delete(attachment)
        try context.save()
        for path in paths {
            let url = files.url(for: path)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    private func store(_ data: Data, at path: String) throws {
        let url = files.url(for: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func copy(_ source: URL, to path: String) throws {
        let destination = files.url(for: path)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.appendingPathExtension("tmp")
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
