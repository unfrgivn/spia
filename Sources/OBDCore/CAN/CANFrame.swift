/// A single CAN frame as printed by the adapter with headers enabled.
public struct CANFrame: Equatable, Sendable {
    /// Arbitration ID. 11-bit (e.g. `0x7E8`) or 29-bit (e.g. `0x18DAF110`).
    public let header: UInt32
    /// Up to 8 data bytes. The first byte is the ISO-TP protocol control information.
    public let data: [UInt8]

    public init(header: UInt32, data: [UInt8]) {
        self.header = header
        self.data = data
    }
}

/// A complete ISO-TP payload reassembled from one ECU.
public struct ECUResponse: Equatable, Sendable {
    /// The responding ECU's CAN header (e.g. `0x7E8` is the engine on most cars).
    public let ecu: UInt32
    public let payload: [UInt8]

    public init(ecu: UInt32, payload: [UInt8]) {
        self.ecu = ecu
        self.payload = payload
    }
}
