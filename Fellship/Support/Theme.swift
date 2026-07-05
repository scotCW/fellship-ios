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
