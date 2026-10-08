import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftUI

struct DiagnosisView: View {
    let review: StoredReview?
    let inFlight: Bool
    let findings: [TimelineEntry]
    let untaggedQuestions: [StoredQuestion]
    let moduleLabels: [ModuleTarget: String]
    let answer: (UUID, String) -> Void
    let checks: [(StoredCheck, Bool)]
    let run: (StoredCheck) -> Void
    let recordFinding: (FindingDraft) -> Void
    let files: SpiaFiles
    let resolve: () -> Void
    let wide: Bool
    let closed: Bool
    static let testsID = "tests"
    static let foundID = "found"
    @State private var composing: UUID?
    @State private var findingInitialText = ""
    @State private var composingOther = false
    @State private var otherTitle = "Finding"

    var body: some View {
        VStack(alignment: .leading, spacing: wide ? 18 : 14) {
            ReadingHeader(
                provider: review?.provider, reading: review?.reading, date: review?.date,
                inFlight: inFlight, busyText: "is reading the problem…")
            if let review, !review.symptoms.isEmpty { symptoms(review.symptoms) }
            if let review, !review.suspects.isEmpty { suspects(review) }
            if let review, !review.checks.isEmpty || !review.inspections.isEmpty { tests(review) }
            if !closed {
                Button("Record something else you found") { composingOther = true }
                    .buttonStyle(OutlineButtonStyle())
            }
            if composingOther {
                FindingComposer(
                    title: "Finding", editableTitle: $otherTitle, files: files,
                    save: { draft in
                        recordFinding(draft)
                        composingOther = false
                    },
                    cancel: { composingOther = false })
            }
            if !findings.isEmpty { found }
            ForEach(untaggedQuestions, id: \.id) { question in
                QuestionView(question: question, answer: answer)
            }
            if let conclusion = review?.conclusion, !closed { conclusionCard(conclusion) }
        }
        #if DEBUG
            .onAppear {
                if Fixture.screen == .findingComposer, composing == nil {
                    composing = review?.inspections.first?.id
                }
            }
        #endif
        .frame(maxWidth: 720, alignment: .leading)
    }

    private func symptoms(_ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Symptoms")
            FlowLayout(spacing: 7) {
                ForEach(values, id: \.self) { value in
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Palette.card, in: Capsule())
                }
            }
        }
    }

    private func suspects(_ review: StoredReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading("Suspects")
            ForEach(Array(review.suspects.enumerated()), id: \.offset) { _, suspect in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(suspect.name).font(.system(size: 15, weight: .medium))
                        Spacer(minLength: 8)
                        Text(suspect.confidence.rawValue.capitalized)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(
                                suspect.confidence == .high ? Palette.accent : Palette.tertiary)
                    }
                    Text(suspect.why).font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    let names = suspect.symptoms.compactMap { index in
                        review.symptoms.indices.contains(index) ? review.symptoms[index] : nil
                    }
                    if !names.isEmpty {
                        Text("Explains: \(names.joined(separator: ", "))")
                            .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
                    }
                }
                .padding(.bottom, 3)
            }
        }
    }

    private func tests(_ review: StoredReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeading("Tests").id(Self.testsID)
            ForEach(Array(checks.enumerated()), id: \.offset) { _, item in
                if item.1 {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("Would read: \(label(for: item.0)), \(item.0.reason)")
                                .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                            Button("Read") { run(item.0) }.buttonStyle(OutlineButtonStyle())
                        }
                        suspectLine(item.0.suspects, review: review)
                    }
                }
            }
            ForEach(review.inspections, id: \.id) { inspection in
                inspectionCard(inspection, review: review)
            }
        }
    }

    private func inspectionCard(_ inspection: StoredInspection, review: StoredReview) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(inspection.title).font(.system(size: 15, weight: .medium))
            Text(inspection.steps).font(.system(size: 13)).foregroundStyle(Palette.secondary)
            Text("Look for: \(inspection.lookFor)").font(.system(size: 13)).foregroundStyle(
                Palette.secondary)
            if let safety = inspection.safety {
                Label(safety, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12.5)).foregroundStyle(Palette.caution)
            }
            suspectLine(inspection.suspects, review: review, suffix: inspection.tellsApart)
            if composing == inspection.id && !closed {
                FindingComposer(
                    title: inspection.title, initialText: findingInitialText, files: files,
                    save: { draft in
                        recordFinding(draft)
                        composing = nil
                    },
                    cancel: {
                        composing = nil
                        findingInitialText = ""
                    })
            } else if !closed {
                HStack(spacing: 12) {
                    Button("Record what you found") {
                        composing = inspection.id
                        findingInitialText = ""
                    }
                    Button("Couldn't do this") {
                        composing = inspection.id
                        findingInitialText = "Couldn't do this: "
                    }
                }.buttonStyle(OutlineButtonStyle())
            }
        }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var found: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading("Found").id(Self.foundID)
            ForEach(findings) { finding in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(finding.date, format: .dateTime.hour().minute())
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.tertiary)
                        Text(finding.title).font(.system(size: 13.5, weight: .medium))
                    }
                    if !finding.body.isEmpty {
                        Text(finding.body).font(.system(size: 13)).foregroundStyle(
                            Palette.secondary)
                    }
                    if !finding.attachments.isEmpty {
                        EvidenceStrip(attachments: finding.attachments, files: files)
                    }
                }
            }
        }
    }

    private func conclusionCard(_ conclusion: StoredConclusion) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Palette.accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Cause").font(.system(size: 12, weight: .semibold)).foregroundStyle(
                    Palette.accent)
                Text(conclusion.cause).font(.system(size: 15, weight: .medium))
                Text("Fix").font(.system(size: 12, weight: .semibold)).foregroundStyle(
                    Palette.accent)
                Text(conclusion.fix).font(.system(size: 14)).foregroundStyle(Palette.secondary)
                HStack {
                    Text(conclusion.confidence.rawValue.capitalized).font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                    Spacer()
                    Button("Resolve…", action: resolve).buttonStyle(OutlineButtonStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12).background(Palette.card, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private func suspectLine(
        _ indexes: [Int], review: StoredReview, suffix: String? = nil
    ) -> some View {
        let names = indexes.compactMap { index in
            review.suspects.indices.contains(index) ? review.suspects[index].name : nil
        }
        if !names.isEmpty {
            Text("Tells apart: \(names.joined(separator: ", "))\(suffix.map { ". \($0)" } ?? "")")
                .font(.system(size: 12)).foregroundStyle(Palette.tertiary)
        }
    }

    private func label(for check: StoredCheck) -> String {
        if let module = check.module, let label = moduleLabels[module] { return label }
        return check.kind.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
