import CryptoKit
import Foundation
import Observation
import SpiaReference

extension SpiaFiles {
    /// Looked-up references for one vehicle: `references.json`, photos, and bulletin PDFs. All of
    /// it can be fetched again, so it's a cache, removed with the vehicle.
    public func referencesFolder(vehicle: UUID) -> URL {
        root.appendingPathComponent("References/\(vehicle.uuidString)", isDirectory: true)
    }

    func snapshotURL(vehicle: UUID) -> URL {
        referencesFolder(vehicle: vehicle).appendingPathComponent("references.json")
    }

    public func photoURL(vehicle: UUID, photo: ReferencePhoto) -> URL {
        let digest = SHA256.hash(data: Data(photo.id.utf8)).prefix(12)
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return referencesFolder(vehicle: vehicle).appendingPathComponent("Photos/\(name).jpg")
    }

    func bulletinURL(vehicle: UUID, fileName: String) -> URL {
        let safe = fileName.filter { $0.isLetter || $0.isNumber || "-_.".contains($0) }
        return referencesFolder(vehicle: vehicle).appendingPathComponent("Bulletins/\(safe)")
    }
}

extension Garage {
    /// The references last looked up for the vehicle, if any.
    public func references(for vehicle: Vehicle) -> ReferenceSnapshot? {
        VehicleReferences.load(from: files.snapshotURL(vehicle: vehicle.id))
    }
}

/// What a lookup is based on, taken from the vehicle.
public struct ReferenceInput: Sendable, Equatable {
    public var vin: String?
    public var name: String
    public var trim: String?
    public var color: PaintColor?
    public var colorName: String?
    /// A reference photo chosen as the cover, kept even when a new search doesn't find it.
    public var keepPhoto: String?

    public init(
        vin: String?, name: String, trim: String? = nil, color: PaintColor? = nil,
        colorName: String? = nil, keepPhoto: String? = nil
    ) {
        self.vin = vin
        self.name = name
        self.trim = trim
        self.color = color
        self.colorName = colorName
        self.keepPhoto = keepPhoto
    }

    /// The photo search for this input, given what the VIN decoded to.
    public func photoQuery(identity: VehicleIdentity?) -> PhotoQuery {
        if let identity {
            return PhotoQuery(identity: identity, trim: trim, color: color, colorName: colorName)
        }
        return PhotoQuery(name: name, trim: trim, color: color, colorName: colorName)
    }
}

extension Vehicle {
    public var referenceInput: ReferenceInput {
        ReferenceInput(
            vin: vin, name: name, trim: trim, color: color, colorName: colorName,
            keepPhoto: coverReferenceID)
    }
}

/// The photo standing for a vehicle, and its credit when it's a reference photo.
public struct CoverImage: Equatable {
    public let file: URL
    public let reference: ReferencePhoto?
}

/// One vehicle's references: the VIN decoded by NHTSA, its recalls, complaints, and service
/// bulletins, and photos of the model, trim, and colour from Wikimedia Commons.
///
///     VIN ──vPIC──▶ make, model, year ──┬─ NHTSA ──▶ recalls, complaints, bulletins
///                                       └─ Commons ─▶ photos ──▶ downloaded
///
/// A lookup that fails keeps what the last one found, and is retried on the next visit.
@MainActor
@Observable
public final class VehicleReferences {
    public private(set) var snapshot: ReferenceSnapshot?
    public private(set) var isRefreshing = false
    /// The bulletin whose document is downloading.
    public private(set) var openingBulletin: Int?

    public let vehicleID: UUID
    private let files: SpiaFiles
    private let client: ReferenceClient

    public init(vehicleID: UUID, files: SpiaFiles, client: ReferenceClient = ReferenceClient()) {
        self.vehicleID = vehicleID
        self.files = files
        self.client = client
        snapshot = Self.load(from: files.snapshotURL(vehicle: vehicleID))
    }

    public var identity: VehicleIdentity? { snapshot?.identity }
    public var safety: SafetyRecord? { snapshot?.safety }

    /// Photos that have been downloaded, in order.
    public var photos: [(photo: ReferencePhoto, file: URL)] {
        (snapshot?.photos ?? []).compactMap { photo in
            let file = files.photoURL(vehicle: vehicleID, photo: photo)
            return FileManager.default.fileExists(atPath: file.path) ? (photo, file) : nil
        }
    }

    /// Looks up again when nothing is cached, the VIN, trim, or colour changed, or the cache is
    /// a week old.
    public func refreshIfNeeded(_ input: ReferenceInput) async {
        if let snapshot, !snapshot.isStale(vin: input.vin),
            snapshot.photoQuery == input.photoQuery(identity: snapshot.identity)
        {
            return
        }
        await refresh(input)
    }

    public func refresh(_ input: ReferenceInput) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        var fresh = await Self.lookUp(input, previous: snapshot, client: client)
        if let keep = input.keepPhoto, !fresh.photos.contains(where: { $0.id == keep }),
            let kept = snapshot?.photos.first(where: { $0.id == keep })
        {
            fresh.photos.append(kept)
        }
        await downloadPhotos(fresh.photos, keeping: input.keepPhoto)
        snapshot = fresh
        save(fresh)
    }

    /// The owner's chosen cover, else the best reference photo that's been downloaded.
    public func cover(for vehicle: Vehicle) -> CoverImage? {
        switch vehicle.cover {
        case .image(let id):
            if let image = vehicle.images.first(where: { $0.id == id }) {
                let file = files.url(for: image.path)
                if FileManager.default.fileExists(atPath: file.path) {
                    return CoverImage(file: file, reference: nil)
                }
            }
        case .reference(let id):
            if let chosen = photos.first(where: { $0.photo.id == id }) {
                return CoverImage(file: chosen.file, reference: chosen.photo)
            }
        case .automatic:
            break
        }
        return photos.first.map { CoverImage(file: $0.file, reference: $0.photo) }
    }

    /// The bulletin's first document, downloaded once and kept.
    public func document(for bulletin: Bulletin) async throws -> URL {
        openingBulletin = bulletin.id
        defer { openingBulletin = nil }
        guard let document = try await client.documents(forBulletin: bulletin.id).first else {
            throw ReferenceError.malformed("NHTSA (no document is attached to this bulletin)")
        }
        let file = files.bulletinURL(vehicle: vehicleID, fileName: document.fileName)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        let data = try await client.get(document.url)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        return file
    }

    // MARK: - Lookup

    /// Everything that can be found for the vehicle. Pieces that fail fall back to `previous`
    /// and are named in `problems`; a lookup with problems keeps the old date, so it's retried.
    static func lookUp(
        _ input: ReferenceInput, previous: ReferenceSnapshot?, client: ReferenceClient
    ) async -> ReferenceSnapshot {
        let raw = input.vin
        var problems: [String] = []
        let sameVIN = previous?.vin == raw
        var identity: VehicleIdentity?
        if let raw, !raw.isEmpty {
            do {
                identity = try await client.identity(for: try VIN(raw))
            } catch {
                problems.append("VIN: \(error)")
                identity = sameVIN ? previous?.identity : nil
            }
        }
        var safety: SafetyRecord?
        var photos: [ReferencePhoto] = []
        let query = input.photoQuery(identity: identity)
        async let photoLookup = attempt { try await client.photos(matching: query) }
        if let identity {
            switch await attempt({ try await client.safety(for: identity) }) {
            case .success(let record): safety = record
            case .failure(let error):
                problems.append("Recalls and bulletins: \(error)")
                safety = sameVIN ? previous?.safety : nil
            }
        }
        if !query.searches.isEmpty {
            switch await photoLookup {
            case .success(let found): photos = found
            case .failure(let error):
                problems.append("Photos: \(error)")
                photos = previous?.photos ?? []
            }
        }
        let fetchedAt = problems.isEmpty ? Date.now : (previous?.fetchedAt ?? .distantPast)
        return ReferenceSnapshot(
            vin: raw, identity: identity, safety: safety, photos: photos, photoQuery: query,
            fetchedAt: fetchedAt, problems: problems)
    }

    /// Reference photos kept on disk, enough to choose a cover from.
    static let downloadedPhotos = 10

    private func downloadPhotos(_ photos: [ReferencePhoto], keeping keptPhoto: String?) async {
        let folder = files.referencesFolder(vehicle: vehicleID).appendingPathComponent("Photos")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var keep = Set<String>()
        for photo in photos.prefix(Self.downloadedPhotos)
            + photos.dropFirst(Self.downloadedPhotos)
            .filter({ $0.id == keptPhoto })
        {
            let file = files.photoURL(vehicle: vehicleID, photo: photo)
            keep.insert(file.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: file.path),
                let data = try? await client.get(photo.imageURL)
            else { continue }
            try? data.write(to: file, options: .atomic)
        }
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in existing where !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    private func save(_ snapshot: ReferenceSnapshot) {
        let url = files.snapshotURL(vehicle: vehicleID)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    nonisolated static func load(from url: URL) -> ReferenceSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ReferenceSnapshot.self, from: data)
    }
}

private func attempt<Value: Sendable>(_ body: @Sendable () async throws -> Value) async -> Result<
    Value, any Error
> {
    do { return .success(try await body()) } catch { return .failure(error) }
}
