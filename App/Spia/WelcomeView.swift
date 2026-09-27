import SpiaKit
import SpiaStore
import SwiftUI

struct WelcomeView: View {
    let addVehicle: () -> Void
    let addDemo: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Image(systemName: "stethoscope.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.tint)
                    Text("Spia")
                        .font(.largeTitle.weight(.semibold))
                    Text(
                        "Work out what's wrong with your car from two sides: what you notice, and what the car reports."
                    )
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                }

                HStack(spacing: 16) {
                    StartOption(
                        symbol: "car.badge.plus", title: "Set up my vehicle",
                        detail: "Add your car, plug in the adapter, and start a session.",
                        action: addVehicle)
                    StartOption(
                        symbol: "play.rectangle", title: "Explore the demo",
                        detail:
                            "A 2017 Maserati Ghibli with dead wheel controls, from real recordings.",
                        action: addDemo)
                }
                .frame(maxWidth: 620)

                VStack(alignment: .leading, spacing: 10) {
                    Label("What you need", systemImage: "cable.connector")
                        .font(.headline)
                    Text(
                        "An OBD-II adapter with USB, such as the **Vgate vLinker FS (USB)**. It plugs into the diagnostic port under the dashboard, usually left of the steering column, and into your Mac with its USB cable."
                    )
                    Text("Bluetooth adapters will come with the iPhone app.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .card()
                .frame(maxWidth: 620)
            }
            .padding(40)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct StartOption: View {
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: symbol)
                    .font(.title)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .card()
        }
        .buttonStyle(.plain)
    }
}

/// Adds a vehicle with a USB adapter profile and a first session.
struct VehicleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onCreate: (Vehicle) -> Void

    @State private var name = ""
    @State private var vin = ""
    @State private var problem = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New vehicle")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. 2017 Maserati Ghibli"))
                TextField("VIN", text: $vin, prompt: Text("Optional, read later from the car"))
                TextField(
                    "What's going on?", text: $problem,
                    prompt: Text("Describe the problem in your own words"),
                    axis: .vertical
                )
                .lineLimit(3...6)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Vehicle") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 480)
        .errorAlert($error)
    }

    private func create() {
        do {
            let trimmedVIN = vin.trimmingCharacters(in: .whitespaces)
            let vehicle = try model.garage.addVehicle(
                name: name.trimmingCharacters(in: .whitespaces),
                vin: trimmedVIN.isEmpty ? nil : trimmedVIN)
            try model.garage.addSession(
                to: vehicle, title: problem.isEmpty ? "First session" : "New problem",
                problem: problem)
            onCreate(vehicle)
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}
