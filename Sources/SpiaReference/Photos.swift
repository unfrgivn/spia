import Foundation

/// A photo of the model from Wikimedia Commons. Every one is freely licensed but most licenses
/// require credit, so `artist` and `license` must be shown with it.
public struct ReferencePhoto: Codable, Sendable, Equatable, Identifiable {
    /// The Commons file title, e.g. `File:2017 Maserati Ghibli (M157) Automatic 3.0 Front.jpg`.
    public let id: String
    /// Resized for display (at most 1280 px wide).
    public let imageURL: URL
    /// The file's page on Commons, with the full license and author details.
    public let pageURL: URL
    public let license: String
    public let licenseURL: URL?
    /// Plain text; Commons supplies it as HTML.
    public let artist: String
    public let width: Int
    public let height: Int

    /// `2017 Maserati Ghibli (M157) Automatic 3.0 Front`
    public var caption: String {
        var name = id.hasPrefix("File:") ? String(id.dropFirst(5)) : id
        if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    /// `Makizox · CC BY-SA 4.0`
    public var credit: String { artist.isEmpty ? license : "\(artist) · \(license)" }
}

/// A car's paint, as a family the user picks. VINs don't encode colour.
public enum PaintColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case black, white, silver, gray, blue, red, green, brown, beige, gold, yellow, orange, purple

    public var id: String { rawValue }

    public var displayName: String { rawValue == "gray" ? "Gray" : rawValue.capitalized }

    /// The word searched for.
    public var searchWord: String { rawValue == "gray" ? "grey" : rawValue }

    /// Words photo titles and descriptions use for it, including the Italian and German names
    /// common on Commons (e.g. Maserati's "Grigio Maratea", "Blu Emozione").
    public var synonyms: [String] {
        switch self {
        case .black: return ["black", "nero", "schwarz", "noir"]
        case .white: return ["white", "bianco", "weiss", "weiß", "blanc"]
        case .silver: return ["silver", "argento", "silber", "argent"]
        case .gray: return ["grey", "gray", "grigio", "grau", "gris", "graphite", "anthracite"]
        case .blue: return ["blue", "blu", "blau", "bleu", "navy"]
        case .red: return ["red", "rosso", "rot", "rouge"]
        case .green: return ["green", "verde", "grün", "vert"]
        case .brown: return ["brown", "bronze", "marrone", "braun"]
        case .beige: return ["beige", "champagne", "sand"]
        case .gold: return ["gold", "oro", "golden"]
        case .yellow: return ["yellow", "giallo", "gelb", "jaune"]
        case .orange: return ["orange", "arancio", "arancione"]
        case .purple: return ["purple", "violet", "viola", "lila"]
        }
    }
}

/// What to look for: the model, and as much about this car as is known.
public struct PhotoQuery: Codable, Sendable, Equatable {
    public var make: String?
    public var model: String?
    /// Used when there's no decoded make and model, e.g. the vehicle's name.
    public var name: String?
    public var year: Int?
    public var series: String?
    public var trim: String?
    public var color: PaintColor?
    /// The maker's paint name, e.g. `Blu Emozione`.
    public var colorName: String?

    public init(
        make: String? = nil, model: String? = nil, name: String? = nil, year: Int? = nil,
        series: String? = nil, trim: String? = nil, color: PaintColor? = nil,
        colorName: String? = nil
    ) {
        func clean(_ text: String?) -> String? {
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        self.make = clean(make)
        self.model = clean(model)
        self.name = clean(name)
        self.year = year
        self.series = clean(series)
        self.trim = clean(trim)
        self.color = color
        self.colorName = clean(colorName)
    }

    public init(
        identity: VehicleIdentity, trim: String?, color: PaintColor?, colorName: String?
    ) {
        self.init(
            make: identity.make, model: identity.model, year: identity.modelYear,
            series: identity.series, trim: trim ?? identity.trim, color: color,
            colorName: colorName)
    }

    /// `Maserati Ghibli`, or the vehicle's name.
    public var subject: String {
        let parts = [make, model].compactMap { $0 }
        return parts.isEmpty ? (name ?? "") : parts.joined(separator: " ")
    }

    /// `2017 Maserati Ghibli S Q4 · Blue`
    public var summary: String {
        let car = ([year.map(String.init)] + [subject, trim]).compactMap { $0 }.filter {
            !$0.isEmpty
        }.joined(separator: " ")
        let paint = colorName ?? color?.displayName
        return [car, paint].compactMap { $0 }.joined(separator: " · ")
    }

    /// Searches from most to least specific. Results are merged and ranked, so a narrow search
    /// that finds nothing costs nothing.
    public var searches: [String] {
        let subject = self.subject
        guard !subject.isEmpty else { return [] }
        let dated = year.map { "\($0) \(subject)" } ?? subject
        let trimmed = trim.map { "\(subject) \"\($0)\"" }
        let paint = colorName.map { "\"\($0)\"" } ?? color?.searchWord
        var searches: [String] = []
        if let trimmed, let paint { searches.append("\(trimmed) \(paint)") }
        if let trimmed { searches.append(trimmed) }
        if let paint { searches.append("\(dated) \(paint)") }
        searches.append(dated)
        var seen = Set<String>()
        return searches.filter { seen.insert($0).inserted }
    }
}

/// Wikimedia Commons, searched for photos of the make and model.
public enum Commons {
    /// The User-Agent Wikimedia asks every client to send, with a way to reach the developer.
    public static let userAgent = "Spia/1.0 (https://github.com/unfrgivn/spia)"

    public static func searchURL(query: String, limit: Int = 20) throws -> URL {
        try https(
            "commons.wikimedia.org", "/w/api.php",
            [
                ("action", "query"), ("format", "json"), ("formatversion", "2"),
                ("generator", "search"), ("gsrsearch", "\(query) filetype:bitmap"),
                ("gsrnamespace", "6"), ("gsrlimit", String(limit)),
                ("prop", "imageinfo|categories"), ("clshow", "!hidden"), ("cllimit", "max"),
                ("iiprop", "url|size|mime|extmetadata"), ("iiurlwidth", "1280"),
                (
                    "iiextmetadatafilter",
                    "LicenseShortName|LicenseUrl|Artist|AttributionRequired|ImageDescription"
                ),
            ])
    }

    /// A search result with the text it's ranked on.
    public struct Candidate: Sendable, Equatable {
        public let photo: ReferencePhoto
        /// Position in its search's results.
        public let position: Int
        let title: String
        let description: String
        let categories: [String]
    }

    /// JPEG and PNG photos at least 640 px wide, in search order.
    public static func candidates(from data: Data) throws -> [Candidate] {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw ReferenceError.malformed("Wikimedia Commons")
        }
        return (reply.query?.pages ?? []).sorted { $0.index < $1.index }.compactMap { page in
            guard let info = page.imageinfo?.first,
                ["image/jpeg", "image/png"].contains(info.mime), info.width >= 640,
                let image = URL(string: info.thumburl ?? info.url),
                let pageURL = URL(string: info.descriptionurl)
            else { return nil }
            let metadata = info.extmetadata ?? [:]
            let photo = ReferencePhoto(
                id: page.title, imageURL: image, pageURL: pageURL,
                license: metadata["LicenseShortName"]?.value ?? "See the file page",
                licenseURL: metadata["LicenseUrl"].flatMap { URL(string: $0.value) },
                artist: plainText(metadata["Artist"]?.value ?? ""), width: info.width,
                height: info.height)
            return Candidate(
                photo: photo, position: page.index, title: page.title,
                description: plainText(metadata["ImageDescription"]?.value ?? ""),
                categories: (page.categories ?? []).map(\.title))
        }
    }

    /// The best photos for `query` across the results of its `searches`.
    ///
    /// A photo must mention the model (in its title, description, or categories) and be of
    /// the right generation:
    /// - Years in categories naming the make or model (e.g. "2017 Maserati automobiles") are
    ///   model years; otherwise years in the title are used, which are often when the photo
    ///   was taken. A year more than four from the model year means another generation.
    /// - Photos that clearly fit (the model year, or the trim in the title) show which of the
    ///   model's categories are this generation (e.g. "Maserati Ghibli III"). A photo filed
    ///   only under the model's other categories ("Maserati Ghibli I") is dropped.
    ///
    /// The rest are scored: the trim in the title 6 (elsewhere 3), the colour in the title 4
    /// (elsewhere 3), the model year 2, the platform code 1. Ties keep the order the searches
    /// returned them in, most specific search first.
    public static func rank(_ results: [[Candidate]], for query: PhotoQuery, limit: Int = 12)
        -> [ReferencePhoto]
    {
        let trusted = generationCategories(results.flatMap { $0 }, for: query)
        var best: [String: (candidate: Candidate, order: Int, score: Int)] = [:]
        for (searchIndex, candidates) in results.enumerated() {
            for candidate in candidates {
                guard let score = score(candidate, for: query, generation: trusted) else {
                    continue
                }
                let order = searchIndex * 1000 + candidate.position
                if let existing = best[candidate.photo.id], existing.order <= order { continue }
                best[candidate.photo.id] = (candidate, order, score)
            }
        }
        return best.values.sorted {
            $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score
        }.prefix(limit).map(\.candidate.photo)
    }

    /// Nil when the photo doesn't fit the query at all.
    static func score(_ candidate: Candidate, for query: PhotoQuery, generation: Set<String>?)
        -> Int?
    {
        let title = Text(candidate.title)
        let rest = Text(candidate.description + " " + candidate.categories.joined(separator: " "))
        if let model = query.model {
            guard title.contains(model) || rest.contains(model) else { return nil }
            let own = modelCategories(candidate, model: model)
            if let generation, !own.isEmpty, own.isDisjoint(with: generation) { return nil }
        }
        let fit = yearFit(candidate, for: query)
        guard fit != .otherGeneration else { return nil }
        var score = 0
        if let trim = query.trim {
            score += title.contains(trim) ? 6 : rest.contains(trim) ? 3 : 0
        }
        let paints = (query.colorName.map { [$0] } ?? []) + (query.color?.synonyms ?? [])
        if paints.contains(where: title.contains) {
            score += 4
        } else if paints.contains(where: rest.contains) {
            score += 3
        }
        if fit == .modelYear { score += 2 }
        if let series = query.series, title.contains(series) || rest.contains(series) {
            score += 1
        }
        return score
    }

    enum YearFit { case modelYear, near, otherGeneration, unknown }

    static func yearFit(_ candidate: Candidate, for query: PhotoQuery) -> YearFit {
        guard let year = query.year else { return .unknown }
        let names = [query.make, query.model].compactMap { $0 }
        let categoryYears = candidate.categories.filter { category in
            let text = Text(category)
            return names.contains(where: text.contains)
        }.flatMap(years(in:))
        let years = categoryYears.isEmpty ? Self.years(in: candidate.title) : categoryYears
        if years.contains(year) { return .modelYear }
        if years.isEmpty { return .unknown }
        return years.contains { abs($0 - year) <= 4 } ? .near : .otherGeneration
    }

    /// The model's categories on photos that clearly fit, or nil when none do.
    static func generationCategories(_ candidates: [Candidate], for query: PhotoQuery)
        -> Set<String>?
    {
        guard let model = query.model else { return nil }
        let confident = candidates.filter { candidate in
            yearFit(candidate, for: query) == .modelYear
                || query.trim.map { Text(candidate.title).contains($0) } == true
        }
        let categories = Set(confident.flatMap { modelCategories($0, model: model) })
        return categories.isEmpty ? nil : categories
    }

    private static func modelCategories(_ candidate: Candidate, model: String) -> Set<String> {
        Set(candidate.categories.filter { Text($0).contains(model) })
    }

    /// Text normalised for matching whole words and phrases, case- and punctuation-blind.
    /// `S Q4` also matches `SQ4`.
    struct Text {
        let words: String
        let compact: String

        init(_ raw: String) {
            let tokens = raw.lowercased().split { !$0.isLetter && !$0.isNumber }
            words = " " + tokens.joined(separator: " ") + " "
            compact = tokens.joined()
        }

        func contains(_ phrase: String) -> Bool {
            let tokens = phrase.lowercased().split { !$0.isLetter && !$0.isNumber }
            guard !tokens.isEmpty else { return false }
            if words.contains(" " + tokens.joined(separator: " ") + " ") { return true }
            return tokens.count > 1 && compact.contains(tokens.joined())
        }
    }

    /// Four-digit years standing alone in a file name, e.g. `(1971)` but not `35887002245`.
    static func years(in title: String) -> [Int] {
        title.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }.compactMap { run in
            guard run.count == 4, run.hasPrefix("19") || run.hasPrefix("20") else { return nil }
            return Int(run)
        }
    }

    /// Strips tags and decodes the few entities Commons uses in author fields.
    static func plainText(_ html: String) -> String {
        var text = html.replacing(/<[^>]+>/, with: "")
        for (entity, character) in [
            ("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"),
            ("&nbsp;", " "),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private struct Reply: Decodable {
        struct Query: Decodable { let pages: [Page] }
        struct Page: Decodable {
            let index: Int
            let title: String
            let imageinfo: [Info]?
            let categories: [Category]?
        }
        struct Category: Decodable { let title: String }
        struct Info: Decodable {
            let url: String
            let thumburl: String?
            let descriptionurl: String
            let mime: String
            let width: Int
            let height: Int
            let extmetadata: [String: Value]?
        }
        struct Value: Decodable {
            let value: String

            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                value = (try? container.decode(String.self, forKey: .value)) ?? ""
            }

            enum CodingKeys: String, CodingKey { case value }
        }
        let query: Query?
    }
}
