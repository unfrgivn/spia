import Foundation

/// A session's results as a board: one row per part of the car, the most urgent first, under a
/// headline that says what they add up to.
///
/// Engine and transmission and the battery always get a row, and so does every module the
/// vehicle knows, read or not: a module nobody has read yet is how the board points at the next
/// check. Results are taken oldest first and a newer reading replaces an older one, except that a
/// module declining a read doesn't erase the codes it gave before.
public struct SessionBoard: Equatable, Sendable {
    /// A module the vehicle knows, in the order the user keeps them.
    public struct Module: Equatable, Sendable {
        public let label: String
        public let target: ModuleTarget

        public init(label: String, target: ModuleTarget) {
            self.label = label
            self.target = target
        }
    }

    /// A check's result and when it arrived.
    public struct Result: Equatable, Sendable {
        public let date: Date
        public let payload: JobPayload

        public init(date: Date, payload: JobPayload) {
            self.date = date
            self.payload = payload
        }
    }

    public enum Subject: Hashable, Sendable {
        case engine
        case module(ModuleTarget)
        case battery

        /// The row a check fills in: engine and transmission for the generic scan, the module it
        /// reads, the battery for the adapter check. Vehicle information has no row.
        public init?(job: DiagnosticJob) {
            switch job {
            case .genericScan: self = .engine
            case .moduleDTCs(let target): self = .module(target)
            case .adapterCheck: self = .battery
            case .vehicleInfo: return nil
            }
        }

        /// The check that reads this row.
        public var job: DiagnosticJob {
            switch self {
            case .engine: .genericScan
            case .module(let target): .moduleDTCs(target)
            case .battery: .adapterCheck
            }
        }
    }

    public enum Status: Equatable, Sendable {
        /// A warning lamp is on or requested.
        case fault
        /// Trouble codes, without a warning lamp.
        case codes
        /// The battery reads under 12 V.
        case low
        /// The battery reads over 15 V.
        case high
        /// Asked, and it declined or couldn't say.
        case noAnswer
        case notRead
        case clear
        /// The battery reads within range.
        case ok

        public var tone: Tone {
            switch self {
            case .fault: .bad
            case .codes, .low, .high, .noAnswer: .attention
            case .notRead: .neutral
            case .clear, .ok: .good
            }
        }

        /// Most urgent first.
        fileprivate var rank: Int {
            switch self {
            case .fault: 0
            case .codes: 1
            case .low, .high: 2
            case .noAnswer: 3
            case .notRead: 4
            case .clear, .ok: 5
            }
        }
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let subject: Subject
        /// "Airbag controller", from the label "Airbag controller (ORC)".
        public let name: String
        /// "ORC": the part of the label in parentheses.
        public let shortName: String?
        public let status: Status
        public let codes: [String]
        /// A measurement: "11.7 V".
        public let value: String?
        public let detail: String
        /// When the reading behind this row arrived. Nil until something is read, and for a
        /// live reading.
        public let date: Date?
        /// Read from the connected adapter just now, rather than from a saved result.
        public var live = false

        public var id: Subject { subject }

        /// The status as the board shows it: "Fault", "Code", "Not read".
        public var word: String {
            switch status {
            case .fault: "Fault"
            case .codes: codes.count == 1 ? "Code" : "Codes"
            case .low: "Low"
            case .high: "High"
            case .noAnswer: "No answer"
            case .notRead: "Not read"
            case .clear: "Clear"
            case .ok: "OK"
            }
        }
    }

    public let rows: [Row]
    /// What the board adds up to: "Two faults in the airbag controller."
    public let headline: String
    /// The rest in brief: "Warning lamp requested. Body computer: 1 code. …"
    public let summary: String

    /// `live` is the connected adapter's status, newer than any saved adapter check.
    public init(modules: [Module], results: [Result], live: AdapterStatus? = nil) {
        var scan: (date: Date, reports: [ECUScan])?
        var reads: [ModuleTarget: (date: Date, outcome: ModuleDTCOutcome)] = [:]
        var readOrder: [ModuleTarget] = []
        var adapter: (date: Date, status: AdapterStatus)?
        for result in results.sorted(by: { $0.date < $1.date }) {
            switch result.payload {
            case .genericScan(let reports):
                scan = (result.date, reports)
            case .moduleDTCs(let module):
                if case .negative = module.outcome, case .records = reads[module.target]?.outcome {
                    continue
                }
                if reads[module.target] == nil { readOrder.append(module.target) }
                reads[module.target] = (result.date, module.outcome)
            case .adapter(let status):
                adapter = (result.date, status)
            case .vehicleInfo:
                continue
            }
        }
        let known = Set(modules.map(\.target))
        let others = readOrder.filter { !known.contains($0) }.map { target in
            Module(label: String(format: "Module %03X", target.request), target: target)
        }
        let unsorted =
            [Self.engineRow(scan)] + (modules + others).map { Self.moduleRow($0, reads[$0.target]) }
            + [Self.batteryRow(live.map { (nil, $0) } ?? adapter.map { ($0.date, $0.status) })]
        rows = unsorted.enumerated()
            .sorted { ($0.element.status.rank, $0.offset) < ($1.element.status.rank, $1.offset) }
            .map(\.element)
        let (headline, covered) = Self.headline(rows)
        self.headline = headline
        summary = Self.summary(rows, covered: covered)
    }

    // MARK: Rows

    private static func engineRow(_ scan: (date: Date, reports: [ECUScan])?) -> Row {
        let name = "Engine and transmission"
        guard let scan else {
            return Row(
                subject: .engine, name: name, shortName: nil, status: .notRead, codes: [],
                value: nil, detail: "Not read yet", date: nil)
        }
        let reports = scan.reports
        let lists: [(name: String, list: KeyPath<ECUScan, Reading<[String]>>)] = [
            ("Stored", \.stored), ("Pending", \.pending), ("Permanent", \.permanent),
        ]
        let codes = Set(
            reports.flatMap { report in lists.compactMap { report[keyPath: $0.list].value }.joined()
            }
        ).sorted()
        let kinds = lists.filter { entry in
            reports.contains { $0[keyPath: entry.list].value?.isEmpty == false }
        }.map { $0.name }
        let monitors = reports.compactMap(\.readiness.value).flatMap(\.monitors)
        let status: Status
        let detail: String
        if reports.contains(where: { $0.readiness.value?.milOn == true }) {
            status = .fault
            detail = (["Check-engine light on"] + kinds).joined(separator: " · ")
        } else if !codes.isEmpty {
            status = .codes
            detail = kinds.joined(separator: " · ")
        } else if reports.isEmpty || reports.contains(where: { $0.stored.value == nil }) {
            status = .noAnswer
            detail = "Some computers couldn't report codes"
        } else {
            status = .clear
            detail =
                monitors.isEmpty
                ? "No codes"
                : "\(monitors.filter(\.complete).count) of \(monitors.count) monitors ready"
        }
        return Row(
            subject: .engine, name: name, shortName: nil, status: status, codes: codes, value: nil,
            detail: detail, date: scan.date)
    }

    private static func moduleRow(
        _ module: Module, _ read: (date: Date, outcome: ModuleDTCOutcome)?
    ) -> Row {
        let (name, shortName) = split(module.label)
        func row(_ status: Status, _ codes: [String], _ detail: String, _ date: Date?) -> Row {
            Row(
                subject: .module(module.target), name: name, shortName: shortName, status: status,
                codes: codes, value: nil, detail: detail, date: date)
        }
        guard let read else { return row(.notRead, [], "Not read yet", nil) }
        switch read.outcome {
        case .records(_, let records) where records.isEmpty:
            return row(.clear, [], "No codes", read.date)
        case .records(let availability, let records):
            let lamp = records.contains { $0.status & availability & 0x80 != 0 }
            let combined = records.reduce(UInt8(0)) { $0 | $1.status }
            return row(
                lamp ? .fault : .codes, records.map(\.code),
                DTCStatus.summary(for: combined, availability: availability), read.date)
        case .negative:
            return row(.noAnswer, [], "Declined to give its codes", read.date)
        }
    }

    /// A nil date is a live reading.
    private static func batteryRow(_ adapter: (date: Date?, status: AdapterStatus)?) -> Row {
        func row(_ status: Status, _ value: String?, _ detail: String, _ date: Date?) -> Row {
            Row(
                subject: .battery, name: "Battery", shortName: nil, status: status, codes: [],
                value: value, detail: detail, date: date, live: adapter != nil && date == nil)
        }
        guard let adapter else { return row(.notRead, nil, "Not read yet", nil) }
        guard let volts = adapter.status.voltage else {
            return row(.noAnswer, nil, "The adapter didn't report a voltage", adapter.date)
        }
        let value = String(format: "%.1f V", volts)
        switch volts {
        case ..<12.0: return row(.low, value, "A rested battery reads about 12.6 V", adapter.date)
        case 15.0...:
            return row(.high, value, "Charging should stay under about 14.7 V", adapter.date)
        case 13.0...: return row(.ok, value, "In range for a running engine", adapter.date)
        default: return row(.ok, value, "In range for a rested battery", adapter.date)
        }
    }

    // MARK: Words

    /// The headline, and the rows it already speaks for, which the summary leaves out.
    private static func headline(_ rows: [Row]) -> (String, Set<Subject>) {
        let faults = rows.filter { $0.status == .fault }
        let coded = rows.filter { $0.status == .codes }
        let silent = rows.filter { $0.status == .noAnswer }
        if faults.count == 1, let only = faults.first {
            if only.subject == .engine { return ("The check-engine light is on.", [only.subject]) }
            let count = only.codes.count
            return (
                "\(number(count, capitalized: true)) \(noun(count, "fault")) in the \(prose(only.name)).",
                [only.subject]
            )
        }
        if faults.count > 1 { return ("Faults in \(number(faults.count)) modules.", []) }
        if coded.count == 1, let only = coded.first {
            let count = only.codes.count
            return (
                "\(number(count, capitalized: true)) \(noun(count, "code")) in the \(prose(only.name)).",
                [only.subject]
            )
        }
        if coded.count > 1 { return ("Codes in \(number(coded.count)) modules.", []) }
        switch rows.first(where: { $0.subject == .battery })?.status {
        case .low?: return ("The battery is low.", [.battery])
        case .high?: return ("The battery voltage is high.", [.battery])
        default: break
        }
        if silent.count == 1, let only = silent.first {
            return ("The \(prose(only.name)) didn't answer.", [only.subject])
        }
        if silent.count > 1 {
            return ("\(number(silent.count, capitalized: true)) modules didn't answer.", [])
        }
        if rows.allSatisfy({ $0.status == .notRead }) { return ("Nothing read yet.", []) }
        if rows.contains(where: { $0.status == .notRead }) {
            return ("No trouble codes so far.", [])
        }
        return ("No trouble codes.", [])
    }

    private static func summary(_ rows: [Row], covered: Set<Subject>) -> String {
        if rows.allSatisfy({ $0.status == .notRead }) {
            return "Run a check to see what the car reports."
        }
        var clauses: [String] = []
        for row in rows {
            let isCovered = covered.contains(row.subject)
            switch row.status {
            case .fault where isCovered && row.subject != .engine:
                clauses.append("Warning lamp requested.")
            case .fault where row.subject == .engine:
                let codes = row.codes.isEmpty ? [] : [count(row.codes, "code")]
                if !isCovered {
                    let parts = ["check-engine light on"] + codes
                    clauses.append("\(row.name): \(parts.joined(separator: ", ")).")
                } else if let codes = codes.first {
                    clauses.append("\(row.name): \(codes).")
                }
            case .fault:
                clauses.append("\(row.name): \(count(row.codes, "fault")).")
            case .codes where !isCovered:
                clauses.append("\(row.name): \(count(row.codes, "code")).")
            case .low where !isCovered, .high where !isCovered:
                let level = row.status == .low ? "low" : "high"
                clauses.append("\(row.name): \(row.value ?? ""), \(level).")
            case .noAnswer where !isCovered:
                clauses.append("\(row.name): no answer.")
            default:
                continue
            }
        }
        let clear = rows.filter { $0.status == .clear }.map { prose($0.name) }
        if !clear.isEmpty { clauses.append("Clear: \(clear.joined(separator: ", ")).") }
        return clauses.joined(separator: " ")
    }

    /// "Airbag controller (ORC)" → ("Airbag controller", "ORC").
    static func split(_ label: String) -> (name: String, shortName: String?) {
        guard label.hasSuffix(")"), let open = label.lastIndex(of: "(") else { return (label, nil) }
        let name = label[..<open].trimmingCharacters(in: .whitespaces)
        let short = label[label.index(after: open)..<label.index(before: label.endIndex)]
            .trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !short.isEmpty else { return (label, nil) }
        return (name, short)
    }

    /// A name inside a sentence: "Body computer" → "body computer". Acronyms like "ABS" stay.
    static func prose(_ name: String) -> String {
        guard let first = name.first, name.dropFirst().first?.isLowercase == true else {
            return name
        }
        return first.lowercased() + name.dropFirst()
    }

    private static func number(_ value: Int, capitalized: Bool = false) -> String {
        let words = [
            "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        ]
        guard words.indices.contains(value) else { return "\(value)" }
        return capitalized ? words[value].capitalized : words[value]
    }

    private static func noun(_ count: Int, _ word: String) -> String {
        count == 1 ? word : word + "s"
    }

    private static func count(_ codes: [String], _ word: String) -> String {
        "\(codes.count) \(noun(codes.count, word))"
    }
}
