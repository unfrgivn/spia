import Foundation

/// Drives an ELM327-compatible adapter (including STN11xx firmware) over a `Transport`.
///
/// Every command is a line ending in `\r`; every reply ends with a `>` prompt.
public actor ELM327Session {
    private let transport: Transport
    private let clock = ContinuousClock()
    /// The rate the transport opened at, and the one to put the adapter back to on disconnect.
    private let baud: Int
    private var switchedBaud: Int?

    /// `baud` is the transport's line rate. It only matters for `switchBaud` bookkeeping and
    /// for recovering an adapter that was left at another rate.
    public init(transport: Transport, baud: Int = 115_200) {
        self.transport = transport
        self.baud = baud
    }

    /// Opens the transport, resets the adapter, and applies the framing settings the parser
    /// expects (`ATE0 ATL0 ATS0 ATH1`). Returns the adapter's identification string from `ATZ`.
    public func connect(protocol selected: ELM327Protocol = .automatic) async throws -> String {
        try await transport.open()
        let identity: String
        do {
            identity = try await send("ATZ", timeout: .seconds(3))
        } catch ELM327Error.timeout {
            identity = try await recoverForeignBaud()
        }
        for command in ["ATE0", "ATL0", "ATS0", "ATH1", "ATSP\(selected.commandDigit)"] {
            let response = try await send(command)
            guard response.contains("OK") else {
                throw ELM327Error.unexpectedResponse(command: command, response: response)
            }
        }
        return identity
    }

    /// Puts the UART back to its opening rate if `switchBaud` changed it, so the next program
    /// to open the port finds the adapter where it expects it. Then closes the transport.
    public func disconnect() async {
        if let switchedBaud, switchedBaud != baud {
            try? await switchBaud(to: baud)
        }
        await transport.close()
    }

    /// A previous session may have left the adapter at a faster rate (`STBR` persists until
    /// reset). Reset it from each plausible rate; the reboot returns it to its stored default.
    private func recoverForeignBaud() async throws -> String {
        for candidate in [2_000_000, 1_000_000, 921_600, 500_000, 230_400, 38_400]
        where candidate != baud {
            try await transport.setBaud(candidate)
            try await transport.write(Array("ATZ\r".utf8))
            try await transport.setBaud(baud)
            if let banner = try? await readUntil(
                UInt8(ascii: ">"), timeout: .seconds(3), command: "ATZ")
            {
                return stripEcho(of: "ATZ", from: String(banner.dropLast()))
            }
        }
        throw ELM327Error.timeout(command: "ATZ", partial: "")
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

    /// Switches the UART to `baud` with the STN `STBR` handshake, which reverts on its own if
    /// the host never shows up at the new rate:
    ///
    ///     host: STBR 2000000⏎        (old rate)
    ///     stn:  OK⏎                  (old rate) then switches
    ///     stn:  STN1170 v4.3.2⏎      (new rate)
    ///     host: ⏎                    (new rate, within STBRT ms, else the STN reverts)
    ///     stn:  OK⏎⏎>                (new rate)
    ///
    /// The bytes received during the switch itself may be garbled and are flushed.
    /// Plain ELM327 clones need `ATBRD` instead and
    /// are not handled.
    public func switchBaud(to newBaud: Int) async throws {
        let confirm = try await send("STBRT 1000")
        guard confirm.contains("OK") else {
            throw ELM327Error.unexpectedResponse(command: "STBRT 1000", response: confirm)
        }
        let command = "STBR \(newBaud)"
        try await transport.write(Array((command + "\r").utf8))
        let acknowledgement = try await readUntil(0x0D, timeout: .seconds(1), command: command)
        guard acknowledgement.contains("OK") else {
            // "?" means the STN cannot generate that rate; nothing has changed.
            await drainPrompt()
            throw ELM327Error.unexpectedResponse(command: command, response: acknowledgement)
        }
        try await transport.setBaud(newBaud)
        // The STN is still finishing its own switch; a CR sent now lands at the wrong rate. Wait
        // for the ID string it prints at the new rate, then confirm.
        _ = try await readUntil(0x0D, timeout: .seconds(2), command: command)
        try await transport.write([UInt8(ascii: "\r")])
        let settled = try await readUntil(UInt8(ascii: ">"), timeout: .seconds(2), command: command)
        guard settled.contains("OK") else {
            throw ELM327Error.unexpectedResponse(command: command, response: settled)
        }
        switchedBaud = newBaud
    }

    private func readUntil(_ marker: UInt8, timeout: Duration, command: String) async throws
        -> String
    {
        let deadline = clock.now + timeout
        var received: [UInt8] = []
        while true {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw ELM327Error.timeout(command: command, partial: decode(received))
            }
            received.append(contentsOf: try await transport.read(timeout: remaining))
            if received.contains(marker) {
                return decode(received)
            }
        }
    }

    private func drainPrompt() async {
        _ = try? await readUntil(UInt8(ascii: ">"), timeout: .milliseconds(500), command: "drain")
    }

    /// Puts the adapter in monitor mode (`ATMA`, or `STMA` on STN firmware) and streams every
    /// line it prints to `handle` until `handle` returns `false` or the task is cancelled. Then
    /// stops monitoring and waits for the prompt, so the session is usable afterwards.
    ///
    /// Returns early if the adapter stops on its own (prints a prompt), e.g. after `?` for an
    /// unsupported command. The caller sees that as a `.prompt` event.
    public func monitor(
        _ command: String = "ATMA",
        handle: @Sendable (Duration, MonitorEvent) async -> Bool
    ) async throws {
        try await transport.write(Array((command + "\r").utf8))
        let started = clock.now
        var parser = MonitorStreamParser()
        var running = true
        while running, !Task.isCancelled {
            let chunk = try await transport.read(timeout: .milliseconds(250))
            let elapsed = started.duration(to: clock.now)
            for event in parser.feed(chunk) {
                let wanted = await handle(elapsed, event)
                if event == .prompt {
                    return
                }
                if !wanted {
                    running = false
                    break
                }
            }
        }
        try await stopMonitoring()
    }

    /// Any byte ends monitor mode. A lone space is the safe choice: the adapter discards it,
    /// whereas a bare CR would repeat the last command and restart the monitor.
    private func stopMonitoring() async throws {
        try await transport.write([UInt8(ascii: " ")])
        _ = try await readUntil(UInt8(ascii: ">"), timeout: .seconds(2), command: "stop monitor")
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
