import Foundation

/// An OBD request as sent to the adapter: service byte, then optional PID and frame number.
public struct OBDRequest: Equatable, Sendable {
    public let bytes: [UInt8]

    public init(service: OBDService, pid: UInt8? = nil, frame: UInt8? = nil) {
        var bytes = [service.rawValue]
        if let pid {
            bytes.append(pid)
        }
        if let frame {
            bytes.append(frame)
        }
        self.bytes = bytes
    }

    /// Arbitrary bytes, for services this library does not model (UDS probing, for example).
    public init(raw: [UInt8]) {
        bytes = raw
    }

    /// Uppercase hex with no separators, exactly as the adapter wants it: `010C`.
    public var hex: String {
        bytes.map { String(format: "%02X", $0) }.joined()
    }
}
