import SpiaKit
import SwiftUI

extension Tone {
    var color: Color {
        switch self {
        case .neutral: return .secondary
        case .working: return .blue
        case .attention: return .orange
        case .good: return .green
        case .bad: return .red
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

    /// The rounded, lightly filled container used for cards throughout the app.
    func card(tint: Color? = nil) -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.map { $0.opacity(0.08) } ?? PlatformColor.controlBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.map { $0.opacity(0.35) } ?? Color.primary.opacity(0.08))
            )
    }
}

/// Small rounded label, e.g. a DTC status flag.
struct Chip: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: Capsule())
    }
}
