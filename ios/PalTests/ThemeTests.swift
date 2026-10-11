import XCTest
import SwiftUI
@testable import Pal

final class ThemeTests: XCTestCase {
    @MainActor private func resolved(_ color: Color, _ style: UIUserInterfaceStyle) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = style == .dark ? .dark : .light
        return color.resolve(in: environment)
    }

    private func luminance(_ color: Color.Resolved) -> Double {
        0.2126 * Double(color.linearRed) + 0.7152 * Double(color.linearGreen) + 0.0722 * Double(color.linearBlue)
    }

    @MainActor func testTextAndBrandRolesKeepReadableContrastInBothAppearances() {
        let roles: [(String, Color, Color)] = [
            ("Primary text", PalTheme.ink, Color(uiColor: .systemBackground)),
            ("Text on an ink bubble", PalTheme.onInk, PalTheme.ink),
            ("Accent button text", PalTheme.onAccent, PalTheme.accent),
            ("Small accent links", PalTheme.accentText, Color(uiColor: .systemBackground)),
            ("Accent on an ink bubble", PalTheme.accentOnInk, PalTheme.ink)
        ]
        for style: UIUserInterfaceStyle in [.light, .dark] {
            for (name, foreground, background) in roles {
                let a = luminance(resolved(foreground, style))
                let b = luminance(resolved(background, style))
                let contrast = (max(a, b) + 0.05) / (min(a, b) + 0.05)
                XCTAssertGreaterThanOrEqual(contrast, 4.5, "\(name) needs readable contrast in \(style == .dark ? "dark" : "light") appearance.")
            }
        }
    }

    @MainActor func testValidationUsesTheNativeSemanticErrorColor() {
        for style: UIUserInterfaceStyle in [.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let actual = resolved(PalTheme.error, style)
            let expected = UIColor.systemRed.resolvedColor(with: traits)
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(expected.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            XCTAssertEqual(actual.red, Float(red), accuracy: 0.00001)
            XCTAssertEqual(actual.green, Float(green), accuracy: 0.00001)
            XCTAssertEqual(actual.blue, Float(blue), accuracy: 0.00001)
            XCTAssertEqual(actual.opacity, Float(alpha), accuracy: 0.00001)
        }
    }
}
