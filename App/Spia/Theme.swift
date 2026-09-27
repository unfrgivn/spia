import SpiaKit
import SwiftUI

extension Tone {
    var color: Color {
        switch self {
        case .neutral: return Palette.secondary
        case .working: return Palette.working
        case .attention: return Palette.caution
        case .good: return Palette.pass
        case .bad: return Palette.fault
        }
    }
}

extension View {
    /// Shows `message` in an alert and clears it when dismissed.
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert(
            "Something went wrong",
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { if !$0 { message.wrappedValue = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }

    /// A card: the card surface with a hairline edge. A tint marks a card that's about one
    /// thing, such as a check waiting for the user.
    func card(tint: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.map { $0.opacity(0.10) } ?? Palette.card, in: shape)
            .overlay(shape.strokeBorder(tint.map { $0.opacity(0.4) } ?? Palette.hairline))
    }
}

/// Small rounded label, e.g. a DTC status flag.
struct Chip: View {
    let text: String
    var color: Color = Palette.secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}
