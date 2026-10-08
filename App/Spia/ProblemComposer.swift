import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftUI

struct ProblemComposer: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let vehicle: Vehicle
    let started: (DiagnosticSession) -> Void

    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Start a Problem")
                .font(.title2.weight(.semibold))
            TextField(
                "What's wrong with the car?", text: $text,
                prompt: Text("What happens, when it started, what you've noticed"), axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...6)
            caption
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .platformSheetFrame(width: 560)
        .errorAlert($error)
        #if DEBUG
            .onAppear {
                if Fixture.screen == .startProblem && text.isEmpty {
                    text = "Horn and wheel buttons are dead, airbag light is on"
                }
            }
        #endif
    }

    private var caption: some View {
        Group {
            let provider = model.assistant.settings.defaultProvider
            if model.assistant.unavailableReason(provider) != nil {
                Text(
                    "Add a \(provider.displayName) key in Settings for an answer; the problem is kept either way."
                )
            } else if provider.isCloud {
                Text(
                    "Your words and the car's readings go to \(provider.displayName). The VIN stays here unless Settings allow it."
                )
            } else {
                Text("Answered on \(PlatformText.thisDevice).")
            }
        }
        .font(.caption)
        .foregroundStyle(Palette.tertiary)
    }

    private func start() {
        do {
            let session = try model.startProblem(for: vehicle, saying: text)
            dismiss()
            started(session)
        } catch {
            self.error = error.readable
        }
    }
}

struct ProblemComposerInline: View {
    @Environment(AppModel.self) private var model
    let vehicle: Vehicle
    let started: (DiagnosticSession) -> Void
    @State private var text = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(
                "What's wrong with the car?", text: $text,
                prompt: Text("What happens, when it started, what you've noticed"), axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...6)
            HStack(alignment: .firstTextBaseline) {
                caption
                Spacer()
                Button("Start", action: start)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .errorAlert($error)
        #if DEBUG
            .onAppear {
                if Fixture.screen == .startProblem && text.isEmpty {
                    text = "Horn and wheel buttons are dead, airbag light is on"
                }
            }
        #endif
    }

    private var caption: some View {
        Group {
            let provider = model.assistant.settings.defaultProvider
            if model.assistant.unavailableReason(provider) != nil {
                Text(
                    "Add a \(provider.displayName) key in Settings for an answer; the problem is kept either way."
                )
            } else if provider.isCloud {
                Text(
                    "Your words and the car's readings go to \(provider.displayName). The VIN stays here unless Settings allow it."
                )
            } else {
                Text("Answered on \(PlatformText.thisDevice).")
            }
        }
        .font(.caption)
        .foregroundStyle(Palette.tertiary)
    }

    private func start() {
        do {
            started(try model.startProblem(for: vehicle, saying: text))
            text = ""
        } catch {
            self.error = error.readable
        }
    }
}

private struct ProblemComposerModifier: ViewModifier {
    @Binding var isPresented: Bool
    let vehicle: Vehicle
    let started: (DiagnosticSession) -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            ProblemComposer(vehicle: vehicle, started: started)
        }
    }
}

extension View {
    func problemComposer(
        isPresented: Binding<Bool>, vehicle: Vehicle,
        started: @escaping (DiagnosticSession) -> Void = { _ in }
    ) -> some View {
        modifier(
            ProblemComposerModifier(isPresented: isPresented, vehicle: vehicle, started: started))
    }
}
