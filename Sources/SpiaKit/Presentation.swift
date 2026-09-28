import Foundation

/// UDS DTC status byte (ISO 14229-1 D.2) in plain English.
public enum DTCStatus {
    public struct Flag: Sendable, Equatable {
        public let bit: UInt8
        public let label: String
        /// Whether this flag describes a problem right now, for highlighting.
        public let isActive: Bool
    }

    public static let flags: [Flag] = [
        Flag(bit: 0x01, label: "Failing now", isActive: true),
        Flag(bit: 0x02, label: "Failed this drive cycle", isActive: true),
        Flag(bit: 0x04, label: "Pending", isActive: true),
        Flag(bit: 0x08, label: "Confirmed", isActive: true),
        Flag(bit: 0x10, label: "Not tested since codes were cleared", isActive: false),
        Flag(bit: 0x20, label: "Failed since codes were cleared", isActive: false),
        Flag(bit: 0x40, label: "Not tested this drive cycle", isActive: false),
        Flag(bit: 0x80, label: "Warning lamp requested", isActive: true),
    ]

    /// Set flags, limited to those the module says it supports when `availability` is known.
    public static func flags(for status: UInt8, availability: UInt8? = nil) -> [Flag] {
        let meaningful = availability.map { status & $0 } ?? status
        return flags.filter { meaningful & $0.bit != 0 }
    }

    /// The set flags that describe a problem, as one line: "Failing now · Confirmed". Failing
    /// now already says it failed this drive cycle and is pending, so those drop out.
    public static func summary(for status: UInt8, availability: UInt8? = nil) -> String {
        let set = flags(for: status, availability: availability)
        let failingNow = set.contains { $0.bit == 0x01 }
        let active = set.filter { flag in
            flag.isActive && !(failingNow && (flag.bit == 0x02 || flag.bit == 0x04))
        }
        return active.isEmpty ? "Not active now" : active.map(\.label).joined(separator: " · ")
    }
}

/// UDS negative response codes a user might see, in plain English.
public enum NegativeResponse {
    public static func explanation(_ code: UInt8) -> String {
        switch code {
        case 0x10: return "The module rejected the request."
        case 0x11: return "The module doesn't support this request."
        case 0x12: return "The module doesn't support this kind of request."
        case 0x13: return "The request was the wrong length."
        case 0x21: return "The module is busy; try again."
        case 0x22:
            return
                "The module won't answer in its current state (it may need the engine running or a different session)."
        case 0x31: return "The module doesn't recognize what was asked for."
        case 0x33: return "The module requires security access for this."
        case 0x78: return "The module was still working when the adapter stopped waiting."
        default: return String(format: "The module declined the request (code %02X).", code)
        }
    }
}

public enum Tone: Sendable, Equatable {
    case neutral, working, attention, good, bad
}

/// How to show a connection: an SF Symbol, a headline, and a detail line.
public struct ConnectionSummary: Sendable, Equatable {
    public let symbol: String
    public let title: String
    public let detail: String
    public let tone: Tone

    public init(adapter: AdapterDescriptor, state: ConnectionState) {
        symbol =
            switch adapter.kind {
            case .usbSerial: "cable.connector"
            case .bluetooth: "antenna.radiowaves.left.and.right"
            case .demo: "play.rectangle"
            case .replay: "arrow.clockwise.circle"
            }
        switch state {
        case .disconnected:
            detail =
                switch adapter.kind {
                case .demo: "Demo recordings ready"
                case .replay: "Saved recordings ready"
                default: "Plug in the adapter, then connect"
                }
            if adapter.kind == .demo {
                title = "Demo recordings"
                tone = .neutral
            } else if adapter.kind == .replay {
                title = "Saved recordings"
                tone = .neutral
            } else {
                title = "Not connected"
                tone = .neutral
            }
        case .connecting:
            title = "Connecting"
            detail = "Resetting the adapter"
            tone = .working
        case .ready(let status):
            switch adapter.kind {
            case .demo:
                title = "Demo recordings"
                detail = "Ready · not a live car reading"
                tone = .neutral
            case .replay:
                title = "Saved recordings"
                detail = "Ready · not a live car reading"
                tone = .neutral
            case .usbSerial, .bluetooth:
                title = status.hardware ?? adapter.displayName
                detail = "Ready · \(Self.voltageText(status.voltage))"
                tone = status.voltage == nil ? .attention : .good
            }
        case .reconnectRequired(let reason):
            title = "Reconnect needed"
            detail = reason
            tone = .attention
        case .failed(let message):
            title = "Couldn't connect"
            detail = message
            tone = .bad
        }
    }

    /// Voltage tells the user whether the adapter is actually in a powered car.
    public static func voltageText(_ volts: Double?) -> String {
        guard let volts else {
            return "No power from the car (is it plugged into the OBD port?)"
        }
        let reading = String(format: "%.1f V", locale: Locale(identifier: "en_US_POSIX"), volts)
        switch volts {
        case ..<12.0: return "\(reading), battery low"
        case 13.2...: return "\(reading), charging (engine likely running)"
        default: return reading
        }
    }
}

extension Error {
    /// What went wrong, in words for the person using Spia. Spia's own errors say it in their
    /// description; the system's (the network, files, decoding) in their localized description,
    /// where `String(describing:)` would give a domain and a code.
    public var readable: String {
        if let text = (self as? any LocalizedError)?.errorDescription { return text }
        if self is CancellationError { return "Cancelled" }
        // Swift's error types bridge with a module-qualified domain, like "SpiaKit.DemoError".
        return (self as NSError).domain.contains(".")
            ? String(describing: self) : localizedDescription
    }
}
