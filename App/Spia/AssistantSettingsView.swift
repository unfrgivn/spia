import SpiaAssist
import SpiaStore
import SwiftUI

/// Settings → Assistant: keys, models, and what may be shared.
struct AssistantSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var assistant = model.assistant
        Form {
            Section {
                Picker("Answer with", selection: $assistant.settings.defaultProvider) {
                    ForEach(ProviderID.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Text("You can switch models for any message in the assistant panel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(PlatformText.onDeviceSection) {
                if let reason = OnDeviceProvider.unavailableReason {
                    Label(reason, systemImage: "info.circle").foregroundStyle(.secondary)
                } else {
                    Label(
                        "Apple's on-device model is ready. \(PlatformText.nothingLeaves)",
                        systemImage: "checkmark.circle"
                    )
                    .foregroundStyle(.green)
                }
            }

            ProviderKeySection(
                provider: .anthropic, modelID: $assistant.settings.anthropicModel,
                defaultModel: AnthropicProvider.defaultModel,
                fastModel: AnthropicProvider.fastModel,
                backgroundModelID: $assistant.settings.anthropicBackgroundModel,
                keysURL: URL(string: "https://platform.claude.com/settings/keys"))
            ProviderKeySection(
                provider: .openAI, modelID: $assistant.settings.openAIModel,
                defaultModel: OpenAIProvider.defaultModel, fastModel: OpenAIProvider.fastModel,
                backgroundModelID: $assistant.settings.openAIBackgroundModel,
                keysURL: URL(string: "https://platform.openai.com/api-keys"))

            Section("Privacy") {
                Toggle(
                    "Pause automatic explanations and reviews",
                    isOn: $assistant.settings.automaticWorkPaused)
                Text(
                    "Codes still get their public names. Nothing is sent to a model until you turn this back on."
                )
                .font(.caption).foregroundStyle(.secondary)
                Text(
                    "Spia records tokens per car; see a vehicle's settings. Prices are the provider's."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Toggle(
                    "Include the VIN when sharing with cloud models",
                    isOn: $assistant.settings.shareVIN)
                Text(
                    "Each problem asks before its data is first sent to Claude or OpenAI. The VIN identifies your car; it's rarely needed for diagnosis."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .platformSheetFrame(width: 520)
        #if os(macOS)
            .fixedSize(horizontal: false, vertical: true)
        #endif
    }
}

private struct ProviderKeySection: View {
    @Environment(AppModel.self) private var app
    let provider: ProviderID
    @Binding var modelID: String
    @Binding var backgroundModelID: String
    let defaultModel: String
    let fastModel: String
    let keysURL: URL?
    @State private var key = ""
    @State private var problem: String?

    init(
        provider: ProviderID, modelID: Binding<String>, defaultModel: String, fastModel: String,
        backgroundModelID: Binding<String>,
        keysURL: URL?
    ) {
        self.provider = provider
        _modelID = modelID
        _backgroundModelID = backgroundModelID
        self.defaultModel = defaultModel
        self.fastModel = fastModel
        self.keysURL = keysURL
    }

    var body: some View {
        Section(provider.displayName) {
            if app.assistant.configuredKeys.contains(provider) {
                LabeledContent("API key") {
                    HStack {
                        Label("Saved in your Keychain", systemImage: "key.fill").foregroundStyle(
                            .secondary)
                        Button("Remove") { save("") }
                    }
                }
            } else {
                LabeledContent("API key") {
                    HStack {
                        SecureField("Paste key", text: $key)
                            .labelsHidden()
                            .onSubmit { save(key) }
                        Button("Save") { save(key) }
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let keysURL {
                    Link("Get an API key", destination: keysURL)
                        .font(.caption)
                }
            }
            LabeledContent("Explanations and reviews") {
                Picker("Explanations and reviews", selection: $backgroundModelID) {
                    Text("Most capable (\(defaultModel))").tag(defaultModel)
                    Text("Faster, cheaper (\(fastModel))").tag(fastModel)
                    if modelID != defaultModel && modelID != fastModel {
                        Text("Same as chat (\(modelID))").tag(modelID)
                    }
                }
                .labelsHidden()
            }
            LabeledContent("Model") {
                HStack {
                    TextField("Model", text: $modelID)
                        .labelsHidden()
                        .font(.body.monospaced())
                    Menu("Presets") {
                        Button("Most capable (\(defaultModel))") { modelID = defaultModel }
                        Button("Faster, cheaper (\(fastModel))") { modelID = fastModel }
                    }
                    .fixedSize()
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func save(_ value: String) {
        do {
            try app.assistant.setKey(value, for: provider)
            key = ""
            problem = nil
        } catch {
            problem = error.readable
        }
    }
}
