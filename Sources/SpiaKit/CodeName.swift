import Foundation

/// A trouble code as people read it. UDS gives three bytes (`80 01 1B`), which SAE J2012 prints as
/// `B0001-1B`; J1979 gives the letter and four digits (`P0133`).
public struct CodeName: Equatable, Sendable, Hashable {
    public enum System: String, Sendable, Codable {
        case powertrain = "P"
        case chassis = "C"
        case body = "B"
        case network = "U"
    }
    public let raw: String
    public let base: String
    public let failureType: UInt8?
    public let system: System
    public let isGeneric: Bool

    public var failureTypeMeaning: String? {
        failureType.flatMap(FailureType.meaning(of:))
    }

    public var failureTypeLabel: String? {
        failureType.map(FailureType.label(for:))
    }

    public var printed: String {
        failureType.map { String(format: "%@-%02X", base, $0) } ?? base
    }

    public init?(_ raw: String) {
        let value = raw.uppercased()
        self.raw = raw
        if value.count == 6, value.allSatisfy({ $0.isHexDigit }), let bytes = Self.bytes(value) {
            let system: System
            switch bytes[0] >> 6 {
            case 0: system = .powertrain
            case 1: system = .chassis
            case 2: system = .body
            case 3: system = .network
            default: return nil
            }
            self.system = system
            self.base =
                "\(system.rawValue)\((bytes[0] >> 4) & 3)\(String(format: "%X", bytes[0] & 15))\(String(format: "%02X", bytes[1]))"
            self.failureType = bytes[2]
            self.isGeneric = Self.generic(system: system, base: self.base)
        } else if value.count == 5,
            let first = value.first,
            let system = System(rawValue: String(first)),
            value.dropFirst().allSatisfy({ $0.isNumber })
        {
            self.system = system
            self.base = value
            self.failureType = nil
            self.isGeneric = Self.generic(system: system, base: value)
        } else {
            return nil
        }
    }

    private static func bytes(_ value: String) -> [UInt8]? {
        stride(from: 0, to: value.count, by: 2).compactMap { index in
            let start = value.index(value.startIndex, offsetBy: index)
            let end = value.index(start, offsetBy: 2)
            return UInt8(value[start..<end], radix: 16)
        }
    }

    private static func generic(system: System, base: String) -> Bool {
        let suffix = String(base.dropFirst())
        switch system {
        case .powertrain:
            return suffix.hasPrefix("0") || suffix.hasPrefix("2")
                || (34...39).contains(Int(suffix.prefix(2)) ?? -1)
        case .body, .chassis: return suffix.hasPrefix("0")
        case .network: return suffix.hasPrefix("0") || suffix.hasPrefix("3")
        }
    }
}
