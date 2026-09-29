import Foundation
import OBDCore

/// The vehicle identity used to match a bounded catalog platform.
public struct CatalogVehicle: Sendable, Equatable {
    public let make: String
    public let model: String
    public let year: Int

    public init(make: String, model: String, year: Int) {
        self.make = make
        self.model = model
        self.year = year
    }
}

public enum ModuleProvenance: String, Codable, Sendable, Equatable {
    case observed
    case reference
}

public struct CatalogModule: Sendable, Equatable {
    public let label: String
    public let target: ModuleTarget
    public let provenance: ModuleProvenance
    public let source: String
}

public struct CatalogPlatform: Sendable, Equatable {
    public let name: String
    public let modules: [CatalogModule]
}

public enum ModuleCatalogError: Error, Equatable, Sendable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case malformed(String)
    case unknownBus(String)
    case unknownProvenance(String)
    case invalidTarget(String)
    case duplicateTarget(String)
    case invalidYearRange
    case emptyField(String)
    case duplicateMake(String)
    case overlappingPlatforms(String)

    public var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version):
            return "module catalog schema version \(version) is not supported"
        case .malformed(let detail): return "malformed module catalog: \(detail)"
        case .unknownBus(let bus): return "module catalog has unknown bus \"\(bus)\""
        case .unknownProvenance(let provenance):
            return "module catalog has unknown provenance \"\(provenance)\""
        case .invalidTarget(let target): return "module catalog has invalid target \"\(target)\""
        case .duplicateTarget(let target): return "module catalog repeats target \"\(target)\""
        case .invalidYearRange:
            return "module catalog has a year range whose first year is after its last"
        case .emptyField(let field): return "module catalog has an empty \(field)"
        case .duplicateMake(let make): return "module catalog lists the make \"\(make)\" twice"
        case .overlappingPlatforms(let model):
            return "module catalog has two platforms for \"\(model)\" in overlapping years"
        }
    }
}

/// Bounded, shipped make and platform knowledge. This is data, not a vehicle discovery result.
public struct ModuleCatalog: Sendable, Equatable {
    public let schemaVersion: Int
    public let catalogVersion: String
    public let makes: [Make]

    public struct Make: Sendable, Equatable {
        public let make: String
        public let aliases: [String]
        public let platforms: [Platform]
    }

    public struct Platform: Sendable, Equatable {
        public let name: String
        public let models: [String]
        public let firstYear: Int
        public let lastYear: Int
        public let modules: [CatalogModule]
        public let source: String?
    }

    public init(data: Data) throws {
        let raw: RawCatalog
        do {
            raw = try JSONDecoder().decode(RawCatalog.self, from: data)
        } catch {
            throw ModuleCatalogError.malformed(error.localizedDescription)
        }
        guard raw.schemaVersion == 1 else {
            throw ModuleCatalogError.unsupportedSchemaVersion(raw.schemaVersion)
        }
        guard !raw.catalogVersion.isEmpty else {
            throw ModuleCatalogError.emptyField("catalog version")
        }
        schemaVersion = raw.schemaVersion
        catalogVersion = raw.catalogVersion
        makes = try raw.makes.map(Self.make)
        try Self.checkNoShadowing(makes)
    }

    public static func bundled() throws -> ModuleCatalog {
        guard
            let url = Bundle.module.url(
                forResource: "modules", withExtension: "json", subdirectory: "Catalog")
        else { throw ModuleCatalogError.malformed("bundled modules.json is missing") }
        return try ModuleCatalog(data: Data(contentsOf: url))
    }

    public func match(_ vehicle: CatalogVehicle) -> Platform? {
        let make = Self.normalize(vehicle.make)
        let model = Self.normalize(vehicle.model)
        return makes.first(where: {
            Self.normalize($0.make) == make
                || $0.aliases.contains { Self.normalize($0) == make }
        })?
        .platforms.first {
            $0.models.contains { Self.normalize($0) == model }
                && ($0.firstYear...$0.lastYear).contains(vehicle.year)
        }
    }

    private static func make(_ raw: RawMake) throws -> Make {
        guard !normalize(raw.make).isEmpty, raw.aliases.allSatisfy({ !normalize($0).isEmpty })
        else { throw ModuleCatalogError.emptyField("make") }
        guard !raw.platforms.isEmpty else { throw ModuleCatalogError.emptyField("platforms") }
        return Make(
            make: raw.make, aliases: raw.aliases,
            platforms: try raw.platforms.map(Self.platform))
    }

    /// `match` takes the first make and the first platform that fit, so a make listed twice, or
    /// two platforms claiming one model in overlapping years, would leave the later one unused.
    private static func checkNoShadowing(_ makes: [Make]) throws {
        var names = Set<String>()
        for make in makes {
            for name in [make.make] + make.aliases {
                guard names.insert(normalize(name)).inserted else {
                    throw ModuleCatalogError.duplicateMake(name)
                }
            }
            for (index, platform) in make.platforms.enumerated() {
                for other in make.platforms.dropFirst(index + 1)
                where platform.firstYear <= other.lastYear && other.firstYear <= platform.lastYear {
                    let models = Set(other.models.map(normalize))
                    let shared = platform.models.first { models.contains(normalize($0)) }
                    if let shared { throw ModuleCatalogError.overlappingPlatforms(shared) }
                }
            }
        }
    }

    private static func platform(_ raw: RawPlatform) throws -> Platform {
        guard !raw.name.isEmpty else { throw ModuleCatalogError.emptyField("platform name") }
        guard !raw.models.isEmpty, raw.models.allSatisfy({ !normalize($0).isEmpty }) else {
            throw ModuleCatalogError.emptyField("models")
        }
        guard raw.years.first <= raw.years.last else {
            throw ModuleCatalogError.invalidYearRange
        }
        guard !raw.modules.isEmpty else { throw ModuleCatalogError.emptyField("modules") }
        var seen = Set<ModuleTarget>()
        let modules = try raw.modules.map { module -> CatalogModule in
            guard !module.label.isEmpty else { throw ModuleCatalogError.emptyField("module label") }
            guard let bus = CANBus(rawValue: module.bus) else {
                throw ModuleCatalogError.unknownBus(module.bus)
            }
            guard let provenance = ModuleProvenance(rawValue: module.provenance) else {
                throw ModuleCatalogError.unknownProvenance(module.provenance)
            }
            guard let request = UInt32(module.request, radix: 16),
                let reply = UInt32(module.reply, radix: 16)
            else { throw ModuleCatalogError.invalidTarget("\(module.request) -> \(module.reply)") }
            let target: ModuleTarget
            do { target = try ModuleTarget(bus: bus, request: request, response: reply) } catch {
                throw ModuleCatalogError.invalidTarget(error.localizedDescription)
            }
            guard seen.insert(target).inserted else {
                throw ModuleCatalogError.duplicateTarget("\(module.request) -> \(module.reply)")
            }
            return CatalogModule(
                label: module.label, target: target, provenance: provenance, source: module.source)
        }
        return Platform(
            name: raw.name, models: raw.models, firstYear: raw.years.first,
            lastYear: raw.years.last, modules: modules, source: raw.source)
    }

    private static func normalize(_ value: String) -> String {
        var result = ""
        var space = false
        for scalar in value.unicodeScalars {
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if space && !result.isEmpty { result.append(" ") }
                result.append(String(scalar).lowercased())
                space = false
            } else {
                space = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}

private struct RawCatalog: Decodable {
    let schemaVersion: Int
    let catalogVersion: String
    let makes: [RawMake]
}

private struct RawMake: Decodable {
    let make: String
    let aliases: [String]
    let platforms: [RawPlatform]
}

private struct RawPlatform: Decodable {
    let name: String
    let models: [String]
    let years: RawYears
    let modules: [RawModule]
    let source: String?
}

private struct RawYears: Decodable {
    let first: Int
    let last: Int
}

private struct RawModule: Decodable {
    let label: String
    let bus: String
    let request: String
    let reply: String
    let provenance: String
    let source: String
}
