import Foundation
import ImageIO
import SpiaAssist
import UniformTypeIdentifiers

public enum PhotoError: Error, Equatable, CustomStringConvertible {
    case unreadable
    case encodingFailed

    public var description: String {
        switch self {
        case .unreadable: return "That file isn't an image Spia can read."
        case .encodingFailed: return "The photo couldn't be converted for sending."
        }
    }
}

/// Photos for the assistant: resized so the long edge is at most `maxPixels` and re-encoded as
/// JPEG, which keeps them within both providers' limits and strips camera metadata such as location.
public enum PhotoPreparation {
    public static func jpeg(from data: Data, maxPixels: Int = 2000) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw PhotoError.unreadable
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            throw PhotoError.unreadable
        }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw PhotoError.encodingFailed }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PhotoError.encodingFailed }
        return output as Data
    }
}

extension Garage {
    /// Prepares and saves a photo for the session, returning the part to store in a message.
    public func storePhoto(_ data: Data, in session: DiagnosticSession) throws -> StoredPart {
        let jpeg = try PhotoPreparation.jpeg(from: data)
        let path = files.attachmentPath(session: session.id, name: "\(UUID().uuidString).jpg")
        let url = files.url(for: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url)
        return .image(path: path, mediaType: "image/jpeg")
    }
}

extension Garage {
    /// Adds one of the owner's photos of the vehicle, resized and without location metadata.
    @discardableResult
    public func addImage(_ data: Data, to vehicle: Vehicle, asCover: Bool = false) throws
        -> VehicleImage
    {
        let jpeg = try PhotoPreparation.jpeg(from: data)
        let path = files.vehicleImagePath(vehicle: vehicle.id, name: "\(UUID().uuidString).jpg")
        let url = files.url(for: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try jpeg.write(to: url, options: .atomic)
        let image = VehicleImage(path: path)
        vehicle.images.append(image)
        if asCover { vehicle.cover = .image(image.id) }
        try context.save()
        return image
    }

    /// Removes the photo and its file. A vehicle whose cover it was goes back to automatic.
    public func delete(_ image: VehicleImage) throws {
        let url = files.url(for: image.path)
        if let vehicle = image.vehicle, vehicle.cover == .image(image.id) {
            vehicle.cover = .automatic
        }
        context.delete(image)
        try context.save()
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func setCover(_ cover: VehicleCover, for vehicle: Vehicle) throws {
        vehicle.cover = cover
        try context.save()
    }
}
