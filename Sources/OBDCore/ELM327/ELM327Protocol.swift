/// Protocol numbers accepted by `ATSP`.
public enum ELM327Protocol: UInt8, CaseIterable, Sendable {
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
}
