import Foundation

public enum EditorPreferences {
    public static let fontSizeKey = "editorFontSize"
    public static let defaultFontSize = 16.0
    public static let minimumFontSize = 10.0
    public static let maximumFontSize = 32.0

    @discardableResult
    public static func increaseFontSize(defaults: UserDefaults = .standard) -> Double {
        setFontSize(fontSize(defaults: defaults) + 1, defaults: defaults)
    }

    @discardableResult
    public static func decreaseFontSize(defaults: UserDefaults = .standard) -> Double {
        setFontSize(fontSize(defaults: defaults) - 1, defaults: defaults)
    }

    @discardableResult
    public static func resetFontSize(defaults: UserDefaults = .standard) -> Double {
        setFontSize(defaultFontSize, defaults: defaults)
    }

    @discardableResult
    public static func setFontSize(_ size: Double, defaults: UserDefaults = .standard) -> Double {
        let clamped = min(max(size, minimumFontSize), maximumFontSize)
        defaults.set(clamped, forKey: fontSizeKey)
        return clamped
    }

    public static func fontSize(defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.double(forKey: fontSizeKey)
        return stored == 0 ? defaultFontSize : min(max(stored, minimumFontSize), maximumFontSize)
    }
}
