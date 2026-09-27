/// A byte pipe to the adapter. Serial today, CoreBluetooth later.
///
/// `read` returns whatever has arrived, waiting at most `timeout` for the first byte.
/// An empty array means nothing arrived in time; it is not an error.
public protocol Transport: Sendable {
    func open() async throws
    func close() async
    func write(_ bytes: [UInt8]) async throws
    func read(timeout: Duration) async throws -> [UInt8]
}
