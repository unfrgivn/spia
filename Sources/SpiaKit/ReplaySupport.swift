import CryptoKit
import Foundation
import OBDCore

enum ReplaySupport {
    static func connection(
        adapter: AdapterDescriptor, transcript: URL, timing: ReplayTiming
    ) throws -> (ReplayTransport, ConnectionManager) {
        let transport = try ReplayTransport(contentsOf: transcript, timing: timing)
        return (transport, ConnectionManager(adapter: adapter) { transport })
    }

    static func copy(_ source: URL, to destination: URL) throws -> TranscriptReference {
        let data = try Data(contentsOf: source)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
        return TranscriptReference(
            fileName: destination.lastPathComponent, byteCount: data.count,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    static func failure(_ error: any Error) -> JobFailure {
        JobFailure(
            message: error.readable, reconnectRequired: false,
            cancelled: error is CancellationError, transcript: nil)
    }
}
