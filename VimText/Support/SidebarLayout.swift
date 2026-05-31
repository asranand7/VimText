import Foundation

public enum SidebarLayout {
    public static let defaultWidth = 300.0
    public static let minimumWidth = 240.0
    public static let maximumWidth = 420.0

    public static func clampedWidth(_ width: Double) -> Double {
        min(max(width, minimumWidth), maximumWidth)
    }
}
