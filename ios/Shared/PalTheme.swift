import SwiftUI

enum PalTheme {
    static let ink = Color(uiColor: .label)
    static let onInk = Color(uiColor: .systemBackground)
    static let accent = Color(red: 1, green: 122 / 255, blue: 26 / 255)
    static let onAccent = Color.black
    /// Darker orange keeps small links readable on a light surface.
    static let accentText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1, green: 0.6, blue: 0.28, alpha: 1)
            : UIColor(red: 0.65, green: 0.24, blue: 0, alpha: 1)
    })
    static let accentOnInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.65, green: 0.24, blue: 0, alpha: 1)
            : UIColor(red: 1, green: 122 / 255, blue: 26 / 255, alpha: 1)
    })
}
