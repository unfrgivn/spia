import Foundation
import SpiaKit

public struct CodeInterpretation: Codable, Sendable, Equatable {
    public let code: String
    public let module: String?
    public let name: String
    public let meaning: String
    public let firstCheck: String
    public let confidence: String
    public init(
        code: String, name: String, meaning: String, firstCheck: String, confidence: String,
        module: String? = nil
    ) {
        self.code = code; self.module = module; self.name = name; self.meaning = meaning;
        self.firstCheck = firstCheck
        self.confidence = confidence
    }
}

public struct ModuleInterpretation: Codable, Sendable, Equatable {
    public let name: String
    public let role: String
    public init(name: String, role: String) { self.name = name; self.role = role }
}

public struct InterpretationResult: Codable, Sendable, Equatable {
    public let codes: [CodeInterpretation]
    public let module: ModuleInterpretation?
    public init(codes: [CodeInterpretation], module: ModuleInterpretation?) {
        self.codes = codes
        self.module = module
    }
}

public enum InterpretationTool {
    public static let name = "record_interpretations"
    public static let definition = ToolDefinition(
        name: name, description: "Record structured code explanations.",
        parameters: [
            "type": "object",
            "properties": [
                "codes": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "code": ["type": "string"], "module": ["type": ["string", "null"]],
                            "name": ["type": "string"],
                            "meaning": ["type": "string"],
                            "first_check": ["type": "string"],
                            "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                        ],
                        "required": [
                            "code", "module", "name", "meaning", "first_check", "confidence",
                        ],
                        "additionalProperties": false,
                    ],
                ],
                "module": [
                    "type": ["object", "null"],
                    "properties": ["name": ["type": "string"], "role": ["type": "string"]],
                    "required": ["name", "role"], "additionalProperties": false,
                ],
            ], "required": ["codes", "module"], "additionalProperties": false,
        ])

    public static func parse(_ call: ToolCall, modules: [String] = []) throws
        -> InterpretationResult
    {
        guard call.name == name, let value = try? JSONValue.parse(call.arguments),
            case .array(let values)? = value["codes"]
        else { throw AssistantError.malformedStream("invalid interpretation") }
        let codes = try values.map { item -> CodeInterpretation in
            guard let code = item["code"]?.string, let moduleValue = item["module"],
                let name = item["name"]?.string,
                let meaning = item["meaning"]?.string, let check = item["first_check"]?.string,
                let confidence = item["confidence"]?.string,
                ["high", "medium", "low"].contains(confidence)
            else { throw AssistantError.malformedStream("invalid interpretation code") }
            let module = moduleValue.string
            if let module, !modules.isEmpty,
                !modules.contains(where: { $0.caseInsensitiveCompare(module) == .orderedSame })
            {
                throw AssistantError.malformedStream("unknown interpretation module \"\(module)\"")
            }
            return CodeInterpretation(
                code: code, name: name, meaning: meaning, firstCheck: check, confidence: confidence,
                module: module)
        }
        let module: ModuleInterpretation?
        switch value["module"] {
        case .some(.null), nil: module = nil
        case .some(let object):
            guard let name = object["name"]?.string, let role = object["role"]?.string else {
                throw AssistantError.malformedStream("invalid interpretation module")
            }
            module = ModuleInterpretation(name: name, role: role)
        }
        return InterpretationResult(codes: codes, module: module)
    }
}

public struct InterpretationCodeInput: Sendable, Equatable {
    public let code: String
    public let catalogName: String?
    public let failureType: String?
    public init(code: String, catalogName: String?, failureType: String? = nil) {
        self.code = code
        self.catalogName = catalogName
        self.failureType = failureType
    }
}

public struct InterpretationModuleInput: Sendable, Equatable {
    public let module: SessionBriefing.ModuleFacts?
    public let codes: [InterpretationCodeInput]
    public let nameModule: Bool

    public init(
        module: SessionBriefing.ModuleFacts?, codes: [InterpretationCodeInput], nameModule: Bool
    ) {
        self.module = module
        self.codes = codes
        self.nameModule = nameModule
    }
}

public enum InterpretationRequest {
    public static func make(
        briefing: SessionBriefing, module: SessionBriefing.ModuleFacts?,
        codes: [InterpretationCodeInput], nameModule: Bool = false, provider: ProviderID,
        sharing: SharingPolicy
    ) -> AssistantRequest {
        make(
            briefing: briefing,
            modules: [
                InterpretationModuleInput(module: module, codes: codes, nameModule: nameModule)
            ], provider: provider, sharing: sharing)
    }

    public static func make(
        briefing: SessionBriefing, modules: [InterpretationModuleInput], provider: ProviderID,
        sharing: SharingPolicy
    ) -> AssistantRequest {
        let sections = modules.enumerated().map { index, input in
            let moduleText =
                input.module.map { facts in
                    "Module: \(facts.label), bus \(facts.bus), request \(facts.request), reply \(facts.reply)."
                } ?? "Module: engine generic scan."
            let codeText = input.codes.map {
                let details = [
                    $0.catalogName ?? "no public description",
                    $0.failureType.map { "failure type \($0)" },
                ]
                .compactMap { $0 }
                .joined(separator: "; ")
                return "- \($0.code) (\(details))"
            }.joined(separator: "\n")
            let naming =
                input.module.map { _ in
                    input.nameModule
                        ? "Name this module: its only label is a placeholder."
                        : "`module` must be null: this module is already named."
                } ?? "The engine generic scan has no module to name."
            return
                "Module group \(index + 1)\n\(moduleText)\n\(naming)\nCodes, read from this module by this app with their status bytes:\n\(codeText)"
        }.joined(separator: "\n\n")
        let prompt = """
            \(sections)

            A public name beside a code is its SAE definition; treat it as reliable, not as a guess, and never propose reading the code again. A failure-type meaning beside a code is from the standard's categories; use it as given. When it says the byte is not described, say what the byte means if you know, and label it a guess otherwise. Use record_interpretations. Give each code a technician's name, its meaning on this car in at most two sentences including the failure-type byte when present, the first physical thing to check, and confidence. Label guesses as guesses.
            Set each code's `module` to the exact module heading it belongs to, or null for the engine generic scan.
            """
        let tokens = modules.reduce(0) { $0 + $1.codes.count * 300 + ($1.nameModule ? 200 : 0) }
        return AssistantRequest(
            instructions: AssistantInstructions.make(
                briefing: briefing, provider: provider, sharing: sharing),
            messages: [.init(role: .user, parts: [.text(prompt)])],
            tools: [InterpretationTool.definition],
            maxOutputTokens: min(4000, max(600, tokens)), toolChoice: .tool(InterpretationTool.name)
        )
    }
}
