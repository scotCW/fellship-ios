import XCTest
import SwiftUI
@testable import Fellship

/// Guards the WCAG AA text-contrast bar (4.5:1) for every theme's accent
/// used as a chat-bubble background — this exact gap ("fell" theme's white
/// text on its own accent came in at 3.32:1) is what App Store Connect's
/// accessibility "Sufficient Contrast" declaration would be lying about if
/// it regressed.
final class ThemeContrastTests: XCTestCase {
    private func contrastRatio(_ a: UIColor, _ b: UIColor) -> Double {
        func luminance(_ c: UIColor) -> Double {
            var r: CGFloat = 0, g: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            c.getRed(&r, green: &g, blue: &blue, alpha: &alpha)
            func lin(_ v: CGFloat) -> Double {
                let v = Double(v)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(blue)
        }
        let l1 = luminance(a), l2 = luminance(b)
        let (hi, lo) = l1 > l2 ? (l1, l2) : (l2, l1)
        return (hi + 0.05) / (lo + 0.05)
    }

    func testEveryThemeAccentMeetsAAContrastForBubbleText() {
        for theme in AppTheme.allCases {
            let background = UIColor(theme.accent)
            let foreground = UIColor(theme.accent.accessibleForeground)
            let ratio = contrastRatio(background, foreground)
            XCTAssertGreaterThanOrEqual(ratio, 4.5,
                "\(theme) bubble text only reaches \(ratio)x contrast, below WCAG AA's 4.5x")
        }
    }

    func testAccessibleForegroundIsAlwaysBlackOrWhite() {
        for theme in AppTheme.allCases {
            let fg = theme.accent.accessibleForeground
            XCTAssertTrue(fg == .white || fg == .black, "\(theme) picked an unexpected foreground")
        }
    }
}
