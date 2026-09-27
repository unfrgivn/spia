import Foundation

public struct LivePollingPlan: Sendable, Equatable {
    public let pids: [UInt8]

    public init(pids: [UInt8]) throws {
        let unique = Array(Set(pids)).sorted()
        guard !unique.isEmpty, unique.count <= 16 else { throw LiveValidationError.tooManyPIDs }
        guard
            unique.allSatisfy({
                (1...0xE0).contains($0) && !PIDDecoder.supportBitmapPIDs.contains($0)
            })
        else {
            throw LiveValidationError.invalidPID
        }
        self.pids = unique
    }
}

public enum LiveSupportDisposition: Sendable, Equatable {
    case supported
    case unsupported
    case unknown
}

public struct LiveSupportState: Sendable, Equatable {
    private let requiredBlocks: Set<UInt8>
    private var queued: Set<UInt8> = [0]
    private var visited: Set<UInt8> = []
    private var supported: [UInt8: [UInt32: Set<UInt8>]] = [:]
    private var unsupported: [UInt8: Set<UInt32>] = [:]
    private var unknown: [UInt8: Set<UInt32>] = [:]
    private var globallyUnknown: Set<UInt8> = []
    public private(set) var knownECUs: Set<UInt32> = []

    public init(plan: LivePollingPlan) {
        requiredBlocks = Set(
            plan.pids.flatMap { pid in
                stride(from: 0, through: (Int(pid) - 1) / 0x20 * 0x20, by: 0x20).map(UInt8.init)
            })
    }

    public mutating func nextBlock() -> UInt8? {
        guard let block = queued.subtracting(visited).sorted().first else { return nil }
        visited.insert(block)
        return block
    }

    public mutating func update(block: UInt8, responses: [(ecu: UInt32, supported: Set<UInt8>)]) {
        for response in responses {
            knownECUs.insert(response.ecu)
            supported[block, default: [:]][response.ecu] = response.supported
            for continuation in [UInt8(0x20), 0x40, 0x60, 0x80, 0xA0, 0xC0]
            where continuation > block && requiredBlocks.contains(continuation) {
                if response.supported.contains(continuation) {
                    queued.insert(continuation)
                } else {
                    unsupported[continuation, default: []].insert(response.ecu)
                }
            }
        }
        if responses.isEmpty {
            globallyUnknown.insert(block)
            for ecu in knownECUs where unsupported[block]?.contains(ecu) != true {
                unknown[block, default: []].insert(ecu)
            }
        } else {
            for ecu in knownECUs
            where supported[block]?[ecu] == nil && unsupported[block]?.contains(ecu) != true {
                unknown[block, default: []].insert(ecu)
            }
        }
    }

    public func disposition(pid: UInt8, ecu: UInt32?) -> LiveSupportDisposition {
        let block = UInt8((Int(pid) - 1) / 0x20 * 0x20)
        guard let ecu else { return .unknown }
        for ancestor in requiredBlocks.sorted() where ancestor <= block {
            if globallyUnknown.contains(ancestor) || unknown[ancestor]?.contains(ecu) == true {
                return .unknown
            }
            if unsupported[ancestor]?.contains(ecu) == true { return .unsupported }
        }
        guard let values = supported[block]?[ecu] else { return .unknown }
        return values.contains(pid) ? .supported : .unsupported
    }
}

public enum LiveValidationError: Error, Equatable, Sendable, CustomStringConvertible {
    case tooManyPIDs
    case invalidPID
    case invalidInterval
    case invalidDuration

    public var description: String {
        switch self {
        case .tooManyPIDs: return "at most 16 unique PIDs may be requested"
        case .invalidPID: return "PIDs must be 01-E0 and cannot be support bitmap PIDs"
        case .invalidInterval: return "interval must be finite and between 0.1 and 60 seconds"
        case .invalidDuration: return "duration must be finite, positive, and at most 86400 seconds"
        }
    }
}

public struct LiveSchedule: Sendable, Equatable {
    public let interval: Duration
    public let duration: Duration

    public init(interval: Duration, duration: Duration) throws {
        guard interval >= .milliseconds(100), interval <= .seconds(60) else {
            throw LiveValidationError.invalidInterval
        }
        guard duration > .zero, duration <= .seconds(86_400) else {
            throw LiveValidationError.invalidDuration
        }
        self.interval = interval
        self.duration = duration
    }

    public func nextDue(after cycleStart: Duration, now: Duration) -> Duration {
        let candidate = cycleStart + interval
        return candidate > now ? candidate : now + interval
    }

    public func boundedWait(now: Duration, nextDue: Duration, deadline: Duration) -> Duration {
        max(.zero, min(nextDue - now, deadline - now))
    }
}

public struct LiveCSVRow: Sendable, Equatable {
    public let elapsedSeconds: Double
    public let ecu: UInt32?
    public let pid: UInt8
    public let name: String
    public let value: String
    public let unit: String
    public let status: String

    public init(
        elapsedSeconds: Double, ecu: UInt32?, pid: UInt8, name: String, value: String, unit: String,
        status: String
    ) {
        self.elapsedSeconds = elapsedSeconds
        self.ecu = ecu
        self.pid = pid
        self.name = name
        self.value = value
        self.unit = unit
        self.status = status
    }

    public var csvLine: String {
        [
            String(
                format: "%.3f", locale: Locale(identifier: "en_US_POSIX"),
                arguments: [elapsedSeconds]),
            ecu.map { String(format: "%03X", $0) } ?? "", String(format: "%02X", pid), name, value,
            unit, status,
        ].map(csvField).joined(separator: ",")
    }

    private func csvField(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}

public enum LiveRowDecoder {
    public static let header = "elapsed_seconds,ecu,pid,name,value,unit,status"

    public static func rows(pid: UInt8, ecu: UInt32?, value: PIDValue, elapsedSeconds: Double)
        -> [LiveCSVRow]
    {
        let name = pidName(pid)
        switch value {
        case .rpm(let number): return [row(elapsedSeconds, ecu, pid, name, number, "rpm")]
        case .celsius(let number): return [row(elapsedSeconds, ecu, pid, name, number, "°C")]
        case .percent(let number): return [row(elapsedSeconds, ecu, pid, name, number, "%")]
        case .kilometersPerHour(let number):
            return [row(elapsedSeconds, ecu, pid, name, number, "km/h")]
        case .kilopascals(let number): return [row(elapsedSeconds, ecu, pid, name, number, "kPa")]
        case .gramsPerSecond(let number):
            return [row(elapsedSeconds, ecu, pid, name, number, "g/s")]
        case .volts(let number): return [row(elapsedSeconds, ecu, pid, name, number, "V")]
        case .seconds(let number):
            return [
                LiveCSVRow(
                    elapsedSeconds: elapsedSeconds, ecu: ecu, pid: pid, name: name,
                    value: String(number), unit: "s", status: "value")
            ]
        case .kilometers(let number):
            return [
                LiveCSVRow(
                    elapsedSeconds: elapsedSeconds, ecu: ecu, pid: pid, name: name,
                    value: String(number), unit: "km", status: "value")
            ]
        case .degrees(let number): return [row(elapsedSeconds, ecu, pid, name, number, "°")]
        case .litersPerHour(let number): return [row(elapsedSeconds, ecu, pid, name, number, "L/h")]
        case .raw(let bytes):
            return [
                LiveCSVRow(
                    elapsedSeconds: elapsedSeconds, ecu: ecu, pid: pid, name: name,
                    value: bytes.map { String(format: "%02X", $0) }.joined(), unit: "",
                    status: "raw")
            ]
        case .supported(let pids):
            return textRow(
                pids.sorted().map { String(format: "%02X", $0) }.joined(separator: " "),
                elapsedSeconds, ecu, pid, name)
        case .monitorStatus(let status):
            return textRow(PIDValue.monitorStatus(status).formatted, elapsedSeconds, ecu, pid, name)
        case .obdStandard(let standard):
            return textRow(PIDValue.obdStandard(standard).formatted, elapsedSeconds, ecu, pid, name)
        }
    }

    public static func unavailable(
        pid: UInt8, ecu: UInt32?, elapsedSeconds: Double, status: String = "unavailable"
    ) -> LiveCSVRow {
        LiveCSVRow(
            elapsedSeconds: elapsedSeconds, ecu: ecu, pid: pid, name: pidName(pid), value: "",
            unit: "", status: status)
    }

    private static func textRow(
        _ value: String, _ elapsed: Double, _ ecu: UInt32?, _ pid: UInt8, _ name: String
    ) -> [LiveCSVRow] {
        [
            LiveCSVRow(
                elapsedSeconds: elapsed, ecu: ecu, pid: pid, name: name, value: value, unit: "",
                status: "text")
        ]
    }

    private static func row(
        _ elapsed: Double, _ ecu: UInt32?, _ pid: UInt8, _ name: String, _ value: Double,
        _ unit: String
    ) -> LiveCSVRow {
        LiveCSVRow(
            elapsedSeconds: elapsed, ecu: ecu, pid: pid, name: name,
            value: String(
                format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), arguments: [value]),
            unit: unit,
            status: "value")
    }

    private static func pidName(_ pid: UInt8) -> String {
        PIDDescriptor.named(pid)
    }
}
