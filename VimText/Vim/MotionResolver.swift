import Foundation

/// Pure Vim motion resolution over an immutable text snapshot:
/// `(motion, position, text) → position`. No AppKit, no NSTextView, no
/// selection mutation — every buffer motion is a total function that can be
/// unit-tested headlessly (the same pattern as `VimWordUnderCursor`, scaled
/// to the whole motion set). The Coordinator delegates here and only keeps
/// the viewport-relative motions (H/M/L), which genuinely need layout.
///
/// Behavior contract, inherited from the previous view-coupled
/// implementation and relied on by operators (`d`/`c`/`y` + motion):
/// - An empty document always resolves to 0.
/// - Offsets are UTF-16 (NSString) offsets, clamped into the document.
/// - `h`/`l` stop at line boundaries; `j`/`k` preserve the column, clamped
///   to the target line's content (never landing on its newline).
public enum MotionResolver {

    /// Resolves `motion` from `position`, or nil when the motion depends on
    /// the viewport (`screenTop`/`screenMiddle`/`screenBottom`) — the caller
    /// resolves those against the live layout.
    public static func resolve(_ motion: Motion, from position: Int, in text: NSString) -> Int? {
        switch motion {
        case .screenTop, .screenMiddle, .screenBottom:
            return nil
        default:
            break
        }

        let nsString = text
        let length = nsString.length
        guard length > 0 else { return 0 }
        let string = nsString as String
        let cursorPos = position

        switch motion {
        case .left:
            let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
            return max(lineRange.location, cursorPos - 1)

        case .right:
            let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
            var lineEnd = lineRange.location + lineRange.length
            if lineEnd > 0 && lineEnd <= length && nsString.character(at: lineEnd - 1) == 0x0A {
                lineEnd -= 1
            }
            return min(max(lineEnd - 1, lineRange.location), cursorPos + 1)

        case .down:
            return moveVertically(from: cursorPos, direction: 1, in: nsString)

        case .up:
            return moveVertically(from: cursorPos, direction: -1, in: nsString)

        case .wordForward:
            return findWordForward(from: cursorPos, in: string, bigWord: false)

        case .wordBackward:
            return findWordBackward(from: cursorPos, in: string, bigWord: false)

        case .wordEnd:
            return findWordEnd(from: cursorPos, in: string, bigWord: false)

        case .bigWordForward:
            return findWordForward(from: cursorPos, in: string, bigWord: true)

        case .bigWordBackward:
            return findWordBackward(from: cursorPos, in: string, bigWord: true)

        case .bigWordEnd:
            return findWordEnd(from: cursorPos, in: string, bigWord: true)

        case .wordEndBackward:
            return findWordEndBackward(from: cursorPos, in: string, bigWord: false)

        case .bigWordEndBackward:
            return findWordEndBackward(from: cursorPos, in: string, bigWord: true)

        case .lineStart:
            let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
            return lineRange.location

        case .lineEnd:
            let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
            var end = lineRange.location + lineRange.length
            if end > 0 && end <= length && nsString.character(at: end - 1) == 0x0A {
                end -= 1
            }
            return max(end - 1, lineRange.location)

        case .firstNonBlank:
            let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
            let lineText = nsString.substring(with: lineRange)
            let indent = lineText.prefix(while: { $0 == " " || $0 == "\t" })
            return lineRange.location + indent.count

        case .documentStart:
            return firstNonBlankOffset(ofLineAt: 0, in: nsString)

        case .documentEnd:
            let lastLineRange = nsString.lineRange(for: NSRange(location: length - 1, length: 0))
            return firstNonBlankOffset(ofLineAt: lastLineRange.location, in: nsString)

        case .paragraphForward:
            var pos = cursorPos
            let currentLineRange = nsString.lineRange(for: NSRange(location: pos, length: 0))
            pos = currentLineRange.location + currentLineRange.length

            while pos < length {
                let lineRange = nsString.lineRange(for: NSRange(location: pos, length: 0))
                let lineText = nsString.substring(with: lineRange)
                if lineText == "\n" || lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return lineRange.location
                }
                pos = lineRange.location + lineRange.length
            }
            return length

        case .paragraphBackward:
            let currentLineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
            var pos = currentLineRange.location

            while pos > 0 {
                let prevPos = pos - 1
                let lineRange = nsString.lineRange(for: NSRange(location: prevPos, length: 0))
                let lineText = nsString.substring(with: lineRange)
                if (lineText == "\n" || lineText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && lineRange.location < currentLineRange.location {
                    return lineRange.location
                }
                pos = lineRange.location
            }
            return 0

        case .findChar(let ch, let forward):
            return findCharInLine(ch, forward: forward, till: false, from: cursorPos, in: nsString)

        case .tillChar(let ch, let forward):
            return findCharInLine(ch, forward: forward, till: true, from: cursorPos, in: nsString)

        case .tillCharRepeat(let ch, let forward):
            return findCharInLine(ch, forward: forward, till: true, from: cursorPos, in: nsString, skipAdjacent: true)

        case .matchingBracket:
            return findMatchingBracket(from: cursorPos, in: nsString)

        case .screenTop, .screenMiddle, .screenBottom:
            return nil
        }
    }

    /// Resolves `motion` applied `count` times, each step starting where the
    /// previous landed (the pure equivalent of pressing the motion N times).
    /// nil for viewport-dependent motions, like `resolve`.
    public static func resolve(_ motion: Motion, count: Int, from position: Int, in text: NSString) -> Int? {
        guard var pos = resolve(motion, from: position, in: text) else { return nil }
        if count > 1 {
            for _ in 1..<count {
                guard let next = resolve(motion, from: pos, in: text) else { return nil }
                pos = next
            }
        }
        return pos
    }

    /// UTF-16 offset of the first non-blank character on the line containing
    /// `loc`, clamped into the document — Vim's landing spot for `G`/`gg`/`:N`.
    public static func firstNonBlankOffset(ofLineAt loc: Int, in nsString: NSString) -> Int {
        let length = nsString.length
        guard length > 0 else { return 0 }
        let lineRange = nsString.lineRange(for: NSRange(location: min(max(loc, 0), length - 1), length: 0))
        let lineText = nsString.substring(with: lineRange)
        let indent = lineText.prefix(while: { $0 == " " || $0 == "\t" })
        return min(lineRange.location + indent.count, max(length - 1, 0))
    }

    // MARK: - Vertical movement

    private static func moveVertically(from pos: Int, direction: Int, in nsString: NSString) -> Int {
        let length = nsString.length
        guard length > 0 else { return 0 }

        let currentLineRange = nsString.lineRange(for: NSRange(location: pos, length: 0))
        let col = pos - currentLineRange.location

        var targetLineStart: Int
        if direction > 0 {
            let nextLineStart = currentLineRange.location + currentLineRange.length
            if nextLineStart >= length { return pos }
            targetLineStart = nextLineStart
        } else {
            if currentLineRange.location == 0 { return pos }
            let prevLineRange = nsString.lineRange(for: NSRange(location: currentLineRange.location - 1, length: 0))
            targetLineStart = prevLineRange.location
        }

        let targetLineRange = nsString.lineRange(for: NSRange(location: targetLineStart, length: 0))
        var targetLineLength = targetLineRange.length
        if targetLineLength > 0 && (targetLineRange.location + targetLineLength) <= length {
            if nsString.character(at: targetLineRange.location + targetLineLength - 1) == 0x0A {
                targetLineLength -= 1
            }
        }

        let targetCol = min(col, max(targetLineLength - 1, 0))
        return targetLineRange.location + targetCol
    }

    // MARK: - Word motions

    private static func findWordForward(from pos: Int, in string: String, bigWord: Bool) -> Int {
        guard pos < string.utf16.count else { return pos }
        let startIndex = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
        var i = startIndex
        let startType = charType(string[i], bigWord: bigWord)

        while i < string.endIndex && charType(string[i], bigWord: bigWord) == startType {
            i = string.index(after: i)
        }
        while i < string.endIndex && charType(string[i], bigWord: bigWord) == .whitespace {
            i = string.index(after: i)
        }
        return i.utf16Offset(in: string)
    }

    private static func findWordBackward(from pos: Int, in string: String, bigWord: Bool) -> Int {
        guard pos > 0 else { return 0 }
        let startIndex = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
        var i = startIndex

        while i > string.startIndex {
            let prevIdx = string.index(before: i)
            if charType(string[prevIdx], bigWord: bigWord) == .whitespace {
                i = prevIdx
            } else {
                break
            }
        }

        guard i > string.startIndex else { return 0 }
        let lastIdx = string.index(before: i)
        let targetType = charType(string[lastIdx], bigWord: bigWord)

        while i > string.startIndex {
            let prevIdx = string.index(before: i)
            if charType(string[prevIdx], bigWord: bigWord) == targetType {
                i = prevIdx
            } else {
                break
            }
        }
        return i.utf16Offset(in: string)
    }

    private static func findWordEnd(from pos: Int, in string: String, bigWord: Bool) -> Int {
        guard pos < string.utf16.count else { return pos }
        let startIndex = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
        var i = startIndex

        if i == string.endIndex || string.index(after: i) == string.endIndex {
            return pos
        }

        i = string.index(after: i)

        while i < string.endIndex && charType(string[i], bigWord: bigWord) == .whitespace {
            i = string.index(after: i)
        }

        if i < string.endIndex {
            let targetType = charType(string[i], bigWord: bigWord)
            while i < string.endIndex {
                let nextIdx = string.index(after: i)
                if nextIdx < string.endIndex && charType(string[nextIdx], bigWord: bigWord) == targetType {
                    i = nextIdx
                } else {
                    break
                }
            }
        }
        return min(i.utf16Offset(in: string), string.utf16.count - 1)
    }

    private static func findWordEndBackward(from pos: Int, in string: String, bigWord: Bool) -> Int {
        guard pos > 0 else { return 0 }
        var i = string.utf16.index(string.utf16.startIndex, offsetBy: min(pos, string.utf16.count - 1))

        if i > string.startIndex {
            i = string.index(before: i)
        }
        while i > string.startIndex && charType(string[i], bigWord: bigWord) == .whitespace {
            i = string.index(before: i)
        }

        let targetType = charType(string[i], bigWord: bigWord)
        while i > string.startIndex {
            let prev = string.index(before: i)
            if charType(string[prev], bigWord: bigWord) == targetType {
                i = prev
            } else {
                break
            }
        }

        var end = i
        while end < string.endIndex {
            let next = string.index(after: end)
            if next < string.endIndex && charType(string[next], bigWord: bigWord) == targetType {
                end = next
            } else {
                break
            }
        }
        return end.utf16Offset(in: string)
    }

    private enum CharType {
        case word, punctuation, whitespace
    }

    private static func charType(_ char: Character, bigWord: Bool = false) -> CharType {
        if char.isNewline || char.isWhitespace { return .whitespace }
        if bigWord { return .word }
        if char.isLetter || char.isNumber || char == "_" { return .word }
        return .punctuation
    }

    // MARK: - Character find (f/F/t/T and ;/, repeats)

    /// `skipAdjacent` steps over a target sitting immediately next to the
    /// cursor — used when `;`/`,` repeats a `t`/`T`, where the cursor already
    /// rests just before/after the previous match and must advance past it.
    private static func findCharInLine(_ ch: Character, forward: Bool, till: Bool, from pos: Int, in nsString: NSString, skipAdjacent: Bool = false) -> Int {
        let string = nsString as String
        guard pos < string.utf16.count else { return pos }
        let startIdx = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
        let lineRange = string.lineRange(for: startIdx..<startIdx)

        if forward {
            var i = startIdx
            if i < lineRange.upperBound {
                i = string.index(after: i)
            }
            if skipAdjacent, i < lineRange.upperBound, string[i] == ch {
                i = string.index(after: i)
            }
            while i < lineRange.upperBound {
                if string[i] == ch {
                    if till {
                        return string.index(before: i).utf16Offset(in: string)
                    } else {
                        return i.utf16Offset(in: string)
                    }
                }
                i = string.index(after: i)
            }
        } else {
            var i = startIdx
            if skipAdjacent, i > lineRange.lowerBound {
                let prev = string.index(before: i)
                if string[prev] == ch { i = prev }
            }
            while i > lineRange.lowerBound {
                i = string.index(before: i)
                if string[i] == ch {
                    if till {
                        return string.index(after: i).utf16Offset(in: string)
                    } else {
                        return i.utf16Offset(in: string)
                    }
                }
            }
        }
        return pos
    }

    // MARK: - Bracket matching (%)

    private static func findMatchingBracket(from pos: Int, in nsString: NSString) -> Int {
        let string = nsString as String
        guard pos < string.utf16.count else { return pos }

        let pairs: [Character: Character] = ["(": ")", "[": "]", "{": "}", ")": "(", "]": "[", "}": "{"]
        let opening: Set<Character> = ["(", "[", "{"]

        let startIdx = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
        var bracketIdx = startIdx
        var ch = string[bracketIdx]

        if pairs[ch] == nil {
            let lineRange = string.lineRange(for: startIdx..<startIdx)
            var searchIdx = string.index(after: startIdx)
            while searchIdx < lineRange.upperBound {
                let searchCh = string[searchIdx]
                if pairs[searchCh] != nil {
                    bracketIdx = searchIdx
                    ch = searchCh
                    break
                }
                searchIdx = string.index(after: searchIdx)
            }
        }

        guard let match = pairs[ch] else { return pos }

        if opening.contains(ch) {
            var depth = 1
            var i = string.index(after: bracketIdx)
            while i < string.endIndex && depth > 0 {
                let c = string[i]
                if c == ch { depth += 1 }
                else if c == match { depth -= 1 }
                if depth == 0 { return i.utf16Offset(in: string) }
                i = string.index(after: i)
            }
        } else {
            var depth = 1
            var i = bracketIdx
            while i > string.startIndex && depth > 0 {
                i = string.index(before: i)
                let c = string[i]
                if c == ch { depth += 1 }
                else if c == match { depth -= 1 }
                if depth == 0 { return i.utf16Offset(in: string) }
            }
        }
        return pos
    }
}
