import SwiftUI

/// Spia's settings: how it looks, and the assistant. A tab each in the Mac's Settings window;
/// one list on an iPhone or iPad, opened from the garage.
struct SettingsView: View {
    var body: some View {
        #if os(macOS)
            TabView {
                Form { AppearanceSection() }
                    .formStyle(.grouped)
                    .platformSheetFrame(width: 520)
                    .fixedSize(horizontal: false, vertical: true)
                    .tabItem { Label("General", systemImage: "gearshape") }
                AssistantSettingsView()
                    .tabItem { Label("Assistant", systemImage: "sparkles") }
            }
        #else
            Form {
                AppearanceSection()
                Section {
                    NavigationLink("Assistant") {
                        AssistantSettingsView()
                            .navigationTitle("Assistant")
                    }
                }
            }
            .navigationTitle("Settings")
        #endif
    }
}

/// Light, dark, or like the device.
private struct AppearanceSection: View {
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    var body: some View {
        Section("Appearance") {
            Picker("Appearance", selection: $appearance) {
                ForEach(Appearance.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(
                "System follows \(PlatformText.thisDevice)'s setting. The car bays stay dark either way, like an instrument cluster at night."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
