import Foundation
import SpiaKit

public struct CodeInterpretation: Codable, Sendable, Equatable {
    public let code: String
    public let name: String
    public let meaning: String
    public let firstCheck: String
    public let confidence: String
    public init(code: String, name: String, meaning: String, firstCheck: String, confidence: String)
    {
        self.code = code; self.name = name; self.meaning = meaning; self.firstCheck = firstCheck
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
                            "code": ["type": "string"], "name": ["type": "string"],
                            "meaning": ["type": "string"],
                            "first_check": ["type": "string"],
                            "confidence": ["type": "string", "enum": ["high", "medium", "low"]],
                        ], "required": ["code", "name", "meaning", "first_check", "confidence"],
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

    public static func parse(_ call: ToolCall) throws -> InterpretationResult {
        guard call.name == name, let value = try? JSONValue.parse(call.arguments),
            case .array(let values)? = value["codes"]
        else { throw AssistantError.malformedStream("invalid interpretation") }
        let codes = try values.map { item -> CodeInterpretation in
            guard let code = item["code"]?.string, let name = item["name"]?.string,
                let meaning = item["meaning"]?.string, let check = item["first_check"]?.string,
                let confidence = item["confidence"]?.string,
                ["high", "medium", "low"].contains(confidence)
            else { throw AssistantError.malformedStream("invalid interpretation code") }
            return CodeInterpretation(
                code: code, name: name, meaning: meaning, firstCheck: check, confidence: confidence)
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
    public init(code: String, catalogName: String?) {
        self.code = code; self.catalogName = catalogName
    }
}

public enum InterpretationRequest {
    public static func make(
        briefing: SessionBriefing, module: SessionBriefing.ModuleFacts?,
        codes: [InterpretationCodeInput], provider: ProviderID, sharing: SharingPolicy
    ) -> AssistantRequest {
        let moduleText =
            module.map {
                "Module: \($0.label), bus \($0.bus), request \($0.request), reply \($0.reply)."
            } ?? "Module: engine generic scan."
        let codeText = codes.map { "- \($0.code) (\($0.catalogName ?? "no public description"))" }
            .joined(separator: "\n")
        let prompt = """
            \(moduleText)
            Codes:
            \(codeText)

            Use record_interpretations. Give each code a technician's name, its meaning on this car in at most two sentences including the failure-type byte when present, the first thing to check, and confidence. Label guesses as guesses. Name and give the role of a fallback module, otherwise return null.
            """
        return AssistantRequest(
            instructions: AssistantInstructions.make(
                briefing: briefing, provider: provider, sharing: sharing),
            messages: [.init(role: .user, parts: [.text(prompt)])],
            tools: [InterpretationTool.definition], toolChoice: .tool(InterpretationTool.name))
    }
}
