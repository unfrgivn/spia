import Foundation

/// Drives an ELM327-compatible adapter (including STN11xx firmware) over a `Transport`.
///
/// Every command is a line ending in `\r`; every reply ends with a `>` prompt.
public actor ELM327Session {
    private let transport: Transport
    private let clock = ContinuousClock()

    public init(transport: Transport) {
        self.transport = transport
    }

    /// Opens the transport, resets the adapter, and applies the framing settings the parser
    /// expects (`ATE0 ATL0 ATS0 ATH1`). Returns the adapter's identification string from `ATZ`.
    public func connect(protocol selected: ELM327Protocol = .automatic) async throws -> String {
        try await transport.open()
        let identity = try await send("ATZ", timeout: .seconds(3))
        for command in ["ATE0", "ATL0", "ATS0", "ATH1", "ATSP\(selected.commandDigit)"] {
            let response = try await send(command)
            guard response.contains("OK") else {
                throw ELM327Error.unexpectedResponse(command: command, response: response)
            }
        }
        return identity
    }

    public func disconnect() async {
        await transport.close()
    }

    /// Sends one command and returns everything the adapter printed before the `>` prompt,
    /// with any echo of the command and surrounding whitespace removed.
    public func send(_ command: String, timeout: Duration = .seconds(2)) async throws -> String {
        try await transport.write(Array((command + "\r").utf8))
        let deadline = clock.now + timeout
        var received: [UInt8] = []
        while true {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw ELM327Error.timeout(command: command, partial: decode(received))
            }
            let chunk = try await transport.read(timeout: remaining)
            received.append(contentsOf: chunk)
            if let prompt = received.lastIndex(of: UInt8(ascii: ">")) {
                return stripEcho(of: command, from: decode(Array(received[..<prompt])))
            }
        }
    }

    /// `ATI`: adapter identification, e.g. `ELM327 v2.3`.
    public func identify() async throws -> String {
        try await send("ATI")
    }

    /// `STI`: STN firmware identification, e.g. `STN1170 v4.3.2`. Nil on plain ELM327 clones.
    public func identifySTN() async throws -> String? {
        let response = try await send("STI")
        return ELM327AdapterMessage(line: response) == .unknownCommand ? nil : response
    }

    /// `ATRV`: vehicle battery voltage at OBD pin 16. Nil when the adapter reports `--.-V`,
    /// which is what you get on USB power with no car attached.
    public func voltage() async throws -> Double? {
        let response = try await send("ATRV")
        let digits = response.trimmingCharacters(in: CharacterSet(charactersIn: "V "))
        if digits.hasPrefix("--") {
            return nil
        }
        guard let value = Double(digits) else {
            throw ELM327Error.unexpectedResponse(command: "ATRV", response: response)
        }
        return value
    }

    /// `ATDP`: the active protocol as prose, e.g. `AUTO, ISO 15765-4 (CAN 11/500)`.
    public func describeProtocol() async throws -> String {
        try await send("ATDP")
    }

    /// `ATDPN`: the active protocol number, prefixed with `A` when it was auto-detected.
    public func protocolNumber() async throws -> String {
        try await send("ATDPN")
    }

    /// Sends an OBD request and returns one reassembled payload per responding ECU.
    ///
    /// Protocol auto-search can take several seconds on the first request, hence the long
    /// default timeout. The adapter answers `NO DATA` on its own well before that when a bus is
    /// present but nothing replies.
    public func request(
        _ request: OBDRequest, timeout: Duration = .seconds(10)
    ) async throws -> [ECUResponse] {
        let raw = try await send(request.hex, timeout: timeout)
        let parsed = try ELM327ResponseParser.parse(raw)
        if parsed.frames.isEmpty, let message = parsed.messages.first {
            throw ELM327Error.adapter(message)
        }
        return try ISOTPReassembler.reassemble(parsed.frames)
    }

    private func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    private func stripEcho(of command: String, from text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(command) {
            trimmed = String(trimmed.dropFirst(command.count))
        }
        return trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
