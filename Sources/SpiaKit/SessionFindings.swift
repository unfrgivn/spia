import Foundation

/// What a session's results say about the car, for the lamps at the top of the session.
///
/// Results are taken oldest first, and a newer reading of the same thing replaces an older one:
/// the latest generic scan, the latest read of each module, the latest adapter check. Nil means
/// that reading hasn't happened yet, which is different from "nothing wrong".
public struct SessionFindings: Equatable, Sendable {
    /// Whether an engine computer is asking for the check-engine light.
    public var checkEngine: Bool?
    /// Distinct trouble codes in the latest generic scan and the latest read of each module.
    public var codes: [String]?
    /// Codes the airbag controller holds.
    public var airbagCodes: [String]?
    /// Battery voltage at the OBD port, from the latest adapter check.
    public var voltage: Double?

    public init(results: [JobPayload], airbag: ModuleTarget? = nil) {
        var genericCodes: [String]?
        var moduleCodes: [ModuleTarget: [String]] = [:]
        for payload in results {
            switch payload {
            case .adapter(let status):
                voltage = status.voltage
            case .genericScan(let reports):
                checkEngine = reports.contains { $0.readiness.value?.milOn == true }
                genericCodes = reports.flatMap { report in
                    [report.stored, report.pending, report.permanent].compactMap(\.value).joined()
                }
            case .moduleDTCs(let module):
                guard case .records(_, let records) = module.outcome else { continue }
                moduleCodes[module.target] = records.map(\.code)
                if module.target == airbag { airbagCodes = records.map(\.code) }
            case .vehicleInfo:
                continue
            }
        }
        if genericCodes != nil || !moduleCodes.isEmpty {
            let all = (genericCodes ?? []) + moduleCodes.values.joined()
            codes = Array(Set(all)).sorted()
        }
    }

    public var checkEngineTone: Tone {
        switch checkEngine {
        case nil: .neutral
        case false?: .good
        case true?: .bad
        }
    }

    public var codesTone: Tone { Self.tone(codes) }
    public var airbagTone: Tone { Self.tone(airbagCodes) }

    private static func tone(_ codes: [String]?) -> Tone {
        guard let codes else { return .neutral }
        return codes.isEmpty ? .good : .bad
    }
}

extension ConnectionSummary {
    /// The battery reading as a lamp: low is the same line `voltageText` draws.
    public static func batteryTone(_ volts: Double?) -> Tone {
        guard let volts else { return .neutral }
        return volts < 12.0 ? .bad : .good
    }
}
