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
    var isMonochrome: Bool { id == "graphite" || id == "ink" }
    var isGraphite: Bool { id == "graphite" }
    var isInk: Bool { id == "ink" }

    var editorBackgroundNS: NSColor { NSColor(hex: editorBg) }
    var surfaceNS: NSColor { NSColor(hex: surfaceBg) }
    var textNS: NSColor { NSColor(hex: textColor) }
    var secondaryTextNS: NSColor { NSColor(hex: secondaryColor) }
    var accentNS: NSColor { NSColor(hex: accentColor) }

    var colorScheme: ColorScheme { isDark ? .dark : .light }
}

extension AppTheme {
    static let indigo = AppTheme(
        id: "indigo", name: "Indigo (Recommended)", isDark: false,
        editorBg: "FFFFFF", surfaceBg: "F8FAFC", textColor: "0F172A",
        secondaryColor: "64748B", accentColor: "4F46E5", separatorColor: "E2E8F0"
    )
    static let sageGreen = AppTheme(
        id: "sage-green", name: "Sage Green", isDark: false,
        editorBg: "FCFDFB", surfaceBg: "F1F5F0", textColor: "1E2E22",
        secondaryColor: "68756A", accentColor: "4E7A67", separatorColor: "E2EAE0"
    )
    static let graphite = AppTheme(
        id: "graphite", name: "Graphite", isDark: true,
        editorBg: "121214", surfaceBg: "1C1C1F", textColor: "E4E4E7",
        secondaryColor: "A1A1AA", accentColor: "A8A8B2", separatorColor: "2A2A2E"
    )
    static let lavender = AppTheme(
        id: "lavender", name: "Lavender", isDark: false,
        editorBg: "FAF9FD", surfaceBg: "F2EEF7", textColor: "2D1D4A",
        secondaryColor: "7C6E9E", accentColor: "8A5CF6", separatorColor: "EAE3F1"
    )
    static let sand = AppTheme(
        id: "sand", name: "Sand", isDark: false,
        editorBg: "FDFCF7", surfaceBg: "F6F3E9", textColor: "3E2723",
        secondaryColor: "8D6E63", accentColor: "C28A3E", separatorColor: "EFEAE0"
    )
    static let oceanBlue = AppTheme(
        id: "ocean-blue", name: "Ocean Blue", isDark: false,
        editorBg: "F7FAFC", surfaceBg: "EEF5F9", textColor: "0F172A",
        secondaryColor: "475569", accentColor: "0284C7", separatorColor: "E1EDF4"
    )
    static let light = AppTheme(
        id: "light", name: "Light", isDark: false,
        editorBg: "FCFCFB", surfaceBg: "F4F3F0", textColor: "26262B",
        secondaryColor: "8E8D87", accentColor: "D99A0B", separatorColor: "EAE8E3"
    )
    static let dark = AppTheme(
        id: "dark", name: "Dark", isDark: true,
        editorBg: "1C1C1E", surfaceBg: "252528", textColor: "E6E6E8",
        secondaryColor: "98989D", accentColor: "FFD60A", separatorColor: "38383A"
    )
    static let ink = AppTheme(
        id: "ink", name: "Ink", isDark: true,
        editorBg: "101112", surfaceBg: "18191B", textColor: "F1F0EC",
        secondaryColor: "9D9B95", accentColor: "D8D3C8", separatorColor: "2B2C2F"
    )
    static let gray = AppTheme(
        id: "gray", name: "Gray", isDark: true,
        editorBg: "3A3D42", surfaceBg: "32353A", textColor: "D6D9DE",
        secondaryColor: "9BA0A8", accentColor: "7FB0C9", separatorColor: "4A4E54"
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
        indigo, sageGreen, graphite, lavender, sand, oceanBlue,
        light, dark, ink, gray, catppuccinLatte, catppuccinMocha,
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
        themeID = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppTheme.indigo.id
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

enum EditorSurfacePalette {
    static func panelFill(for theme: AppTheme) -> Color {
        if theme.isInk { return theme.surface.opacity(0.82) }
        if theme.isGraphite { return theme.surface.opacity(0.88) }
        return theme.isDark ? theme.surface.opacity(0.34) : Color.white.opacity(0.78)
    }

    static func panelStroke(for theme: AppTheme) -> Color {
        if theme.isMonochrome { return theme.separator.opacity(theme.isDark ? 0.55 : 0.62) }
        return Color.white.opacity(theme.isDark ? 0.055 : 0.55)
    }

    static func paperFill(for theme: AppTheme) -> Color {
        if theme.isGraphite { return theme.editorBackground.opacity(0.92) }
        if theme.isInk { return Color(hex: "121315") }
        return theme.editorBackground.opacity(theme.isDark ? 0.14 : 0.18)
    }

    static func paperColorForContrast(for theme: AppTheme) -> NSColor {
        if theme.isInk { return NSColor(hex: "121315") }
        return theme.editorBackgroundNS
    }
}

public enum ThemeContrastChecks {
    public static let minimumReadableContrastRatio = 4.5

    public static func graphiteEditorTextContrastRatio() -> Double {
        contrastRatio(
            foreground: AppTheme.graphite.textNS,
            background: EditorSurfacePalette.paperColorForContrast(for: .graphite)
        )
    }

    private static func contrastRatio(foreground: NSColor, background: NSColor) -> Double {
        let foregroundLuminance = relativeLuminance(foreground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func relativeLuminance(_ color: NSColor) -> Double {
        let rgb = color.usingColorSpace(.sRGB) ?? color
        let r = linearized(Double(rgb.redComponent))
        let g = linearized(Double(rgb.greenComponent))
        let b = linearized(Double(rgb.blueComponent))
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private static func linearized(_ component: Double) -> Double {
        component <= 0.03928
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
}

let sidebarTintPresets: [String] = [
    "E5A50A", "3F4146", "D8D3C8", "868E96", "FF6B6B",
    "F06595", "CC5DE8", "845EF7", "5C7CFA", "339AF0",
    "22B8CF", "20C997", "51CF66", "94D82D", "FCC419", "FF922B"
]

/// Shared design tokens for a consistent, Linear-inspired motion & shape language.
enum DS {
    /// Primary spring for selection, panel and content transitions. Fast, settled, understated.
    static let spring = Animation.spring(response: 0.14, dampingFraction: 0.82)
    /// Snappier spring for hover / press microinteractions.
    static let snappy = Animation.spring(response: 0.11, dampingFraction: 0.85)
    /// Crossfade used for content / page-state changes.
    static let crossfade = Animation.easeInOut(duration: 0.14)

    static let cardRadius: CGFloat = 12
    static let panelRadius: CGFloat = 16
    static let controlRadius: CGFloat = 10
}

struct PressableIconButtonStyle: ButtonStyle {
    var radius: CGFloat = DS.controlRadius
    var pressedScale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(DS.snappy, value: configuration.isPressed)
    }
}

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
