import SwiftUI

enum PalTheme {
    // Brand variants live here; screens use semantic roles rather than fixed colors.
    private static let orange = UIColor(red: 1, green: 122 / 255, blue: 26 / 255, alpha: 1)
    private static let darkOrange = UIColor(red: 0.65, green: 0.24, blue: 0, alpha: 1)
    private static let lightOrange = UIColor(red: 1, green: 0.6, blue: 0.28, alpha: 1)

    static let ink = Color(uiColor: .label)
    static let onInk = Color(uiColor: .systemBackground)
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? darkOrange : orange
    })
    static let onAccent = ink
    static let error = Color(uiColor: .systemRed)
    /// Small links use a brand variant with contrast against the current surface.
    static let accentText = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? lightOrange : darkOrange
    })
    static let accentOnInk = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? darkOrange : orange
    })

    // Mascot artwork keeps its supplied colors against a transparent background.
    static let mascotInkHex = "#ff7a1a"
    static let mascotPaperHex = "#fffff5"
}
