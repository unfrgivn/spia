import SwiftUI

/// Automatic work that didn't run, shown where its result would be.
struct AssistantFailureCard: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline).foregroundStyle(Palette.primary)
            Text(message)
                .font(.callout)
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Try again", action: retry).buttonStyle(.borderedProminent)
                AssistantSettingsButton(look: .bordered, onDismiss: retry)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: Palette.accent)
    }
}

/// The same as a line, for work whose earlier result is still on screen. The links sit under
/// the reason so a long one wraps across the full width of an iPhone.
struct AssistantFailureLine: View {
    let title: String
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title): \(message)")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Try again", action: retry)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.accent)
                AssistantSettingsButton(look: .link, onDismiss: retry)
            }
        }
    }
}

/// Opens Assistant Settings: the Settings window on a Mac, a sheet on an iPhone or iPad. It
/// styles itself, below its sheet: the sheet inherits the environment around this view, so a
/// style applied from outside would restyle the settings form too.
struct AssistantSettingsButton: View {
    enum Look { case prominent, bordered, link }

    #if os(macOS)
        @Environment(\.openSettings) private var openSettings
    #endif
    let look: Look
    let onDismiss: (() -> Void)?
    @State private var showingSettings = false

    var body: some View {
        styled
            #if os(iOS)
                .sheet(isPresented: $showingSettings, onDismiss: { onDismiss?() }) {
                    NavigationStack {
                        AssistantSettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showingSettings = false }
                            }
                        }
                    }
                }
            #endif
    }

    @ViewBuilder private var styled: some View {
        let button = Button("Assistant Settings…", action: showSettings)
        switch look {
        case .prominent: button.buttonStyle(.borderedProminent)
        case .bordered: button.buttonStyle(.bordered)
        case .link:
            button
                .buttonStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.accent)
        }
    }

    private func showSettings() {
        #if os(macOS)
            openSettings()
        #else
            showingSettings = true
        #endif
    }
}
