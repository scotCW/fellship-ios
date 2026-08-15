import SwiftUI

extension AppTheme {
    /// Accent color per theme (light/dark variants where it matters).
    var accent: Color {
        switch self {
        case .fell: return Color(red: 0.165, green: 0.616, blue: 0.560)
        case .ocean: return Color(red: 0.145, green: 0.463, blue: 0.737)
        case .ember: return Color(red: 0.851, green: 0.420, blue: 0.180)
        case .moss: return Color(red: 0.333, green: 0.541, blue: 0.290)
        case .violet: return Color(red: 0.478, green: 0.353, blue: 0.702)
        case .slate: return Color(red: 0.408, green: 0.463, blue: 0.522)
        }
    }
}

extension AppearanceOverride {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

extension Color {
    /// WCAG relative luminance (sRGB → linear, ITU-R BT.709 weights).
    private var relativeLuminance: Double {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        func linearize(_ c: CGFloat) -> Double {
            let c = Double(c)
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(r) + 0.7152 * linearize(g) + 0.0722 * linearize(b)
    }

    /// Black or white, whichever gives higher WCAG contrast when used as text
    /// on top of this color as a background. Used so accent-colored surfaces
    /// (e.g. the "my message" chat bubble) stay legible under every theme,
    /// including ones tuned for icon/accent use rather than body text.
    var accessibleForeground: Color {
        let bg = relativeLuminance
        let contrastWithWhite = 1.05 / (bg + 0.05)
        let contrastWithBlack = (bg + 0.05) / 0.05
        return contrastWithWhite >= contrastWithBlack ? .white : .black
    }
}
