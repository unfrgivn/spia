import ArgumentParser
import Foundation
import OBDCore

struct Inspect: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect a saved transcript without opening a serial connection.")

    @Argument(help: "Transcript file in `<milliseconds> TX|RX <hex>` format.")
    var transcript: String

    func run() throws {
        let url = URL(fileURLWithPath: transcript)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ValidationError("transcript must be a regular file")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let limit = 16 * 1024 * 1024
        var data = Data()
        while data.count <= limit {
            let amount = min(64 * 1024, limit + 1 - data.count)
            let chunk = try handle.read(upToCount: amount) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        guard data.count <= limit else {
            throw ValidationError("transcript exceeds the 16 MiB inspection limit")
        }
        let text = String(decoding: data, as: UTF8.self)
        let events = try Transcript.decodeFile(text)
        print(TranscriptInspection.inspect(events).rendered)
    }
}
