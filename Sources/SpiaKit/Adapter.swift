import Foundation

/// How the Mac reaches the OBD adapter.
public enum AdapterKind: String, Codable, Sendable, CaseIterable {
    /// A USB adapter such as the vLinker FS, seen by macOS as `/dev/cu.usbserial-*`.
    case usbSerial
    /// A Bluetooth adapter. Planned for the iPhone app; not implemented yet.
    case bluetooth
    /// Real recordings from the 2017 Ghibli, replayed through the same code as a live adapter.
    case demo
}

/// Which adapter a connection uses, for display and for reconnecting.
public struct AdapterDescriptor: Codable, Sendable, Hashable {
    public let kind: AdapterKind
    public let displayName: String
    public let devicePath: String?

    public init(kind: AdapterKind, displayName: String, devicePath: String? = nil) {
        self.kind = kind
        self.displayName = displayName
        self.devicePath = devicePath
    }
}

/// What the adapter has told us about itself.
public struct AdapterStatus: Codable, Sendable, Equatable {
    /// `ATZ` banner, e.g. `ELM327 v2.3`.
    public var identity: String
    /// STN firmware from `STI`, e.g. `STN1170 v4.3.2`. Nil on plain ELM327 clones.
    public var firmware: String?
    /// Hardware name from `STDI`, e.g. `vLinker FS r2`.
    public var hardware: String?
    /// Battery voltage at OBD pin 16. Nil when the adapter reports none (not plugged into a car).
    public var voltage: Double?

    public init(
        identity: String, firmware: String? = nil, hardware: String? = nil, voltage: Double? = nil
    ) {
        self.identity = identity
        self.firmware = firmware
        self.hardware = hardware
        self.voltage = voltage
    }
}

public enum ConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case ready(AdapterStatus)
    /// A command was interrupted, so the adapter and the Mac may disagree about what was said.
    /// The only safe recovery is to reconnect, which resets the adapter.
    case reconnectRequired(reason: String)
    case failed(message: String)

    public var status: AdapterStatus? {
        if case .ready(let status) = self { return status }
        return nil
    }
}
