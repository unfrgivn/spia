import Foundation

/// A 17-character vehicle identification number (ISO 3779 / 49 CFR 565).
///
/// Length and characters are required everywhere. The check digit (position 9) is only
/// required for North American vehicles, so a mismatch is reported, not rejected.
public struct VIN: Sendable, Hashable, Codable, CustomStringConvertible {
    public let value: String
    /// Whether position 9 matches the computed check digit.
    public let checkDigitMatches: Bool

    public enum Problem: Error, Sendable, Equatable, CustomStringConvertible {
        case length(Int)
        case invalidCharacter(Character)

        public var description: String {
            switch self {
            case .length(let count): return "A VIN has 17 characters; this has \(count)."
            case .invalidCharacter(let character):
                return "“\(character)” can't appear in a VIN (I, O, and Q are never used)."
            }
        }
    }

    /// Accepts lowercase and ignores spaces and dashes.
    public init(_ raw: String) throws {
        let cleaned = raw.uppercased().filter { !$0.isWhitespace && $0 != "-" }
        guard cleaned.count == 17 else { throw Problem.length(cleaned.count) }
        for character in cleaned where Self.transliteration(character) == nil {
            throw Problem.invalidCharacter(character)
        }
        value = cleaned
        checkDigitMatches = Self.checkDigit(for: cleaned) == Array(cleaned)[8]
    }

    public var description: String { value }

    /// The check digit for a 17-character VIN of valid characters: a weighted sum of
    /// transliterated values, modulo 11, with 10 written as `X`.
    public static func checkDigit(for vin: String) -> Character? {
        let characters = Array(vin)
        guard characters.count == 17 else { return nil }
        var sum = 0
        for (character, weight) in zip(characters, weights) {
            guard let value = transliteration(character) else { return nil }
            sum += value * weight
        }
        let remainder = sum % 11
        return remainder == 10 ? "X" : Character(String(remainder))
    }

    private static let weights = [8, 7, 6, 5, 4, 3, 2, 10, 0, 9, 8, 7, 6, 5, 4, 3, 2]

    private static func transliteration(_ character: Character) -> Int? {
        if let digit = character.wholeNumberValue, character.isASCII { return digit }
        switch character {
        case "A", "J": return 1
        case "B", "K", "S": return 2
        case "C", "L", "T": return 3
        case "D", "M", "U": return 4
        case "E", "N", "V": return 5
        case "F", "W": return 6
        case "G", "P", "X": return 7
        case "H", "Y": return 8
        case "R", "Z": return 9
        default: return nil
        }
    }
}
