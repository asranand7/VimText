import Foundation

/// Shared, cached `DateFormatter` instances.
///
/// Creating a `DateFormatter` is expensive (locale / ICU setup). The note
/// list renders many rows many times per second during hover and scroll, so
/// allocating a formatter inside a view's `body` shows up as CPU spikes and
/// mouse stutter. Each formatter here is configured once and only ever read
/// afterwards — `DateFormatter.string(from:)` is safe to call concurrently on
/// an otherwise-immutable formatter, and in practice all use is on the main
/// (render) thread.
///
/// Locale is intentionally left at the user default (matching the previous
/// inline formatters) so weekday / month names stay localized.
enum AppDateFormatters {
    /// e.g. "3:45 PM"
    static let timeOnly = make("h:mm a")
    /// e.g. "Tuesday"
    static let weekday = make("EEEE")
    /// e.g. "3/4/25"
    static let shortDate = make("M/d/yy")
    /// e.g. "March"
    static let month = make("MMMM")
    /// e.g. "March 2024"
    static let monthYear = make("MMMM yyyy")

    /// Localized short date + short time, e.g. "3/4/25, 3:45 PM".
    static let shortDateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        return f
    }
}
