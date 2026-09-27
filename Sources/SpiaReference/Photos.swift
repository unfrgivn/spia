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

/// Wikimedia Commons, searched for photos of the make and model.
public enum Commons {
    /// The User-Agent Wikimedia asks every client to send, with a way to reach the developer.
    public static let userAgent = "Spia/1.0 (https://github.com/unfrgivn/spia)"

    public static func searchURL(query: String, limit: Int = 12) throws -> URL {
        try https(
            "commons.wikimedia.org", "/w/api.php",
            [
                ("action", "query"), ("format", "json"), ("formatversion", "2"),
                ("generator", "search"), ("gsrsearch", "\(query) filetype:bitmap"),
                ("gsrnamespace", "6"), ("gsrlimit", String(limit)), ("prop", "imageinfo"),
                ("iiprop", "url|size|mime|extmetadata"), ("iiurlwidth", "1280"),
                ("iiextmetadatafilter", "LicenseShortName|LicenseUrl|Artist|AttributionRequired"),
            ])
    }

    public static func query(for identity: VehicleIdentity) -> String {
        "\(identity.modelYear) \(identity.make) \(identity.model)"
    }

    /// Photos in search order, keeping JPEG and PNG photos at least 640 px wide. With a
    /// `modelYear`, files naming a year more than four years away are dropped (an older
    /// generation, usually) and files naming the model year come first.
    public static func photos(from data: Data, modelYear: Int? = nil, limit: Int = 8) throws
        -> [ReferencePhoto]
    {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            throw ReferenceError.malformed("Wikimedia Commons")
        }
        let candidates = (reply.query?.pages ?? []).sorted { $0.index < $1.index }.compactMap {
            page -> (photo: ReferencePhoto, years: [Int])? in
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
            return (photo, years(in: page.title))
        }
        guard let modelYear else { return Array(candidates.map(\.photo).prefix(limit)) }
        let fitting = candidates.filter { candidate in
            candidate.years.allSatisfy { abs($0 - modelYear) <= 4 }
        }
        let named = fitting.filter { $0.years.contains(modelYear) }
        let others = fitting.filter { !$0.years.contains(modelYear) }
        return Array((named + others).map(\.photo).prefix(limit))
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
        }
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
