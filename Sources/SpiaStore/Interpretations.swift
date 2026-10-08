import Foundation
import CryptoKit
import Observation
import SpiaAssist
import SpiaKit

extension SpiaFiles {
    public func interpretationsURL(vehicle: UUID) -> URL {
        vehicleFolder(vehicle).appendingPathComponent("Interpretations.json")
    }
}

public struct InterpretationConsent: Codable, Sendable, Equatable {
    public let provider: ProviderID
    public let grantedAt: Date
}

public enum UsageKind: String, Codable, Sendable, Equatable {
    case interpretation
    case review
    case diagnosis
}

public enum ReviewKind: String, Codable, Sendable, Equatable { case review, diagnosis }

public struct StoredSuspect: Codable, Sendable, Equatable {
    public let name: String
    public let why: String
    public let confidence: Confidence
    public let symptoms: [Int]

    public init(name: String, why: String, confidence: Confidence, symptoms: [Int]) {
        self.name = name
        self.why = why
        self.confidence = confidence
        self.symptoms = symptoms
    }
}

public struct StoredInspection: Codable, Sendable, Equatable {
    public let id: UUID
    public let title: String
    public let steps: String
    public let lookFor: String
    public let safety: String?
    public let suspects: [Int]
    public let tellsApart: String

    public init(
        id: UUID, title: String, steps: String, lookFor: String, safety: String?, suspects: [Int],
        tellsApart: String
    ) {
        self.id = id
        self.title = title
        self.steps = steps
        self.lookFor = lookFor
        self.safety = safety
        self.suspects = suspects
        self.tellsApart = tellsApart
    }
}

public struct StoredConclusion: Codable, Sendable, Equatable {
    public let cause: String
    public let fix: String
    public let confidence: Confidence

    public init(cause: String, fix: String, confidence: Confidence) {
        self.cause = cause
        self.fix = fix
        self.confidence = confidence
    }
}

public struct UsageEntry: Codable, Sendable, Equatable {
    public let date: Date
    public let kind: UsageKind
    public let provider: ProviderID
    public let model: String
    public let input: Int
    public let output: Int
    public let modules: Int
    public let scope: ReviewScope?

    public init(
        date: Date = .now, kind: UsageKind, provider: ProviderID, model: String, input: Int,
        output: Int, modules: Int, scope: ReviewScope? = nil
    ) {
        self.date = date
        self.kind = kind
        self.provider = provider
        self.model = model
        self.input = input
        self.output = output
        self.modules = modules
        self.scope = scope
    }
}

public struct UsageTotals: Sendable, Equatable {
    public let requests: Int
    public let input: Int
    public let output: Int

    public init(requests: Int = 0, input: Int = 0, output: Int = 0) {
        self.requests = requests
        self.input = input
        self.output = output
    }
}

public struct UsageSummary: Sendable, Equatable {
    public let total: UsageTotals
    public let byModel: [String: UsageTotals]
    public let last30Days: UsageTotals
    public let last30DaysByModel: [String: UsageTotals]
}

public struct StoredCodeInterpretation: Codable, Sendable, Equatable {
    public let target: ModuleTarget?
    public let code: String
    public let name: String
    public let meaning: String
    public let firstCheck: String
    public let confidence: Confidence
    public let provider: ProviderID
    public let model: String
    public let date: Date
}

public struct StoredModuleInterpretation: Codable, Sendable, Equatable {
    public let target: ModuleTarget
    public let name: String
    public let role: String
    public let provider: ProviderID
    public let model: String
    public let date: Date
}

public struct StoredQuestion: Codable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let module: ModuleTarget?
    public let codes: [String]
    public let askedAt: Date
    public var answer: String?
    public var answeredAt: Date?

    public init(
        id: UUID, text: String, module: ModuleTarget?, codes: [String], askedAt: Date,
        answer: String?, answeredAt: Date?
    ) {
        self.id = id
        self.text = text
        self.module = module
        self.codes = codes
        self.askedAt = askedAt
        self.answer = answer
        self.answeredAt = answeredAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, module, codes, code, askedAt, answer, answeredAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        module = try container.decodeIfPresent(ModuleTarget.self, forKey: .module)
        if let storedCodes = try container.decodeIfPresent([String].self, forKey: .codes) {
            codes = storedCodes
        } else if let oldCode = try container.decodeIfPresent(String.self, forKey: .code) {
            codes = [oldCode]
        } else {
            codes = []
        }
        askedAt = try container.decode(Date.self, forKey: .askedAt)
        answer = try container.decodeIfPresent(String.self, forKey: .answer)
        answeredAt = try container.decodeIfPresent(Date.self, forKey: .answeredAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encodeIfPresent(module, forKey: .module)
        try container.encode(codes, forKey: .codes)
        try container.encode(askedAt, forKey: .askedAt)
        try container.encodeIfPresent(answer, forKey: .answer)
        try container.encodeIfPresent(answeredAt, forKey: .answeredAt)
    }
}

public struct StoredCheck: Codable, Sendable, Equatable {
    public let kind: CheckKind
    public let module: ModuleTarget?
    public let reason: String
    public let suspects: [Int]

    public init(kind: CheckKind, module: ModuleTarget?, reason: String, suspects: [Int] = []) {
        self.kind = kind
        self.module = module
        self.reason = reason
        self.suspects = suspects
    }

    private enum CodingKeys: String, CodingKey { case kind, module, reason, suspects }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(CheckKind.self, forKey: .kind)
        module = try container.decodeIfPresent(ModuleTarget.self, forKey: .module)
        reason = try container.decode(String.self, forKey: .reason)
        suspects = try container.decodeIfPresent([Int].self, forKey: .suspects) ?? []
    }
}

public struct StoredReview: Codable, Sendable, Equatable {
    public let kind: ReviewKind
    public let scope: ReviewScope
    public let reading: String
    public var questions: [StoredQuestion]
    public let checks: [StoredCheck]
    public let inputs: String
    public let provider: ProviderID
    public let model: String
    public let date: Date
    public let symptoms: [String]
    public let suspects: [StoredSuspect]
    public let inspections: [StoredInspection]
    public let conclusion: StoredConclusion?

    public init(
        scope: ReviewScope, reading: String, questions: [StoredQuestion], checks: [StoredCheck],
        inputs: String, provider: ProviderID, model: String, date: Date, kind: ReviewKind = .review,
        symptoms: [String] = [], suspects: [StoredSuspect] = [],
        inspections: [StoredInspection] = [],
        conclusion: StoredConclusion? = nil
    ) {
        self.kind = kind
        self.scope = scope
        self.reading = reading
        self.questions = questions
        self.checks = checks
        self.inputs = inputs
        self.provider = provider
        self.model = model
        self.date = date
        self.symptoms = symptoms
        self.suspects = suspects
        self.inspections = inspections
        self.conclusion = conclusion
    }

    private enum CodingKeys: String, CodingKey {
        case kind, scope, reading, questions, checks, inputs, provider, model, date
        case symptoms, suspects, inspections, conclusion
    }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(ReviewKind.self, forKey: .kind) ?? .review
        scope = try container.decode(ReviewScope.self, forKey: .scope)
        reading = try container.decode(String.self, forKey: .reading)
        questions = try container.decode([StoredQuestion].self, forKey: .questions)
        checks = try container.decode([StoredCheck].self, forKey: .checks)
        inputs = try container.decode(String.self, forKey: .inputs)
        provider = try container.decode(ProviderID.self, forKey: .provider)
        model = try container.decode(String.self, forKey: .model)
        date = try container.decode(Date.self, forKey: .date)
        symptoms = try container.decodeIfPresent([String].self, forKey: .symptoms) ?? []
        suspects = try container.decodeIfPresent([StoredSuspect].self, forKey: .suspects) ?? []
        inspections =
            try container.decodeIfPresent([StoredInspection].self, forKey: .inspections) ?? []
        conclusion = try container.decodeIfPresent(StoredConclusion.self, forKey: .conclusion)
    }
}

public struct InterpretationSnapshot: Codable, Sendable, Equatable {
    public var consent: InterpretationConsent?
    public var codes: [StoredCodeInterpretation]
    public var modules: [StoredModuleInterpretation]
    public var reviews: [StoredReview]
    public var usage: [UsageEntry]

    public init(
        consent: InterpretationConsent?, codes: [StoredCodeInterpretation],
        modules: [StoredModuleInterpretation], reviews: [StoredReview] = [],
        usage: [UsageEntry] = []
    ) {
        self.consent = consent
        self.codes = codes
        self.modules = modules
        self.reviews = reviews
        self.usage = usage
    }

    private enum CodingKeys: String, CodingKey { case consent, codes, modules, reviews, usage }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        consent = try container.decodeIfPresent(InterpretationConsent.self, forKey: .consent)
        codes = try container.decode([StoredCodeInterpretation].self, forKey: .codes)
        modules = try container.decode([StoredModuleInterpretation].self, forKey: .modules)
        reviews = try container.decodeIfPresent([StoredReview].self, forKey: .reviews) ?? []
        usage = try container.decodeIfPresent([UsageEntry].self, forKey: .usage) ?? []
    }
}

@MainActor @Observable
public final class VehicleInterpretations {
    public private(set) var consent: InterpretationConsent?
    public private(set) var codes: [StoredCodeInterpretation]
    public private(set) var modules: [StoredModuleInterpretation]
    public private(set) var reviews: [StoredReview]
    public private(set) var usage: [UsageEntry]
    public private(set) var inFlight: Set<ModuleTarget?> = []
    public private(set) var reviewInFlight: Set<ReviewScope> = []
    public var lastError: String?
    private let url: URL

    public init(vehicleID: UUID, files: SpiaFiles) {
        url = files.interpretationsURL(vehicle: vehicleID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: url),
            let snapshot = try? decoder.decode(InterpretationSnapshot.self, from: data)
        {
            consent = snapshot.consent
            codes = snapshot.codes
            modules = snapshot.modules
            reviews = snapshot.reviews
            usage = snapshot.usage
        } else {
            consent = nil
            codes = []
            modules = []
            reviews = []
            usage = []
        }
    }

    public func allow(_ provider: ProviderID) {
        consent = InterpretationConsent(provider: provider, grantedAt: .now)
        save()
    }

    public func withdraw() {
        consent = nil
        save()
    }

    public func begin(_ target: ModuleTarget?) {
        inFlight.insert(target)
    }

    public func end(_ target: ModuleTarget?) {
        inFlight.remove(target)
    }

    public func beginReview(_ scope: ReviewScope) {
        reviewInFlight.insert(scope)
    }

    public func endReview(_ scope: ReviewScope) {
        reviewInFlight.remove(scope)
    }

    public func recordUsage(
        _ tokenUsage: TokenUsage, kind: UsageKind, provider: ProviderID, model: String,
        modules: Int, scope: ReviewScope? = nil
    ) {
        usage.append(
            UsageEntry(
                kind: kind, provider: provider, model: model, input: tokenUsage.input,
                output: tokenUsage.output, modules: modules, scope: scope))
        save()
    }

    public var usageSummary: UsageSummary {
        let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
        func totals(_ entries: [UsageEntry]) -> UsageTotals {
            UsageTotals(
                requests: entries.count, input: entries.reduce(0) { $0 + $1.input },
                output: entries.reduce(0) { $0 + $1.output })
        }
        func grouped(_ entries: [UsageEntry]) -> [String: UsageTotals] {
            Dictionary(grouping: entries, by: \.model).mapValues(totals)
        }
        let recent = usage.filter { $0.date >= cutoff }
        return UsageSummary(
            total: totals(usage), byModel: grouped(usage), last30Days: totals(recent),
            last30DaysByModel: grouped(recent))
    }

    public func interpretation(for subject: SessionBoard.Subject, code: String)
        -> StoredCodeInterpretation?
    {
        let printed = CodeName(code)?.printed ?? code
        return codes.first {
            $0.target == subject.target && (CodeName($0.code)?.printed ?? $0.code) == printed
        }
    }
    public func interpretation(for target: ModuleTarget) -> StoredModuleInterpretation? {
        modules.first { $0.target == target }
    }
    public func store(
        _ result: InterpretationResult, target: ModuleTarget?, provider: ProviderID, model: String,
        module: ModuleInterpretation? = nil
    ) {
        let date = Date.now
        for item in result.codes {
            codes.removeAll { $0.target == target && $0.code == item.code }
            codes.append(
                StoredCodeInterpretation(
                    target: target, code: item.code, name: item.name, meaning: item.meaning,
                    firstCheck: item.firstCheck, confidence: item.confidence, provider: provider,
                    model: model, date: date))
        }
        if let module, let target {
            modules.removeAll { $0.target == target }
            modules.append(
                StoredModuleInterpretation(
                    target: target, name: module.name, role: module.role, provider: provider,
                    model: model, date: date))
        }
        save()
    }

    public func review(for scope: ReviewScope) -> StoredReview? {
        reviews.first { $0.scope == scope }
    }

    public func review(
        for scope: ReviewScope, fallingBackTo fallback: ReviewScope
    ) -> StoredReview? {
        review(for: scope) ?? review(for: fallback)
    }

    public func openQuestions(for scope: ReviewScope) -> [StoredQuestion] {
        review(for: scope)?.questions.filter { $0.answer == nil } ?? []
    }

    public func openQuestions(about subject: SessionBoard.Subject, code: String?)
        -> [StoredQuestion]
    {
        openQuestions(about: subject, code: code, scope: nil)
    }

    public func questions(about subject: SessionBoard.Subject, code: String?, scope: ReviewScope?)
        -> [StoredQuestion]
    {
        matchingQuestions(about: subject, code: code, scope: scope)
    }

    public func openQuestions(
        about subject: SessionBoard.Subject, code: String?, scope: ReviewScope?
    ) -> [StoredQuestion] {
        matchingQuestions(about: subject, code: code, scope: scope).filter {
            $0.answer == nil
        }
    }

    /// A nil code query is the module-level bucket for questions with zero or several codes.
    /// A single-code query returns only questions whose codes contain that code.
    private func matchingQuestions(
        about subject: SessionBoard.Subject, code: String?, scope: ReviewScope?
    ) -> [StoredQuestion] {
        let printed = code.flatMap { CodeName($0)?.printed } ?? code
        return reviews.filter { scope == nil || $0.scope == scope }.flatMap(\.questions).filter {
            question in
            let subjectMatches: Bool
            switch subject {
            case .engine: subjectMatches = question.module == nil
            case .module(let target): subjectMatches = question.module == target
            case .battery: subjectMatches = false
            }
            let codeMatches: Bool
            if let printed {
                codeMatches =
                    question.codes.contains {
                        (CodeName($0)?.printed ?? $0) == printed
                    } && question.codes.count == 1
            } else {
                codeMatches = question.codes.count != 1
            }
            return subjectMatches && codeMatches
        }
    }

    public func answer(questionID: UUID, text: String) {
        for index in reviews.indices {
            guard
                let questionIndex = reviews[index].questions.firstIndex(where: {
                    $0.id == questionID
                })
            else { continue }
            reviews[index].questions[questionIndex].answer = text
            reviews[index].questions[questionIndex].answeredAt = .now
            save()
            return
        }
    }

    public func storeReview(
        _ result: ReviewResult, scope: ReviewScope, inputs: String, provider: ProviderID,
        model: String, modules: [(label: String, target: ModuleTarget)]
    ) {
        let previous = review(for: scope)
        let questions = carryOverQuestions(result.questions, previous: previous, modules: modules)
        let checks = result.checks.map { item in
            StoredCheck(
                kind: item.check,
                module: item.module.flatMap { label in
                    modules.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }?.target
                }, reason: item.reason)
        }
        reviews.removeAll { $0.scope == scope }
        reviews.append(
            StoredReview(
                scope: scope, reading: result.reading, questions: questions, checks: checks,
                inputs: inputs, provider: provider, model: model, date: .now))
        save()
    }

    public func storeDiagnosis(
        _ result: DiagnosisResult, scope: ReviewScope, inputs: String, provider: ProviderID,
        model: String, modules: [(label: String, target: ModuleTarget)]
    ) {
        let previous = review(for: scope)
        let questions = carryOverQuestions(result.questions, previous: previous, modules: modules)
        let checks = result.checks.map { item in
            StoredCheck(
                kind: item.proposal.check,
                module: item.proposal.module.flatMap { label in
                    modules.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }?.target
                }, reason: item.proposal.reason, suspects: item.suspects)
        }
        let inspections = result.inspections.map {
            StoredInspection(
                id: UUID(), title: $0.title, steps: $0.steps, lookFor: $0.lookFor,
                safety: $0.safety, suspects: $0.suspects, tellsApart: $0.tellsApart)
        }
        let suspects = result.suspects.map {
            StoredSuspect(
                name: $0.name, why: $0.why, confidence: $0.confidence, symptoms: $0.symptoms)
        }
        let conclusion = result.conclusion.map {
            StoredConclusion(cause: $0.cause, fix: $0.fix, confidence: $0.confidence)
        }
        reviews.removeAll { $0.scope == scope }
        reviews.append(
            StoredReview(
                scope: scope, reading: result.reading, questions: questions, checks: checks,
                inputs: inputs, provider: provider, model: model, date: .now, kind: .diagnosis,
                symptoms: result.symptoms, suspects: suspects, inspections: inspections,
                conclusion: conclusion))
        save()
    }

    public func removeReview(for scope: ReviewScope) {
        reviews.removeAll { $0.scope == scope }
        save()
    }

    private func carryOverQuestions(
        _ source: [ReviewQuestion], previous: StoredReview?,
        modules: [(label: String, target: ModuleTarget)]
    ) -> [StoredQuestion] {
        source.map { item in
            let moduleTarget = item.module.flatMap { label in
                modules.first { $0.label.caseInsensitiveCompare(label) == .orderedSame }?.target
            }
            let storedCodes = item.codes
            let old = previous?.questions.first {
                $0.text == item.question && $0.module == moduleTarget
                    && $0.codes.map { CodeName($0)?.printed ?? $0 }
                        == storedCodes.map { CodeName($0)?.printed ?? $0 }
            }
            return StoredQuestion(
                id: UUID(), text: item.question,
                module: moduleTarget,
                codes: storedCodes,
                askedAt: old?.askedAt ?? .now, answer: old?.answer, answeredAt: old?.answeredAt)
        }
    }
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard
            let data = try? encoder.encode(
                InterpretationSnapshot(
                    consent: consent, codes: codes, modules: modules, reviews: reviews, usage: usage
                ))
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

public enum ReviewInputs {
    public static func hash(
        board: SessionBoard, problem: String, answers: [(question: String, answer: String)],
        notes: [String] = [], findings: [(title: String, text: String, evidence: String)] = []
    ) -> String {
        let rows = board.rows.map { "\($0.name)|\($0.printedCodes.joined(separator: ","))" }.joined(
            separator: "\n")
        let answerText = answers.map { "\($0.question)=\($0.answer)" }.joined(separator: "\n")
        var input = "board:\n\(rows)\nproblem:\n\(problem)\nanswers:\n\(answerText)"
        if !notes.isEmpty {
            input += "\nnotes:\n\(notes.joined(separator: "\n"))"
        }
        if !findings.isEmpty {
            let findingText = findings.map { "\($0.title)=\($0.text)|\($0.evidence)" }.joined(
                separator: "\n")
            input += "\nfindings:\n\(findingText)"
        }
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension SessionBoard.Subject {
    fileprivate var target: ModuleTarget? {
        if case .module(let target) = self {
            return target
        }
        return nil
    }
}

public enum InterpretationPlan {
    public struct Work: Sendable, Equatable {
        public let target: ModuleTarget?
        public let label: String
        public let codes: [String]
        public let needsName: Bool

        public init(target: ModuleTarget?, label: String, codes: [String], needsName: Bool) {
            self.target = target
            self.label = label
            self.codes = codes
            self.needsName = needsName
        }
    }

    public static func batches(_ work: [Work], size: Int) -> [[Work]] {
        guard size > 0 else { return [] }
        return stride(from: 0, to: work.count, by: size).map { index in
            Array(work[index..<min(index + size, work.count)])
        }
    }

    public static func missing(
        board: SessionBoard, stored: [StoredCodeInterpretation], modules: [ModulePreset]
    ) -> [Work] {
        board.rows.compactMap { row in
            guard !row.codes.isEmpty else { return nil }
            let target = row.subject.target
            let missing = row.codes.filter { code in
                let printed = CodeName(code)?.printed ?? code
                return !stored.contains {
                    $0.target == target && (CodeName($0.code)?.printed ?? $0.code) == printed
                }
            }
            let preset = modules.first { $0.target == target }
            let needsName =
                target.map {
                    (preset?.label ?? row.name).localizedCaseInsensitiveCompare($0.fallbackLabel)
                        == .orderedSame
                } ?? false
            guard !missing.isEmpty || needsName else { return nil }
            return Work(
                target: target, label: preset?.label ?? row.name, codes: missing,
                needsName: needsName)
        }
    }
}
