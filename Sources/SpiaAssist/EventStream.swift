import Foundation

/// One server-sent event.
public struct SSEEvent: Sendable, Equatable {
    public let event: String?
    public let data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

/// Incremental server-sent-events parser (WHATWG HTML §9.2). Works on raw bytes because
/// `URLSession.AsyncBytes.lines` drops the blank lines that terminate each event.
public struct SSEParser: Sendable {
    private var line: [UInt8] = []
    private var event: String?
    private var data: [String] = []
    private var lastWasCR = false

    public init() {}

    public mutating func feed(_ bytes: some Sequence<UInt8>) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in bytes {
            if lastWasCR {
                lastWasCR = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0D:
                lastWasCR = true
                if let event = endLine() { events.append(event) }
            case 0x0A:
                if let event = endLine() { events.append(event) }
            default:
                line.append(byte)
            }
        }
        return events
    }

    /// Dispatches an event left unterminated at the end of the stream.
    public mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !line.isEmpty, let event = endLine() { events.append(event) }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func endLine() -> SSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        guard !line.isEmpty else { return dispatch() }
        let text = String(decoding: line, as: UTF8.self)
        if text.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": event = String(value)
        case "data": data.append(String(value))
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        defer {
            event = nil
            data = []
        }
        guard !data.isEmpty else { return nil }
        return SSEEvent(event: event, data: data.joined(separator: "\n"))
    }
}

/// Posts `body` and yields server-sent events. HTTP errors become `AssistantError.http` with
/// the provider's own message when it sent one.
struct EventStreamClient: Sendable {
    let session: URLSession

    func events(
        _ request: URLRequest, errorMessage: @escaping @Sendable (Data) -> String?
    ) -> AsyncThrowingStream<SSEEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status) else {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 64 * 1024 { break }
                        }
                        let message =
                            errorMessage(body) ?? String(decoding: body.prefix(500), as: UTF8.self)
                        throw AssistantError.http(status: status, message: message)
                    }
                    var parser = SSEParser()
                    var chunk: [UInt8] = []
                    chunk.reserveCapacity(1024)
                    for try await byte in bytes {
                        chunk.append(byte)
                        if byte == 0x0A {
                            for event in parser.feed(chunk) { continuation.yield(event) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    for event in parser.feed(chunk) + parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
