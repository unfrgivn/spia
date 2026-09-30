import Foundation
import OBDCore

/// One field an ECU was asked for. Keeps "answered with nothing" apart from "did not answer",
/// which is the difference between "no codes" and "we don't know".
public enum Reading<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    case value(Value)
    case unsupported(String)
    case unavailable(String)
    /// The ECU answered with bytes that do not fit the standard. Hex, uppercase.
    case malformed(String)
    case unknown(String)

    public var value: Value? {
        if case .value(let value) = self { return value }
        return nil
    }
}

public struct MonitorReadiness: Codable, Sendable, Equatable {
    public let monitor: String
    public let complete: Bool
}

public struct Readiness: Codable, Sendable, Equatable {
    public let milOn: Bool
    public let dtcCount: Int
    public let monitors: [MonitorReadiness]
}

public struct FreezeFrameValue: Codable, Sendable, Equatable {
    public let pid: UInt8
    public let name: String
    public let reading: Reading<String>
}

/// Generic scan result for one ECU.
public struct ECUScan: Codable, Sendable, Equatable {
    public let ecu: UInt32
    public let stored: Reading<[String]>
    public let pending: Reading<[String]>
    public let permanent: Reading<[String]>
    public let readiness: Reading<Readiness>
    /// The DTC that stored freeze frame 0; `.value(nil)` means the ECU has no freeze frame.
    public let freezeFrameDTC: Reading<String?>
    public let freezeFrame: [FreezeFrameValue]
}

/// Generic identity data for one ECU.
public struct ECUIdentity: Codable, Sendable, Equatable {
    public let ecu: UInt32
    public let vin: Reading<String>
    public let calibrationIDs: Reading<[String]>
    public let cvns: Reading<[String]>
    /// As sent, which may include NUL padding. Use `displayName` for screens.
    public let name: Reading<String>

    public var displayName: String? {
        name.value.map { $0.replacingOccurrences(of: "\0", with: "") }
    }
}

public struct ModuleDTCRecord: Codable, Sendable, Equatable {
    /// Three raw bytes as uppercase hex, e.g. `80011B`. Not translated to a manufacturer name.
    public let code: String
    public let status: UInt8

    public init(code: String, status: UInt8) {
        self.code = code
        self.status = status
    }
}

public enum ModuleDTCOutcome: Codable, Sendable, Equatable {
    case records(availability: UInt8, [ModuleDTCRecord])
    /// The module answered, but declined: e.g. `22` conditions not correct.
    case negative(service: UInt8, code: UInt8)
}

public struct ModuleDTCs: Codable, Sendable, Equatable {
    public let target: ModuleTarget
    public let outcome: ModuleDTCOutcome

    public init(target: ModuleTarget, outcome: ModuleDTCOutcome) {
        self.target = target
        self.outcome = outcome
    }
}

public enum JobPayload: Codable, Sendable, Equatable {
    case adapter(AdapterStatus)
    case vehicleInfo([ECUIdentity])
    case genericScan([ECUScan])
    case moduleDTCs(ModuleDTCs)
    case survey(SurveyReport)
}

public enum ResultSource: Codable, Sendable, Equatable {
    case live
    /// Produced from a real recording, named after the file (demo mode).
    case recording(String)
    /// Produced by replaying a saved live check from this vehicle.
    case replay(recorded: Date)
}

extension ResultSource {
    public var replayDate: Date? {
        if case .replay(let recorded) = self { return recorded }
        return nil
    }
}

/// A saved transcript of every byte exchanged during one check.
public struct TranscriptReference: Codable, Sendable, Equatable {
    public let fileName: String
    public let byteCount: Int
    public let sha256: String

    public init(fileName: String, byteCount: Int, sha256: String) {
        self.fileName = fileName
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

/// Everything a finished check produced, versioned so stored results survive app updates.
public struct JobResult: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let job: DiagnosticJob
    public let payload: JobPayload
    public let source: ResultSource
    public let transcript: TranscriptReference?

    public init(
        job: DiagnosticJob, payload: JobPayload, source: ResultSource,
        transcript: TranscriptReference?
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.job = job
        self.payload = payload
        self.source = source
        self.transcript = transcript
    }

    public enum DecodingFailure: Error, Equatable, Sendable {
        case unsupportedSchemaVersion(Int)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, job, payload, source, transcript
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == Self.currentSchemaVersion else {
            throw DecodingFailure.unsupportedSchemaVersion(version)
        }
        schemaVersion = version
        job = try values.decode(DiagnosticJob.self, forKey: .job)
        payload = try values.decode(JobPayload.self, forKey: .payload)
        source = try values.decode(ResultSource.self, forKey: .source)
        transcript = try values.decodeIfPresent(TranscriptReference.self, forKey: .transcript)
    }
}

// MARK: - Mapping from OBDCore reports

extension Reading {
    init<Raw>(_ result: OBDReadResult<Raw>, _ transform: (Raw) -> Value) {
        switch result {
        case .positive(let raw): self = .value(transform(raw))
        case .unsupported(let code): self = .unsupported(code.description)
        case .unavailable(let reason): self = .unavailable(reason)
        case .malformed(let bytes): self = .malformed(hex(bytes))
        case .unknown(let bytes): self = .unknown(hex(bytes))
        }
    }
}

extension ECUScan {
    public init(_ report: ECUReport) {
        ecu = report.ecu
        stored = Reading(report.stored) { $0.map(\.description) }
        pending = Reading(report.pending) { $0.map(\.description) }
        permanent = Reading(report.permanent) { $0.map(\.description) }
        readiness = Reading(report.readiness) { status in
            Readiness(
                milOn: status.milOn, dtcCount: Int(status.dtcCount),
                monitors: status.complete.map {
                    MonitorReadiness(monitor: $0.key.rawValue, complete: $0.value)
                }
                .sorted { $0.monitor < $1.monitor })
        }
        freezeFrameDTC = Reading(report.freezeFrameDTC) { $0?.description }
        freezeFrame = report.freezeFrameValues.sorted { $0.key < $1.key }.map { pid, value in
            FreezeFrameValue(
                pid: pid, name: PIDDescriptor.named(pid), reading: Reading(value) { $0.formatted })
        }
    }
}

extension ECUIdentity {
    public init(_ report: ECUInfoReport) {
        ecu = report.ecu
        vin = Reading(report.vin) { $0 }
        calibrationIDs = Reading(report.calibrationIDs) { $0 }
        cvns = Reading(report.cvns) { $0 }
        name = Reading(report.name) { $0 }
    }
}

extension ModuleDTCs {
    public init(target: ModuleTarget, response: UDSDTCResponse) {
        switch response {
        case .positive(let availability, let records):
            self.init(
                target: target,
                outcome: .records(
                    availability: availability,
                    records.map { ModuleDTCRecord(code: hex($0.code), status: $0.status) }))
        case .negative(let service, let code):
            self.init(target: target, outcome: .negative(service: service, code: code.byte))
        }
    }
}

func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined()
}
