import Foundation

/// Everything one part of the car has ever said, and the life of each code it reported.
public struct ReadingHistory: Equatable, Sendable {
    public struct Reading: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let date: Date
        public let row: SessionBoard.Row

        public init(id: UUID, date: Date, row: SessionBoard.Row) {
            self.id = id
            self.date = date
            self.row = row
        }
    }

    public struct Code: Equatable, Sendable, Identifiable {
        public let code: String
        public var name: CodeName? { CodeName(code) }
        public let firstSeen: Date
        public let lastSeen: Date
        public let present: Bool
        public let flags: [DTCStatus.Flag]
        public let readings: Int

        public var id: String { code }
    }

    public let subject: SessionBoard.Subject
    public let readings: [Reading]
    public let codes: [Code]

    public init(
        subject: SessionBoard.Subject, modules: [SessionBoard.Module],
        results: [(id: UUID, result: SessionBoard.Result)]
    ) {
        self.subject = subject
        let relevant = results.sorted { $0.result.date > $1.result.date }.compactMap { item in
            SessionBoard.row(for: subject, result: item.result, modules: modules)
                .map { Reading(id: item.id, date: item.result.date, row: $0) }
        }
        readings = relevant

        struct Observation {
            var first: Date
            var last: Date
            var count: Int
            var flags: [DTCStatus.Flag]
            var latestRecordsDate: Date
        }
        var observations: [String: Observation] = [:]
        for item in results.sorted(by: { $0.result.date < $1.result.date }) {
            guard let records = Self.records(for: subject, payload: item.result.payload) else {
                continue
            }
            for record in records.records {
                let flags = DTCStatus.flags(
                    for: record.status, availability: records.availability)
                if var observation = observations[record.code] {
                    observation.last = item.result.date
                    observation.count += 1
                    observation.flags = flags
                    observation.latestRecordsDate = item.result.date
                    observations[record.code] = observation
                } else {
                    observations[record.code] = Observation(
                        first: item.result.date, last: item.result.date, count: 1,
                        flags: flags, latestRecordsDate: item.result.date)
                }
            }
        }

        let latestRecordDate = results.compactMap { item -> Date? in
            guard Self.records(for: subject, payload: item.result.payload) != nil else {
                return nil
            }
            return item.result.date
        }.max()
        codes = observations.map { code, observation in
            Code(
                code: code, firstSeen: observation.first, lastSeen: observation.last,
                present: observation.latestRecordsDate == latestRecordDate,
                flags: observation.flags, readings: observation.count)
        }
        .sorted {
            if $0.present != $1.present { return $0.present }
            if $0.firstSeen != $1.firstSeen { return $0.firstSeen < $1.firstSeen }
            return $0.code < $1.code
        }
    }

    private struct Records {
        let availability: UInt8
        let records: [ModuleDTCRecord]
    }

    private static func records(for subject: SessionBoard.Subject, payload: JobPayload) -> Records?
    {
        switch (subject, payload) {
        case (.engine, .genericScan(let reports)):
            // A code can be both stored and permanent; it's still one code in this reading.
            let codes = Set(
                reports.flatMap { report in
                    [report.stored, report.pending, report.permanent].compactMap(\.value).flatMap {
                        $0
                    }
                })
            return Records(
                availability: 0,
                records: codes.sorted().map { ModuleDTCRecord(code: $0, status: 0) })
        case (.module(let target), .moduleDTCs(let module)) where module.target == target:
            guard case .records(let availability, let records) = module.outcome else { return nil }
            return Records(availability: availability, records: records)
        case (.module(let target), .survey(let report)):
            guard let module = report.modules.first(where: { $0.candidate.target == target }),
                case .outcome(.records(let availability, let records)) = module.codes
            else { return nil }
            return Records(availability: availability, records: records)
        default:
            return nil
        }
    }
}
