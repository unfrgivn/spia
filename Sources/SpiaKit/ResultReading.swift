import Foundation

/// A check's result as a reading: a lamp and a plain headline saying what it means for the car.
public struct ResultReading: Equatable, Sendable {
    public let tone: Tone
    public let headline: String

    /// Nil for results that aren't about the car's health: the adapter check and vehicle
    /// information.
    public init?(_ payload: JobPayload, moduleName: (ModuleTarget) -> String) {
        switch payload {
        case .genericScan(let reports):
            let codes = Set(
                reports.flatMap { report in
                    [report.stored, report.pending, report.permanent].compactMap(\.value).joined()
                })
            let milOn = reports.contains { $0.readiness.value?.milOn == true }
            let unanswered = reports.isEmpty || reports.contains { $0.stored.value == nil }
            let subject = "Engine and transmission"
            if !codes.isEmpty {
                self.init(.bad, "\(subject): \(Self.codes(codes.count))")
            } else if milOn {
                self.init(.bad, "\(subject): check-engine light on")
            } else if unanswered {
                self.init(.attention, "\(subject): some modules couldn't report codes")
            } else {
                self.init(.good, "\(subject): no trouble codes")
            }
        case .moduleDTCs(let module):
            let name = moduleName(module.target)
            switch module.outcome {
            case .records(_, let records) where records.isEmpty:
                self.init(.good, "\(name): no trouble codes")
            case .records(_, let records):
                self.init(.bad, "\(name): \(Self.codes(records.count))")
            case .negative:
                self.init(.attention, "\(name) didn't give its codes")
            }
        case .adapter, .vehicleInfo:
            return nil
        }
    }

    init(_ tone: Tone, _ headline: String) {
        self.tone = tone
        self.headline = headline
    }

    private static func codes(_ count: Int) -> String {
        count == 1 ? "1 trouble code" : "\(count) trouble codes"
    }
}

extension DTCStatus {
    /// The set flags that describe a problem, as one line: "Failing now · Confirmed". Failing
    /// now already says it failed this drive cycle and is pending, so those drop out.
    public static func summary(for status: UInt8, availability: UInt8? = nil) -> String {
        let set = flags(for: status, availability: availability)
        let failingNow = set.contains { $0.bit == 0x01 }
        let active = set.filter { flag in
            flag.isActive && !(failingNow && (flag.bit == 0x02 || flag.bit == 0x04))
        }
        return active.isEmpty ? "Not active now" : active.map(\.label).joined(separator: " · ")
    }

    /// Failing, confirmed, or lighting a lamp is a fault; pending is worth watching.
    public static func tone(for status: UInt8, availability: UInt8? = nil) -> Tone {
        let meaningful = availability.map { status & $0 } ?? status
        if meaningful & (0x01 | 0x08 | 0x80) != 0 { return .bad }
        if meaningful & (0x02 | 0x04) != 0 { return .attention }
        return .neutral
    }
}
