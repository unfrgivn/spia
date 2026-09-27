import Foundation

public struct InspectedUDSResult: Sendable, Equatable {
    public let ecu: UInt32
    public let response: UDSDTCResponse

    public init(ecu: UInt32, response: UDSDTCResponse) {
        self.ecu = ecu
        self.response = response
    }
}

public struct InspectedMonitor: Sendable, Equatable {
    public let started: UInt64
    public let ended: UInt64
    public let receivedBytes: Int
    public let complete: Bool

    public init(started: UInt64, ended: UInt64, receivedBytes: Int, complete: Bool) {
        self.started = started
        self.ended = ended
        self.receivedBytes = receivedBytes
        self.complete = complete
    }
}

public struct InspectedExchange: Sendable, Equatable {
    public let started: UInt64
    public let request: [UInt8]
    public let responseBytes: Int
    public let complete: Bool
    public let kind: String

    public init(
        started: UInt64, request: [UInt8], responseBytes: Int, complete: Bool, kind: String
    ) {
        self.started = started
        self.request = request
        self.responseBytes = responseBytes
        self.complete = complete
        self.kind = kind
    }
}

public struct TranscriptInspectionReport: Sendable, Equatable {
    public let exchanges: [InspectedExchange]
    public let obdInfo: [ECUInfoReport]
    public let obdScan: [ECUReport]
    public let uds: [InspectedUDSResult]
    public let monitors: [InspectedMonitor]
    public let warnings: [String]
    public let firstTimestamp: UInt64?
    public let lastTimestamp: UInt64?

    public init(
        exchanges: [InspectedExchange], obdInfo: [ECUInfoReport], obdScan: [ECUReport],
        uds: [InspectedUDSResult], monitors: [InspectedMonitor], warnings: [String],
        firstTimestamp: UInt64?, lastTimestamp: UInt64?
    ) {
        self.exchanges = exchanges
        self.obdInfo = obdInfo
        self.obdScan = obdScan
        self.uds = uds
        self.monitors = monitors
        self.warnings = warnings
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
    }

    public var rendered: String {
        var lines = ["Transcript inspection: \(exchanges.count) exchanges"]
        if let firstTimestamp, let lastTimestamp {
            let low = min(firstTimestamp, lastTimestamp)
            let high = max(firstTimestamp, lastTimestamp)
            lines.append("Time: \(low)–\(high) ms (\(high - low) ms)")
        }
        if !warnings.isEmpty {
            lines.append("Warnings:")
            lines += warnings.map { "  - \($0)" }
        }
        if !obdInfo.isEmpty {
            lines.append("Generic OBD info:")
            lines += obdInfo.map(\.formatted)
        }
        if !obdScan.isEmpty {
            lines.append("Generic OBD scan:")
            for report in obdScan {
                lines.append(
                    "  ECU \(String(report.ecu, radix: 16, uppercase: true)): stored \(dtcText(report.stored)), pending \(dtcText(report.pending)), permanent \(dtcText(report.permanent))"
                )
            }
        }
        if !uds.isEmpty {
            lines.append("UDS DTC results:")
            for result in uds { lines += renderUDS(result) }
        }
        if !monitors.isEmpty {
            lines.append("Monitor capture (not interpreted as diagnostics):")
            for monitor in monitors {
                let low = min(monitor.started, monitor.ended)
                let high = max(monitor.started, monitor.ended)
                lines.append(
                    "  \(monitor.receivedBytes) RX bytes over \(high - low) ms, \(monitor.complete ? "complete" : "incomplete")"
                )
            }
        }
        lines.append("Exchanges:")
        lines += exchanges.map { exchange in
            let request = exchange.request.map { String(format: "%02X", $0) }.joined()
            return
                "  \(exchange.started) ms \(exchange.kind) \(request), \(exchange.responseBytes) RX bytes, \(exchange.complete ? "complete" : "incomplete")"
        }
        return lines.joined(separator: "\n")
    }

    private func dtcText(_ result: OBDReadResult<[DTC]>) -> String {
        switch result {
        case .positive(let codes):
            return codes.isEmpty
                ? "positive empty" : codes.map(\.description).joined(separator: ",")
        case .unsupported(let code): return "unsupported (\(code))"
        case .unavailable(let reason): return "unavailable (\(reason))"
        case .malformed: return "malformed"
        case .unknown: return "unknown"
        }
    }

    private func renderUDS(_ result: InspectedUDSResult) -> [String] {
        let prefix = "  ECU \(String(result.ecu, radix: 16, uppercase: true)): "
        switch result.response {
        case .positive(let availability, let records):
            if records.isEmpty {
                return [
                    prefix + "positive empty, availability \(String(format: "%02X", availability))"
                ]
            }
            return [
                prefix
                    + records.map {
                        "raw \($0.code.map { String(format: "%02X", $0) }.joined()) status \(String(format: "%02X", $0.status))"
                    }.joined(separator: ", ")
            ]
        case .negative(let service, let code):
            return [prefix + "negative service \(String(format: "%02X", service)): \(code)"]
        }
    }
}

public enum TranscriptInspection {
    public static func inspect(_ events: [TranscriptEvent]) -> TranscriptInspectionReport {
        var exchanges: [InspectedExchange] = []
        var warnings: [String] = []
        var monitors: [InspectedMonitor] = []
        var obdObservations: [OBDObservation] = []
        var udsResults: [InspectedUDSResult] = []
        var active: ActiveExchange?
        var pendingTX: [UInt8] = []
        var pendingTXTimestamp: UInt64?

        for pair in zip(events, events.dropFirst()) where pair.1.milliseconds < pair.0.milliseconds
        {
            warnings.append(
                "timestamps decrease at \(pair.0.milliseconds) ms → \(pair.1.milliseconds) ms")
        }

        func finish(_ current: ActiveExchange, complete: Bool, at timestamp: UInt64) {
            let kind = current.kind
            exchanges.append(
                InspectedExchange(
                    started: current.started, request: current.request,
                    responseBytes: current.rx.count, complete: complete, kind: kind))
            if kind == "ATMA" {
                monitors.append(
                    InspectedMonitor(
                        started: current.started, ended: timestamp, receivedBytes: current.rx.count,
                        complete: complete))
                monitorWarnings(current.rx, warnings: &warnings)
                return
            }
            if kind == "STMA" {
                monitors.append(
                    InspectedMonitor(
                        started: current.started, ended: timestamp, receivedBytes: current.rx.count,
                        complete: complete))
                monitorWarnings(current.rx, warnings: &warnings)
                return
            }
            if kind == "handshake" {
                warnings.append("baud handshake at \(current.started) ms was not interpreted")
            }
            guard complete else { return }
            if kind == "OBD" || kind == "UDS" || kind == "uninterpreted diagnostic" {
                inspectPayload(
                    current, warnings: &warnings, obdObservations: &obdObservations,
                    udsResults: &udsResults)
            }
        }

        for event in events {
            switch event.direction {
            case .tx:
                if (active?.kind == "ATMA" || active?.kind == "STMA"), event.bytes == [0x20] {
                    continue
                }
                if active?.kind == "handshake", event.bytes == [0x0D] {
                    continue
                }
                if pendingTX.isEmpty, let active {
                    finish(active, complete: false, at: event.milliseconds)
                    warnings.append("TX interrupted an exchange at \(active.started) ms")
                }
                active = nil
                if pendingTX.isEmpty { pendingTXTimestamp = event.milliseconds }
                pendingTX.append(contentsOf: event.bytes)
                guard let cr = pendingTX.firstIndex(of: 0x0D) else { continue }
                let commandBytes = Array(pendingTX[..<cr]) + [0x0D]
                if cr + 1 < pendingTX.count {
                    warnings.append("TX bytes after CR at \(event.milliseconds) ms were ignored")
                }
                pendingTX.removeAll(keepingCapacity: false)
                let commandTimestamp = pendingTXTimestamp ?? event.milliseconds
                pendingTXTimestamp = nil
                guard let command = command(from: commandBytes) else {
                    warnings.append(
                        "unrecognized binary TX at \(event.milliseconds) ms was not executed")
                    continue
                }
                active = ActiveExchange(
                    started: commandTimestamp, request: command.bytes, kind: command.kind, rx: [])
            case .rx:
                guard var current = active else {
                    warnings.append(
                        "unsolicited RX at \(event.milliseconds) ms was not assigned to a command")
                    continue
                }
                if let prompt = event.bytes.firstIndex(of: UInt8(ascii: ">")),
                    prompt + 1 < event.bytes.count
                {
                    warnings.append(
                        "RX bytes after prompt at \(event.milliseconds) ms were ignored")
                }
                current.rx.append(contentsOf: event.bytes)
                active = current
                if event.bytes.contains(UInt8(ascii: ">")) {
                    finish(current, complete: true, at: event.milliseconds)
                    active = nil
                }
            }
        }
        if let active {
            finish(active, complete: false, at: events.last?.milliseconds ?? active.started)
            warnings.append("transcript ended before the prompt for \(active.kind)")
        }
        if !pendingTX.isEmpty {
            exchanges.append(
                InspectedExchange(
                    started: pendingTXTimestamp ?? 0, request: pendingTX, responseBytes: 0,
                    complete: false, kind: "incomplete TX"))
            warnings.append("transcript ended with TX bytes without CR")
        }
        let first = events.first?.milliseconds
        let last = events.last?.milliseconds
        let obdRequests = exchanges.filter { $0.kind == "OBD" }.map { OBDRequest(raw: $0.request) }
        let discoveredECUs = Set(obdObservations.compactMap(\.ecu))
        let finalizedOBD = OBDReportBuilder.finalizeObservations(
            obdObservations, requests: obdRequests, ecus: discoveredECUs)
        return TranscriptInspectionReport(
            exchanges: exchanges,
            obdInfo: OBDReportBuilder.info(observations: finalizedOBD),
            obdScan: OBDReportBuilder.scan(observations: finalizedOBD),
            uds: udsResults,
            monitors: monitors,
            warnings: warnings,
            firstTimestamp: first,
            lastTimestamp: last)
    }

    private struct ActiveExchange {
        let started: UInt64
        let request: [UInt8]
        let kind: String
        var rx: [UInt8]
    }

    private static func command(from bytes: [UInt8]) -> (bytes: [UInt8], kind: String)? {
        guard let cr = bytes.firstIndex(of: 0x0D) else {
            return bytes == [0x20] ? ([], "monitor stop") : nil
        }
        let command = Array(bytes[..<cr])
        let text = String(decoding: command, as: UTF8.self)
        let normalized = text.split(whereSeparator: { $0.isWhitespace }).joined().uppercased()
        if normalized == "ATMA" { return (command, "ATMA") }
        if normalized == "STMA" { return (command, "STMA") }
        if normalized.hasPrefix("STBR") || normalized.hasPrefix("STPBR") {
            return (command, "handshake")
        }
        guard !command.isEmpty, command.count.isMultiple(of: 2),
            command.allSatisfy({ $0.isASCIIHex })
        else {
            return (command, text.isEmpty ? "binary" : text)
        }
        let raw = stride(from: 0, to: command.count, by: 2).compactMap { index in
            UInt8(String(decoding: command[index..<index + 2], as: UTF8.self), radix: 16)
        }
        guard raw.count == command.count / 2 else { return (command, text) }
        if raw.first == 0x19 { return (raw, "UDS") }
        if [0x01, 0x02, 0x03, 0x07, 0x09, 0x0A].contains(raw.first) {
            return (raw, "OBD")
        }
        return (raw, "uninterpreted diagnostic")
    }

    private static func inspectPayload(
        _ exchange: ActiveExchange, warnings: inout [String],
        obdObservations: inout [OBDObservation], udsResults: inout [InspectedUDSResult]
    ) {
        let response = exchange.rx.prefix(while: { $0 != UInt8(ascii: ">") })
        let raw = String(decoding: response, as: UTF8.self)
        guard let parsed = try? ELM327ResponseParser.parse(raw) else {
            warnings.append(
                "malformed adapter response for \(exchange.kind) at \(exchange.started) ms")
            return
        }
        let adapterErrors = parsed.messages.filter { $0 != .ok }
        if !adapterErrors.isEmpty {
            warnings.append(
                contentsOf: adapterErrors.map {
                    "adapter: \($0.description) at \(exchange.started) ms"
                })
            return
        }
        if exchange.kind == "UDS" {
            do {
                var sawPending = false
                var sawFinal = false
                for response in try UDSMessageAssembler.assemble(parsed.frames) {
                    let decoded = try UDSDTCDecoder.decode(response.payload)
                    if case .negative(let service, .responsePending) = decoded {
                        sawPending = true
                        if service != 0x19 {
                            warnings.append(
                                "UDS negative response referenced service \(String(format: "%02X", service))"
                            )
                        }
                    } else {
                        sawFinal = true
                    }
                    udsResults.append(InspectedUDSResult(ecu: response.ecu, response: decoded))
                }
                if sawPending && !sawFinal {
                    warnings.append(
                        "UDS response pending without a final response at \(exchange.started) ms")
                }
            } catch {
                warnings.append("incomplete UDS response at \(exchange.started) ms: \(error)")
            }
            return
        }
        guard exchange.kind == "OBD" else { return }
        do {
            let responses = try ISOTPReassembler.reassemble(parsed.frames)
            for response in responses {
                obdObservations.append(
                    OBDObservation(
                        request: OBDRequest(raw: exchange.request), ecu: response.ecu,
                        outcome: .response(ServiceResponse.decode(response.payload))))
            }
        } catch { warnings.append("malformed OBD response at \(exchange.started) ms: \(error)") }
    }

    private static func monitorWarnings(_ bytes: [UInt8], warnings: inout [String]) {
        let text = String(decoding: bytes, as: UTF8.self)
        for marker in ["BUFFER FULL", "CAN ERROR", "BUS ERROR", "DATA ERROR", "STOPPED"]
        where text.contains(marker) {
            if let message = ELM327AdapterMessage(line: marker) {
                warnings.append("monitor adapter: \(message.description)")
            } else {
                warnings.append("monitor adapter: \(marker)")
            }
        }
    }
}

private extension UInt8 {
    var isASCIIHex: Bool {
        (48...57).contains(self) || (65...70).contains(self) || (97...102).contains(self)
    }
}
