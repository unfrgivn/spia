import SwiftUI

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The Instrument palette: neutral near-black panels, so the only colours on screen are the
/// car's (amber to red for its condition, the icon's arc) and cyan, like an instrument's
/// backlight, for what can be pressed and for Spia at work. Warm colours only ever describe the
/// car. Every colour follows the appearance of the view it's drawn in, so a view drawn dark stays
/// dark by day.
enum Palette {
    // Surfaces, from the window background up.
    static let base = Color(day: 0xF4F5F7, night: 0x08090B)
    static let panel = Color(day: 0xEBEDF0, night: 0x0F1114)
    static let card = Color(day: 0xFFFFFF, night: 0x14171B)
    static let hairline = Color(day: 0x0E1116, night: 0xFFFFFF, opacity: 0.08)
    /// The near-black a photo fades into under text, the same by day and by night.
    static let scrim = Color(day: 0x08090B, night: 0x08090B, opacity: 0.92)

    // Text.
    static let primary = Color(day: 0x0E1116, night: 0xF2F3F5)
    static let secondary = Color(day: 0x4A505A, night: 0xA6AAB2)
    static let tertiary = Color(day: 0x878D97, night: 0x6C717A)

    // The car's condition.
    static let caution = Color(day: 0xB7791F, night: 0xFFC24A)
    static let fault = Color(day: 0xD63A1F, night: 0xFF4D2E)
    static let pass = Color(day: 0x1F9D6B, night: 0x3DDC97)

    /// Spia at work: connecting, reading, live values.
    static let working = Color(day: 0x0A84C6, night: 0x4CC3FF)

    /// What can be pressed: the same cyan, the app's AccentColor too.
    static let accent = working
    /// Text on the accent colour.
    static let onAccent = Color(day: 0xFFFFFF, night: 0x04121B)
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
