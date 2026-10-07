/// Protocol numbers accepted by `ATSP`.
public enum ELM327Protocol: UInt8, CaseIterable, Sendable, Codable {
    case automatic = 0x0
    case j1850PWM = 0x1
    case j1850VPW = 0x2
    case iso9141 = 0x3
    case kwp2000Slow = 0x4
    case kwp2000Fast = 0x5
    case can11bit500k = 0x6
    case can29bit500k = 0x7
    case can11bit250k = 0x8
    case can29bit250k = 0x9
    case j1939 = 0xA
    case user1 = 0xB
    case user2 = 0xC

    /// The single hex digit used in `ATSP<digit>`.
    public var commandDigit: String {
        String(rawValue, radix: 16, uppercase: true)
    }

    /// Parses the digit as typed on a command line, e.g. `"6"` or `"A"`.
    public init?(commandDigit: String) {
        guard let value = UInt8(commandDigit, radix: 16) else {
            return nil
        }
        self.init(rawValue: value)
    }

    public static func parseDetection(_ response: String) -> Self? {
        let value = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let digit = value.first == "A" || value.first == "a" ? String(value.dropFirst()) : value
        guard digit.count == 1 else { return nil }
        return Self(commandDigit: digit)
    }

    public var surveyName: String {
        switch self {
        case .j1850PWM: return "J1850 PWM"
        case .j1850VPW: return "J1850 VPW"
        case .iso9141: return "ISO 9141-2"
        case .kwp2000Slow: return "ISO 14230 slow"
        case .kwp2000Fast: return "ISO 14230 fast"
        case .can11bit500k: return "11-bit, 500k CAN"
        case .can29bit500k: return "29-bit CAN"
        case .can11bit250k: return "250k CAN"
        case .can29bit250k: return "29-bit, 250k CAN"
        case .j1939: return "J1939"
        case .automatic: return "automatic protocol detection"
        case .user1: return "user protocol 1"
        case .user2: return "user protocol 2"
        }
    }

    /// Why the survey can't look for modules on a car that talks this protocol, or nil when it
    /// can (11-bit 500k CAN) or when the answer doesn't settle the bus (automatic, user
    /// protocols), in which case the survey probes as it always has.
    public var surveyUnsupportedNote: String? {
        switch self {
        case .j1850PWM, .j1850VPW, .iso9141, .kwp2000Slow, .kwp2000Fast:
            return
                "This car's computers use \(surveyName), an older protocol, so Spia read its engine computers but can't look for other modules on it."
        case .can29bit500k, .can11bit250k, .can29bit250k, .j1939:
            return
                "This car uses \(surveyName), which Spia's module search doesn't support yet, so it read the engine computers only."
        case .can11bit500k, .automatic, .user1, .user2:
            return nil
        }
    }
}
