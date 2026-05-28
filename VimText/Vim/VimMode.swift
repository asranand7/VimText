import Foundation

enum VimMode: String {
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

enum VimAction {
    case moveCursor(Motion)
    case insertMode(InsertEntry)
    case normalMode
    case visualMode
    case visualLineMode
    case commandMode
    case replaceChar

    case deleteMotion(Motion, Int)
    case deleteLine
    case deleteToEnd
    case deleteChar
    case deleteCharBefore

    case changeMotion(Motion, Int)
    case changeLine
    case changeToEnd

    case yankMotion(Motion, Int)
    case yankLine

    case pasteAfter
    case pasteBefore

    case joinLines

    case undo
    case redo

    case indent
    case outdent

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

enum CenteringAlignment {
    case top
    case center
    case bottom
}

enum TextObject {
    case inner(TextObjectType)
    case around(TextObjectType)
}

enum TextObjectType {
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

enum Motion {
    case left
    case down
    case up
    case right

    case wordForward
    case wordBackward
    case wordEnd

    case lineStart
    case lineEnd
    case firstNonBlank

    case documentStart
    case documentEnd

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
        case .documentStart, .documentEnd, .paragraphForward, .paragraphBackward, .up, .down:
            return true
        default:
            return false
        }
    }
}

enum InsertEntry {
    case beforeCursor
    case afterCursor
    case lineStart
    case lineEnd
    case newLineBelow
    case newLineAbove
}
