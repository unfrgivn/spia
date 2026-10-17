import Foundation
import SpiaKit

public struct ToolDefinition: Sendable, Equatable {
    public let name: String
    public let description: String
    /// JSON Schema for the arguments. Every property required, no extras, so it works with
    /// OpenAI strict mode and Anthropic alike.
    public let parameters: JSONValue
}

/// The kinds of check the assistant may propose. Mirrors the read-only `DiagnosticJob` list.
public enum CheckKind: String, Codable, Sendable, CaseIterable {
    case genericScan = "generic_scan"
    case vehicleInfo = "vehicle_info"
    case adapterCheck = "adapter_check"
    case moduleCodes = "module_codes"
}

/// A check the assistant wants to run. Nothing runs until the user approves it.
public struct CheckProposal: Codable, Sendable, Equatable {
    public let check: CheckKind
    /// For `module_codes`: the module's label exactly as listed in the session data.
    public let module: String?
    /// Why this check, in the assistant's words, shown to the user.
    public let reason: String

    public init(check: CheckKind, module: String?, reason: String) {
        self.check = check
        self.module = module
        self.reason = reason
    }

    public enum Invalid: Error, Equatable, Sendable, CustomStringConvertible {
        case moduleRequired
        case unknownModule(String)

        public var description: String {
            switch self {
            case .moduleRequired:
                return "module_codes needs a module from the session's module list"
            case .unknownModule(let name): return "\"\(name)\" is not one of this vehicle's modules"
            }
        }
    }

    /// The concrete job, resolving module labels against the vehicle's own module list.
    public func job(modules: [(label: String, target: ModuleTarget)]) throws -> DiagnosticJob {
        switch check {
        case .genericScan: return .genericScan
        case .vehicleInfo: return .vehicleInfo
        case .adapterCheck: return .adapterCheck
        case .moduleCodes:
            guard let module, !module.isEmpty else { throw Invalid.moduleRequired }
            guard
                let match = modules.first(where: {
                    $0.label.caseInsensitiveCompare(module) == .orderedSame
                })
            else { throw Invalid.unknownModule(module) }
            return .moduleDTCs(match.target)
        }
    }
}

public enum AssistantAction: Sendable, Equatable {
    case proposeCheck(CheckProposal)
    case askUser(question: String)
    /// Answered by the app straight away: nothing on the car is involved.
    case searchBulletins(query: String)
}

public enum AssistantTools {
    public static let proposeCheckName = "propose_check"
    public static let askUserName = "ask_user"
    public static let searchBulletinsName = "search_bulletins"

    /// Tools offered to the model. `modules` are the vehicle's module labels, offered as an enum
    /// so the model can only pick modules that exist. Bulletin search is offered only when the
    /// vehicle's bulletins are loaded.
    public static func definitions(modules: [String], bulletins: Bool = false) -> [ToolDefinition] {
        let moduleSchema: JSONValue =
            modules.isEmpty
            ? ["type": "null", "description": "This vehicle has no modules configured."]
            : [
                "type": ["string", "null"],
                "enum": .array(modules.map { .string($0) } + [.null]),
                "description":
                    "Required for module_codes: one of the vehicle's modules. Null otherwise.",
            ]
        return [
            ToolDefinition(
                name: proposeCheckName,
                description: """
                    Propose one read-only diagnostic check. The user sees the reason and decides whether \
                    to run it; you receive the result afterwards. Checks: generic_scan (standard engine \
                    and transmission codes, readiness, freeze frame), vehicle_info (VIN, software IDs), \
                    adapter_check (adapter identity and battery voltage), module_codes (trouble codes from \
                    one module such as the airbag controller). Nothing else can be run.
                    """,
                parameters: [
                    "type": "object",
                    "properties": [
                        "check": [
                            "type": "string",
                            "enum": .array(CheckKind.allCases.map { .string($0.rawValue) }),
                        ],
                        "module": moduleSchema,
                        "reason": [
                            "type": "string",
                            "description": "One or two sentences on what this check will tell us.",
                        ],
                    ],
                    "required": ["check", "module", "reason"],
                    "additionalProperties": false,
                ]),
            ToolDefinition(
                name: askUserName,
                description: """
                    Ask the person at the car one focused question, when their answer changes what to do \
                    next (what they see, hear, or feel; when it happens; what was done recently).
                    """,
                parameters: [
                    "type": "object",
                    "properties": ["question": ["type": "string"]],
                    "required": ["question"],
                    "additionalProperties": false,
                ]),
        ] + (bulletins ? [searchBulletins] : [])
    }

    static let searchBulletins = ToolDefinition(
        name: searchBulletinsName,
        description: """
            Search the manufacturer's service bulletins filed with NHTSA for this make, model, and \
            year, by keywords (e.g. "steering wheel horn", "clock spring", "airbag lamp"). Returns \
            the best matches with number, date, title, summary, and components. Runs immediately; \
            the person doesn't need to approve it.
            """,
        parameters: [
            "type": "object",
            "properties": [
                "query": [
                    "type": "string", "description": "A few keywords describing the fault or part.",
                ]
            ],
            "required": ["query"],
            "additionalProperties": false,
        ])

    public enum ParseError: Error, Equatable, Sendable, CustomStringConvertible {
        case unknownTool(String)
        case badArguments(String)

        public var description: String {
            switch self {
            case .unknownTool(let name): return "unknown tool \(name)"
            case .badArguments(let detail): return "invalid tool arguments: \(detail)"
            }
        }
    }

    public static func parse(_ call: ToolCall) throws -> AssistantAction {
        let arguments: JSONValue
        do {
            arguments = try JSONValue.parse(call.arguments)
        } catch {
            throw ParseError.badArguments(call.arguments)
        }
        switch call.name {
        case proposeCheckName:
            guard let raw = arguments["check"]?.string, let check = CheckKind(rawValue: raw),
                let reason = arguments["reason"]?.string
            else { throw ParseError.badArguments(call.arguments) }
            return .proposeCheck(
                CheckProposal(check: check, module: arguments["module"]?.string, reason: reason))
        case askUserName:
            guard let question = arguments["question"]?.string, !question.isEmpty else {
                throw ParseError.badArguments(call.arguments)
            }
            return .askUser(question: question)
        case searchBulletinsName:
            guard let query = arguments["query"]?.string,
                !query.trimmingCharacters(in: .whitespaces).isEmpty
            else { throw ParseError.badArguments(call.arguments) }
            return .searchBulletins(query: query)
        default:
            throw ParseError.unknownTool(call.name)
        }
    }
}
