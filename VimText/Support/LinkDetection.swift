import Foundation

/// Pure URL detection for the editor's link highlighting. Wraps NSDataDetector
/// (which understands `https://…`, bare `www.…`, and email addresses) behind a
/// value type so the storage-free logic stays testable from the smoke tests.
public enum LinkDetection {
    public struct Link: Equatable {
        /// UTF-16 range into the scanned text.
        public let range: NSRange
        public let url: URL

        public init(range: NSRange, url: URL) {
            self.range = range
            self.url = url
        }
    }

    /// Safety cap so a pathological note can't accumulate unbounded
    /// highlight/cursor-rect work (same idea as `maxSearchMatches`).
    public static let maxLinks = 2000

    private static let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// Every link in `text`, in document order.
    public static func links(in text: String) -> [Link] {
        guard !text.isEmpty, let detector else { return [] }
        let ns = text as NSString
        var out: [Link] = []
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, stop in
            if let match, let url = match.url {
                out.append(Link(range: match.range, url: url))
                if out.count >= maxLinks { stop.pointee = true }
            }
        }
        return out
    }
}
