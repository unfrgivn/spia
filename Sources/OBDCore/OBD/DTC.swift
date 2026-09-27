/// A diagnostic trouble code such as `P0133`, packed into two bytes on the wire.
///
/// ```
///  byte A                    byte B
///  7 6 | 5 4 | 3 2 1 0  |  7 6 5 4 | 3 2 1 0
///  sys | dig |  digit   |   digit  |  digit
///  00 P  0-3    hex         hex        hex
///  01 C
///  10 B
///  11 U
/// ```
public struct DTC: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum System: String, Codable, Sendable {
        case powertrain = "P"
        case chassis = "C"
        case body = "B"
        case network = "U"
    }

    public let system: System
    /// The four characters after the system letter, e.g. `0133`.
    public let digits: String

    public var description: String {
        system.rawValue + digits
    }

    /// Nil unless exactly two bytes are given, and nil for the `00 00` padding ECUs emit.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 2, bytes != [0, 0] else {
            return nil
        }
        let systems: [System] = [.powertrain, .chassis, .body, .network]
        system = systems[Int(bytes[0] >> 6)]
        digits =
            String((bytes[0] >> 4) & 0x3)
            + String(bytes[0] & 0xF, radix: 16, uppercase: true)
            + String(bytes[1] >> 4, radix: 16, uppercase: true)
            + String(bytes[1] & 0xF, radix: 16, uppercase: true)
    }

    /// Parses the human form, e.g. `"P0133"`. Case-insensitive.
    public init?(code: String) {
        let upper = code.uppercased()
        guard upper.count == 5, let first = upper.first,
            let system = System(rawValue: String(first))
        else {
            return nil
        }
        let rest = String(upper.dropFirst())
        guard let second = rest.first, ("0"..."3").contains(second),
            rest.allSatisfy(\.isHexDigit)
        else {
            return nil
        }
        self.system = system
        self.digits = rest
    }

    /// The two-byte wire form.
    public var bytes: [UInt8] {
        let systems: [System] = [.powertrain, .chassis, .body, .network]
        let systemBits = UInt8(systems.firstIndex(of: system) ?? 0) << 6
        let nibbles = digits.compactMap { UInt8(String($0), radix: 16) }
        guard nibbles.count == 4 else {
            return [systemBits, 0]
        }
        return [systemBits | (nibbles[0] << 4) | nibbles[1], (nibbles[2] << 4) | nibbles[3]]
    }
}
