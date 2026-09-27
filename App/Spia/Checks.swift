import SpiaKit
import SpiaStore
import SwiftUI

struct ChecksSection: View {
    let vehicle: Vehicle?
    let workbench: Workbench
    let session: DiagnosticSession
    let connect: () -> Void
    let editModules: () -> Void

    private var ready: Bool { workbench.connection.status != nil && workbench.activity == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Run a check")
                    .font(.title2.weight(.semibold))
                Spacer()
                if workbench.connection.status == nil {
                    Button("Connect…", action: connect)
                        .buttonStyle(.borderedProminent)
                }
            }
            if workbench.connection.status == nil {
                Text(notConnectedHint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                CheckCard(job: .genericScan, symbol: "engine.combustion", enabled: ready) {
                    run(.genericScan)
                }
                ModuleCheckCard(
                    modules: vehicle?.orderedModules ?? [], enabled: ready, edit: editModules
                ) {
                    run(.moduleDTCs($0))
                }
                CheckCard(job: .vehicleInfo, symbol: "doc.text.magnifyingglass", enabled: ready) {
                    run(.vehicleInfo)
                }
                CheckCard(job: .adapterCheck, symbol: "cable.connector", enabled: ready) {
                    run(.adapterCheck)
                }
            }
        }
    }

    private var notConnectedHint: String {
        if case .reconnectRequired = workbench.connection {
            return
                "The last check was interrupted. Reconnect the adapter to reset it before running another."
        }
        return "Connect the adapter to run checks. The connection assistant walks you through it."
    }

    private func run(_ job: DiagnosticJob) {
        Task { await workbench.run(job, in: session) }
    }
}

private struct CheckCard: View {
    let job: DiagnosticJob
    let symbol: String
    let enabled: Bool
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                Spacer()
                RequirementChip(requirement: job.requirement)
            }
            Text(job.title)
                .font(.headline)
            Text(job.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Run", action: run)
                .disabled(!enabled)
                .help("Sends: \(job.plannedCommands.joined(separator: " "))")
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .card()
    }
}

private struct ModuleCheckCard: View {
    let modules: [ModulePreset]
    let enabled: Bool
    let edit: () -> Void
    let run: (ModuleTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: "cpu")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                Spacer()
                RequirementChip(requirement: .ignitionOn)
            }
            Text("Read module trouble codes")
                .font(.headline)
            Text(
                "Airbag, ABS, body computer and other modules keep their own codes, separate from the engine."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if modules.isEmpty {
                Button("Add Modules…", action: edit)
            } else {
                Menu("Choose Module") {
                    ForEach(modules) { module in
                        if let target = module.target {
                            Button("\(module.label)\(module.confirmed ? "" : " (unconfirmed)")") {
                                run(target)
                            }
                        }
                    }
                    Divider()
                    Button("Edit Modules…", action: edit)
                }
                .fixedSize()
                .disabled(!enabled)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .card()
    }
}

private struct RequirementChip: View {
    let requirement: VehicleRequirement

    var body: some View {
        switch requirement {
        case .none: Chip(text: "No car needed")
        case .ignitionOn: Chip(text: "Ignition on", color: .orange)
        }
    }
}

/// What a running check is doing: pulling data (blue) or waiting for the user (amber).
struct ActivityPanel: View {
    let activity: CheckActivity
    let workbench: Workbench

    var body: some View {
        if let prompt = activity.prompt {
            VStack(alignment: .leading, spacing: 12) {
                Label(prompt.action.title, systemImage: "hand.raised.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.orange)
                Text(prompt.action.instructions)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Done, try again") { Task { await workbench.confirmPrompt() } }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .keyboardShortcut(.defaultAction)
                    Button("Cancel Check") { Task { await workbench.cancel() } }
                }
            }
            .card(tint: .orange)
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

/// Always-visible connection status in the toolbar.
struct ConnectionPill: View {
    let workbench: Workbench
    let action: () -> Void

    var body: some View {
        let summary = ConnectionSummary(adapter: workbench.adapter, state: workbench.connection)
        let busy = workbench.activity != nil
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: summary.symbol)
                Circle()
                    .fill((busy ? Tone.working : summary.tone).color)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(busy ? "Reading from the car" : summary.title)
                        .font(.callout.weight(.medium))
                    Text(summary.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
        }
        .help("Adapter connection")
        .accessibilityLabel("Connection: \(summary.title), \(summary.detail)")
    }
}
