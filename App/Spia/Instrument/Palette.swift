import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The Instrument palette: navy panels from the app icon, the icon's amber-to-red arc for the
/// car's condition, and cyan, like an instrument's backlight, for what can be pressed and for
/// Spia at work. Warm colours only ever describe the car. Every colour follows the appearance
/// of the view it's drawn in, so the cluster, which is always drawn dark, stays dark by day.
enum Palette {
    // Surfaces, from the window background up.
    static let base = Color(day: 0xF4F6FB, night: 0x0A1022)
    static let panel = Color(day: 0xEEF1F8, night: 0x10182E)
    static let card = Color(day: 0xFFFFFF, night: 0x16213D)
    static let raised = Color(day: 0xF7F9FD, night: 0x1D2A4C)
    static let inset = Color(day: 0xEBEEF6, night: 0x0D1428)
    static let hairline = Color(day: 0x0E1630, night: 0xFFFFFF, opacity: 0.08)
    /// A highlight along a panel's top edge, like light catching a bezel.
    static let bezel = Color(day: 0xFFFFFF, night: 0xFFFFFF, opacity: 0.06)
    static let gaugeTrack = Color(day: 0xD5DBEA, night: 0x2F4270)
    /// The navy a photo fades into under text, the same by day and by night.
    static let scrim = Color(day: 0x0A1022, night: 0x0A1022, opacity: 0.92)

    // Text.
    static let primary = Color(day: 0x0E1630, night: 0xEEF2FA)
    static let secondary = Color(day: 0x4A5577, night: 0xA3AECB)
    static let tertiary = Color(day: 0x7A84A3, night: 0x6E7BA0)

    // The car's condition.
    static let caution = Color(day: 0xB7791F, night: 0xFFC24A)
    static let fault = Color(day: 0xD63A1F, night: 0xFF4D2E)
    static let pass = Color(day: 0x1F9D6B, night: 0x3DDC97)

    /// Spia at work: connecting, reading, live values.
    static let working = Color(day: 0x0A84C6, night: 0x4CC3FF)

    /// What can be pressed: the same cyan, the app's AccentColor too.
    static let accent = working
}

extension Color {
    /// A colour that resolves per appearance: `day` in light mode, `night` in dark.
    init(day: UInt32, night: UInt32, opacity: Double = 1) {
        #if os(macOS)
            self.init(
                nsColor: NSColor(name: nil) { appearance in
                    let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    let (red, green, blue) = channels(dark ? night : day)
                    return NSColor(srgbRed: red, green: green, blue: blue, alpha: opacity)
                })
        #else
            self.init(
                uiColor: UIColor { traits in
                    let (red, green, blue) = channels(
                        traits.userInterfaceStyle == .dark ? night : day)
                    return UIColor(red: red, green: green, blue: blue, alpha: opacity)
                })
        #endif
    }
}

private func channels(_ rgb: UInt32) -> (CGFloat, CGFloat, CGFloat) {
    (
        CGFloat((rgb >> 16) & 0xFF) / 255,
        CGFloat((rgb >> 8) & 0xFF) / 255,
        CGFloat(rgb & 0xFF) / 255
    )
}
