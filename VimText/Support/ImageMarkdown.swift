import Foundation
import CoreGraphics

/// Pure helpers for the Markdown image syntax used to embed images in notes.
/// The portable on-disk form is `![|<width>](path)` (Obsidian-compatible: the
/// alt slot carries an optional display width in points). Plain `![](path)` is
/// still accepted for back-compat. Kept AppKit-free so the storage layer and
/// tests can use it.
public enum ImageMarkdown {
    /// Group 1 = alt text (may contain `|<width>`), group 2 = path.
    public static let pattern = "!\\[([^\\]]*)\\]\\(([^)]+)\\)"

    public struct Reference: Equatable {
        public let range: NSRange
        public let path: String
        public let width: CGFloat?
    }

    /// Every image reference in `content`, in document order.
    public static func references(in content: String) -> [Reference] {
        guard !content.isEmpty,
              let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = content as NSString
        return regex.matches(in: content, range: NSRange(location: 0, length: ns.length)).map { match in
            Reference(
                range: match.range,
                path: ns.substring(with: match.range(at: 2)),
                width: width(fromAlt: ns.substring(with: match.range(at: 1)))
            )
        }
    }

    /// Every referenced path, in document order.
    public static func referencedPaths(in content: String) -> [String] {
        references(in: content).map(\.path)
    }

    /// Paths under the local `assets/` folder (the ones this app owns).
    public static func localAssetPaths(in content: String) -> [String] {
        referencedPaths(in: content).filter { $0.hasPrefix("assets/") }
    }

    /// The Markdown string for an embedded asset, optionally carrying a width.
    public static func reference(for relativePath: String, width: CGFloat?) -> String {
        if let width, width > 0 {
            return "![|\(Int(width.rounded()))](\(relativePath))"
        }
        return "![](\(relativePath))"
    }

    /// Parses a display width out of an alt string like `|320` or `alt|320`.
    public static func width(fromAlt alt: String) -> CGFloat? {
        guard let bar = alt.lastIndex(of: "|") else { return nil }
        let value = alt[alt.index(after: bar)...].trimmingCharacters(in: .whitespaces)
        guard let number = Double(value), number > 0 else { return nil }
        return CGFloat(number)
    }

    /// True if `line` (already trimmed) consists solely of an image reference,
    /// so callers like title extraction can skip it.
    public static func isImageOnly(_ line: String) -> Bool {
        let refs = references(in: line)
        guard let only = refs.first, refs.count == 1 else { return false }
        return only.range.location == 0 && only.range.length == (line as NSString).length
    }

    /// Replaces image references with `replacement` (default empty) — used to
    /// keep sidebar previews readable instead of showing raw Markdown.
    public static func strippingImageRefs(from content: String, replacement: String = "") -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }
        let ns = content as NSString
        return regex.stringByReplacingMatches(
            in: content,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: replacement
        )
    }
}
