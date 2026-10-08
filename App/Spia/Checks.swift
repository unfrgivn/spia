import SpiaKit
import SpiaStore
import SwiftUI

/// What a running check is doing: pulling data (blue) or waiting for the user (amber).
struct ActivityPanel: View {
    let activity: CheckActivity
    let workbench: Workbench

    var body: some View {
        if let prompt = activity.prompt {
            VStack(alignment: .leading, spacing: 12) {
                Label(prompt.action.title, systemImage: "hand.raised.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.caution)
                Text(prompt.action.instructions)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Done, try again") { Task { await workbench.confirmPrompt() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.caution)
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel Check") { Task { await workbench.cancel() } }
                }
            }
            .card(tint: Palette.caution)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Action needed: \(prompt.action.title)")
        } else if let scan = activity.scan {
            let phases = scan.phases.reduce(into: [ScanPhase]()) { phases, phase in
                if !phases.contains(phase) { phases.append(phase) }
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ForEach(phases, id: \.self) { phase in
                        VStack(spacing: 5) {
                            Circle()
                                .fill(color(for: phase, scan: scan))
                                .frame(width: 11, height: 11)
                            Text(phase.title)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(color(for: phase, scan: scan))
                                .lineLimit(1)
                        }
                        if phase != phases.last {
                            Rectangle().fill(Palette.hairline).frame(height: 1)
                        }
                    }
                }
                Text(activity.currentStep ?? "Starting")
                    .font(.caption.monospaced())
                    .foregroundStyle(Palette.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { Task { await workbench.cancel() } }
                }
            }
            .card(tint: Palette.accent)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Scanning: \(activity.currentStep ?? "Starting")")
        } else {
            HStack(alignment: .top, spacing: 14) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(activity.job.title)…")
                        .font(.headline)
                    Text(activity.currentStep ?? "Starting")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                    if !activity.warnings.isEmpty {
                        Text(
                            "\(activity.warnings.count) request\(activity.warnings.count == 1 ? "" : "s") got no answer"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Cancel") { Task { await workbench.cancel() } }
            }
            .card(tint: .blue)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Reading from the car: \(activity.job.title)")
        }
    }

    private func color(for phase: ScanPhase, scan: ScanProgress) -> Color {
        guard let index = scan.phases.firstIndex(of: phase),
            let current = scan.phases.firstIndex(of: scan.current)
        else { return Palette.tertiary }
        if index == current { return Palette.accent }
        return index < current ? Palette.secondary : Palette.tertiary
    }
}
