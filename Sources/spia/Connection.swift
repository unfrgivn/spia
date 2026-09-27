import ArgumentParser
import Foundation
import OBDCore
import OBDSerial

enum ConnectionError: Error, CustomStringConvertible {
    case noPort(available: [String])

    var description: String {
        switch self {
        case .noPort(let available):
            let list = available.isEmpty ? "none" : available.joined(separator: ", ")
            return "no serial port found. Connect an adapter or pass --port <path>. "
                + "Available ports: \(list)"
        }
    }
}

/// Everything a subcommand needs to talk to the adapter, built from the global options.
struct Connection {
    let session: ELM327Session
    let adapterIdentity: String

    static func open(_ options: GlobalOptions) async throws -> Connection {
        guard let port = options.port ?? SerialTransport.defaultPort() else {
            throw ConnectionError.noPort(available: SerialTransport.availablePorts())
        }
        var transport: Transport = SerialTransport(path: port, baud: options.baud)
        if let record = options.record {
            transport = RecordingTransport(transport, writingTo: URL(fileURLWithPath: record))
        }
        if options.verbose {
            transport = LoggingTransport(transport)
        }
        let session = ELM327Session(transport: transport, baud: options.baud)
        let identity = try await session.connect(protocol: options.protocol)
        return Connection(session: session, adapterIdentity: identity)
    }

    /// Opens a connection, runs `body`, and always closes the port afterwards.
    static func with<Result>(
        _ options: GlobalOptions, _ body: (Connection) async throws -> Result
    ) async throws -> Result {
        let connection = try await open(options)
        do {
            let result = try await body(connection)
            await connection.close()
            return result
        } catch {
            await connection.close()
            throw error
        }
    }

    func close() async {
        await session.disconnect()
    }
}

/// Human chatter goes to stderr so stdout can stay machine-readable.
func stderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// Mirrors traffic to stderr for `--verbose`. Instrumentation only; it never alters bytes.
actor LoggingTransport: Transport {
    private let base: Transport

    init(_ base: Transport) {
        self.base = base
    }

    func open() async throws {
        try await base.open()
    }

    func close() async {
        await base.close()
    }

    func setBaud(_ baud: Int) async throws {
        FileHandle.standardError.write(Data("-- host UART now \(baud) baud\n".utf8))
        try await base.setBaud(baud)
    }

    func write(_ bytes: [UInt8]) async throws {
        log("TX", bytes)
        try await base.write(bytes)
    }

    func read(timeout: Duration) async throws -> [UInt8] {
        let bytes = try await base.read(timeout: timeout)
        if !bytes.isEmpty {
            log("RX", bytes)
        }
        return bytes
    }

    private func log(_ direction: String, _ bytes: [UInt8]) {
        let text = String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\r", with: "⏎")
            .replacingOccurrences(of: "\n", with: "␊")
        FileHandle.standardError.write(Data("\(direction) \(text)\n".utf8))
    }
}
