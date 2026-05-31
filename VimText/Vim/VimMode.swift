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
