import SpiaReference
import SpiaKit
import SpiaStore
import SwiftUI

/// Adds a vehicle with a platform-appropriate adapter profile and a first session. A VIN is decoded
/// as it's typed.
struct VehicleEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let onCreate: (Vehicle) -> Void

    @State private var vin = ""
    @State private var name = ""
    @State private var trim = ""
    @State private var color: PaintColor?
    @State private var colorName = ""
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
                    TrimField(trim: $trim, decoded: lookup.identity?.trim)
                }
                Section {
                    PaintPicker(color: $color, name: $colorName)
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
        .platformSheetFrame(width: 560)
        .errorAlert($error)
    }

    private var resolvedName: String {
        let typed = name.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? (lookup.identity?.title ?? "") : typed
    }

    private func create() {
        do {
            #if os(iOS)
                let kind: AdapterKind = .bluetooth
            #else
                let kind: AdapterKind = .usbSerial
            #endif
            let vehicle = try model.garage.addVehicle(
                name: resolvedName, vin: lookup.normalized, adapterKind: kind)
            vehicle.trim = trim.trimmed
            vehicle.color = color
            vehicle.colorName = colorName.trimmed
            if !problem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = try model.garage.addSession(to: vehicle, title: "New problem", problem: problem)
            }
            onCreate(vehicle)
            dismiss()
        } catch {
            self.error = error.readable
        }
    }
}

/// Name, VIN, trim, colour, cover, and notes of an existing vehicle. A changed VIN, trim, or
/// colour looks up the references again.
struct VehicleSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle
    let references: VehicleReferences

    @State private var name = ""
    @State private var vin = ""
    @State private var trim = ""
    @State private var color: PaintColor?
    @State private var colorName = ""
    @State private var notes = ""
    @State private var lookup = VINLookup()
    @State private var choosingCover = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Edit vehicle")
                .font(.title2.weight(.semibold))
            Form {
                Section {
                    TextField("Name", text: $name)
                    VINField(vin: $vin, lookup: lookup)
                    TrimField(trim: $trim, decoded: references.identity?.trim)
                }
                Section {
                    PaintPicker(color: $color, name: $colorName)
                }
                Section("Cover") {
                    HStack(spacing: 14) {
                        VehiclePhoto(vehicle: vehicle, references: references)
                            .frame(width: 120, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(coverDescription)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Button("Upload Photo…") { choosingCover = true }
                                .controlSize(.small)
                        }
                    }
                }
                Section {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(2...6)
                }
                Section("Code explanations") {
                    let interpretations = model.interpreter.interpretations(for: vehicle)
                    if let consent = interpretations.consent {
                        HStack {
                            Text(
                                "Allowed with \(consent.provider.displayName) since \(consent.grantedAt.formatted(date: .abbreviated, time: .omitted))"
                            )
                            Spacer()
                            Button("Stop") { interpretations.withdraw() }
                        }
                    } else {
                        HStack {
                            Text("Not allowed")
                            Spacer()
                            Button("Allow…") {
                                interpretations.allow(model.assistant.settings.defaultProvider)
                            }
                            .disabled(
                                model.assistant.unavailableReason(
                                    model.assistant.settings.defaultProvider) != nil)
                        }
                        if let reason = model.assistant.unavailableReason(
                            model.assistant.settings.defaultProvider)
                        {
                            Text(reason)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if interpretations.usageSummary.total.requests == 0 {
                        Text("Nothing sent yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(interpretations.usageSummary.byModel.keys.sorted(), id: \.self) {
                            model in
                            let totals = interpretations.usageSummary.byModel[model] ?? .init()
                            Text(
                                "\(totals.requests) requests · \(totals.input.formatted()) tokens in · \(totals.output.formatted()) out · \(model)"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
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
        .platformSheetFrame(width: 560)
        .onAppear {
            name = vehicle.name
            vin = vehicle.vin ?? ""
            trim = vehicle.trim ?? ""
            color = vehicle.color
            colorName = vehicle.colorName ?? ""
            notes = vehicle.notes
        }
        .fileImporter(isPresented: $choosingCover, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                let problems = model.garage.addImages(from: [url], to: vehicle, asCover: true)
                if !problems.isEmpty { error = problems.joined(separator: "\n") }
            case .failure(let failure):
                error = failure.localizedDescription
            }
        }
        .errorAlert($error)
    }

    private var coverDescription: String {
        vehicle.coverImage == nil
            ? "The reference photo that best matches the model, trim, and colour. Upload one of your car to use it instead."
            : "Your photo. Choose another in Photos."
    }

    private func save() {
        vehicle.name = name.trimmingCharacters(in: .whitespaces)
        vehicle.vin = lookup.normalized
        vehicle.trim = trim.trimmed
        vehicle.color = color
        vehicle.colorName = colorName.trimmed
        vehicle.notes = notes
        do {
            try model.garage.context.save()
            dismiss()
        } catch {
            self.error = error.readable
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
            if length >= 17 { problem = error.readable }
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
            problem = error.readable
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

/// The trim as the owner calls it, which the photo search uses.
private struct TrimField: View {
    @Binding var trim: String
    let decoded: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Trim", text: $trim, prompt: Text(decoded ?? "e.g. S Q4"))
            Text(
                decoded.map {
                    "The VIN decodes as “\($0)”. Enter the trim you'd call it if that's different; photos are matched to it."
                } ?? "Photos are matched to it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension String {
    /// Nil when blank.
    fileprivate var trimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
