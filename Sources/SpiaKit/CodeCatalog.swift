import Foundation

public struct CodeCatalog: Sendable, Equatable {
    public struct Source: Codable, Sendable, Equatable {
        public let repository: String
        public let commit: String
        public let license: String
    }

    public struct Entry: Codable, Sendable, Equatable {
        public let code: String
        public let title: String
        public let description: String
        public let causes: [String]
    }

    public let source: Source
    private let entries: [String: Entry]
    public var count: Int { entries.count }

    public static let bundledCatalog: CodeCatalog? = try? bundled()

    public init(data: Data) throws {
        let decoded = try JSONDecoder().decode(Raw.self, from: data)
        source = decoded.source
        entries = Dictionary(uniqueKeysWithValues: decoded.codes.map { ($0.code, $0) })
    }

    public static func bundled() throws -> CodeCatalog {
        guard
            let url = Bundle.module.url(
                forResource: "dtc-generic", withExtension: "json", subdirectory: "Catalog")
        else {
            throw NSError(
                domain: "SpiaKit.CodeCatalog", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "bundled code catalog is missing"])
        }
        return try CodeCatalog(data: Data(contentsOf: url))
    }

    public func entry(for name: CodeName) -> Entry? {
        guard name.isGeneric else { return nil }
        return entries[name.base]
    }

    private struct Raw: Codable {
        let source: Source
        let codes: [Entry]
    }
}
