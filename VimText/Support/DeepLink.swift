import AppKit
import Foundation

/// `vimtext://` URLs — the way something outside the app points at something
/// inside it: an agent's MCP tool result, a Spotlight hit, a link pasted into
/// another note or a calendar event.
///
/// Notes are addressed by id rather than by file path, so a link survives a
/// rename and a move between folders — which is the whole reason this exists
/// instead of `file://` URLs into the notes directory.
///
/// ```
/// vimtext://note/<uuid>              open the note
/// vimtext://note/<uuid>?line=42      …with the caret on line 42
/// vimtext://note/<uuid>?heading=Design
/// vimtext://search?q=<query>         open with the sidebar search filled in
/// vimtext://capture?text=<text>      prefill the Quick Capture panel
/// ```
///
/// Deliberately navigation-only. A registered URL scheme accepts input from
/// anywhere — any web page can hand macOS a `vimtext://` URL, with no prompt
/// and no way to tell where it came from — so there is no case here that
/// deletes, overwrites, moves or unlocks anything. `capture` comes closest to a
/// write and only *fills* the panel: saving stays a keystroke the user makes,
/// looking at the text.
public enum DeepLink: Equatable {
    case note(id: UUID, target: Target?)
    case search(query: String)
    case capture(text: String?)

    /// Where to put the caret once the note is open.
    public enum Target: Equatable {
        /// 1-based, matching the gutter and `:N`.
        case line(Int)
        /// Matched against the note's Markdown heading text, not its `#`s.
        case heading(String)
    }

    public static let scheme = "vimtext"

    /// Cap on text accepted from a URL. Quick Capture is a scratch buffer, and
    /// a link that arrives from outside shouldn't be able to paste a novel into
    /// it; anything longer is a sign the link isn't a capture at all.
    public static let maxCaptureLength = 4_000

    // MARK: - Building

    /// The canonical link to a note. Handed out in MCP tool results so an
    /// agent's answer can end in something the user clicks.
    public static func url(forNoteId id: UUID) -> String {
        "\(scheme)://note/\(id.uuidString)"
    }

    // MARK: - Parsing

    /// Returns nil for anything unrecognised — a wrong scheme, an unknown host,
    /// a malformed id. Callers do nothing in that case rather than guessing.
    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func query(_ name: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?
                .value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }

        switch url.host?.lowercased() {
        case "note":
            // Both `note/<uuid>` and `note?id=<uuid>`: the first is what we
            // hand out, the second is what people hand-write.
            let fromPath = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).nilIfEmpty
            guard let raw = fromPath ?? query("id"), let id = UUID(uuidString: raw) else { return nil }
            return .note(id: id, target: target(heading: query("heading"), line: query("line")))
        case "search":
            guard let q = query("q") ?? query("query") else { return nil }
            return .search(query: q)
        case "capture":
            return .capture(text: query("text").map { String($0.prefix(maxCaptureLength)) })
        default:
            return nil
        }
    }

    /// A heading wins over a line when a link carries both: it's the more
    /// specific of the two, and it stays right when the note is edited.
    private static func target(heading: String?, line: String?) -> Target? {
        if let heading { return .heading(heading) }
        guard let line, let number = Int(line), number >= 1 else { return nil }
        return .line(number)
    }

    // MARK: - Resolving

    /// The UTF-16 offset a target names, or nil when the note has no such line
    /// or heading — a link written against an older version of a note is a
    /// routine event, and doing nothing beats dropping the caret somewhere
    /// arbitrary and calling it a jump.
    public static func offset(of target: Target, in text: String) -> Int? {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)

        switch target {
        case .line(let requested):
            guard requested >= 1 else { return nil }
            guard requested > 1 else { return 0 }
            var line = 1
            var found: Int?
            ns.enumerateSubstrings(in: whole, options: [.byLines, .substringNotRequired]) { _, _, enclosing, stop in
                line += 1
                guard line == requested else { return }
                // `enclosing` covers the line separator, so its end is the next
                // line's start — unless it's also the end of the note, which
                // means the requested line doesn't exist.
                let start = NSMaxRange(enclosing)
                if start < ns.length { found = start }
                stop.pointee = true
            }
            return found

        case .heading(let wanted):
            let key = headingKey(wanted)
            guard !key.isEmpty else { return nil }
            var found: Int?
            ns.enumerateSubstrings(in: whole, options: [.byLines, .substringNotRequired]) { _, range, _, stop in
                guard let text = headingText(in: ns, lineRange: range), headingKey(text) == key else { return }
                found = range.location
                stop.pointee = true
            }
            return found
        }
    }

    /// The text of a Markdown heading line, minus its `#`s — or nil if the line
    /// isn't a heading. Levels come from `VimNSTextView.headingLevel` so a link
    /// and the editor's own rendering can't disagree about what a heading is.
    private static func headingText(in ns: NSString, lineRange: NSRange) -> String? {
        guard let level = VimNSTextView.headingLevel(in: ns, lineRange: lineRange) else { return nil }
        let after = NSRange(location: lineRange.location + level, length: lineRange.length - level)
        return ns.substring(with: after).trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    /// Compares headings the way a person writing a URL by hand would expect:
    /// case-insensitively, with hyphens and underscores reading as spaces, so
    /// `?heading=design-notes` finds `## Design Notes`.
    private static func headingKey(_ text: String) -> String {
        let spaced = text.map { character -> Character in
            (character == "-" || character == "_") ? " " : character
        }
        return String(spaced)
            .lowercased()
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
