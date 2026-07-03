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
    /// e.g. "March"
    static let month = make("MMMM")
    /// e.g. "March 2024"
    static let monthYear = make("MMMM yyyy")

    /// Ordinal day suffixes ("6th") — like the date formatters, configured
    /// once and only read afterwards, so concurrent `string(from:)` is safe.
    private static let ordinalDay: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f
    }()

    /// e.g. "6th June 2026" — the app-wide format for absolute dates, so the
    /// sidebar, palette, and editor header never disagree on day/month order.
    static func ordinalDate(from date: Date) -> String {
        let day = Calendar.current.component(.day, from: date)
        let dayString = ordinalDay.string(from: NSNumber(value: day)) ?? String(day)
        return "\(dayString) \(monthYear.string(from: date))"
    }

    /// e.g. "6th June 2026, 3:45 PM"
    static func ordinalDateTime(from date: Date) -> String {
        "\(ordinalDate(from: date)), \(timeOnly.string(from: date))"
    }

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        return f
    }
}
