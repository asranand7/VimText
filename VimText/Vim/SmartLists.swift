import Foundation

/// The model behind smart lists: parsing a line's list marker, deciding what
/// marker the *next* item should carry, and renumbering an ordered list block.
///
/// Pure string/range math with no AppKit dependency so it can be tested
/// headlessly — `VimNSTextView` (Return / Tab / Backspace in insert mode) and
/// the Vim coordinator (`o` / `O`) both drive their edits from here.
enum SmartList {
    /// One indent level, used by Tab / Shift-Tab and by the empty-item outdent.
    static let indentUnit = "    "
    static let tabWidth = 4

    enum Kind: Equatable {
        /// `-`, `*`, `+` or `•`.
        case bullet(Character)
        /// A number plus its `.` or `)` separator.
        case ordered(number: Int, separator: Character)
    }

    struct Item: Equatable {
        /// Leading whitespace of the line, verbatim.
        let indent: String
        let kind: Kind
        /// True when the marker is followed by a `[ ]` / `[x]` checkbox.
        let checkbox: Bool
        let checked: Bool
        /// Everything after the marker (and checkbox, when present).
        let body: String
        /// UTF-16 length of the number as written (`007.` counts 3), so a
        /// renumber replaces exactly the digits that are there. 0 for bullets.
        let numberLength: Int
        /// UTF-16 distance from the line start to the first body character —
        /// i.e. the length of the marker exactly as it appears on the line,
        /// which can be one shorter than `markerText` when the line ends right
        /// after `- [ ]` with no trailing space.
        let prefixLength: Int

        /// An item with nothing typed into it yet: the Return that ends a list.
        var isEmpty: Bool { body.trimmingCharacters(in: .whitespaces).isEmpty }

        var indentWidth: Int { SmartList.indentWidth(indent) }

        var number: Int? {
            if case let .ordered(number, _) = kind { return number }
            return nil
        }

        /// The marker as it should be written out, normalized to a single
        /// trailing space.
        var markerText: String { SmartList.markerText(kind: kind, checkbox: checkbox, checked: checked) }

        /// The marker for a *new* item that follows this one. Checkboxes always
        /// start unchecked, and ordered items step to the next number.
        func nextMarkerText(previousSibling: Item? = nil) -> String {
            switch kind {
            case .bullet:
                return SmartList.markerText(kind: kind, checkbox: checkbox, checked: false)
            case let .ordered(number, separator):
                // A lazily numbered list (`1.` on every line) stays lazy.
                let lazyNumbering = previousSibling?.number == number
                let next = lazyNumbering ? number : number + 1
                return SmartList.markerText(kind: .ordered(number: next, separator: separator),
                                            checkbox: checkbox, checked: false)
            }
        }
    }

    static func markerText(kind: Kind, checkbox: Bool, checked: Bool) -> String {
        let marker: String
        switch kind {
        case let .bullet(char): marker = "\(char) "
        case let .ordered(number, separator): marker = "\(number)\(separator) "
        }
        guard checkbox else { return marker }
        return marker + (checked ? "[x] " : "[ ] ")
    }

    static func indentWidth<S: StringProtocol>(_ indent: S) -> Int {
        indent.reduce(0) { $0 + ($1 == "\t" ? tabWidth : 1) }
    }

    // MARK: - Parsing

    /// Parses a single line (with or without its trailing newline) into a list
    /// item. Returns nil when the line isn't one.
    static func parse(_ line: String) -> Item? {
        var s = Substring(line)
        if s.hasSuffix("\n") { s = s.dropLast() }
        if s.hasSuffix("\r") { s = s.dropLast() }
        let indent = s.prefix { $0 == " " || $0 == "\t" }
        let rest = s.dropFirst(indent.count)
        guard let first = rest.first else { return nil }

        var kind: Kind
        var afterMarker: Substring
        var markerLength: Int
        var numberLength = 0

        if "-*+•".contains(first) {
            let after = rest.dropFirst()
            guard after.first == " " else { return nil }
            kind = .bullet(first)
            afterMarker = after.dropFirst()
            markerLength = String(first).utf16.count + 1
        } else {
            let digits = rest.prefix { $0.isNumber && $0.isASCII }
            // Cap the digit run so an absurd number can't overflow `Int`.
            guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
            let afterDigits = rest.dropFirst(digits.count)
            guard let separator = afterDigits.first, separator == "." || separator == ")" else { return nil }
            let afterSeparator = afterDigits.dropFirst()
            guard afterSeparator.first == " " else { return nil }
            kind = .ordered(number: number, separator: separator)
            afterMarker = afterSeparator.dropFirst()
            markerLength = digits.count + 2
            numberLength = digits.count
        }

        // Optional checkbox: `[ ]` / `[x]`, which must end the marker or be
        // followed by a space — the same rule `ListMarkers` renders by.
        var checkbox = false
        var checked = false
        var body = afterMarker
        if afterMarker.count >= 3 {
            let chars = Array(afterMarker.prefix(3))
            let after = afterMarker.dropFirst(3)
            if chars[0] == "[", chars[2] == "]",
               chars[1] == " " || chars[1] == "x" || chars[1] == "X",
               after.isEmpty || after.first == " " {
                checkbox = true
                checked = (chars[1] == "x" || chars[1] == "X")
                markerLength += after.isEmpty ? 3 : 4
                body = after.isEmpty ? after : after.dropFirst()
            }
        }

        return Item(indent: String(indent),
                    kind: kind,
                    checkbox: checkbox,
                    checked: checked,
                    body: String(body),
                    numberLength: numberLength,
                    prefixLength: indent.utf16.count + markerLength)
    }

    /// Parses the line containing `location` (its content, newline excluded).
    static func item(in text: NSString, at location: Int) -> (item: Item, lineRange: NSRange, contentEnd: Int)? {
        guard text.length > 0 else { return nil }
        let clamped = min(max(location, 0), text.length)
        let lineRange = text.lineRange(for: NSRange(location: clamped, length: 0))
        var contentEnd = lineRange.location + lineRange.length
        while contentEnd > lineRange.location,
              text.character(at: contentEnd - 1) == 0x0A || text.character(at: contentEnd - 1) == 0x0D {
            contentEnd -= 1
        }
        let content = text.substring(with: NSRange(location: lineRange.location, length: contentEnd - lineRange.location))
        guard let item = parse(content) else { return nil }
        return (item, lineRange, contentEnd)
    }

    /// The nearest preceding item at the same indent level, stopping at a
    /// non-list line or at a shallower one (which ends the sub-list).
    static func previousSibling(in text: NSString, beforeLineAt lineStart: Int, indentWidth targetWidth: Int) -> Item? {
        var location = lineStart
        while location > 0 {
            let previous = text.lineRange(for: NSRange(location: location - 1, length: 0))
            guard let (item, lineRange, _) = item(in: text, at: previous.location) else { return nil }
            let width = item.indentWidth
            if width == targetWidth { return item }
            if width < targetWidth { return nil }
            location = lineRange.location
            if location == 0 { return nil }
        }
        return nil
    }

    // MARK: - Renumbering

    struct Edit: Equatable {
        let range: NSRange
        let replacement: String
    }

    /// Renumbers the ordered items of the list block containing `location`.
    ///
    /// A block is the run of consecutive list lines around the caret; within it
    /// each indent level keeps its own counter, so nested lists restart at 1 and
    /// resuming a parent level continues where it left off. Lists that are
    /// deliberately numbered lazily (every item `1.`) are left alone.
    ///
    /// Returns the edits needed; ranges are document ranges and non-overlapping.
    static func renumberEdits(in text: NSString, around location: Int) -> [Edit] {
        guard let (_, anchorLine, _) = item(in: text, at: location) else { return [] }

        // Grow upward to the first line of the block.
        var start = anchorLine.location
        while start > 0 {
            guard let (_, lineRange, _) = item(in: text, at: start - 1) else { break }
            start = lineRange.location
        }

        // Collect the block's lines top-down.
        var lines: [(item: Item, lineStart: Int)] = []
        var cursor = start
        while cursor < text.length {
            var lineEnd = 0
            text.getLineStart(nil, end: &lineEnd, contentsEnd: nil, for: NSRange(location: cursor, length: 0))
            guard let (item, lineRange, _) = item(in: text, at: cursor) else { break }
            lines.append((item, lineRange.location))
            if lineEnd <= cursor { break }
            cursor = lineEnd
        }
        guard !lines.isEmpty else { return [] }

        // Leave a lazily numbered list (all items share one number) as it is.
        // The caret's own line is excluded: it is the item just inserted, and
        // its number hasn't been reconciled with the rest yet.
        let anchorStart = anchorLine.location
        let otherNumbers = lines.filter { $0.lineStart != anchorStart }.compactMap { $0.item.number }
        if otherNumbers.count >= 2, Set(otherNumbers).count == 1 { return [] }

        struct Level {
            let width: Int
            var next: Int?
            let isRoot: Bool
        }
        var stack: [Level] = []
        var edits: [Edit] = []

        for (item, lineStart) in lines {
            let width = item.indentWidth
            while let top = stack.last, top.width > width { stack.removeLast() }
            if stack.last?.width != width {
                stack.append(Level(width: width, next: nil, isRoot: stack.isEmpty))
            }

            guard case let .ordered(number, _) = item.kind else { continue }
            var level = stack.removeLast()
            // The first ordered item of a level sets its start: the outermost
            // level keeps whatever the user typed (a list may start at 5), a
            // nested one restarts at 1.
            let assigned = level.next ?? (level.isRoot ? number : 1)
            level.next = assigned + 1
            stack.append(level)

            guard assigned != number else { continue }
            let digitsRange = NSRange(location: lineStart + item.indent.utf16.count,
                                      length: item.numberLength)
            edits.append(Edit(range: digitsRange, replacement: String(assigned)))
        }

        return edits
    }
}
