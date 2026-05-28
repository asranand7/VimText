import SwiftUI

struct AppTheme: Identifiable, Hashable {
    let id: String
    let name: String
    let isDark: Bool

    private let editorBg: String
    private let surfaceBg: String
    private let textColor: String
    private let secondaryColor: String
    private let accentColor: String
    private let separatorColor: String

    var editorBackground: Color { Color(hex: editorBg) }
    var surface: Color { Color(hex: surfaceBg) }
    var text: Color { Color(hex: textColor) }
    var secondaryText: Color { Color(hex: secondaryColor) }
    var accent: Color { Color(hex: accentColor) }
    var separator: Color { Color(hex: separatorColor) }

    var editorBackgroundNS: NSColor { NSColor(hex: editorBg) }
    var surfaceNS: NSColor { NSColor(hex: surfaceBg) }
    var textNS: NSColor { NSColor(hex: textColor) }
    var secondaryTextNS: NSColor { NSColor(hex: secondaryColor) }
    var accentNS: NSColor { NSColor(hex: accentColor) }

    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

extension AppTheme {
    static let light = AppTheme(
        id: "light", name: "Light", isDark: false,
        editorBg: "FFFFFF", surfaceBg: "F6F6F7", textColor: "1D1D1F",
        secondaryColor: "8A8A8E", accentColor: "E5A50A", separatorColor: "E2E2E5"
    )
    static let gray = AppTheme(
        id: "gray", name: "Gray", isDark: true,
        editorBg: "3A3D42", surfaceBg: "32353A", textColor: "D6D9DE",
        secondaryColor: "9BA0A8", accentColor: "7FB0C9", separatorColor: "4A4E54"
    )
    static let dark = AppTheme(
        id: "dark", name: "Dark", isDark: true,
        editorBg: "1C1C1E", surfaceBg: "252528", textColor: "E6E6E8",
        secondaryColor: "98989D", accentColor: "FFD60A", separatorColor: "38383A"
    )
    static let catppuccinLatte = AppTheme(
        id: "catppuccin-latte", name: "Catppuccin Latte", isDark: false,
        editorBg: "EFF1F5", surfaceBg: "E6E9EF", textColor: "4C4F69",
        secondaryColor: "6C6F85", accentColor: "8839EF", separatorColor: "CCD0DA"
    )
    static let catppuccinMocha = AppTheme(
        id: "catppuccin-mocha", name: "Catppuccin Mocha", isDark: true,
        editorBg: "1E1E2E", surfaceBg: "313244", textColor: "CDD6F4",
        secondaryColor: "A6ADC8", accentColor: "CBA6F7", separatorColor: "45475A"
    )
    static let nord = AppTheme(
        id: "nord", name: "Nord", isDark: true,
        editorBg: "2E3440", surfaceBg: "3B4252", textColor: "D8DEE9",
        secondaryColor: "81A1C1", accentColor: "88C0D0", separatorColor: "434C5E"
    )
    static let dracula = AppTheme(
        id: "dracula", name: "Dracula", isDark: true,
        editorBg: "282A36", surfaceBg: "44475A", textColor: "F8F8F2",
        secondaryColor: "6272A4", accentColor: "BD93F9", separatorColor: "44475A"
    )
    static let gruvbox = AppTheme(
        id: "gruvbox", name: "Gruvbox", isDark: true,
        editorBg: "282828", surfaceBg: "3C3836", textColor: "EBDBB2",
        secondaryColor: "A89984", accentColor: "FE8019", separatorColor: "504945"
    )
    static let solarizedDark = AppTheme(
        id: "solarized-dark", name: "Solarized Dark", isDark: true,
        editorBg: "002B36", surfaceBg: "073642", textColor: "93A1A1",
        secondaryColor: "586E75", accentColor: "B58900", separatorColor: "094350"
    )

    static let all: [AppTheme] = [
        light, gray, dark,
        catppuccinLatte, catppuccinMocha,
        nord, dracula, gruvbox, solarizedDark
    ]

    static func theme(id: String) -> AppTheme {
        all.first { $0.id == id } ?? light
    }
}

final class ThemeManager: ObservableObject {
    @Published var themeID: String {
        didSet { UserDefaults.standard.set(themeID, forKey: Self.storageKey) }
    }

    /// Optional user-picked sidebar tint (hex). When nil, the theme accent is used.
    @Published var sidebarTintHex: String? {
        didSet { UserDefaults.standard.set(sidebarTintHex, forKey: Self.sidebarKey) }
    }

    private static let storageKey = "selectedThemeID"
    private static let sidebarKey = "sidebarTintHex"

    init() {
        themeID = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppTheme.light.id
        sidebarTintHex = UserDefaults.standard.string(forKey: Self.sidebarKey)
    }

    var theme: AppTheme { AppTheme.theme(id: themeID) }

    /// Effective sidebar tint color: custom pick, or theme accent.
    var sidebarTint: Color {
        if let hex = sidebarTintHex { return Color(hex: hex) }
        return theme.accent
    }

    var isUsingCustomSidebarTint: Bool { sidebarTintHex != nil }

    func setSidebarTint(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        sidebarTintHex = String(
            format: "%02X%02X%02X",
            Int((ns.redComponent * 255).rounded()),
            Int((ns.greenComponent * 255).rounded()),
            Int((ns.blueComponent * 255).rounded())
        )
    }

    func resetSidebarTint() { sidebarTintHex = nil }
}

let sidebarTintPresets: [String] = [
    "E5A50A", "FF6B6B", "F06595", "CC5DE8", "845EF7",
    "5C7CFA", "339AF0", "22B8CF", "20C997", "51CF66",
    "94D82D", "FCC419", "FF922B", "868E96"
]

extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
