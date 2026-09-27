import Foundation

/// Everything Spia has looked up about one vehicle, as of `fetchedAt`.
public struct ReferenceSnapshot: Codable, Sendable, Equatable {
    /// The VIN the lookup used, so a changed VIN triggers a new one.
    public var vin: String?
    public var identity: VehicleIdentity?
    public var safety: SafetyRecord?
    public var photos: [ReferencePhoto]
    /// What the photos were searched for, so a changed trim or colour searches again.
    public var photoQuery: PhotoQuery?
    public var fetchedAt: Date
    /// What couldn't be loaded last time, in plain words.
    public var problems: [String]

    public init(
        vin: String?, identity: VehicleIdentity?, safety: SafetyRecord?,
        photos: [ReferencePhoto], photoQuery: PhotoQuery? = nil, fetchedAt: Date,
        problems: [String]
    ) {
        self.vin = vin
        self.identity = identity
        self.safety = safety
        self.photos = photos
        self.photoQuery = photoQuery
        self.fetchedAt = fetchedAt
        self.problems = problems
    }

    /// Recalls and bulletins change rarely; a week is fresh enough.
    public func isStale(now: Date = .now, vin: String?) -> Bool {
        vin != self.vin || now.timeIntervalSince(fetchedAt) > 7 * 24 * 3600
    }
}

/// The network side: plain requests to NHTSA and Wikimedia, parsed by the functions beside it.
public struct ReferenceClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func identity(for vin: VIN) async throws -> VehicleIdentity {
        var identity = try VPIC.identity(from: try await get(try VPIC.decodeURL(vin: vin.value)))
        identity.vin = vin.value
        return identity
    }

    public func safety(for identity: VehicleIdentity) async throws -> SafetyRecord {
        try NHTSA.safety(
            from: try await get(
                try NHTSA.safetyURL(
                    make: identity.make, model: identity.model, year: identity.modelYear)))
    }

    /// The best photos across the query's searches, run together. Fails only if every
    /// search fails.
    public func photos(matching query: PhotoQuery) async throws -> [ReferencePhoto] {
        let searches = query.searches
        let results = await withTaskGroup(of: (Int, Result<[Commons.Candidate], any Error>).self) {
            group in
            for (index, search) in searches.enumerated() {
                group.addTask {
                    do {
                        let data = try await get(try Commons.searchURL(query: search))
                        return (index, .success(try Commons.candidates(from: data)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results: [(Int, Result<[Commons.Candidate], any Error>)] = []
            for await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
        var candidates: [[Commons.Candidate]] = []
        var failure: (any Error)?
        for result in results {
            switch result {
            case .success(let found): candidates.append(found)
            case .failure(let error): failure = failure ?? error
            }
        }
        if candidates.isEmpty, let failure { throw failure }
        return Commons.rank(candidates, for: query)
    }

    public func documents(forBulletin id: Int) async throws -> [BulletinDocument] {
        try NHTSA.bulletinDocuments(from: try await get(try NHTSA.bulletinDocumentsURL(id: id)))
    }

    public func get(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(Commons.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ReferenceError.http(status: http.statusCode, host: url.host ?? "The server")
        }
        return data
    }
}
