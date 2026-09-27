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
}
