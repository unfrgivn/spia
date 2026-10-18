import SpiaAssist
import SpiaKit
import SpiaStore
import SwiftUI

struct InterpretationConsentCard: View {
    @Environment(AppModel.self) private var model
    let compact: Bool
    let board: SessionBoard
    let vehicle: Vehicle
    let interpretations: VehicleInterpretations
    let allow: () -> Void
    let dismiss: () -> Void

    private var provider: ProviderID { model.assistant.settings.defaultProvider }
    private var unavailable: String? { model.assistant.unavailableReason(provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(
                unavailable == nil
                    ? "Explain this car's codes with \(provider.displayName)?"
                    : "Code explanations are unavailable"
            )
            .font(.headline)
            .foregroundStyle(Palette.primary)
            Text(
                unavailable
                    ?? "Spia sends the make, model, and year, the module names, the codes and their public names, what you noticed in open problems, and the photos and clip frames you attach to findings. The VIN stays here unless Settings allow it. Once allowed, new codes are explained as they're read."
            )
            .font(.callout)
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if unavailable == nil {
                    Button("Allow for this car", action: allow)
                        .buttonStyle(.borderedProminent)
                    Button("Not now", action: dismiss)
                        .buttonStyle(.bordered)
                } else {
                    AssistantSettingsButton(look: .prominent, onDismiss: nil)
                    Button("Not now", action: dismiss)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(compact ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: Palette.accent)
    }
}
