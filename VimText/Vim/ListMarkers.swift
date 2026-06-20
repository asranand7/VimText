import Foundation

/// Detects line-leading list markers — `- `/`* `/`+ ` bullets and
/// `- [ ]`/`- [x]` checkboxes — so the editor can render them as a real bullet
/// dot or a clickable checkbox. Pure range math over the document string: the
/// literal characters stay in the text (the source of truth); only their
/// on-screen rendering changes, via `FoldingLayoutManager`.
enum ListMarkers {
    struct Marker: Equatable {
        enum Kind: Equatable {
            case bullet
            case checkbox(checked: Bool)
        }
        let kind: Kind
        /// The whole line (without its terminator) — used to keep the marker on
        /// the line the caret is editing shown as raw text.
        let lineRange: NSRange
        /// The `-`/`*`/`+` character, repurposed as a fixed-width control glyph
        /// that holds the drawn bullet/checkbox.
        let slotIndex: Int
        /// For checkboxes, the ` [ ]` characters after the marker, hidden so only
        /// the drawn box shows. nil for bullets.
        let hiddenRange: NSRange?
        /// For checkboxes, the index of the character between the brackets (a
        /// space or `x`) — flipped on click. nil for bullets.
        let toggleCharIndex: Int?
    }

    static let maxMarkers = 5000

    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09
    private static let dash: unichar = 0x2D
    private static let star: unichar = 0x2A
    private static let plus: unichar = 0x2B
    private static let openBracket: unichar = 0x5B
    private static let closeBracket: unichar = 0x5D
    private static let lowerX: unichar = 0x78
    private static let upperX: unichar = 0x58

    static func detect(in text: NSString) -> [Marker] {
        let length = text.length
        guard length > 0 else { return [] }
        var markers: [Marker] = []
        var lineStart = 0
        while lineStart < length {
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
            let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
            if let marker = marker(in: text, lineRange: lineRange) {
                markers.append(marker)
                if markers.count >= maxMarkers { break }
            }
            if lineEnd <= lineStart { break } // safety against non-advancing scan
            lineStart = lineEnd
        }
        return markers
    }

    private static func isSpace(_ c: unichar) -> Bool { c == space || c == tab }
    private static func isBulletChar(_ c: unichar) -> Bool { c == dash || c == star || c == plus }

    private static func marker(in text: NSString, lineRange: NSRange) -> Marker? {
        let end = lineRange.location + lineRange.length
        var i = lineRange.location
        while i < end, isSpace(text.character(at: i)) { i += 1 }
        guard i < end, isBulletChar(text.character(at: i)) else { return nil }
        // A bullet/checkbox marker requires a space right after the marker char.
        guard i + 1 < end, isSpace(text.character(at: i + 1)) else { return nil }

        // Checkbox: `- [ ]` / `- [x]`, optionally followed by a space or EOL.
        if i + 4 < end,
           text.character(at: i + 2) == openBracket,
           text.character(at: i + 4) == closeBracket {
            let inside = text.character(at: i + 3)
            let afterOK = (i + 5 >= end) || isSpace(text.character(at: i + 5))
            if (inside == space || inside == lowerX || inside == upperX), afterOK {
                let checked = (inside == lowerX || inside == upperX)
                return Marker(
                    kind: .checkbox(checked: checked),
                    lineRange: lineRange,
                    slotIndex: i,
                    hiddenRange: NSRange(location: i + 1, length: 4),
                    toggleCharIndex: i + 3
                )
            }
        }

        return Marker(kind: .bullet, lineRange: lineRange, slotIndex: i, hiddenRange: nil, toggleCharIndex: nil)
    }
}
