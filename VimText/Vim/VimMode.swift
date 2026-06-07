import Foundation

public enum VimMode: String, Equatable {
    case normal = "NORMAL"
    case insert = "INSERT"
    case visual = "VISUAL"
    case visualLine = "V-LINE"
    case visualBlock = "V-BLOCK"
    case command = "COMMAND"
    case replace = "REPLACE"

    var displayName: String { rawValue }

    var isEditing: Bool {
        self == .insert || self == .replace
    }

    var isVisual: Bool {
        self == .visual || self == .visualLine || self == .visualBlock
    }
}

public enum VimAction: Equatable {
    case moveCursor(Motion)
    case insertMode(InsertEntry)
    case normalMode
    case visualMode
    case visualLineMode
    case commandMode
    case replaceChar

    case deleteMotion(Motion, Int)
    case deleteLine
    case deleteLines(Int)
    case deleteToEnd
    case deleteChar
    case deleteCharBefore

    case changeMotion(Motion, Int)
    case changeLine
    case changeLines(Int)
    case changeToEnd

    case yankMotion(Motion, Int)
    case yankLine
    case yankLines(Int)

    case pasteAfter
    case pasteBefore

    case joinLines

    case undo
    case redo

    case indent
    case outdent
    case indentLines(Int)
    case outdentLines(Int)

    case searchForward
    case searchBackward
    case searchExecute(String, Bool)
    case nextMatch
    case previousMatch
    /// `*` / `#` — search for the word under the cursor (forward / backward).
    case searchWordUnderCursor(forward: Bool)

    case goToLine(Int)
    case save
    case quit

    case visualDelete
    case visualYank
    case visualChange
    case visualIndent
    case visualOutdent
    case visualBlockMode
    case visualBlockInsert
    case visualBlockAppend

    case deleteTextObject(TextObject)
    case changeTextObject(TextObject)
    case yankTextObject(TextObject)
    case visualSelectTextObject(TextObject)
    case visualSwapAnchor

    case toggleCase
    case repeatLastChange
    case none
    
    case substitute(pattern: String, replacement: String, isEntireDocument: Bool, isGlobalReplace: Bool, isCaseInsensitive: Bool)
    case centerCursor(CenteringAlignment)
}

public enum CenteringAlignment: Equatable {
    case top
    case center
    case bottom
}

public enum TextObject: Equatable {
    case inner(TextObjectType)
    case around(TextObjectType)
}

public enum TextObjectType: Equatable {
    case doubleQuote
    case singleQuote
    case backtick
    case paren
    case bracket
    case brace
    case angleBracket
    case word
    case bigWord
    case paragraph
    case tag
}

public enum Motion: Equatable {
    case left
    case down
    case up
    case right

    case wordForward
    case wordBackward
    case wordEnd
    case bigWordForward
    case bigWordBackward
    case bigWordEnd
    case wordEndBackward
    case bigWordEndBackward

    case lineStart
    case lineEnd
    case firstNonBlank

    case documentStart
    case documentEnd

    // Screen-relative jumps: H / M / L (top / middle / bottom of the
    // currently visible area), landing on the line's first non-blank char.
    case screenTop
    case screenMiddle
    case screenBottom

    case paragraphForward
    case paragraphBackward

    case findChar(Character, Bool)
    case tillChar(Character, Bool)

    case matchingBracket

    var isInclusive: Bool {
        switch self {
        case .findChar, .tillChar, .wordEnd, .matchingBracket:
            return true
        default:
            return false
        }
    }

    var isLinewise: Bool {
        switch self {
        case .documentStart, .documentEnd, .paragraphForward, .paragraphBackward, .up, .down,
             .screenTop, .screenMiddle, .screenBottom:
            return true
        default:
            return false
        }
    }
}

public enum InsertEntry: Equatable {
    case beforeCursor
    case afterCursor
    case lineStart
    case lineEnd
    case newLineBelow
    case newLineAbove
}

/// Pure word-under-cursor extraction for `*` / `#`. Kept free of AppKit so it
/// can be unit-tested independently of the text view.
public enum VimWordUnderCursor {
    private static func isWordChar(_ u: unichar) -> Bool {
        if u == 0x5F { return true } // underscore
        guard let scalar = Unicode.Scalar(u) else { return false }
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// The keyword (letters/digits/underscore) covering `location`. If
    /// `location` isn't on a keyword char, scans forward on the current line to
    /// the next one (matching Vim). Returns nil if no word exists before the
    /// end of the line.
    public static func word(in string: NSString, at location: Int) -> String? {
        let length = string.length
        guard length > 0 else { return nil }

        var pos = min(max(location, 0), length - 1)

        if !isWordChar(string.character(at: pos)) {
            var scan = pos
            while scan < length {
                let c = string.character(at: scan)
                if c == 0x0A { return nil } // stop at end of current line
                if isWordChar(c) { break }
                scan += 1
            }
            guard scan < length, isWordChar(string.character(at: scan)) else { return nil }
            pos = scan
        }

        var start = pos
        while start > 0 && isWordChar(string.character(at: start - 1)) { start -= 1 }
        var end = pos
        while end < length && isWordChar(string.character(at: end)) { end += 1 }
        return string.substring(with: NSRange(location: start, length: end - start))
    }
}
