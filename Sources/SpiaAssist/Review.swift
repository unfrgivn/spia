import Foundation
import SpiaKit

public enum ReviewScope: Codable, Sendable, Hashable, Equatable {
    case car
    case problem(UUID)
}

public struct ReviewQuestion: Codable, Sendable, Equatable {
    public let question: String
    public let module: String?
    public let codes: [String]

    public init(question: String, module: String?, codes: [String]) {
        self.question = question
        self.module = module
        self.codes = codes
    }
}

public struct ReviewResult: Codable, Sendable, Equatable {
    public let reading: String
    public let questions: [ReviewQuestion]
    public let checks: [CheckProposal]

    public init(reading: String, questions: [ReviewQuestion], checks: [CheckProposal]) {
        self.reading = reading
        self.questions = questions
        self.checks = checks
    }
}

public enum ReviewTool {
    public static let name = "record_review"

    public static func definition(modules: [String]) -> ToolDefinition {
        let module: JSONValue = [
            "type": ["string", "null"],
            "enum": .array(modules.map { .string($0) } + [.null]),
        ]
        return ToolDefinition(
            name: name,
            description: "Record the technician's review of the vehicle.",
            parameters: [
                "type": "object",
                "properties": [
                    "reading": ["type": "string"],
                    "questions": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "question": ["type": "string"],
                                "module": module,
                                "codes": [
                                    "type": "array",
                                    "items": ["type": "string"],
                                ],
                            ],
                            "required": ["question", "module", "codes"],
                            "additionalProperties": false,
                        ],
                    ],
                    "checks": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "check": [
                                    "type": "string",
                                    "enum": .array(CheckKind.allCases.map { .string($0.rawValue) }),
                                ],
                                "module": module,
                                "reason": ["type": "string"],
                            ],
                            "required": ["check", "module", "reason"],
                            "additionalProperties": false,
                        ],
                    ],
                ],
                "required": ["reading", "questions", "checks"],
                "additionalProperties": false,
            ])
    }

    public static func parse(_ call: ToolCall, modules: [String]) throws -> ReviewResult {
        guard call.name == name, let value = try? JSONValue.parse(call.arguments),
            case .object(let root) = value,
            Set(root.keys) == ["reading", "questions", "checks"],
            let reading = root["reading"]?.string,
            case .array(let questionValues)? = root["questions"],
            case .array(let checkValues)? = root["checks"], questionValues.count <= 3
        else { throw AssistantError.malformedStream("invalid review") }
        let questions = try parseQuestions(questionValues, modules: modules)
        let checks = try checkValues.map { item -> CheckProposal in
            guard case .object(let object) = item,
                Set(object.keys) == ["check", "module", "reason"],
                let raw = object["check"]?.string, let check = CheckKind(rawValue: raw),
                let reason = object["reason"]?.string
            else { throw AssistantError.malformedStream("invalid review check") }
            let module = object["module"]?.string
            if let module,
                !modules.contains(where: { $0.caseInsensitiveCompare(module) == .orderedSame })
            {
                throw AssistantError.malformedStream("unknown review check module \"\(module)\"")
            }
            return CheckProposal(check: check, module: module, reason: reason)
        }
        return ReviewResult(reading: reading, questions: questions, checks: checks)
    }

    static func parseQuestions(_ values: [JSONValue], modules: [String]) throws -> [ReviewQuestion]
    {
        try values.map { item -> ReviewQuestion in
            guard case .object(let object) = item,
                Set(object.keys) == ["question", "module", "codes"],
                let question = object["question"]?.string, !question.isEmpty
            else {
                throw AssistantError.malformedStream("invalid review question")
            }
            let module = object["module"]?.string
            if let module,
                !modules.contains(where: { $0.caseInsensitiveCompare(module) == .orderedSame })
            {
                throw AssistantError.malformedStream("unknown review module \"\(module)\"")
            }
            guard case .array(let codeValues)? = object["codes"] else {
                throw AssistantError.malformedStream("invalid review question codes")
            }
            let codes = try codeValues.map { value -> String in
                guard let code = value.string else {
                    throw AssistantError.malformedStream("invalid review code")
                }
                guard validCode(code) else {
                    throw AssistantError.malformedStream("invalid review code \"\(code)\"")
                }
                return code
            }
            return ReviewQuestion(question: question, module: module, codes: codes)
        }
    }

    static func validCode(_ code: String) -> Bool {
        if CodeName(code) != nil { return true }
        let parts = code.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1].count == 2,
            parts[1].allSatisfy(\.isHexDigit), CodeName(String(parts[0])) != nil
        else { return false }
        return true
    }
}

public enum ReviewRequest {
    public enum Scope: Sendable, Equatable {
        case car
        case problem(title: String, text: String)
    }

    public static func make(
        briefing: SessionBriefing, scope: Scope, answered: [(question: String, answer: String)],
        codes: [(
            printed: String, name: String?, failureType: String?
        )], unread: [String], provider: ProviderID,
        sharing: SharingPolicy
    ) -> AssistantRequest {
        let subject: String
        switch scope {
        case .car: subject = "Review the board for this car."
        case .problem(let title, let text):
            subject = "Review the board for this problem, \(title). The owner noticed: \"\(text)\""
        }
        let answers =
            answered.isEmpty
            ? "No questions have been answered yet."
            : answered.map { "- Q: \($0.question)\n  A: \($0.answer)" }.joined(separator: "\n")
        let codeText =
            codes.isEmpty
            ? "- None"
            : codes.map {
                let details = [
                    $0.name ?? "manufacturer-specific, no public name",
                    $0.failureType.map { "failure type \($0)" },
                ]
                .compactMap { $0 }
                .joined(separator: "; ")
                return "- \($0.printed): \(details)"
            }
            .joined(separator: "\n")
        let unreadText =
            unread.isEmpty ? "- None" : unread.map { "- \($0)" }.joined(separator: "\n")
        let prompt = """
            \(subject)
            Write a careful technician's reading of what the board adds up to for this car or problem.
            The reading must be at most three sentences of plain prose, with no lists or headings.
            Ask at most three questions, only when an answer would change what to do next. Tag a question
            with the module label it concerns, and list every printed code it concerns in `codes`; leave
            `codes` empty when it's about the module or the car as a whole. Never repeat an answered question.
            Codes on the board, with their public names; use these names and do not rename or reinterpret a code's identity:
            \(codeText)
            Not read yet:
            \(unreadText)
            Propose checks only for parts listed as not read yet. The adapter check is allowed only when Battery is
            listed as not read yet. Never propose vehicle_info when the briefing already has a VIN.
            Manufacturer-code meanings are interpretations, not verified descriptions.
            A failure-type meaning beside a code is from the standard's categories; use it as given. When it says the byte is not described, say what the byte means if you know, and label it a guess otherwise.

            Already answered questions:
            \(answers)

            Use record_review.
            """
        return AssistantRequest(
            instructions: AssistantInstructions.make(
                briefing: briefing, provider: provider, sharing: sharing),
            messages: [.init(role: .user, parts: [.text(prompt)])],
            tools: [ReviewTool.definition(modules: briefing.modules.map(\.label))],
            maxOutputTokens: 900,
            toolChoice: .tool(ReviewTool.name))
    }
}
