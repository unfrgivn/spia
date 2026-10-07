import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// How Spia looks: like the device, always light, or always dark. The car bays are drawn dark
/// whichever it is.
enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    /// Where the choice is kept.
    static let storageKey = "appearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Puts every window in this appearance. AppKit and UIKit own it, not SwiftUI's
    /// `preferredColorScheme`, which can't reliably go back to the system's: after Light or
    /// Dark, `nil` leaves a split view's content in the old appearance until the window loses
    /// focus. On a Mac this covers windows opened later too; on iOS each window applies it as
    /// it opens.
    @MainActor func apply() {
        #if os(macOS)
            NSApplication.shared.appearance =
                switch self {
                case .system: nil
                case .light: NSAppearance(named: .aqua)
                case .dark: NSAppearance(named: .darkAqua)
                }
        #else
            let style: UIUserInterfaceStyle =
                switch self {
                case .system: .unspecified
                case .light: .light
                case .dark: .dark
                }
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                for window in scene.windows { window.overrideUserInterfaceStyle = style }
            }
        #endif
    }
}

extension View {
    /// Keeps the app in the appearance chosen in Settings, from the moment this view appears.
    func followsAppearanceSetting() -> some View { modifier(FollowsAppearanceSetting()) }
}

private struct FollowsAppearanceSetting: ViewModifier {
    @AppStorage(Appearance.storageKey) private var appearance: Appearance = .system

    func body(content: Content) -> some View {
        content.onChange(of: chosen, initial: true) { _, chosen in chosen.apply() }
    }

    /// Screenshot fixtures choose their own.
    private var chosen: Appearance {
        #if DEBUG
            Fixture.appearance ?? appearance
        #else
            appearance
        #endif
    }
}
