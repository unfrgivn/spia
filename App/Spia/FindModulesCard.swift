import SwiftUI

struct FindModulesCard: View {
    let compact: Bool
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find this car's modules")
                .font(.headline)
                .foregroundStyle(Palette.primary)
            Text(
                "Ask the car which diagnostic modules are awake, then review their names and codes."
            )
            .font(.callout)
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Find Modules", action: action)
                .buttonStyle(.borderedProminent)
                .disabled(disabled)
        }
        .padding(compact ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(tint: Palette.accent)
    }
}
