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
            }
        switch state {
        case .disconnected:
            title = "Not connected"
            detail =
                adapter.kind == .demo
                ? "Demo recordings ready" : "Plug in the adapter, then connect"
            tone = .neutral
        case .connecting:
            title = "Connecting"
            detail = "Resetting the adapter"
            tone = .working
        case .ready(let status):
            title = status.hardware ?? adapter.displayName
            detail = Self.voltageText(status.voltage)
            tone = status.voltage == nil ? .attention : .good
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
            return "Ready · no power from the car (is it plugged into the OBD port?)"
        }
        let reading = String(format: "%.1f V", locale: Locale(identifier: "en_US_POSIX"), volts)
        switch volts {
        case ..<12.0: return "Ready · \(reading), battery low"
        case 13.2...: return "Ready · \(reading), charging (engine likely running)"
        default: return "Ready · \(reading)"
        }
    }
}
