import Foundation
import SpiaAssist
import SpiaKit
import Testing

private let diagnosisModules = ["Airbag controller (ORC)", "Steering column module (SCCM)"]

private func diagnosisText(_ request: AssistantRequest) -> String {
    request.messages.flatMap(\.parts).compactMap { part in
        if case .text(let text) = part { return text }
        return nil
    }.joined(separator: "\n")
}

private func diagnosisBriefing(
    vin: String? = "SECRET", events: [SessionBriefing.Event] = []
) -> SessionBriefing {
    SessionBriefing(
        vehicle: .init(name: "2017 Maserati Ghibli S Q4", vin: vin, notes: ""),
        problem: "Horn and steering-wheel controls are dead.",
        modules: diagnosisModules.map {
            .init(label: $0, bus: "hs", request: "744", reply: "4C4", labelConfirmed: true)
        }, adapter: nil, events: events)
}

private func realisticDiagnosisCall() -> ToolCall {
    ToolCall(
        id: "diagnosis-1", name: DiagnosisTool.name,
        arguments: #"""
            {
              "reading": "The simultaneous loss of the horn and steering-wheel controls points first to an open clock spring circuit.",
              "symptoms": [
                "Steering wheel controls dead",
                "Horn dead",
                "Airbag lamp on",
                "Paddles and wiper stalk work"
              ],
              "suspects": [
                {
                  "name": "Clock spring",
                  "why": "It connects the wheel controls and horn while an open circuit can also illuminate the airbag lamp.",
                  "confidence": "high",
                  "symptoms": [
                    0,
                    1,
                    2
                  ]
                },
                {
                  "name": "Steering wheel switch pack",
                  "why": "A failed switch pack could explain dead controls but not the horn and airbag lamp together.",
                  "confidence": "low",
                  "symptoms": [
                    0
                  ]
                }
              ],
              "checks": [
                {
                  "check": "module_codes",
                  "module": "Steering column module (SCCM)",
                  "reason": "Read the SCCM codes to separate a clock spring fault from switch inputs.",
                  "suspects": [
                    0,
                    1
                  ]
                }
              ],
              "inspections": [
                {
                  "title": "Press the horn with the key on",
                  "steps": "Press the horn briefly with the key on.",
                  "look_for": "Listen for the horn and watch the airbag lamp.",
                  "safety": "Keep clear of the steering wheel while testing.",
                  "suspects": [
                    0
                  ],
                  "tells_apart": "A silent horn supports the clock spring suspect."
                },
                {
                  "title": "Try each wheel button",
                  "steps": "Turn the key on and press each steering-wheel button.",
                  "look_for": "Check whether any button responds.",
                  "safety": null,
                  "suspects": [
                    0,
                    1
                  ],
                  "tells_apart": "A completely dead pack supports the clock spring."
                }
              ],
              "questions": [
                {
                  "question": "Does code B0001-1B return after clearing is not available?",
                  "module": "Steering column module (SCCM)",
                  "codes": [
                    "B0001-1B"
                  ]
                },
                {
                  "question": "Did the symptoms begin after steering-wheel work?",
                  "module": null,
                  "codes": []
                }
              ],
              "conclusion": null
            }
            """#
    )
}

@Suite("Diagnosis assistant")
struct DiagnosisTests {
    @Test("record_diagnosis is strict at every object level")
    func strictDefinition() {
        assertStrict(DiagnosisTool.definition(modules: diagnosisModules).parameters)
    }

    @Test("record_diagnosis parses the Ghibli steering-wheel case")
    func parsesRealisticCall() throws {
        let result = try DiagnosisTool.parse(realisticDiagnosisCall(), modules: diagnosisModules)
        #expect(
            result.reading
                == "The simultaneous loss of the horn and steering-wheel controls points first to an open clock spring circuit."
        )
        #expect(
            result.symptoms == [
                "Steering wheel controls dead", "Horn dead", "Airbag lamp on",
                "Paddles and wiper stalk work",
            ])
        #expect(
            result.suspects == [
                .init(
                    name: "Clock spring",
                    why:
                        "It connects the wheel controls and horn while an open circuit can also illuminate the airbag lamp.",
                    confidence: .high, symptoms: [0, 1, 2]),
                .init(
                    name: "Steering wheel switch pack",
                    why:
                        "A failed switch pack could explain dead controls but not the horn and airbag lamp together.",
                    confidence: .low, symptoms: [0]),
            ])
        #expect(
            result.checks == [
                .init(
                    proposal: .init(
                        check: .moduleCodes, module: "Steering column module (SCCM)",
                        reason:
                            "Read the SCCM codes to separate a clock spring fault from switch inputs."
                    ), suspects: [0, 1])
            ])
        #expect(result.inspections.count == 2)
        #expect(result.inspections[0].safety == "Keep clear of the steering wheel while testing.")
        #expect(result.inspections[1].safety == nil)
        #expect(result.questions.count == 2)
        #expect(result.conclusion == nil)
    }

    @Test("record_diagnosis parses a conclusion")
    func parsesConclusion() throws {
        let call = ToolCall(
            id: "1", name: DiagnosisTool.name,
            arguments:
                #"{"reading":"r","symptoms":["s"],"suspects":[{"name":"n","why":"w","confidence":"high","symptoms":[0]}],"checks":[],"inspections":[],"questions":[],"conclusion":{"cause":"The clock spring is open.","fix":"Replace the clock spring using the SRS procedure.","confidence":"high"}}"#
        )
        #expect(
            try DiagnosisTool.parse(call, modules: diagnosisModules).conclusion
                == .init(
                    cause: "The clock spring is open.",
                    fix: "Replace the clock spring using the SRS procedure.", confidence: .high))
    }

    @Test("record_diagnosis rejects invalid bounded and referenced values")
    func rejectsInvalidValues() {
        let cases = [
            (
                "unknown check module",
                #"{"reading":"r","symptoms":[],"suspects":[],"checks":[{"check":"module_codes","module":"Engine","reason":"r","suspects":[]}],"inspections":[],"questions":[],"conclusion":null}"#
            ),
            (
                "unknown question module",
                #"{"reading":"r","symptoms":[],"suspects":[],"checks":[],"inspections":[],"questions":[{"question":"q","module":"Engine","codes":[]}],"conclusion":null}"#
            ),
            (
                "fourth question",
                #"{"reading":"r","symptoms":[],"suspects":[],"checks":[],"inspections":[],"questions":[{"question":"1","module":null,"codes":[]},{"question":"2","module":null,"codes":[]},{"question":"3","module":null,"codes":[]},{"question":"4","module":null,"codes":[]}],"conclusion":null}"#
            ),
            (
                "sixth suspect",
                #"{"reading":"r","symptoms":[],"suspects":[{"name":"n","why":"w","confidence":"high","symptoms":[]},{"name":"n","why":"w","confidence":"high","symptoms":[]},{"name":"n","why":"w","confidence":"high","symptoms":[]},{"name":"n","why":"w","confidence":"high","symptoms":[]},{"name":"n","why":"w","confidence":"high","symptoms":[]},{"name":"n","why":"w","confidence":"high","symptoms":[]}],"checks":[],"inspections":[],"questions":[],"conclusion":null}"#
            ),
            (
                "ninth symptom",
                #"{"reading":"r","symptoms":["1","2","3","4","5","6","7","8","9"],"suspects":[],"checks":[],"inspections":[],"questions":[],"conclusion":null}"#
            ),
            (
                "sixth inspection",
                #"{"reading":"r","symptoms":[],"suspects":[],"checks":[],"inspections":[{"title":"t","steps":"s","look_for":"l","safety":null,"suspects":[],"tells_apart":"a"},{"title":"t","steps":"s","look_for":"l","safety":null,"suspects":[],"tells_apart":"a"},{"title":"t","steps":"s","look_for":"l","safety":null,"suspects":[],"tells_apart":"a"},{"title":"t","steps":"s","look_for":"l","safety":null,"suspects":[],"tells_apart":"a"},{"title":"t","steps":"s","look_for":"l","safety":null,"suspects":[],"tells_apart":"a"},{"title":"t","steps":"s","look_for":"l","safety":null,"suspects":[],"tells_apart":"a"}],"questions":[],"conclusion":null}"#
            ),
            (
                "suspect symptom index",
                #"{"reading":"r","symptoms":["s"],"suspects":[{"name":"n","why":"w","confidence":"high","symptoms":[1]}],"checks":[],"inspections":[],"questions":[],"conclusion":null}"#
            ),
            (
                "check suspect index",
                #"{"reading":"r","symptoms":[],"suspects":[],"checks":[{"check":"generic_scan","module":null,"reason":"r","suspects":[0]}],"inspections":[],"questions":[],"conclusion":null}"#
            ),
            (
                "inspection suspect index",
                #"{"reading":"r","symptoms":[],"suspects":[],"checks":[],"inspections":[{"title":"t","steps":"s","look_for":"l","safety":null,"suspects":[0],"tells_apart":"a"}],"questions":[],"conclusion":null}"#
            ),
            (
                "bad code",
                #"{"reading":"r","symptoms":[],"suspects":[],"checks":[],"inspections":[],"questions":[{"question":"q","module":null,"codes":["not-a-code"]}],"conclusion":null}"#
            ),
            (
                "extra root key",
                #"{"reading":"r","symptoms":[],"suspects":[],"checks":[],"inspections":[],"questions":[],"conclusion":null,"extra":true}"#
            ),
            (
                "empty inspection title",
                #"{"reading":"r","symptoms":[],"suspects":[],"checks":[],"inspections":[{"title":" ","steps":"s","look_for":"l","safety":null,"suspects":[],"tells_apart":"a"}],"questions":[],"conclusion":null}"#
            ),
            (
                "empty conclusion fix",
                #"{"reading":"r","symptoms":[],"suspects":[],"checks":[],"inspections":[],"questions":[],"conclusion":{"cause":"c","fix":" ","confidence":"high"}}"#
            ),
            (
                "invalid confidence",
                #"{"reading":"r","symptoms":[],"suspects":[{"name":"n","why":"w","confidence":"certain","symptoms":[]}],"checks":[],"inspections":[],"questions":[],"conclusion":null}"#
            ),
        ]
        for (name, arguments) in cases {
            let call = ToolCall(id: name, name: DiagnosisTool.name, arguments: arguments)
            #expect(throws: Error.self) { try DiagnosisTool.parse(call, modules: diagnosisModules) }
        }
    }

    @Test("diagnosis request includes owner evidence and safety instructions")
    func request() {
        let request = DiagnosisRequest.make(
            briefing: diagnosisBriefing(), title: "Horn controls",
            text: "The horn stopped after rain.",
            notes: ["The lamp stayed on."],
            answered: [(question: "Was the battery disconnected?", answer: "Yes, yesterday.")],
            findings: [.init(title: "Fuse check", text: "The fuse is intact.", date: .now)],
            codes: [
                (
                    printed: "B0001-1B", name: "Driver Frontal Stage 1 Deployment Control",
                    failureType: "1B: resistance in the circuit is too high"
                )
            ],
            unread: ["Steering column module (SCCM)"], provider: .anthropic,
            sharing: .init(includeVIN: false))
        let text = diagnosisText(request) + request.instructions
        for phrase in [
            "Horn controls", "The horn stopped after rain.", "The lamp stayed on.", "Fuse check",
            "The fuse is intact.", "Was the battery disconnected?", "Yes, yesterday.", "B0001-1B",
            "Driver Frontal Stage 1 Deployment Control", "failure type 1B", "Not read yet",
            "at most three sentences", "Never propose an inspection that already has a finding",
            "SRS or airbag circuits", "set conclusion to null", "record_diagnosis",
        ] { #expect(text.contains(phrase)) }
        #expect(!text.contains("SECRET"))
        #expect(request.toolChoice == .tool(DiagnosisTool.name))
        #expect(request.maxOutputTokens == 4000)
    }

    @Test("diagnosis request uses None for absent notes and findings")
    func emptyEvidence() {
        let request = DiagnosisRequest.make(
            briefing: diagnosisBriefing(vin: nil), title: "t", text: "x", notes: [], answered: [],
            findings: [], codes: [], unread: [], provider: .anthropic,
            sharing: .init(includeVIN: false))
        let text = diagnosisText(request)
        #expect(text.contains("Notes the owner added:\n- None"))
        #expect(text.contains("Findings from inspections the owner has done:\n- None"))
    }

    @Test("diagnosis request labels and includes finding images")
    func findingImages() {
        let finding = DiagnosisRequest.Finding(
            title: "Horn test", text: "No sound.", date: Date(timeIntervalSince1970: 1),
            photos: [
                .init(mediaType: "image/jpeg", data: Data([1])),
                .init(mediaType: "image/jpeg", data: Data([2])),
            ],
            clips: [
                .init(
                    duration: 6.4,
                    frames: (3...5).map { .init(mediaType: "image/jpeg", data: Data([$0])) })
            ], sounds: [12])
        let request = DiagnosisRequest.make(
            briefing: diagnosisBriefing(), title: "t", text: "x", notes: [], answered: [],
            findings: [finding], codes: [], unread: [], provider: .anthropic,
            sharing: .init(includeVIN: false))

        let parts = request.messages[0].parts
        #expect(parts.count == 11)
        #expect(
            diagnosisText(request).contains(
                "- Horn test: No sound. (2 photos; a 6-second clip, shown as 3 frames; a 12-second sound recording you can't hear)"
            ))
        #expect(diagnosisText(request).contains("labelled with the finding they belong to"))
        #expect(!diagnosisText(request).contains("Older findings' images"))
        let labels = parts.compactMap { part -> String? in
            if case .text(let text) = part, text.hasPrefix("Evidence for") { return text }
            return nil
        }
        #expect(
            labels == [
                "Evidence for \"Horn test\": photo 1 of 2",
                "Evidence for \"Horn test\": photo 2 of 2",
                "Evidence for \"Horn test\": clip frame 1 of 3",
                "Evidence for \"Horn test\": clip frame 2 of 3",
                "Evidence for \"Horn test\": clip frame 3 of 3",
            ])
    }

    @Test("diagnosis request keeps newest six finding images")
    func findingImageCap() {
        let findings = (1...3).map { day in
            DiagnosisRequest.Finding(
                title: "Day \(day)", text: "found", date: Date(timeIntervalSince1970: Double(day)),
                photos: (1...3).map {
                    .init(mediaType: "image/jpeg", data: Data([UInt8(day * 10 + $0)]))
                })
        }
        let request = DiagnosisRequest.make(
            briefing: diagnosisBriefing(), title: "t", text: "x", notes: [], answered: [],
            findings: findings, codes: [], unread: [], provider: .anthropic,
            sharing: .init(includeVIN: false))
        let imageParts = request.messages[0].parts.filter {
            if case .image = $0 { return true }
            return false
        }

        #expect(imageParts.count == 6)
        #expect(diagnosisText(request).contains("Older findings' images are left out"))
        #expect(
            request.messages[0].parts.compactMap { part -> String? in
                if case .text(let text) = part, text.hasPrefix("Evidence for") { return text }
                return nil
            } == [
                "Evidence for \"Day 3\": photo 1 of 3", "Evidence for \"Day 3\": photo 2 of 3",
                "Evidence for \"Day 3\": photo 3 of 3", "Evidence for \"Day 2\": photo 1 of 3",
                "Evidence for \"Day 2\": photo 2 of 3", "Evidence for \"Day 2\": photo 3 of 3",
            ])
    }

    @Test("diagnosis request describes sound evidence without images")
    func soundEvidence() {
        let one = DiagnosisRequest.Finding(
            title: "Listen", text: "A click", date: .now, sounds: [12])
        let two = DiagnosisRequest.Finding(
            title: "Listen twice", text: "Two clicks", date: .now, sounds: [12, 5])
        let first = DiagnosisRequest.make(
            briefing: diagnosisBriefing(), title: "t", text: "x", notes: [], answered: [],
            findings: [one], codes: [], unread: [], provider: .anthropic,
            sharing: .init(includeVIN: false))
        let second = DiagnosisRequest.make(
            briefing: diagnosisBriefing(), title: "t", text: "x", notes: [], answered: [],
            findings: [two], codes: [], unread: [], provider: .anthropic,
            sharing: .init(includeVIN: false))
        #expect(first.messages[0].parts.count == 1)
        #expect(diagnosisText(first).contains("(a 12-second sound recording you can't hear)"))
        #expect(!diagnosisText(first).contains("attached below"))
        #expect(
            diagnosisText(second).contains("(2 sound recordings you can't hear, 12 and 5 seconds)"))
    }

    @Test(
        "Anthropic diagnoses the Ghibli steering-wheel problem",
        .enabled(if: ProcessInfo.processInfo.environment["SPIA_ANTHROPIC_API_KEY"] != nil))
    func anthropicDiagnosis() async throws {
        try await liveDiagnosis(
            AnthropicProvider(
                apiKey: ProcessInfo.processInfo.environment["SPIA_ANTHROPIC_API_KEY"] ?? "",
                model: AnthropicProvider.fastModel))
    }

    @Test(
        "OpenAI diagnoses the Ghibli steering-wheel problem",
        .enabled(if: ProcessInfo.processInfo.environment["SPIA_OPENAI_API_KEY"] != nil))
    func openAIDiagnosis() async throws {
        try await liveDiagnosis(
            OpenAIProvider(
                apiKey: ProcessInfo.processInfo.environment["SPIA_OPENAI_API_KEY"] ?? "",
                model: OpenAIProvider.fastModel))
    }

    /// The Ghibli's own problem, as the app would send it after the first visit: both modules
    /// read, the owner's note, and one finding. Prints what came back so a run can be read.
    private func liveDiagnosis(_ provider: any AssistantProvider) async throws {
        let readings: [SessionBriefing.Event] = [
            .init(
                date: .now, kind: "result", title: "Airbag controller (ORC)",
                summary: "Two stored faults, failing now, warning lamp requested", result: nil,
                codes: ["B0001-1B", "B0002-1B"], fromRecording: false, warnings: []),
            .init(
                date: .now, kind: "result", title: "Steering column module (SCCM)",
                summary: "Two switch-input faults failing now and one confirmed", result: nil,
                codes: ["P0593-00", "P0581-00", "U1008-00"], fromRecording: false, warnings: []),
        ]
        let request = DiagnosisRequest.make(
            briefing: diagnosisBriefing(vin: nil, events: readings),
            title: "Dead steering-wheel controls",
            text:
                "Every steering-wheel control is dead: volume, cluster menu, cruise. The horn is dead. The airbag lamp is on. The paddles and the wiper stalk work. The washer pump is silent with a full reservoir.",
            notes: ["Nothing was serviced before this started."],
            answered: [],
            findings: [
                .init(
                    title: "Press the horn with the key on",
                    text:
                        "Nothing at all, and no click from the horn relay. The airbag lamp stayed on.",
                    date: .now)
            ],
            codes: [
                (
                    printed: "B0001-1B", name: "Driver Frontal Stage 1 Deployment Control",
                    failureType: "1B: resistance in the circuit is too high"
                ),
                (
                    printed: "B0002-1B", name: "Driver Frontal Stage 2 Deployment Control",
                    failureType: "1B: resistance in the circuit is too high"
                ),
                (
                    printed: "P0593-00",
                    name: "Cruise Control Multi-Function Input \"B\" Circuit High",
                    failureType: "00: no further detail from the module"
                ),
                (
                    printed: "P0581-00",
                    name: "Cruise Control Multi-Function Input \"A\" Circuit High",
                    failureType: "00: no further detail from the module"
                ),
            ], unread: [], provider: provider.id, sharing: .init(includeVIN: false))
        var call: ToolCall?
        var usage: TokenUsage?
        var stop: StopReason?
        for try await event in provider.respond(to: request) {
            switch event {
            case .toolCall(let value): call = value
            case .usage(let value): usage = value
            case .finished(let reason): stop = reason
            default: break
            }
        }
        print(
            "=== \(provider.id.rawValue) stopped: \(String(describing: stop)), usage: \(String(describing: usage))"
        )
        let answer = try #require(call)
        let result: DiagnosisResult
        do {
            result = try DiagnosisTool.parse(answer, modules: diagnosisModules)
        } catch {
            print("=== \(provider.id.rawValue) unparseable diagnosis ===\n\(answer.arguments)")
            throw error
        }
        #expect(!result.suspects.isEmpty)
        #expect(!result.reading.isEmpty)
        #expect(result.suspects.first?.confidence == .high)
        #expect(result.inspections.allSatisfy { $0.title != "Press the horn with the key on" })
        print(Self.describe(result, provider: provider.id, usage: usage))
    }

    private static func describe(
        _ result: DiagnosisResult, provider: ProviderID, usage: TokenUsage?
    )
        -> String
    {
        var lines = ["", "=== \(provider.rawValue) diagnosis ==="]
        lines.append("Reading: \(result.reading)")
        lines.append("Symptoms: \(result.symptoms.joined(separator: " | "))")
        for suspect in result.suspects {
            lines.append(
                "Suspect (\(suspect.confidence.rawValue)) \(suspect.name): \(suspect.why) [\(suspect.symptoms)]"
            )
        }
        for check in result.checks {
            lines.append(
                "Check: \(check.proposal.check.rawValue) \(check.proposal.module ?? "") because \(check.proposal.reason) [\(check.suspects)]"
            )
        }
        for inspection in result.inspections {
            lines.append("Inspection: \(inspection.title) [\(inspection.suspects)]")
            lines.append("  Steps: \(inspection.steps)")
            lines.append("  Look for: \(inspection.lookFor)")
            if let safety = inspection.safety { lines.append("  Safety: \(safety)") }
            lines.append("  Tells apart: \(inspection.tellsApart)")
        }
        for question in result.questions {
            lines.append(
                "Question: \(question.question) (\(question.module ?? "untagged") \(question.codes))"
            )
        }
        if let conclusion = result.conclusion {
            lines.append(
                "Conclusion (\(conclusion.confidence.rawValue)): \(conclusion.cause) Fix: \(conclusion.fix)"
            )
        } else {
            lines.append("Conclusion: none yet")
        }
        if let usage { lines.append("Tokens: \(usage.input) in, \(usage.output) out") }
        return lines.joined(separator: "\n")
    }
}
