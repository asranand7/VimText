import Foundation
import AppKit

public final class VimEngine: ObservableObject {
    @Published public var mode: VimMode = .normal
    @Published var commandBuffer: String = ""
    @Published var statusMessage: String = ""
    @Published var showCommandLine: Bool = false
    @Published var commandLineText: String = ""
    @Published var cursorLine: Int = 1
    @Published var cursorCol: Int = 1

    var keyBuffer: String = ""
    var countBuffer: String = ""
    var lastFindChar: (Character, Bool, Bool)? = nil
    var register: String = "" {
        didSet {
            if !register.isEmpty {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(register, forType: .string)
            }
        }
    }
    var lastAction: (() -> Void)?

    var searchTerm: String = ""
    var searchForwardDirection: Bool = true
    var isSearchMode: Bool = false
    @Published var commandLinePrefix: String = ":"

    var lastChangeActions: [VimAction] = []
    var lastInsertedText: String = ""
    var isRecordingChange: Bool = false
    private var pendingChangeActions: [VimAction] = []
    var lastReplaceChar: String = ""

    var pendingCount: Int {
        Int(countBuffer) ?? 1
    }

    func resetBuffers() {
        keyBuffer = ""
        countBuffer = ""
    }

    func startRecordingChange(actions: [VimAction]) {
        isRecordingChange = true
        pendingChangeActions = actions
    }

    func finalizeChange(insertedText: String? = nil) {
        if isRecordingChange {
            lastChangeActions = pendingChangeActions
            lastInsertedText = insertedText ?? ""
            isRecordingChange = false
            pendingChangeActions = []
        }
    }

    func recordNonInsertChange(actions: [VimAction]) {
        lastChangeActions = actions
        lastInsertedText = ""
        isRecordingChange = false
        pendingChangeActions = []
    }

    public init() {}

    public func processKey(_ key: String, modifiers: KeyModifiers = []) -> [VimAction] {
        switch mode {
        case .normal:
            return processNormalMode(key, modifiers: modifiers)
        case .visual, .visualLine, .visualBlock:
            return processVisualMode(key, modifiers: modifiers)
        case .command:
            return processCommandMode(key, modifiers: modifiers)
        case .insert:
            return processInsertMode(key, modifiers: modifiers)
        case .replace:
            return processReplaceMode(key, modifiers: modifiers)
        }
    }

    private func processInsertMode(_ key: String, modifiers: KeyModifiers) -> [VimAction] {
        if key == "escape" || (key == "[" && modifiers.contains(.control)) {
            mode = .normal
            statusMessage = ""
            return [.normalMode]
        }
        return [.none]
    }

    private func processReplaceMode(_ key: String, modifiers: KeyModifiers) -> [VimAction] {
        if key == "escape" {
            mode = .normal
            return [.normalMode]
        }
        return [.replaceChar]
    }

    private func processNormalMode(_ key: String, modifiers: KeyModifiers) -> [VimAction] {
        if key == "escape" {
            resetBuffers()
            statusMessage = ""
            return [.none]
        }

        if modifiers.contains(.control) {
            return processControlKey(key)
        }

        if key.count == 1, let ch = key.first, ch.isNumber && !(countBuffer.isEmpty && ch == "0") {
            countBuffer.append(ch)
            return [.none]
        }

        let count = pendingCount
        let operator_ = keyBuffer

        if !operator_.isEmpty {
            return processOperatorPending(operator_: operator_, key: key, count: count)
        }

        var actions: [VimAction] = []

        switch key {
        case "h":
            actions = Array(repeating: .moveCursor(.left), count: count)
        case "j":
            actions = Array(repeating: .moveCursor(.down), count: count)
        case "k":
            actions = Array(repeating: .moveCursor(.up), count: count)
        case "l":
            actions = Array(repeating: .moveCursor(.right), count: count)
        case "w":
            actions = Array(repeating: .moveCursor(.wordForward), count: count)
        case "b":
            actions = Array(repeating: .moveCursor(.wordBackward), count: count)
        case "e":
            actions = Array(repeating: .moveCursor(.wordEnd), count: count)
        case "W":
            actions = Array(repeating: .moveCursor(.bigWordForward), count: count)
        case "B":
            actions = Array(repeating: .moveCursor(.bigWordBackward), count: count)
        case "E":
            actions = Array(repeating: .moveCursor(.bigWordEnd), count: count)
        case "0":
            actions = [.moveCursor(.lineStart)]
        case "$":
            actions = [.moveCursor(.lineEnd)]
        case "^":
            actions = [.moveCursor(.firstNonBlank)]
        case "{":
            actions = Array(repeating: .moveCursor(.paragraphBackward), count: count)
        case "}":
            actions = Array(repeating: .moveCursor(.paragraphForward), count: count)
        case "%":
            actions = [.moveCursor(.matchingBracket)]
        case "H":
            actions = [.moveCursor(.screenTop)]
        case "M":
            actions = [.moveCursor(.screenMiddle)]
        case "L":
            actions = [.moveCursor(.screenBottom)]
        case "G":
            if !countBuffer.isEmpty {
                actions = [.goToLine(count)]
            } else {
                actions = [.moveCursor(.documentEnd)]
            }
        case "g":
            keyBuffer = "g"
            return [.none]
        case "z":
            keyBuffer = "z"
            return [.none]
        case "i":
            mode = .insert
            resetBuffers()
            return [.insertMode(.beforeCursor)]
        case "a":
            mode = .insert
            resetBuffers()
            return [.insertMode(.afterCursor)]
        case "I":
            mode = .insert
            resetBuffers()
            return [.insertMode(.lineStart)]
        case "A":
            mode = .insert
            resetBuffers()
            return [.insertMode(.lineEnd)]
        case "o":
            mode = .insert
            resetBuffers()
            return [.insertMode(.newLineBelow)]
        case "O":
            mode = .insert
            resetBuffers()
            return [.insertMode(.newLineAbove)]
        case "d":
            keyBuffer = "d"
            return [.none]
        case "D":
            resetBuffers()
            return [.deleteToEnd]
        case "c":
            keyBuffer = "c"
            return [.none]
        case "C":
            mode = .insert
            resetBuffers()
            return [.changeToEnd]
        case "y":
            keyBuffer = "y"
            return [.none]
        case "Y":
            resetBuffers()
            return [.yankLines(count)]
        case "x":
            resetBuffers()
            return Array(repeating: .deleteChar, count: count)
        case "X":
            resetBuffers()
            return Array(repeating: .deleteCharBefore, count: count)
        case "s":
            mode = .insert
            resetBuffers()
            return [.deleteChar, .insertMode(.beforeCursor)]
        case "S":
            mode = .insert
            resetBuffers()
            return [.changeLine]
        case "~":
            resetBuffers()
            return Array(repeating: .toggleCase, count: count)
        case "p":
            resetBuffers()
            return Array(repeating: .pasteAfter, count: count)
        case "P":
            resetBuffers()
            return Array(repeating: .pasteBefore, count: count)
        case "r":
            keyBuffer = "r"
            return [.none]
        case "m":
            keyBuffer = "m"
            return [.none]
        case "`":
            keyBuffer = "`"
            return [.none]
        case "'":
            keyBuffer = "'"
            return [.none]
        case "R":
            mode = .replace
            resetBuffers()
            return [.none]
        case "J":
            resetBuffers()
            return [.joinLines]
        case "u":
            resetBuffers()
            return [.undo]
        case "v":
            mode = .visual
            resetBuffers()
            return [.visualMode]
        case "V":
            mode = .visualLine
            resetBuffers()
            return [.visualLineMode]
        case ":":
            mode = .command
            showCommandLine = true
            commandLineText = ""
            commandLinePrefix = ":"
            isSearchMode = false
            resetBuffers()
            return [.commandMode]
        case "/":
            mode = .command
            showCommandLine = true
            commandLineText = ""
            commandLinePrefix = "/"
            isSearchMode = true
            searchForwardDirection = true
            resetBuffers()
            return [.searchForward]
        case "?":
            mode = .command
            showCommandLine = true
            commandLineText = ""
            commandLinePrefix = "?"
            isSearchMode = true
            searchForwardDirection = false
            resetBuffers()
            return [.searchBackward]
        case "n":
            resetBuffers()
            return [.nextMatch]
        case "N":
            resetBuffers()
            return [.previousMatch]
        case "*":
            resetBuffers()
            return [.searchWordUnderCursor(forward: true)]
        case "#":
            resetBuffers()
            return [.searchWordUnderCursor(forward: false)]
        case ">":
            keyBuffer = ">"
            return [.none]
        case "<":
            keyBuffer = "<"
            return [.none]
        case "f":
            keyBuffer = "f"
            return [.none]
        case "F":
            keyBuffer = "F"
            return [.none]
        case "t":
            keyBuffer = "t"
            return [.none]
        case "T":
            keyBuffer = "T"
            return [.none]
        case ";":
            if let (ch, forward, isFind) = lastFindChar {
                resetBuffers()
                if isFind {
                    return Array(repeating: .moveCursor(.findChar(ch, forward)), count: count)
                } else {
                    return Array(repeating: .moveCursor(.tillChar(ch, forward)), count: count)
                }
            }
            resetBuffers()
            return [.none]
        case ",":
            if let (ch, forward, isFind) = lastFindChar {
                resetBuffers()
                if isFind {
                    return Array(repeating: .moveCursor(.findChar(ch, !forward)), count: count)
                } else {
                    return Array(repeating: .moveCursor(.tillChar(ch, !forward)), count: count)
                }
            }
            resetBuffers()
            return [.none]
        case ".":
            resetBuffers()
            return [.repeatLastChange]
        default:
            resetBuffers()
            return [.none]
        }

        resetBuffers()
        return actions
    }

    private func textObjectType(for key: String) -> TextObjectType? {
        switch key {
        case "\"": return .doubleQuote
        case "'":  return .singleQuote
        case "`":  return .backtick
        case "(", ")", "b": return .paren
        case "[", "]": return .bracket
        case "{", "}", "B": return .brace
        case "<", ">": return .angleBracket
        case "w": return .word
        case "W": return .bigWord
        case "p": return .paragraph
        case "t": return .tag
        default: return nil
        }
    }

    private func motionForKey(_ key: String) -> Motion? {
        switch key {
        case "h": return .left
        case "j": return .down
        case "k": return .up
        case "l": return .right
        case "w": return .wordForward
        case "b": return .wordBackward
        case "e": return .wordEnd
        case "W": return .bigWordForward
        case "B": return .bigWordBackward
        case "E": return .bigWordEnd
        case "0": return .lineStart
        case "$": return .lineEnd
        case "^": return .firstNonBlank
        case "{": return .paragraphBackward
        case "}": return .paragraphForward
        case "G": return .documentEnd
        case "%": return .matchingBracket
        case "H": return .screenTop
        case "M": return .screenMiddle
        case "L": return .screenBottom
        default: return nil
        }
    }

    private func processOperatorPending(operator_: String, key: String, count: Int) -> [VimAction] {
        switch operator_ {
        case "z":
            resetBuffers()
            switch key {
            case "z":
                return [.centerCursor(.center)]
            case "t":
                return [.centerCursor(.top)]
            case "b":
                return [.centerCursor(.bottom)]
            default:
                return [.none]
            }

        case "g":
            // gu / gU stay pending for their motion (keep the count buffer).
            if key == "u" {
                keyBuffer = "gu"
                return [.none]
            }
            if key == "U" {
                keyBuffer = "gU"
                return [.none]
            }
            resetBuffers()
            if key == "g" {
                if count != 1 {
                    return [.goToLine(count)]
                }
                return [.moveCursor(.documentStart)]
            } else if key == "e" {
                return Array(repeating: .moveCursor(.wordEndBackward), count: count)
            } else if key == "E" {
                return Array(repeating: .moveCursor(.bigWordEndBackward), count: count)
            } else if key == "d" {
                // `gd` opens the link under the cursor (this app's take on
                // Vim's `gx`; there are no definitions to go to in notes).
                return [.openLinkUnderCursor]
            }
            return [.none]

        case "gu", "gU":
            let upper = (operator_ == "gU")
            resetBuffers()
            // guu / gUU (and gugu-style doubled operators) act on lines.
            if (key == "u" && !upper) || (key == "U" && upper) || key == "g" {
                return [.changeCaseLines(count, upper: upper)]
            }
            if let motion = motionForKey(key) {
                return [.changeCaseMotion(motion, count, upper: upper)]
            }
            return [.none]

        case "m":
            resetBuffers()
            if let ch = key.first, ch.isLetter, key.count == 1 {
                return [.setMark(ch)]
            }
            return [.none]

        case "`", "'":
            resetBuffers()
            if let ch = key.first, ch.isLetter, key.count == 1 {
                return [.jumpToMark(ch, exact: operator_ == "`")]
            }
            return [.none]

        case "d":
            switch key {
            case "d":
                resetBuffers()
                return [.deleteLines(count)]
            case "g":
                keyBuffer = "dg"
                return [.none]
            case "i":
                keyBuffer = "di"
                return [.none]
            case "a":
                keyBuffer = "da"
                return [.none]
            case "f":
                keyBuffer = "df"
                return [.none]
            case "F":
                keyBuffer = "dF"
                return [.none]
            case "t":
                keyBuffer = "dt"
                return [.none]
            case "T":
                keyBuffer = "dT"
                return [.none]
            default:
                if let motion = motionForKey(key) {
                    resetBuffers()
                    if key == "$" { return [.deleteToEnd] }
                    return [.deleteMotion(motion, count)]
                }
                resetBuffers()
                return [.none]
            }

        case "di":
            resetBuffers()
            if let objType = textObjectType(for: key) {
                return [.deleteTextObject(.inner(objType))]
            }
            return [.none]

        case "da":
            resetBuffers()
            if let objType = textObjectType(for: key) {
                return [.deleteTextObject(.around(objType))]
            }
            return [.none]

        case "dg":
            resetBuffers()
            if key == "g" {
                return [.deleteMotion(.documentStart, 1)]
            }
            return [.none]

        case "df":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, true, true)
                return [.deleteMotion(.findChar(ch, true), 1)]
            }
            return [.none]

        case "dF":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, false, true)
                return [.deleteMotion(.findChar(ch, false), 1)]
            }
            return [.none]

        case "dt":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, true, false)
                return [.deleteMotion(.tillChar(ch, true), 1)]
            }
            return [.none]

        case "dT":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, false, false)
                return [.deleteMotion(.tillChar(ch, false), 1)]
            }
            return [.none]

        case "c":
            switch key {
            case "c":
                resetBuffers()
                mode = .insert
                return [.changeLines(count)]
            case "g":
                keyBuffer = "cg"
                return [.none]
            case "i":
                keyBuffer = "ci"
                return [.none]
            case "a":
                keyBuffer = "ca"
                return [.none]
            case "f":
                keyBuffer = "cf"
                return [.none]
            case "F":
                keyBuffer = "cF"
                return [.none]
            case "t":
                keyBuffer = "ct"
                return [.none]
            case "T":
                keyBuffer = "cT"
                return [.none]
            default:
                if let motion = motionForKey(key) {
                    resetBuffers()
                    mode = .insert
                    if key == "$" { return [.changeToEnd] }
                    return [.changeMotion(motion, count)]
                }
                resetBuffers()
                return [.none]
            }

        case "ci":
            resetBuffers()
            if let objType = textObjectType(for: key) {
                mode = .insert
                return [.changeTextObject(.inner(objType))]
            }
            return [.none]

        case "ca":
            resetBuffers()
            if let objType = textObjectType(for: key) {
                mode = .insert
                return [.changeTextObject(.around(objType))]
            }
            return [.none]

        case "cf":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, true, true)
                mode = .insert
                return [.changeMotion(.findChar(ch, true), 1)]
            }
            return [.none]

        case "cF":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, false, true)
                mode = .insert
                return [.changeMotion(.findChar(ch, false), 1)]
            }
            return [.none]

        case "ct":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, true, false)
                mode = .insert
                return [.changeMotion(.tillChar(ch, true), 1)]
            }
            return [.none]

        case "cT":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, false, false)
                mode = .insert
                return [.changeMotion(.tillChar(ch, false), 1)]
            }
            return [.none]

        case "cg":
            resetBuffers()
            if key == "g" {
                mode = .insert
                return [.changeMotion(.documentStart, 1)]
            }
            return [.none]

        case "y":
            switch key {
            case "y":
                resetBuffers()
                return [.yankLines(count)]
            case "g":
                keyBuffer = "yg"
                return [.none]
            case "i":
                keyBuffer = "yi"
                return [.none]
            case "a":
                keyBuffer = "ya"
                return [.none]
            case "f":
                keyBuffer = "yf"
                return [.none]
            case "F":
                keyBuffer = "yF"
                return [.none]
            case "t":
                keyBuffer = "yt"
                return [.none]
            case "T":
                keyBuffer = "yT"
                return [.none]
            default:
                if let motion = motionForKey(key) {
                    resetBuffers()
                    return [.yankMotion(motion, count)]
                }
                resetBuffers()
                return [.none]
            }

        case "yi":
            resetBuffers()
            if let objType = textObjectType(for: key) {
                return [.yankTextObject(.inner(objType))]
            }
            return [.none]

        case "ya":
            resetBuffers()
            if let objType = textObjectType(for: key) {
                return [.yankTextObject(.around(objType))]
            }
            return [.none]

        case "yf":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, true, true)
                return [.yankMotion(.findChar(ch, true), 1)]
            }
            return [.none]

        case "yF":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, false, true)
                return [.yankMotion(.findChar(ch, false), 1)]
            }
            return [.none]

        case "yt":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, true, false)
                return [.yankMotion(.tillChar(ch, true), 1)]
            }
            return [.none]

        case "yT":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, false, false)
                return [.yankMotion(.tillChar(ch, false), 1)]
            }
            return [.none]

        case "yg":
            resetBuffers()
            if key == "g" {
                return [.yankMotion(.documentStart, 1)]
            }
            return [.none]

        case "r":
            resetBuffers()
            return [.replaceChar]

        case ">":
            resetBuffers()
            if key == ">" {
                return [.indentLines(count)]
            }
            return [.none]

        case "<":
            resetBuffers()
            if key == "<" {
                return [.outdentLines(count)]
            }
            return [.none]

        case "f":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, true, true)
                return [.moveCursor(.findChar(ch, true))]
            }
            return [.none]

        case "F":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, false, true)
                return [.moveCursor(.findChar(ch, false))]
            }
            return [.none]

        case "t":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, true, false)
                return [.moveCursor(.tillChar(ch, true))]
            }
            return [.none]

        case "T":
            resetBuffers()
            if let ch = key.first {
                lastFindChar = (ch, false, false)
                return [.moveCursor(.tillChar(ch, false))]
            }
            return [.none]

        default:
            resetBuffers()
            return [.none]
        }
    }

    private func processVisualMode(_ key: String, modifiers: KeyModifiers) -> [VimAction] {
        if modifiers.contains(.control) && key == "v" {
            if mode == .visualBlock {
                mode = .normal
                resetBuffers()
                return [.normalMode]
            }
            mode = .visualBlock
            resetBuffers()
            return [.visualBlockMode]
        }

        if keyBuffer == "vi" {
            keyBuffer = ""
            if let objType = textObjectType(for: key) {
                return [.visualSelectTextObject(.inner(objType))]
            }
            return [.none]
        }
        if keyBuffer == "va" {
            keyBuffer = ""
            if let objType = textObjectType(for: key) {
                return [.visualSelectTextObject(.around(objType))]
            }
            return [.none]
        }
        if keyBuffer == "vf" || keyBuffer == "vF" || keyBuffer == "vt" || keyBuffer == "vT" {
            let buf = keyBuffer
            let direction = (buf == "vf" || buf == "vt")
            let isFind = (buf == "vf" || buf == "vF")
            keyBuffer = ""
            if let ch = key.first {
                lastFindChar = (ch, direction, isFind)
                if isFind {
                    return [.moveCursor(.findChar(ch, direction))]
                } else {
                    return [.moveCursor(.tillChar(ch, direction))]
                }
            }
            return [.none]
        }

        if keyBuffer == "g" {
            keyBuffer = ""
            let gCount = pendingCount
            let hadCount = !countBuffer.isEmpty
            countBuffer = ""
            switch key {
            case "g":
                if hadCount {
                    return [.goToLine(gCount)]
                }
                return [.moveCursor(.documentStart)]
            case "e":
                return Array(repeating: .moveCursor(.wordEndBackward), count: gCount)
            case "E":
                return Array(repeating: .moveCursor(.bigWordEndBackward), count: gCount)
            default:
                return [.none]
            }
        }

        // Counts: digits accumulate exactly like normal mode. Checked after
        // the pending-key blocks above so `f3` still finds a literal "3".
        if key.count == 1, let ch = key.first, ch.isNumber && !(countBuffer.isEmpty && ch == "0") {
            countBuffer.append(ch)
            return [.none]
        }
        let count = pendingCount

        // Returns `motion` repeated `count` times, consuming the count buffer.
        func counted(_ motion: Motion) -> [VimAction] {
            countBuffer = ""
            return Array(repeating: .moveCursor(motion), count: count)
        }

        switch key {
        case "escape":
            mode = .normal
            resetBuffers()
            return [.normalMode]
        case "h":
            return counted(.left)
        case "j":
            return counted(.down)
        case "k":
            return counted(.up)
        case "l":
            return counted(.right)
        case "w":
            return counted(.wordForward)
        case "b":
            return counted(.wordBackward)
        case "e":
            return counted(.wordEnd)
        case "W":
            return counted(.bigWordForward)
        case "B":
            return counted(.bigWordBackward)
        case "E":
            return counted(.bigWordEnd)
        case "0":
            return counted(.lineStart)
        case "$":
            return counted(.lineEnd)
        case "^":
            return counted(.firstNonBlank)
        case "{":
            return counted(.paragraphBackward)
        case "}":
            return counted(.paragraphForward)
        case "H":
            return counted(.screenTop)
        case "M":
            return counted(.screenMiddle)
        case "L":
            return counted(.screenBottom)
        case "G":
            if !countBuffer.isEmpty {
                countBuffer = ""
                return [.goToLine(count)]
            }
            return [.moveCursor(.documentEnd)]
        case "g":
            keyBuffer = "g"
            return [.none]
        case "i":
            keyBuffer = "vi"
            return [.none]
        case "a":
            keyBuffer = "va"
            return [.none]
        case "o":
            return [.visualSwapAnchor]
        case "d", "x":
            mode = .normal
            resetBuffers()
            return [.visualDelete]
        case "y":
            mode = .normal
            resetBuffers()
            return [.visualYank]
        case "c", "s":
            mode = .insert
            resetBuffers()
            return [.visualChange]
        case "p", "P":
            let linewise = (mode == .visualLine)
            mode = .normal
            resetBuffers()
            return [.visualPaste(linewise: linewise)]
        case "u":
            mode = .normal
            resetBuffers()
            return [.visualChangeCase(upper: false)]
        case "U":
            mode = .normal
            resetBuffers()
            return [.visualChangeCase(upper: true)]
        case "I":
            if mode == .visualBlock {
                mode = .insert
                resetBuffers()
                return [.visualBlockInsert]
            }
            return [.none]
        case "A":
            if mode == .visualBlock {
                mode = .insert
                resetBuffers()
                return [.visualBlockAppend]
            }
            return [.none]
        case "v":
            if mode == .visual {
                mode = .normal
                return [.normalMode]
            }
            mode = .visual
            return [.visualMode]
        case "V":
            if mode == .visualLine {
                mode = .normal
                return [.normalMode]
            }
            mode = .visualLine
            return [.visualLineMode]
        case ">":
            mode = .normal
            resetBuffers()
            return [.visualIndent]
        case "<":
            mode = .normal
            resetBuffers()
            return [.visualOutdent]
        case "f":
            keyBuffer = "vf"
            return [.none]
        case "F":
            keyBuffer = "vF"
            return [.none]
        case "t":
            keyBuffer = "vt"
            return [.none]
        case "T":
            keyBuffer = "vT"
            return [.none]
        case ";":
            if let (ch, forward, isFind) = lastFindChar {
                return counted(isFind ? .findChar(ch, forward) : .tillChar(ch, forward))
            }
            return [.none]
        case ",":
            if let (ch, forward, isFind) = lastFindChar {
                return counted(isFind ? .findChar(ch, !forward) : .tillChar(ch, !forward))
            }
            return [.none]
        default:
            resetBuffers()
            return [.none]
        }
    }

    private func processCommandMode(_ key: String, modifiers: KeyModifiers) -> [VimAction] {
        if key == "escape" {
            mode = .normal
            showCommandLine = false
            commandLineText = ""
            isSearchMode = false
            resetBuffers()
            return [.normalMode]
        }
        return [.none]
    }

    public func executeCommand(_ command: String) -> [VimAction] {
        mode = .normal
        showCommandLine = false

        let trimmed = command.trimmingCharacters(in: .whitespaces)

        if let lineNum = Int(trimmed) {
            return [.goToLine(lineNum)]
        }

        switch trimmed {
        case "w":
            statusMessage = "Saved"
            return [.save]
        case "q":
            return [.quit]
        case "wq", "x":
            statusMessage = "Saved"
            return [.save, .quit]
        case "q!":
            return [.quit]
        case "noh", "nohl", "nohlsearch":
            return [.clearSearchHighlight]
        default:
            if trimmed.hasPrefix("s/") || trimmed.hasPrefix("%s/") {
                let isEntireDocument = trimmed.hasPrefix("%")
                let commandBody = isEntireDocument ? String(trimmed.dropFirst()) : trimmed
                let parts = splitCommand(commandBody)
                if parts.count >= 3 {
                    let pattern = parts[1]
                    let replacement = parts[2].replacingOccurrences(of: "\\/", with: "/")
                    let flags = parts.count > 3 ? parts[3] : ""
                    let isGlobal = flags.contains("g")
                    let isCaseInsensitive = flags.contains("i")
                    return [.substitute(pattern: pattern, replacement: replacement, isEntireDocument: isEntireDocument, isGlobalReplace: isGlobal, isCaseInsensitive: isCaseInsensitive)]
                } else {
                    statusMessage = "Invalid substitute syntax. Expected: :[range]s/pattern/replacement/[flags]"
                }
            } else {
                statusMessage = "Unknown command: \(trimmed)"
            }
            return [.none]
        }
    }

    private func splitCommand(_ s: String, delimiter: Character = "/") -> [String] {
        var parts: [String] = []
        var current = ""
        var escaped = false
        for ch in s {
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
                current.append(ch)
            } else if ch == delimiter {
                parts.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        parts.append(current)
        return parts
    }

    private func processControlKey(_ key: String) -> [VimAction] {
        switch key {
        case "r":
            return [.redo]
        case "d":
            return Array(repeating: .moveCursor(.down), count: 15)
        case "u":
            return Array(repeating: .moveCursor(.up), count: 15)
        case "v":
            mode = .visualBlock
            resetBuffers()
            return [.visualBlockMode]
        default:
            return [.none]
        }
    }
}

public struct KeyModifiers: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let shift   = KeyModifiers(rawValue: 1 << 0)
    public static let control = KeyModifiers(rawValue: 1 << 1)
    public static let option  = KeyModifiers(rawValue: 1 << 2)
    public static let command = KeyModifiers(rawValue: 1 << 3)
}
