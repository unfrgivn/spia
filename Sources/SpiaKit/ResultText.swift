import Foundation

/// One-line plain-English summaries of results, for timelines and for the assistant's context.
public enum ResultText {
    public static func summary(_ result: JobResult) -> String {
        switch result.payload {
        case .adapter(let status):
            let parts = [status.hardware ?? status.identity, status.firmware].compactMap { $0 }
            return (parts + [ConnectionSummary.voltageText(status.voltage)])
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
            let printed = unique.map { CodeName($0)?.printed ?? $0 }
            let mil = reports.contains { $0.readiness.value?.milOn == true }
            let unanswered = reports.contains { $0.stored.value == nil }
            var text =
                unique.isEmpty
                ? (unanswered
                    ? "Some modules couldn't report codes" : "No engine or transmission codes")
                : "\(unique.count) code\(unique.count == 1 ? "" : "s"): \(printed.joined(separator: ", "))"
            text += mil ? " · check-engine light ON" : " · check-engine light off"
            return text

        case .moduleDTCs(let module):
            switch module.outcome {
            case .records(_, let records) where records.isEmpty:
                return "No trouble codes"
            case .records(let availability, let records):
                let failing = records.filter { $0.status & availability & 0x01 != 0 }.count
                let list = records.map { CodeName($0.code)?.printed ?? $0.code }.joined(
                    separator: ", ")
                let suffix = failing == 0 ? "" : " · \(failing) failing now"
                return "\(records.count) code\(records.count == 1 ? "" : "s"): \(list)\(suffix)"
            case .negative(_, let code):
                return NegativeResponse.explanation(code)
            }

        case .survey(let report):
            let codeModules = report.modules.filter {
                if case .outcome(.records(_, let records)) = $0.codes { return !records.isEmpty }
                if case .outcome(.negative) = $0.codes { return true }
                return false
            }.count
            var sentences: [String] = []
            if report.vehicleInfo.isEmpty {
                sentences.append("The engine computers didn't answer.")
            }
            if report.modules.isEmpty {
                sentences.append("No modules answered.")
            } else {
                var found =
                    "Found \(report.modules.count) module\(report.modules.count == 1 ? "" : "s")."
                if codeModules > 0 {
                    found =
                        "Found \(report.modules.count) module\(report.modules.count == 1 ? "" : "s"), "
                        + "\(codeModules) with codes."
                }
                sentences.append(found)
            }
            if report.unanswered.count > 0 {
                sentences.append("\(report.unanswered.count) didn't answer.")
            }
            if let stop = report.stop {
                let label: String
                if case .catalog(let catalogLabel, _, _) = stop.candidate.origin {
                    label = catalogLabel
                } else if case .saved(let savedLabel, _) = stop.candidate.origin {
                    label = savedLabel
                } else {
                    label = stop.candidate.target.fallbackLabel
                }
                var stopped = String(
                    format: "Stopped at %@ (%03X): %@.", label, stop.candidate.target.request,
                    stop.reason)
                if !report.notProbed.isEmpty {
                    stopped += " \(report.notProbed.count) not asked."
                }
                sentences.append(stopped)
            }
            return sentences.joined(separator: " ")
        }
    }
}
