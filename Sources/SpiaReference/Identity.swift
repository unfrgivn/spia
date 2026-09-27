import Foundation

/// What a VIN says about the car, from NHTSA's vPIC decoder.
public struct VehicleIdentity: Codable, Sendable, Equatable {
    public var vin: String
    public var make: String
    public var model: String
    public var modelYear: Int
    public var trim: String?
    /// The maker's platform or generation code, e.g. `M157`.
    public var series: String?
    public var bodyClass: String?
    public var driveType: String?
    public var engine: String?
    public var fuel: String?
    public var transmission: String?
    public var manufacturer: String?
    public var plantCountry: String?
    /// What the decoder flagged, e.g. a check digit that doesn't calculate.
    public var decoderNotes: [String]

    public init(
        vin: String, make: String, model: String, modelYear: Int, trim: String? = nil,
        series: String? = nil, bodyClass: String? = nil, driveType: String? = nil,
        engine: String? = nil, fuel: String? = nil, transmission: String? = nil,
        manufacturer: String? = nil, plantCountry: String? = nil, decoderNotes: [String] = []
    ) {
        self.vin = vin
        self.make = make
        self.model = model
        self.modelYear = modelYear
        self.trim = trim
        self.series = series
        self.bodyClass = bodyClass
        self.driveType = driveType
        self.engine = engine
        self.fuel = fuel
        self.transmission = transmission
        self.manufacturer = manufacturer
        self.plantCountry = plantCountry
        self.decoderNotes = decoderNotes
    }

    /// `2017 Maserati Ghibli`
    public var title: String { "\(modelYear) \(make) \(model)" }

    /// `Sport · M157 · 3.0 L V6 (M156B) · AWD`
    public var detail: String {
        [trim, series, engine, driveType].compactMap { $0 }.joined(separator: " · ")
    }

    /// One line for the assistant.
    public var summary: String {
        var parts = [title]
        parts += [trim, series, bodyClass, engine, transmission, driveType, fuel].compactMap { $0 }
        if let plantCountry { parts.append("built in \(plantCountry.capitalized)") }
        return parts.joined(separator: ", ")
    }
}

public enum ReferenceError: Error, Sendable, Equatable, CustomStringConvertible {
    case http(status: Int, host: String)
    case notDecoded(String)
    case malformed(String)
    case badRequest(String)

    public var description: String {
        switch self {
        case .http(let status, let host): return "\(host) answered with HTTP \(status)."
        case .notDecoded(let reason): return "NHTSA couldn't decode the VIN: \(reason)"
        case .malformed(let what): return "The reply from \(what) couldn't be read."
        case .badRequest(let what): return "Spia couldn't build the request for \(what)."
        }
    }
}

/// An HTTPS URL from parts. Only fails for a path that isn't absolute, which is a bug here.
func https(_ host: String, _ path: String, _ query: [(String, String)] = []) throws -> URL {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = path
    if !query.isEmpty {
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
    }
    guard let url = components.url else { throw ReferenceError.badRequest(host + path) }
    return url
}

/// NHTSA's Product Information Catalog (vPIC). No key; free for any use.
public enum VPIC {
    public static func decodeURL(vin: String) throws -> URL {
        try https(
            "vpic.nhtsa.dot.gov", "/api/vehicles/DecodeVinValues/\(vin)", [("format", "json")])
    }

    /// Reads a `DecodeVinValues` reply. Throws when make, model, or year are missing, which is
    /// how vPIC reports a VIN it can't place.
    public static func identity(from data: Data) throws -> VehicleIdentity {
        struct Reply: Decodable {
            let results: [[String: String?]]
            enum CodingKeys: String, CodingKey { case results = "Results" }
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data),
            let fields = reply.results.first
        else { throw ReferenceError.malformed("NHTSA's VIN decoder") }
        func field(_ name: String) -> String? {
            guard let value = fields[name] ?? nil else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed == "Not Applicable" ? nil : trimmed
        }
        let codes = (field("ErrorCode") ?? "0").split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard let make = field("Make"), let model = field("Model"),
            let year = field("ModelYear").flatMap(Int.init)
        else {
            throw ReferenceError.notDecoded(field("ErrorText") ?? "no make, model, or year")
        }
        let notes =
            codes == ["0"]
            ? []
            : (field("ErrorText") ?? "").split(separator: ";").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        return VehicleIdentity(
            vin: field("VIN") ?? "", make: displayMake(make), model: model, modelYear: year,
            trim: field("Trim"), series: field("Series"), bodyClass: field("BodyClass"),
            driveType: field("DriveType").map(shortDrive),
            engine: engine(
                litres: field("DisplacementL"), cylinders: field("EngineCylinders"),
                layout: field("EngineConfiguration"), code: field("EngineModel")),
            fuel: field("FuelTypePrimary"), transmission: field("TransmissionStyle"),
            manufacturer: field("Manufacturer"), plantCountry: field("PlantCountry"),
            decoderNotes: notes)
    }

    /// vPIC writes makes in capitals. Most read better in title case; a few are initialisms.
    static func displayMake(_ make: String) -> String {
        let initialisms: Set<String> = ["BMW", "GMC", "MINI", "MG", "AMC", "DS", "SRT", "VW"]
        return make.split(separator: " ").map { word in
            let upper = word.uppercased()
            if initialisms.contains(upper) { return upper }
            return upper.split(separator: "-", omittingEmptySubsequences: false).map {
                $0.prefix(1) + $0.dropFirst().lowercased()
            }.joined(separator: "-")
        }.joined(separator: " ")
    }

    /// `AWD/All-Wheel Drive` → `AWD`
    static func shortDrive(_ drive: String) -> String {
        drive.split(separator: "/").first.map(String.init) ?? drive
    }

    /// `3.0 L V6 (M156B)` from vPIC's separate engine fields.
    static func engine(litres: String?, cylinders: String?, layout: String?, code: String?)
        -> String?
    {
        var words: [String] = []
        if let litres = litres.flatMap(Double.init) {
            words.append(
                String(format: "%.1f L", locale: Locale(identifier: "en_US_POSIX"), litres))
        }
        if let cylinders = cylinders.flatMap(Int.init) {
            switch layout {
            case "V-Shaped": words.append("V\(cylinders)")
            case "In-Line": words.append("inline-\(cylinders)")
            case "Horizontally opposed (boxer)": words.append("flat-\(cylinders)")
            default: words.append("\(cylinders)-cylinder")
            }
        }
        if let code { words.append("(\(code))") }
        return words.isEmpty ? nil : words.joined(separator: " ")
    }
}
