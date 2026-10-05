import Foundation
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

public struct StoredCodeInterpretation: Codable, Sendable, Equatable {
    public let target: ModuleTarget?
    public let code: String
    public let name: String
    public let meaning: String
    public let firstCheck: String
    public let confidence: String
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

public struct InterpretationSnapshot: Codable, Sendable, Equatable {
    public var consent: InterpretationConsent?
    public var codes: [StoredCodeInterpretation]
    public var modules: [StoredModuleInterpretation]
}

@MainActor @Observable
public final class VehicleInterpretations {
    public private(set) var consent: InterpretationConsent?
    public private(set) var codes: [StoredCodeInterpretation]
    public private(set) var modules: [StoredModuleInterpretation]
    public private(set) var inFlight: Set<ModuleTarget?> = []
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
        } else {
            consent = nil
            codes = []
            modules = []
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
        _ result: InterpretationResult, target: ModuleTarget?, provider: ProviderID, model: String
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
        if let module = result.module, let target {
            modules.removeAll { $0.target == target }
            modules.append(
                StoredModuleInterpretation(
                    target: target, name: module.name, role: module.role, provider: provider,
                    model: model, date: date))
        }
        save()
    }
    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard
            let data = try? encoder.encode(
                InterpretationSnapshot(consent: consent, codes: codes, modules: modules))
        else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
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
