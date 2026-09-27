import SpiaReference
import SpiaStore
import SwiftUI

/// Adds a vehicle with a USB adapter profile and a first session. A VIN is decoded as it's typed.
struct VehicleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onCreate: (Vehicle) -> Void

    @State private var vin = ""
    @State private var name = ""
    @State private var problem = ""
    @State private var lookup = VINLookup()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New vehicle")
                .font(.title2.weight(.semibold))
            Form {
                Section {
                    VINField(vin: $vin, lookup: lookup)
                    TextField(
                        "Name", text: $name,
                        prompt: Text(lookup.identity?.title ?? "e.g. 2017 Maserati Ghibli"))
                }
                Section {
                    TextField(
                        "What's going on?", text: $problem,
                        prompt: Text("Describe the problem in your own words"), axis: .vertical
                    )
                    .lineLimit(3...6)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Vehicle", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(resolvedName.isEmpty || lookup.isInvalid)
            }
        }
        .padding(24)
        .frame(width: 520)
        .errorAlert($error)
    }

    private var resolvedName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? (lookup.identity?.title ?? "") : typed
    }

    private func create() {
        do {
            let vehicle = try model.garage.addVehicle(name: resolvedName, vin: lookup.normalized)
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

/// Name, VIN, and notes of an existing vehicle. A changed VIN looks up the references again.
struct VehicleSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle

    @State private var name = ""
    @State private var vin = ""
    @State private var notes = ""
    @State private var lookup = VINLookup()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit vehicle")
                .font(.title2.weight(.semibold))
            Form {
                TextField("Name", text: $name)
                VINField(vin: $vin, lookup: lookup)
                TextField("Notes", text: $notes, axis: .vertical)
                    .lineLimit(2...6)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || lookup.isInvalid)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            name = vehicle.name
            vin = vehicle.vin ?? ""
            notes = vehicle.notes
        }
        .errorAlert($error)
    }

    private func save() {
        vehicle.name = name.trimmingCharacters(in: .whitespaces)
        vehicle.vin = lookup.normalized
        vehicle.notes = notes
        do {
            try model.garage.context.save()
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}

/// What's known about the VIN being typed.
@MainActor
@Observable
final class VINLookup {
    private(set) var identity: VehicleIdentity?
    private(set) var problem: String?
    private(set) var isDecoding = false
    /// Nil when fine; otherwise what a mismatched check digit means for this VIN.
    private(set) var checkDigitNote: String?
    /// The VIN as it will be stored, or nil when the field is empty or invalid.
    private(set) var normalized: String?
    private(set) var isInvalid = false

    func update(_ raw: String) async {
        identity = nil
        problem = nil
        normalized = nil
        isInvalid = false
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let vin: VIN
        do {
            vin = try VIN(raw)
        } catch {
            // Complain only once the length is right; while typing, just wait.
            let length = raw.filter { !$0.isWhitespace && $0 != "-" }.count
            isInvalid = true
            if length >= 17 { problem = String(describing: error) }
            return
        }
        normalized = vin.value
        checkDigitNote =
            vin.checkDigitMatches
            ? nil
            : vin.isNorthAmerican
                ? "The check digit doesn't match. Check the VIN for a typo."
                : "The check digit doesn't match; that's normal for cars built outside North America."
        // A pause first, so pasting or fast typing sends one request.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        isDecoding = true
        defer { isDecoding = false }
        do {
            let found = try await ReferenceClient().identity(for: vin)
            guard !Task.isCancelled else { return }
            identity = found
        } catch {
            guard !Task.isCancelled else { return }
            problem = String(describing: error)
        }
    }
}

private struct VINField: View {
    @Binding var vin: String
    let lookup: VINLookup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(
                "VIN", text: $vin, prompt: Text("17 characters, on the windshield or door jamb")
            )
            .font(.body.monospaced())
            status
                .font(.caption)
        }
        .task(id: vin) { await lookup.update(vin) }
    }

    @ViewBuilder private var status: some View {
        if vin.trimmingCharacters(in: .whitespaces).isEmpty {
            Text(
                "Optional. With it, Spia looks up the exact model, its recalls and service bulletins, and photos. The VIN is sent to NHTSA to decode it."
            )
            .foregroundStyle(.secondary)
        } else if let problem = lookup.problem {
            Label(problem, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        } else if lookup.isDecoding {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Looking up the VIN with NHTSA…")
            }
            .foregroundStyle(.secondary)
        } else if let identity = lookup.identity {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    [identity.title, identity.detail].filter { !$0.isEmpty }.joined(
                        separator: " · "),
                    systemImage: "checkmark.seal.fill"
                )
                .foregroundStyle(.green)
                if let note = lookup.checkDigitNote {
                    Text(note).foregroundStyle(.secondary)
                }
            }
        }
    }
}
