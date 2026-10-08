import Foundation
import SpiaKit

public enum Confidence: String, Codable, Sendable, CaseIterable {
    case high, medium, low
}

public struct DiagnosisSuspect: Codable, Sendable, Equatable {
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

public struct DiagnosisCheck: Codable, Sendable, Equatable {
    public let proposal: CheckProposal
    public let suspects: [Int]

    public init(proposal: CheckProposal, suspects: [Int]) {
        self.proposal = proposal
        self.suspects = suspects
    }
}

public struct DiagnosisInspection: Codable, Sendable, Equatable {
    public let title: String
    public let steps: String
    public let lookFor: String
    public let safety: String?
    public let suspects: [Int]
    public let tellsApart: String

    public init(
        title: String, steps: String, lookFor: String, safety: String?, suspects: [Int],
        tellsApart: String
    ) {
        self.title = title
        self.steps = steps
        self.lookFor = lookFor
        self.safety = safety
        self.suspects = suspects
        self.tellsApart = tellsApart
    }
}

public struct DiagnosisConclusion: Codable, Sendable, Equatable {
    public let cause: String
    public let fix: String
    public let confidence: Confidence

    public init(cause: String, fix: String, confidence: Confidence) {
        self.cause = cause
        self.fix = fix
        self.confidence = confidence
    }
}

public struct DiagnosisResult: Codable, Sendable, Equatable {
    public let reading: String
    public let symptoms: [String]
    public let suspects: [DiagnosisSuspect]
    public let checks: [DiagnosisCheck]
    public let inspections: [DiagnosisInspection]
    public let questions: [ReviewQuestion]
    public let conclusion: DiagnosisConclusion?

    public init(
        reading: String, symptoms: [String], suspects: [DiagnosisSuspect], checks: [DiagnosisCheck],
        inspections: [DiagnosisInspection], questions: [ReviewQuestion],
        conclusion: DiagnosisConclusion?
    ) {
        self.reading = reading
        self.symptoms = symptoms
        self.suspects = suspects
        self.checks = checks
        self.inspections = inspections
        self.questions = questions
        self.conclusion = conclusion
    }
}

public enum DiagnosisTool {
    public static let name = "record_diagnosis"

    public static func definition(modules: [String]) -> ToolDefinition {
        let module: JSONValue = [
            "type": ["string", "null"], "enum": .array(modules.map { .string($0) } + [.null]),
        ]
        let question: JSONValue = [
            "type": "object",
            "properties": [
                "question": ["type": "string"], "module": module,
                "codes": ["type": "array", "items": ["type": "string"]],
            ], "required": ["question", "module", "codes"], "additionalProperties": false,
        ]
        let suspect: JSONValue = [
            "type": "object",
            "properties": [
                "name": ["type": "string"], "why": ["type": "string"],
                "confidence": [
                    "type": "string",
                    "enum": .array(Confidence.allCases.map { .string($0.rawValue) }),
                ],
                "symptoms": [
                    "type": "array", "items": ["type": "integer"],
                    "description": "Zero-based indexes into symptoms; the first symptom is 0.",
                ],
            ], "required": ["name", "why", "confidence", "symptoms"], "additionalProperties": false,
        ]
        let check: JSONValue = [
            "type": "object",
            "properties": [
                "check": [
                    "type": "string",
                    "enum": .array(CheckKind.allCases.map { .string($0.rawValue) }),
                ],
                "module": module, "reason": ["type": "string"],
                "suspects": [
                    "type": "array", "items": ["type": "integer"],
                    "description": "Zero-based indexes into suspects; the first suspect is 0.",
                ],
            ], "required": ["check", "module", "reason", "suspects"], "additionalProperties": false,
        ]
        let inspection: JSONValue = [
            "type": "object",
            "properties": [
                "title": ["type": "string"], "steps": ["type": "string"],
                "look_for": ["type": "string"],
                "safety": ["type": ["string", "null"]],
                "suspects": [
                    "type": "array", "items": ["type": "integer"],
                    "description": "Zero-based indexes into suspects; the first suspect is 0.",
                ],
                "tells_apart": ["type": "string"],
            ], "required": ["title", "steps", "look_for", "safety", "suspects", "tells_apart"],
            "additionalProperties": false,
        ]
        let conclusion: JSONValue = [
            "anyOf": [
                [
                    "type": "object",
                    "properties": [
                        "cause": ["type": "string"], "fix": ["type": "string"],
                        "confidence": [
                            "type": "string",
                            "enum": .array(Confidence.allCases.map { .string($0.rawValue) }),
                        ],
                    ], "required": ["cause", "fix", "confidence"], "additionalProperties": false,
                ],
                ["type": "null"],
            ]
        ]
        return ToolDefinition(
            name: name, description: "Record the technician's working diagnosis of the problem.",
            parameters: [
                "type": "object",
                "properties": [
                    "reading": ["type": "string"],
                    "symptoms": ["type": "array", "items": ["type": "string"]],
                    "suspects": ["type": "array", "items": suspect],
                    "checks": ["type": "array", "items": check],
                    "inspections": ["type": "array", "items": inspection],
                    "questions": ["type": "array", "items": question],
                    "conclusion": conclusion,
                ],
                "required": [
                    "reading", "symptoms", "suspects", "checks", "inspections", "questions",
                    "conclusion",
                ],
                "additionalProperties": false,
            ])
    }

    public static func parse(_ call: ToolCall, modules: [String]) throws -> DiagnosisResult {
        guard call.name == name, let value = try? JSONValue.parse(call.arguments),
            case .object(let root) = value,
            Set(root.keys) == [
                "reading", "symptoms", "suspects", "checks", "inspections", "questions",
                "conclusion",
            ]
        else { throw AssistantError.malformedStream("invalid diagnosis root") }
        guard let reading = root["reading"]?.string, !reading.trimmed.isEmpty else {
            throw AssistantError.malformedStream("invalid diagnosis reading")
        }
        let symptoms = try strings(root["symptoms"], label: "diagnosis symptoms", cap: 8)
        guard case .array(let suspectValues)? = root["suspects"], suspectValues.count <= 5 else {
            throw AssistantError.malformedStream("invalid diagnosis suspects")
        }
        let suspects = try suspectValues.map { item -> DiagnosisSuspect in
            guard case .object(let object) = item,
                Set(object.keys) == ["name", "why", "confidence", "symptoms"],
                let name = object["name"]?.string, !name.trimmed.isEmpty,
                let why = object["why"]?.string, !why.trimmed.isEmpty,
                let confidence = object["confidence"]?.string.flatMap(Confidence.init(rawValue:)),
                case .array(let indexes)? = object["symptoms"]
            else { throw AssistantError.malformedStream("invalid diagnosis suspect") }
            return DiagnosisSuspect(
                name: name, why: why, confidence: confidence,
                symptoms: try indexes.map {
                    try index($0, count: symptoms.count, label: "suspect symptom")
                })
        }
        guard case .array(let checkValues)? = root["checks"] else {
            throw AssistantError.malformedStream("invalid diagnosis checks")
        }
        let checks = try checkValues.map { item -> DiagnosisCheck in
            guard case .object(let object) = item,
                Set(object.keys) == ["check", "module", "reason", "suspects"],
                let raw = object["check"]?.string, let check = CheckKind(rawValue: raw),
                let reason = object["reason"]?.string,
                case .array(let indexes)? = object["suspects"]
            else { throw AssistantError.malformedStream("invalid diagnosis check") }
            let module = try optionalString(object["module"], label: "diagnosis check module")
            if let module,
                !modules.contains(where: { $0.caseInsensitiveCompare(module) == .orderedSame })
            {
                throw AssistantError.malformedStream("unknown diagnosis check module \"\(module)\"")
            }
            return DiagnosisCheck(
                proposal: CheckProposal(check: check, module: module, reason: reason),
                suspects: try indexes.map {
                    try index($0, count: suspects.count, label: "check suspect")
                })
        }
        guard case .array(let inspectionValues)? = root["inspections"], inspectionValues.count <= 5
        else { throw AssistantError.malformedStream("invalid diagnosis inspections") }
        let inspections = try inspectionValues.map { item -> DiagnosisInspection in
            guard case .object(let object) = item,
                Set(object.keys) == [
                    "title", "steps", "look_for", "safety", "suspects", "tells_apart",
                ], let title = object["title"]?.string, !title.trimmed.isEmpty,
                let steps = object["steps"]?.string, !steps.trimmed.isEmpty,
                let lookFor = object["look_for"]?.string, !lookFor.trimmed.isEmpty,
                let tellsApart = object["tells_apart"]?.string, !tellsApart.trimmed.isEmpty,
                case .array(let indexes)? = object["suspects"]
            else { throw AssistantError.malformedStream("invalid diagnosis inspection") }
            return DiagnosisInspection(
                title: title, steps: steps, lookFor: lookFor,
                safety: try optionalString(object["safety"], label: "diagnosis inspection safety"),
                suspects: try indexes.map {
                    try index($0, count: suspects.count, label: "inspection suspect")
                }, tellsApart: tellsApart)
        }
        guard case .array(let questionValues)? = root["questions"], questionValues.count <= 3 else {
            throw AssistantError.malformedStream("invalid diagnosis questions")
        }
        let questions = try ReviewTool.parseQuestions(questionValues, modules: modules)
        let conclusion: DiagnosisConclusion?
        switch root["conclusion"] {
        case .some(.null): conclusion = nil
        case .some(.object(let object)):
            guard Set(object.keys) == ["cause", "fix", "confidence"],
                let cause = object["cause"]?.string, !cause.trimmed.isEmpty,
                let fix = object["fix"]?.string, !fix.trimmed.isEmpty,
                let confidenceText = object["confidence"]?.string,
                let confidence = Confidence(rawValue: confidenceText)
            else { throw AssistantError.malformedStream("invalid diagnosis conclusion") }
            conclusion = DiagnosisConclusion(cause: cause, fix: fix, confidence: confidence)
        default: throw AssistantError.malformedStream("invalid diagnosis conclusion")
        }
        return DiagnosisResult(
            reading: reading, symptoms: symptoms, suspects: suspects, checks: checks,
            inspections: inspections, questions: questions, conclusion: conclusion)
    }

    private static func strings(_ value: JSONValue?, label: String, cap: Int) throws -> [String] {
        guard case .array(let values)? = value, values.count <= cap else {
            throw AssistantError.malformedStream("invalid \(label)")
        }
        return try values.map {
            guard let string = $0.string, !string.trimmed.isEmpty else {
                throw AssistantError.malformedStream("invalid \(label) element")
            }; return string
        }
    }

    private static func optionalString(_ value: JSONValue?, label: String) throws -> String? {
        guard let value else { throw AssistantError.malformedStream("invalid \(label)") }
        if case .null = value { return nil }
        guard let string = value.string else {
            throw AssistantError.malformedStream("invalid \(label)")
        }
        return string
    }

    private static func index(_ value: JSONValue, count: Int, label: String) throws -> Int {
        guard case .number(let number) = value, number.rounded() == number, number >= 0,
            number < Double(count)
        else { throw AssistantError.malformedStream("invalid \(label) index") }
        return Int(number)
    }
}

private extension String { var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) } }

public enum DiagnosisRequest {
    public struct Clip: Sendable, Equatable {
        public let duration: TimeInterval
        public let frames: [ImageInput]
        public init(duration: TimeInterval, frames: [ImageInput]) {
            self.duration = duration; self.frames = frames
        }
    }

    public struct Finding: Sendable, Equatable {
        public let title: String
        public let text: String
        public let date: Date
        public let photos: [ImageInput]
        public let clips: [Clip]
        public let sounds: [TimeInterval]
        public init(
            title: String, text: String, date: Date, photos: [ImageInput] = [],
            clips: [Clip] = [], sounds: [TimeInterval] = []
        ) {
            self.title = title; self.text = text; self.date = date
            self.photos = photos; self.clips = clips; self.sounds = sounds
        }
    }

    public static let maximumImages = 6

    public static func make(
        briefing: SessionBriefing, title: String, text: String, notes: [String],
        answered: [(question: String, answer: String)], findings: [Finding],
        codes: [(printed: String, name: String?, failureType: String?)], unread: [String],
        provider: ProviderID, sharing: SharingPolicy
    ) -> AssistantRequest {
        let noteText = notes.isEmpty ? "- None" : notes.map { "- \($0)" }.joined(separator: "\n")
        let findingText =
            findings.isEmpty ? "- None" : findings.map(findingLine).joined(separator: "\n")
        let answers =
            answered.isEmpty
            ? "No questions have been answered yet."
            : answered.map { "- Q: \($0.question)\n  A: \($0.answer)" }.joined(separator: "\n")
        let codeText =
            codes.isEmpty
            ? "- None"
            : codes.map { code in
                let details = [
                    code.name ?? "manufacturer-specific, no public name",
                    code.failureType.map { "failure type \($0)" },
                ].compactMap { $0 }.joined(separator: "; ")
                return "- \(code.printed): \(details)"
            }.joined(separator: "\n")
        let unreadText =
            unread.isEmpty ? "- None" : unread.map { "- \($0)" }.joined(separator: "\n")
        let imageItems = findings.sorted { $0.date > $1.date }.flatMap { finding in
            finding.photos.enumerated().map {
                AttachedImage(
                    finding: finding, kind: "photo", index: $0.offset + 1,
                    total: finding.photos.count, image: $0.element)
            }
                + finding.clips.flatMap { clip in
                    clip.frames.enumerated().map {
                        AttachedImage(
                            finding: finding, kind: "clip frame", index: $0.offset + 1,
                            total: clip.frames.count, image: $0.element)
                    }
                }
        }
        let selectedImages = Array(imageItems.prefix(maximumImages))
        let evidenceParagraph: String? =
            selectedImages.isEmpty
            ? nil
            : "Photos and clip frames are attached below, labelled with the finding they belong to, newest findings first, at most 6. Describe what you see only as far as it bears on a suspect, and say when an image is too unclear to judge."
                + (imageItems.count > selectedImages.count
                    ? " Older findings' images are left out; their words are above." : "")
        let prompt = """
            Diagnose this problem, \(title). The owner noticed: "\(text)"
            Notes the owner added:
            \(noteText)
            Findings from inspections the owner has done:
            \(findingText)
            Write a careful technician's reading of what the board, the owner's words, and the findings add up to for this problem.
            The reading must be at most three sentences of plain prose, with no lists or headings.
            List the symptoms you are working from, in the owner's terms, at most eight, each a short phrase. Symptoms are what the owner noticed, not codes and not findings.
            Rank at most five suspects, most likely first. For each give the evidence for and against it in a sentence or two and list the symptoms it explains by zero-based index into your symptoms list (the first symptom is 0). Confidence is high, medium, or low.
            Codes on the board, with their public names; use these names and do not rename or reinterpret a code's identity. The parts these codes came from have been read; never propose reading them again:
            \(codeText)
            Not read yet:
            \(unreadText)
            Propose checks only for parts listed as not read yet, and say which suspects each would tell apart by zero-based index into your suspects list (the first suspect is 0). When nothing is listed as not read yet, `checks` is an empty array. The adapter check is allowed only when Battery is listed as not read yet. Never propose vehicle_info when the briefing already has a VIN.
            Propose at most five inspections the owner can do safely with no tools beyond a flashlight: looking, listening, pressing, turning, and reading fuse labels; no multimeter or test light, and no removing trim, panels, the horn pad, the steering wheel, or any airbag part. Each has a short imperative title, the steps, what to look for, a safety line when one is due, which suspects it tells apart by zero-based index, and what each outcome would mean. Never propose an inspection that already has a finding, and never one whose answer the owner has already given. Never ask the owner to probe, unplug, or measure SRS or airbag circuits, work on fuel or high-voltage parts, or get under a lifted car; that work belongs in the fix, as a job for a shop.
            Ask at most three questions, only when an answer would change what to do next. Tag a question with the module label it concerns, and list every printed code it concerns in `codes`; leave `codes` empty when it's about the module or the car as a whole. Never repeat an answered question.
            Give a conclusion only when one suspect stands at high confidence and the findings rule the others out or leave them far behind: the cause, the fix in the owner's terms (what to do, or what to tell a shop), and your confidence, which is then high. Otherwise set conclusion to null; never give a conclusion at medium or low confidence.
            Manufacturer-code meanings are interpretations, not verified descriptions.
            A failure-type meaning beside a code is from the standard's categories; use it as given. When it says the byte is not described, say what the byte means if you know, and label it a guess otherwise.
            \(evidenceParagraph.map { "\n\($0)\n" } ?? "")
            Already answered questions:
            \(answers)

            Use record_diagnosis.
            """
        var parts: [MessagePart] = [.text(prompt)]
        parts += selectedImages.flatMap { item -> [MessagePart] in
            [
                .text(
                    "Evidence for \"\(item.finding.title)\": \(item.kind) \(item.index) of \(item.total)"
                ),
                .image(item.image),
            ]
        }
        return AssistantRequest(
            instructions: AssistantInstructions.make(
                briefing: briefing, provider: provider, sharing: sharing),
            messages: [.init(role: .user, parts: parts)],
            tools: [DiagnosisTool.definition(modules: briefing.modules.map(\.label))],
            maxOutputTokens: 4000, toolChoice: .tool(DiagnosisTool.name))
    }

    /// One photo or clip frame on its way into the message, with the label that ties it to its
    /// finding.
    private struct AttachedImage {
        let finding: Finding
        let kind: String
        let index: Int
        let total: Int
        let image: ImageInput
    }

    private static func findingLine(_ finding: Finding) -> String {
        let pieces = [
            finding.photos.isEmpty
                ? nil : "\(finding.photos.count) photo\(finding.photos.count == 1 ? "" : "s")",
            finding.clips.map(clipDescription).joined(separator: ", ").nilIfEmpty,
            soundDescription(finding.sounds),
        ].compactMap { $0 }
        let evidence = pieces.isEmpty ? "" : " (\(pieces.joined(separator: "; ")))"
        return "- \(finding.title): \(finding.text)\(evidence)"
    }

    private static func clipDescription(_ clip: Clip) -> String {
        "a \(Int(clip.duration.rounded()))-second clip, shown as \(clip.frames.count) frames"
    }

    private static func soundDescription(_ sounds: [TimeInterval]) -> String? {
        guard !sounds.isEmpty else { return nil }
        if sounds.count == 1 {
            return "a \(Int(sounds[0].rounded()))-second sound recording you can't hear"
        }
        let durations = sounds.map { "\(Int($0.rounded()))" }.joined(separator: " and ")
        return "\(sounds.count) sound recordings you can't hear, \(durations) seconds"
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
