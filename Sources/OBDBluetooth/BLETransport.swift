@preconcurrency import CoreBluetooth
import Dispatch
import Foundation
import OBDCore

public struct BLEProfile: Sendable, Equatable {
    public let service: String
    public let notificationCharacteristic: String
    public let writeCharacteristic: String

    public init(service: String, notificationCharacteristic: String, writeCharacteristic: String) {
        self.service = service
        self.notificationCharacteristic = notificationCharacteristic
        self.writeCharacteristic = writeCharacteristic
    }

    public static let vLinker = BLEProfile(
        service: "18F0", notificationCharacteristic: "2AF0", writeCharacteristic: "2AF1")
}

public enum BLEError: Error, Sendable, CustomStringConvertible {
    case unavailable(CBManagerState)
    case notFound
    case timedOut(String)
    case missingCharacteristics
    case disconnected
    case operation(String)

    public var description: String {
        switch self {
        case .unavailable(.unauthorized):
            return
                "Bluetooth is not authorized. Enable it in System Settings > Privacy & Security > Bluetooth."
        case .unavailable(.poweredOff): return "Bluetooth is powered off. Turn it on and try again."
        case .unavailable(.unsupported): return "This device does not support Bluetooth LE."
        case .unavailable(let state): return "Bluetooth is unavailable (state \(state.rawValue))."
        case .notFound:
            return
                "No vLinker FS found. Plug it in, wake it by pressing its button, and select BLE+BT mode with VgateFwUpdater."
        case .timedOut(let operation): return "Bluetooth operation timed out: \(operation)."
        case .missingCharacteristics:
            return "The adapter did not expose the expected 18F0/2AF0/2AF1 characteristics."
        case .disconnected: return "The Bluetooth adapter disconnected. Reconnect and try again."
        case .operation(let message): return message
        }
    }
}

public struct BLESighting: Sendable, Equatable {
    public let name: String
    public let identifier: UUID
    public let rssi: Int

    public init(name: String, identifier: UUID, rssi: Int) {
        self.name = name
        self.identifier = identifier
        self.rssi = rssi
    }
}

public enum BLETransportLogic {
    public static func chunks(_ bytes: [UInt8], maximumLength: Int) -> [[UInt8]] {
        guard maximumLength > 0 else { return [] }
        return stride(from: 0, to: bytes.count, by: maximumLength).map {
            Array(bytes[$0..<min($0 + maximumLength, bytes.count)])
        }
    }

    public static func strongest(_ sightings: [BLESighting]) -> BLESighting? {
        sightings.max { lhs, rhs in lhs.rssi < rhs.rssi }
    }
}

public actor BLETransport: Transport {
    private let queue = DispatchSerialQueue(label: "spia.ble")
    private let identifier: UUID?
    private let profile: BLEProfile
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var bytes = [UInt8]()
    private var readWaiter: CheckedContinuation<[UInt8], Error>?
    private var centralWaiter: CheckedContinuation<Void, Error>?
    private var scanWaiter: CheckedContinuation<Void, Error>?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    private var discoveryWaiter: CheckedContinuation<Void, Error>?
    private var notifyWaiter: CheckedContinuation<Void, Error>?
    private var writeWaiter: CheckedContinuation<Void, Error>?
    private var disconnectWaiter: CheckedContinuation<Void, Never>?
    private var readGeneration = 0
    private var centralGeneration = 0
    private var scanGeneration = 0
    private var connectGeneration = 0
    private var discoveryGeneration = 0
    private var notifyGeneration = 0
    private var writeGeneration = 0
    private var disconnectGeneration = 0
    private var scanning = false
    private var opened = false
    private var disconnected = false
    private let delegate: BLEDelegate

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    public init(identifier: UUID? = nil, profile: BLEProfile = .vLinker) {
        self.identifier = identifier
        self.profile = profile
        delegate = BLEDelegate()
        delegate.owner = self
    }

    public var connectedName: String? { peripheral?.name }
    public var connectedIdentifier: UUID? { peripheral?.identifier }

    public func open() async throws {
        guard !opened else { return }
        if central == nil { central = CBCentralManager(delegate: delegate, queue: queue) }
        try await waitForCentral()
        let service = CBUUID(string: profile.service)
        let found: CBPeripheral?
        if let identifier,
            let retrieved = central?.retrievePeripherals(withIdentifiers: [identifier]).first
        {
            found = retrieved
        } else {
            found = central?.retrieveConnectedPeripherals(withServices: [service]).first
        }
        peripheral = found
        if peripheral == nil {
            try await scan(for: identifier, service: service)
        }
        guard let peripheral else { throw BLEError.notFound }
        disconnected = false
        peripheral.delegate = delegate
        try await connect(peripheral)
        try await discover(on: peripheral, service: service)
        guard let notifyCharacteristic else { throw BLEError.missingCharacteristics }
        try await setNotify(on: peripheral, characteristic: notifyCharacteristic)
        opened = true
    }

    public func close() async {
        central?.stopScan()
        scanning = false
        failPending(with: BLEError.disconnected)
        opened = false
        guard let peripheral else { central = nil; return }
        if peripheral.state == .connected || peripheral.state == .connecting {
            central?.cancelPeripheralConnection(peripheral)
            await waitForDisconnect(peripheral)
        }
        self.peripheral = nil
        notifyCharacteristic = nil
        writeCharacteristic = nil
        central = nil
    }

    public func read(timeout: Duration) async throws -> [UInt8] {
        guard opened else { throw BLEError.disconnected }
        if !bytes.isEmpty { defer { bytes.removeAll() }; return bytes }
        readGeneration += 1
        let generation = readGeneration
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                readWaiter = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    await self?.finishReadIfWaiting(generation: generation)
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.failRead(CancellationError(), generation: generation) }
        }
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard opened, let peripheral, let characteristic = writeCharacteristic else {
            throw BLEError.disconnected
        }
        let type: CBCharacteristicWriteType =
            characteristic.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse
        for chunk in BLETransportLogic.chunks(
            bytes, maximumLength: peripheral.maximumWriteValueLength(for: type))
        {
            if type == .withoutResponse {
                let deadline = ContinuousClock.now.advanced(by: .seconds(5))
                while !peripheral.canSendWriteWithoutResponse {
                    guard opened, !disconnected, peripheral.state == .connected else {
                        throw BLEError.disconnected
                    }
                    guard ContinuousClock.now < deadline else {
                        throw BLEError.timedOut("write without response")
                    }
                    try await Task.sleep(for: .milliseconds(20))
                    try Task.checkCancellation()
                }
                peripheral.writeValue(Data(chunk), for: characteristic, type: type)
            } else {
                try await withCheckedThrowingContinuation { continuation in
                    writeGeneration += 1
                    let generation = writeGeneration
                    writeWaiter = continuation
                    peripheral.writeValue(Data(chunk), for: characteristic, type: type)
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(5))
                        await self?.failWriteIfWaiting(generation: generation)
                    }
                }
            }
        }
    }

    public func setBaud(_ baud: Int) async throws {}

    public static func discover(profile: BLEProfile = .vLinker, for duration: Duration) async throws
        -> [BLESighting]
    {
        let scanner = BLEScanner(profile: profile)
        return try await scanner.run(for: duration)
    }

    private func waitForCentral() async throws {
        guard let central, central.state != .unknown else {
            try await withCheckedThrowingContinuation { continuation in
                centralGeneration += 1
                let generation = centralGeneration
                centralWaiter = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    await self?.failCentralIfWaiting(generation: generation)
                }
            }
            return
        }
        try checkCentralState()
    }

    private func checkCentralState() throws {
        guard let state = central?.state else { throw BLEError.unavailable(.unknown) }
        guard state == .poweredOn else { throw BLEError.unavailable(state) }
    }

    private func scan(for identifier: UUID?, service: CBUUID) async throws {
        central?.scanForPeripherals(withServices: [service])
        scanning = true
        defer { if scanning { central?.stopScan(); scanning = false } }
        try await withCheckedThrowingContinuation { continuation in
            scanGeneration += 1
            let generation = scanGeneration
            scanWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.finishScan(
                    identifier: identifier, timedOut: true, generation: generation)
            }
        }
        guard peripheral != nil else { throw BLEError.notFound }
    }

    private func finishScan(identifier: UUID?, timedOut: Bool = false, generation: Int) {
        guard scanning else { return }
        guard generation == scanGeneration else { return }
        if !timedOut, let identifier, peripheral?.identifier != identifier { return }
        central?.stopScan()
        scanning = false
        scanWaiter?.resume()
        scanWaiter = nil
    }

    private func connect(_ peripheral: CBPeripheral) async throws {
        central?.connect(peripheral)
        try await withCheckedThrowingContinuation { continuation in
            connectGeneration += 1
            let generation = connectGeneration
            connectWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.failConnectIfWaiting(generation: generation, peripheral: peripheral)
            }
        }
    }

    private func discover(on peripheral: CBPeripheral, service: CBUUID) async throws {
        peripheral.discoverServices([service])
        try await withCheckedThrowingContinuation { continuation in
            discoveryGeneration += 1
            let generation = discoveryGeneration
            discoveryWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(10))
                await self?.failDiscoveryIfWaiting(generation: generation)
            }
        }
    }

    private func setNotify(on peripheral: CBPeripheral, characteristic: CBCharacteristic)
        async throws
    {
        peripheral.setNotifyValue(true, for: characteristic)
        try await withCheckedThrowingContinuation { continuation in
            notifyGeneration += 1
            let generation = notifyGeneration
            notifyWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                await self?.failNotifyIfWaiting(generation: generation)
            }
        }
    }

    private func finishReadIfWaiting(generation: Int) {
        guard let waiter = readWaiter else { return }
        guard generation == readGeneration else { return }
        readWaiter = nil
        waiter.resume(returning: bytes)
        bytes.removeAll()
    }

    fileprivate func failRead(_ error: Error, generation: Int) {
        guard generation == readGeneration else { return }
        readWaiter?.resume(throwing: error)
        readWaiter = nil
    }

    fileprivate func failCurrentRead(_ error: Error) {
        failRead(error, generation: readGeneration)
    }

    private func failConnectIfWaiting(generation: Int, peripheral: CBPeripheral) {
        guard generation == connectGeneration, connectWaiter != nil else { return }
        central?.cancelPeripheralConnection(peripheral)
        connectWaiter?.resume(throwing: BLEError.timedOut("connecting"))
        connectWaiter = nil
    }

    private func failCentralIfWaiting(generation: Int) {
        guard generation == centralGeneration, centralWaiter != nil else { return }
        centralWaiter?.resume(
            throwing: BLEError.operation(
                "Bluetooth did not become ready. Allow Bluetooth for this app or terminal in System Settings > Privacy & Security > Bluetooth."
            ))
        centralWaiter = nil
    }

    private func failDiscoveryIfWaiting(generation: Int) {
        guard generation == discoveryGeneration else { return }
        discoveryWaiter?.resume(throwing: BLEError.timedOut("service and characteristic discovery"))
        discoveryWaiter = nil
    }

    private func failNotifyIfWaiting(generation: Int) {
        guard generation == notifyGeneration else { return }
        notifyWaiter?.resume(throwing: BLEError.timedOut("notification subscription"))
        notifyWaiter = nil
    }

    private func failWriteIfWaiting(generation: Int) {
        guard generation == writeGeneration else { return }
        writeWaiter?.resume(throwing: BLEError.timedOut("write response"))
        writeWaiter = nil
    }

    private func waitForDisconnect(_ peripheral: CBPeripheral) async {
        guard peripheral.state != .disconnected else { return }
        await withCheckedContinuation { continuation in
            disconnectGeneration += 1
            let generation = disconnectGeneration
            disconnectWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                await self?.finishDisconnectWait(generation: generation)
            }
        }
    }

    private func finishDisconnectWait(generation: Int) {
        guard generation == disconnectGeneration, let waiter = disconnectWaiter else { return }
        disconnectWaiter = nil
        waiter.resume()
    }

    private func failPending(with error: Error) {
        readGeneration += 1
        centralGeneration += 1
        scanGeneration += 1
        connectGeneration += 1
        discoveryGeneration += 1
        notifyGeneration += 1
        writeGeneration += 1
        readWaiter?.resume(throwing: error); readWaiter = nil
        centralWaiter?.resume(throwing: error); centralWaiter = nil
        scanWaiter?.resume(throwing: error); scanWaiter = nil
        connectWaiter?.resume(throwing: error); connectWaiter = nil
        discoveryWaiter?.resume(throwing: error); discoveryWaiter = nil
        notifyWaiter?.resume(throwing: error); notifyWaiter = nil
        writeWaiter?.resume(throwing: error); writeWaiter = nil
    }

    fileprivate func stateUpdated(_ state: CBManagerState) {
        guard centralWaiter != nil else { return }
        if state == .poweredOn {
            centralWaiter?.resume(); centralWaiter = nil
        } else if state != .unknown {
            centralWaiter?.resume(throwing: BLEError.unavailable(state)); centralWaiter = nil
        }
    }

    fileprivate func discovered(_ peripheral: CBPeripheral) {
        guard scanning, identifier == nil || identifier == peripheral.identifier else { return }
        self.peripheral = peripheral
        finishScan(identifier: identifier, generation: scanGeneration)
    }

    fileprivate func connected(_ peripheral: CBPeripheral) {
        connectWaiter?.resume(); connectWaiter = nil
    }

    fileprivate func servicesDiscovered(_ peripheral: CBPeripheral, error: Error?) {
        guard
            let service = peripheral.services?.first(where: {
                $0.uuid == CBUUID(string: profile.service)
            })
        else {
            discoveryWaiter?.resume(throwing: error ?? BLEError.missingCharacteristics)
            discoveryWaiter = nil
            return
        }
        peripheral.discoverCharacteristics(
            [
                CBUUID(string: profile.notificationCharacteristic),
                CBUUID(string: profile.writeCharacteristic),
            ],
            for: service)
    }

    fileprivate func characteristicsDiscovered(_ service: CBService, error: Error?) {
        if let error { discoveryWaiter?.resume(throwing: error); discoveryWaiter = nil; return }
        notifyCharacteristic = service.characteristics?.first {
            $0.uuid == CBUUID(string: profile.notificationCharacteristic)
        }
        writeCharacteristic = service.characteristics?.first {
            $0.uuid == CBUUID(string: profile.writeCharacteristic)
        }
        guard notifyCharacteristic != nil, writeCharacteristic != nil else {
            discoveryWaiter?.resume(throwing: BLEError.missingCharacteristics)
            discoveryWaiter = nil
            return
        }
        discoveryWaiter?.resume(); discoveryWaiter = nil
    }

    fileprivate func notificationState(_ characteristic: CBCharacteristic, error: Error?) {
        if let error { notifyWaiter?.resume(throwing: error) } else { notifyWaiter?.resume() }
        notifyWaiter = nil
    }

    fileprivate func received(_ data: Data) {
        bytes.append(contentsOf: data)
        finishReadIfWaiting(generation: readGeneration)
    }

    fileprivate func wrote(error: Error?) {
        if let error { writeWaiter?.resume(throwing: error) } else { writeWaiter?.resume() }
        writeWaiter = nil
    }

    fileprivate func disconnected(_ peripheral: CBPeripheral, error: Error?) {
        disconnected = true
        opened = false
        let failure: Error = error ?? BLEError.disconnected
        readWaiter?.resume(throwing: failure); readWaiter = nil
        connectWaiter?.resume(throwing: failure); connectWaiter = nil
        discoveryWaiter?.resume(throwing: failure); discoveryWaiter = nil
        notifyWaiter?.resume(throwing: failure); notifyWaiter = nil
        writeWaiter?.resume(throwing: failure); writeWaiter = nil
        disconnectWaiter?.resume(); disconnectWaiter = nil
    }
}

private final class BLEDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var owner: BLETransport?
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        owner?.assumeIsolated { $0.stateUpdated(central.state) }
    }
    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi rssiValue: NSNumber
    ) {
        owner?.assumeIsolated { $0.discovered(peripheral) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        owner?.assumeIsolated { $0.connected(peripheral) }
    }
    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        owner?.assumeIsolated {
            $0.disconnected(peripheral, error: error ?? BLEError.timedOut("connecting"))
        }
    }
    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        owner?.assumeIsolated { $0.disconnected(peripheral, error: error) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        owner?.assumeIsolated { $0.servicesDiscovered(peripheral, error: error) }
    }
    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        owner?.assumeIsolated { $0.characteristicsDiscovered(service, error: error) }
    }
    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        owner?.assumeIsolated { $0.notificationState(characteristic, error: error) }
    }
    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        owner?.assumeIsolated {
            if let error {
                $0.failCurrentRead(error)
            } else if let data = characteristic.value {
                $0.received(data)
            }
        }
    }
    func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        owner?.assumeIsolated { $0.wrote(error: error) }
    }
}

private actor BLEScanner {
    let profile: BLEProfile
    let queue = DispatchSerialQueue(label: "spia.ble.scan")
    var central: CBCentralManager?
    var delegate: ScanDelegate?
    var sightings: [UUID: BLESighting] = [:]
    var stateWaiter: CheckedContinuation<Void, Error>?
    var stateGeneration = 0
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    init(profile: BLEProfile) { self.profile = profile }
    func run(for duration: Duration) async throws -> [BLESighting] {
        delegate = ScanDelegate(owner: self)
        central = CBCentralManager(delegate: delegate, queue: queue)
        if central?.state != .poweredOn {
            try await withCheckedThrowingContinuation { continuation in
                stateGeneration += 1
                let generation = stateGeneration
                stateWaiter = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(30))
                    await self?.failStateIfWaiting(generation: generation)
                }
            }
        }
        central?.scanForPeripherals(withServices: [CBUUID(string: profile.service)])
        try await Task.sleep(for: duration)
        central?.stopScan()
        return sightings.values.sorted { $0.rssi > $1.rssi }
    }
    func stateUpdated(_ state: CBManagerState) {
        guard let stateWaiter else { return }
        if state == .poweredOn {
            self.stateWaiter = nil
            stateWaiter.resume()
        } else if state != .unknown {
            self.stateWaiter = nil
            stateWaiter.resume(throwing: BLEError.unavailable(state))
        }
    }

    func failStateIfWaiting(generation: Int) {
        guard generation == stateGeneration, let stateWaiter else { return }
        self.stateWaiter = nil
        stateWaiter.resume(
            throwing: BLEError.operation(
                "Bluetooth did not become ready. Allow Bluetooth for this app or terminal in System Settings > Privacy & Security > Bluetooth."
            ))
    }

    func found(_ peripheral: CBPeripheral, name: String?, rssi: NSNumber) {
        sightings[peripheral.identifier] = BLESighting(
            name: name ?? peripheral.name ?? "Unknown", identifier: peripheral.identifier,
            rssi: rssi.intValue)
    }
}

private final class ScanDelegate: NSObject, CBCentralManagerDelegate {
    weak var owner: BLEScanner?
    init(owner: BLEScanner) { self.owner = owner }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        owner?.assumeIsolated { $0.stateUpdated(central.state) }
    }
    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi rssiValue: NSNumber
    ) {
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        owner?.assumeIsolated { $0.found(peripheral, name: name, rssi: rssiValue) }
    }
}
