import Foundation

/// One-line plain-English summaries of results, for timelines and for the assistant's context.
public enum ResultText {
    public static func summary(_ result: JobResult) -> String {
        switch result.payload {
        case .adapter(let status):
            let parts = [status.hardware ?? status.identity, status.firmware].compactMap { $0 }
            return
                (parts + [
                    ConnectionSummary.voltageText(status.voltage).replacingOccurrences(
                        of: "Ready · ", with: "")
                ])
                .joined(separator: " · ")

        case .vehicleInfo(let ecus):
            let vin = ecus.lazy.compactMap(\.vin.value).first
            let names = ecus.compactMap(\.displayName)
            var text = vin.map { "VIN \($0)" } ?? "No VIN reported"
            text += " · \(ecus.count) module\(ecus.count == 1 ? "" : "s") answered"
            if !names.isEmpty { text += " (\(names.joined(separator: ", ")))" }
            return text

        case .genericScan(let reports):
            let codes = reports.flatMap { report in
                [report.stored, report.pending, report.permanent].compactMap(\.value).flatMap { $0 }
            }
            let unique = Array(Set(codes)).sorted()
            let mil = reports.contains { $0.readiness.value?.milOn == true }
            let unanswered = reports.contains { $0.stored.value == nil }
            var text =
                unique.isEmpty
                ? (unanswered
                    ? "Some modules couldn't report codes" : "No engine or transmission codes")
                : "\(unique.count) code\(unique.count == 1 ? "" : "s"): \(unique.joined(separator: ", "))"
            text += mil ? " · check-engine light ON" : " · check-engine light off"
            return text

        case .moduleDTCs(let module):
            switch module.outcome {
            case .records(_, let records) where records.isEmpty:
                return "No trouble codes"
            case .records(let availability, let records):
                let failing = records.filter { $0.status & availability & 0x01 != 0 }.count
                let list = records.map(\.code).joined(separator: ", ")
                let suffix = failing == 0 ? "" : " · \(failing) failing now"
                return "\(records.count) code\(records.count == 1 ? "" : "s"): \(list)\(suffix)"
            case .negative(_, let code):
                return NegativeResponse.explanation(code)
            }
        }
    }
}
