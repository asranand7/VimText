import SwiftUI
import AppKit

/// The NSTextViewDelegate that bridges the SwiftUI binding, the Vim engine,
/// and the live NSTextView — resolves motions, executes VimActions, syncs
/// text/RTF, and drives find. Split out of VimTextView.swift for navigability.
extension VimTextView {
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VimTextView
        weak var textView: VimNSTextView?
        weak var scrollView: NSScrollView?
        /// True when the user has typed into the NSTextView but the change
        /// hasn't been serialized + reported via onContentChange yet.
        var hasUnsyncedEdits = false
        /// Latest serialized content (Markdown text / RTF). Seeded from the
        /// initial values in makeNSView, updated by the deferred sync work,
        /// and reported together through onContentChange.
        var latestText: String = ""
        var latestRTF: Data = Data()
        var visualAnchor: Int = 0
        var visualCursorPos: Int = 0
        private var yankHighlightLayer: CALayer?
        private var searchHighlightTimer: DispatchWorkItem?
        private var blockHighlightLayers: [CALayer] = []
        var blockInsertText: String?
        var lastBlockRanges: [NSRange] = []
        var wasInBlockMode = false
        var blockInsertStartPos: Int?
        var blockInsertIsAppend = false
        var blockInsertColumn: Int = 0
        var blockInsertLineCount: Int = 0
        var blockInsertFirstLineStart: Int = 0

        var insertModeStartContent: String = ""
        var insertModeStartPos: Int = 0
        /// Vim marks (`m{a-zA-Z}`) as UTF-16 offsets. Per-note: the editor is
        /// recreated per note via `.id(noteId)`. Positions are not adjusted as
        /// the text changes; jumps clamp into the current document.
        var marks: [Character: Int] = [:]
        var isReplayingDot: Bool = false
        var lastFontSize: CGFloat = 0
        var lastFontName: String = ""
        var lastThemeKey: String = ""
        var lastPaperStyle: String = "plain"
        var lastAppliedText: String = ""
        var refocusObserver: Any?
        private var findMatchRanges: [NSRange] = []
        private var currentFindIndex: Int = -1
        /// Debounce timer for expensive RTF serialization + code-block restyling.
        private var deferredWorkItem: DispatchWorkItem?
        private var rtfStale = false
        /// Observer that flushes deferred RTF / restyle work before the editor
        /// disappears (e.g. switching notes) so persisted data stays in sync.
        private var commitObserver: Any?

        init(_ parent: VimTextView) {
            self.parent = parent
            super.init()
            // Listen for the flush-before-teardown notification.
            commitObserver = NotificationCenter.default.addObserver(
                forName: .commitEditorPendingWork,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.flushDeferredWork()
            }
        }

        func setupRefocusObserver(for textView: VimNSTextView) {
            if let observer = refocusObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            refocusObserver = NotificationCenter.default.addObserver(
                forName: .refocusEditor,
                object: nil,
                queue: .main
            ) { [weak textView] _ in
                if let tv = textView {
                    tv.window?.makeFirstResponder(tv)
                }
            }
        }

        deinit {
            if let observer = refocusObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = commitObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            deferredWorkItem?.cancel()
        }

        func setupFindController() {
            guard let fc = parent.findController else { return }
            fc.performFind = { [weak self] query in
                self?.performFindInEditor(query: query)
            }
            fc.findNext = { [weak self] in
                self?.navigateToNextFindMatch()
            }
            fc.findPrev = { [weak self] in
                self?.navigateToPrevFindMatch()
            }
            fc.dismiss = { [weak self] in
                self?.clearFindHighlights()
            }
            fc.refocusEditor = { [weak self] in
                guard let tv = self?.textView else { return }
                tv.window?.makeFirstResponder(tv)
            }
        }

        func performFindInEditor(query: String) {
            guard let textView = textView else { return }
            textView.clearSearchHighlights()
            findMatchRanges = []
            currentFindIndex = -1

            guard !query.isEmpty else {
                parent.findController?.totalMatches = 0
                parent.findController?.currentMatch = 0
                return
            }

            // searchMatches folds the text so straight quotes match smart
            // quotes (folding is 1:1 in UTF-16, so the ranges are valid in
            // the live storage) and caches the folded document across
            // keystrokes — re-folding a large note per keystroke was the
            // find bar's dominant cost.
            findMatchRanges = textView.searchMatches(for: query)

            textView.applyMatchHighlights(findMatchRanges)

            let fc = parent.findController
            fc?.totalMatches = findMatchRanges.count

            if !findMatchRanges.isEmpty {
                let cursorPos = textView.selectedRange().location
                currentFindIndex = 0
                for (i, range) in findMatchRanges.enumerated() {
                    if range.location >= cursorPos {
                        currentFindIndex = i
                        break
                    }
                }
                navigateToFindMatch(in: textView)
            } else {
                fc?.currentMatch = 0
            }
        }

        private func navigateToNextFindMatch() {
            guard let textView = textView, !findMatchRanges.isEmpty else { return }
            currentFindIndex = (currentFindIndex + 1) % findMatchRanges.count
            navigateToFindMatch(in: textView)
        }

        private func navigateToPrevFindMatch() {
            guard let textView = textView, !findMatchRanges.isEmpty else { return }
            currentFindIndex = (currentFindIndex - 1 + findMatchRanges.count) % findMatchRanges.count
            navigateToFindMatch(in: textView)
        }

        private func navigateToFindMatch(in textView: VimNSTextView) {
            guard currentFindIndex >= 0 && currentFindIndex < findMatchRanges.count else { return }
            let range = findMatchRanges[currentFindIndex]
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.scrollRangeToVisible(range)
            textView.highlightCurrentMatch(range: range)
            parent.findController?.currentMatch = currentFindIndex + 1
        }

        private func clearFindHighlights() {
            textView?.clearSearchHighlights()
            findMatchRanges = []
            currentFindIndex = -1
        }

        func textDidChange(_ notification: Notification) {
            guard notification.object is NSTextView else { return }
            // Don't serialize here. For a 2.9 MB note, copying the entire
            // NSString into a Swift String on every keystroke costs ~5-10ms.
            // The NSTextView is the authoritative source of truth; content is
            // serialized and reported when typing pauses (500ms debounce) or
            // on teardown/flush.
            hasUnsyncedEdits = true
            rtfStale = true
            scheduleDeferredWork()
        }

        /// Reports the latest serialized content to the SwiftUI layer.
        private func notifyContentChange() {
            parent.onContentChange?(latestText, latestRTF)
        }

        /// Immediately executes all deferred work (text sync, RTF export,
        /// code-block restyle, cursor position). Called before note teardown
        /// so persisted data stays in sync.
        func flushDeferredWork() {
            deferredWorkItem?.cancel()
            deferredWorkItem = nil
            cursorDebounceItem?.cancel()
            cursorDebounceItem = nil
            executeDeferredWork()
            serializeRTFIfStale()
            syncCursorPosition()
        }

        /// Serializes the document to RTF, or returns empty `Data` when it has
        /// no rich formatting worth preserving — a plain-prose or code-only note
        /// is fully reconstructible from the `.txt`, so we skip the (whole-
        /// document, O(length)) RTF encode entirely for the common case.
        private func serializedRTF() -> Data {
            guard let storage = textView?.textStorage,
                  storage.length > 0,
                  textView?.hasRichTextFormatting == true else { return Data() }
            let flattened = ImageAttachments.flattened(storage)
            let range = NSRange(location: 0, length: flattened.length)
            return (try? flattened.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
        }

        private func serializeRTFIfStale() {
            guard rtfStale else { return }
            latestRTF = serializedRTF()
            rtfStale = false
            notifyContentChange()
        }

        private func scheduleDeferredWork() {
            deferredWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.executeDeferredWork()
            }
            deferredWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
        }

        private func executeDeferredWork() {
            guard let textView = textView, hasUnsyncedEdits else { return }

            // Typing has paused — serialize the current content and report it
            // so the save pipeline sees it. Image attachments serialize back
            // to portable `![](assets/…)` Markdown so the on-disk content
            // stays plain text.
            hasUnsyncedEdits = false
            var synced = textView.textStorage.map { ImageAttachments.markdownString(from: $0) } ?? textView.string
            synced.makeContiguousUTF8()
            latestText = synced
            notifyContentChange()

            textView.restyleCodeBlocks(baseFont: parent.font)
            textView.refreshLinkHighlightsDeferred()
            textView.refreshListMarkers()

            // Re-scan find matches if the find bar is open
            if parent.findController?.isVisible == true,
               let query = parent.findController?.query, !query.isEmpty {
                performFindInEditor(query: query)
            }
        }

        /// Called after an image is resized via its drag handle: re-serialize
        /// both content (Markdown, with the new `|width`) and RTF so the size
        /// persists.
        func imageDidResize() {
            guard let storage = textView?.textStorage else { return }
            var synced = ImageAttachments.markdownString(from: storage)
            synced.makeContiguousUTF8()
            latestText = synced
            latestRTF = serializedRTF()
            rtfStale = false
            notifyContentChange()
        }

        func formattingDidChange() {
            // Formatting changes (bold/italic/underline toggle) are explicit
            // user actions — serialize RTF immediately so it persists. If the
            // toggle just removed the last formatting, serializedRTF() returns
            // empty and the now-plain note drops its sidecar.
            latestRTF = serializedRTF()
            rtfStale = false
            notifyContentChange()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            return false
        }

        /// Debounce item for cursor line/col updates. Setting @Published
        /// cursorLine/cursorCol on VimEngine triggers a full SwiftUI
        /// re-render of NoteEditorView on every keystroke. Debounce to 100ms
        /// so the status bar still feels responsive but typing isn't blocked.
        private var cursorDebounceItem: DispatchWorkItem?

        func textViewDidChangeSelection(_ notification: Notification) {
            // Expand the link under the caret (and re-fold the rest) immediately
            // so moving onto a chip reveals its URL without a visible lag. This
            // no-ops in setFolds when the fold set is unchanged, so ordinary
            // cursor moves away from any link cost nothing.
            textView?.updateLinkFolds()
            // Re-fold the checkbox the caret just left / unfold the one it
            // entered (no-ops when unchanged).
            textView?.applyListMarkers()

            // Debounce — don't let @Published cursorLine/cursorCol trigger
            // SwiftUI body re-evaluation on every keystroke.
            cursorDebounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                self?.syncCursorPosition()
            }
            cursorDebounceItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }

        private func syncCursorPosition() {
            guard let textView = textView else { return }
            let cursorPos = textView.selectedRange().location
            let nsString = textView.string as NSString
            let length = nsString.length
            let safeCursor = min(cursorPos, length)

            // Column: distance from start of current line to cursor
            let lineRange = nsString.lineRange(for: NSRange(location: safeCursor, length: 0))
            let col = safeCursor - lineRange.location + 1

            // Line number: count newlines using raw bytes — no Swift String
            // allocation. getBytes copies into a stack buffer we control.
            var lineNum = 1
            if safeCursor > 0 {
                let range = NSRange(location: 0, length: safeCursor)
                let bufSize = min(safeCursor * 4, 4 * 1024 * 1024) // UTF-8 upper bound, 4 MB cap
                let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
                defer { buf.deallocate() }
                var usedLen = 0
                nsString.getBytes(buf, maxLength: bufSize, usedLength: &usedLen, encoding: String.Encoding.utf8.rawValue, options: [], range: range, remaining: nil)
                for i in 0..<usedLen {
                    if buf[i] == 0x0A { lineNum += 1 }
                }
            }

            parent.vimEngine.cursorLine = lineNum
            parent.vimEngine.cursorCol = col
        }

        func executeActions(_ actions: [VimAction]) {
            guard let textView = textView else { return }
            let engine = parent.vimEngine

            // Locked notes are read-only: reject any mutating action with a
            // hint, and undo the mode switch the engine already made (e.g. `i`
            // flips to .insert before actions reach us). Navigation, visual
            // selection, and search all pass through untouched.
            if textView.isLockedNote {
                let mutates = actions.contains { action in
                    if Self.isTextMutating(action) { return true }
                    switch action {
                    case .undo, .redo, .replaceChar, .deleteToEnd:
                        return true
                    default:
                        return false
                    }
                }
                if mutates {
                    if engine.mode.isEditing { engine.mode = .normal }
                    engine.resetBuffers()
                    engine.statusMessage = "Note is locked — unlock to edit"
                    return
                }
            }

            if !isReplayingDot {
                let isChangeAction = actions.contains { action in
                    switch action {
                    case .insertMode, .deleteMotion, .deleteLine, .deleteLines, .deleteToEnd, .deleteChar,
                         .deleteCharBefore, .changeMotion, .changeLine, .changeLines, .changeToEnd,
                         .deleteTextObject, .changeTextObject, .toggleCase, .joinLines,
                         .changeCaseMotion, .changeCaseLines,
                         .pasteAfter, .pasteBefore, .indent, .outdent, .indentLines, .outdentLines, .replaceChar:
                        return true
                    default:
                        return false
                    }
                }
                let entersInsert = actions.contains { action in
                    switch action {
                    case .insertMode, .changeMotion, .changeLine, .changeLines, .changeToEnd, .changeTextObject:
                        return true
                    default:
                        return false
                    }
                }

                if isChangeAction {
                    if entersInsert {
                        engine.startRecordingChange(actions: actions)
                    } else {
                        engine.recordNonInsertChange(actions: actions)
                    }
                }
            }

            // Group every mutating command into one undo step, so e.g. `3x`,
            // a block-mode delete loop, or a `.` replay undoes atomically
            // instead of one NSTextView edit at a time. Never wrap undo/redo
            // themselves — running undo inside an open group corrupts the
            // stack.
            let touchesUndoStack = actions.contains { $0 == .undo || $0 == .redo }
            let shouldGroup = !touchesUndoStack && actions.contains(where: Self.isTextMutating)
            if shouldGroup { textView.undoManager?.beginUndoGrouping() }
            for action in actions {
                executeAction(action, in: textView)
            }
            if shouldGroup { textView.undoManager?.endUndoGrouping() }
        }

        /// Actions that can mutate the text storage (used to decide undo
        /// grouping). Motions, mode bookkeeping, search, and scrolling are out.
        private static func isTextMutating(_ action: VimAction) -> Bool {
            switch action {
            case .insertMode, .deleteMotion, .deleteLine, .deleteLines, .deleteToEnd, .deleteChar,
                 .deleteCharBefore, .changeMotion, .changeLine, .changeLines, .changeToEnd,
                 .deleteTextObject, .changeTextObject, .toggleCase, .joinLines,
                 .changeCaseMotion, .changeCaseLines, .visualChangeCase,
                 .pasteAfter, .pasteBefore, .indent, .outdent, .indentLines, .outdentLines,
                 .visualDelete, .visualChange, .visualPaste, .visualIndent, .visualOutdent,
                 .repeatLastChange, .substitute:
                return true
            default:
                return false
            }
        }

        private func lineRangeForCount(from cursorPos: Int, count: Int, in nsString: NSString, includeTrailingNewline: Bool = true) -> NSRange {
            let length = nsString.length
            guard length > 0 else { return NSRange(location: 0, length: 0) }

            let safeCursor = min(cursorPos, max(length - 1, 0))
            let firstLine = nsString.lineRange(for: NSRange(location: safeCursor, length: 0))
            var lastLine = firstLine

            if count > 1 {
                for _ in 1..<count {
                    let nextLineStart = lastLine.location + lastLine.length
                    guard nextLineStart < length else { break }
                    lastLine = nsString.lineRange(for: NSRange(location: nextLineStart, length: 0))
                }
            }

            var end = lastLine.location + lastLine.length
            if !includeTrailingNewline, end > firstLine.location, nsString.character(at: end - 1) == 0x0A {
                end -= 1
            }
            return NSRange(location: firstLine.location, length: max(0, end - firstLine.location))
        }

        /// Marks `text` as a linewise register. The file's last line carries no
        /// trailing newline, so a raw `yy`/`dd` there would yield text without a
        /// `\n` and paste would degrade to charwise — append one so the register
        /// is unambiguously linewise.
        private func linewiseRegister(_ text: String) -> String {
            text.hasSuffix("\n") ? text : text + "\n"
        }

        /// The range to actually delete for a linewise *delete* of `range`. When
        /// the target reaches the end of the document and has no trailing newline
        /// of its own (it's the last line), the newline that precedes it must go
        /// too — otherwise deleting the last line leaves a blank line behind
        /// ("first\nsecond" + dd → "first", not "first\n"). The register is still
        /// built from the original `range`, so the yank stays linewise.
        private func linewiseDeletionRange(_ range: NSRange, in nsString: NSString) -> NSRange {
            let end = range.location + range.length
            guard end == nsString.length, range.location > 0,
                  end > 0, nsString.character(at: end - 1) != 0x0A else { return range }
            return NSRange(location: range.location - 1, length: range.length + 1)
        }


        private func indentLineRange(_ range: NSRange, in textView: VimNSTextView) {
            var pos = range.location
            var limit = range.location + range.length
            while pos < limit {
                let currentNsString = textView.string as NSString
                let lr = currentNsString.lineRange(for: NSRange(location: min(pos, max(currentNsString.length - 1, 0)), length: 0))
                textView.insertText("    ", replacementRange: NSRange(location: lr.location, length: 0))
                pos = lr.location + lr.length + 4
                limit += 4
            }
        }

        private func outdentLineRange(_ range: NSRange, in textView: VimNSTextView) {
            var pos = range.location
            var limit = range.location + range.length
            while pos < limit {
                let currentNsString = textView.string as NSString
                guard currentNsString.length > 0 else { break }
                let lr = currentNsString.lineRange(for: NSRange(location: min(pos, currentNsString.length - 1), length: 0))
                let lineText = currentNsString.substring(with: lr)
                var removeCount = 0
                for ch in lineText {
                    if ch == " " && removeCount < 4 { removeCount += 1 }
                    else if ch == "\t" && removeCount == 0 { removeCount = 1; break }
                    else { break }
                }
                if removeCount > 0 {
                    textView.setSelectedRange(NSRange(location: lr.location, length: removeCount))
                    textView.delete(nil)
                    limit -= removeCount
                }
                let newNsString = textView.string as NSString
                guard newNsString.length > 0 else { break }
                let nextLine = newNsString.lineRange(for: NSRange(location: min(lr.location, newNsString.length - 1), length: 0))
                let next = nextLine.location + nextLine.length
                if next <= pos { break }
                pos = next
            }
        }

        func executeAction(_ action: VimAction, in textView: VimNSTextView) {
            let string = textView.string
            let nsString = string as NSString
            let cursorPos = textView.selectedRange().location
            let length = nsString.length
            let engine = parent.vimEngine
            let isVisual = engine.mode.isVisual

            switch action {
            case .none:
                break

            case .moveCursor(let motion):
                let newPos: Int
                if isVisual {
                    let savedRange = textView.selectedRange()
                    textView.setSelectedRange(NSRange(location: visualCursorPos, length: 0))
                    newPos = resolveMotion(motion, in: textView)
                    textView.setSelectedRange(savedRange)
                    visualCursorPos = newPos
                    if engine.mode == .visualBlock {
                        updateBlockSelection(in: textView)
                    } else {
                        updateVisualSelection(cursorAt: newPos, in: textView)
                    }
                } else {
                    newPos = resolveMotion(motion, in: textView)
                    textView.setSelectedRange(NSRange(location: newPos, length: 0))
                }
                textView.scrollRangeToVisible(NSRange(location: newPos, length: 0))

            case .insertMode(let entry):
                // Each insert session is its own undo unit: typed text must
                // not coalesce with text typed in a previous session.
                textView.breakUndoCoalescing()
                handleInsertEntry(entry, in: textView)
                textView.updateCursorAppearance(isBlock: false)
                textView.clearSearchHighlights()
                if !isReplayingDot {
                    insertModeStartContent = textView.string
                    insertModeStartPos = textView.selectedRange().location
                }

            case .normalMode:
                textView.breakUndoCoalescing()
                textView.visualCursorOverride = nil
                clearBlockHighlights(in: textView)

                if !isReplayingDot && engine.isRecordingChange {
                    let currentContent = textView.string
                    let oldLen = insertModeStartContent.utf16.count
                    let newLen = currentContent.utf16.count
                    if newLen >= oldLen {
                        let diffLen = newLen - oldLen
                        if diffLen > 0 {
                            let startIdx = String.Index(utf16Offset: insertModeStartPos, in: currentContent)
                            let endIdx = currentContent.utf16.index(startIdx, offsetBy: diffLen, limitedBy: currentContent.utf16.endIndex) ?? currentContent.endIndex
                            let typed = String(currentContent[startIdx..<endIdx])
                            engine.finalizeChange(insertedText: typed)
                        } else {
                            engine.finalizeChange(insertedText: "")
                        }
                    } else {
                        engine.finalizeChange(insertedText: "")
                    }
                }

                if let startPos = blockInsertStartPos, wasInBlockMode, blockInsertLineCount > 1 {
                    let currentPos = textView.selectedRange().location
                    if currentPos > startPos {
                        let insertedText = (textView.string as NSString).substring(with: NSRange(location: startPos, length: currentPos - startPos))
                        let firstLineNs = textView.string as NSString
                        let firstLR = firstLineNs.lineRange(for: NSRange(location: startPos, length: 0))
                        var nextLineStart = firstLR.location + firstLR.length

                        for _ in 1..<blockInsertLineCount {
                            let currentNs = textView.string as NSString
                            if nextLineStart >= currentNs.length { break }
                            let lr = currentNs.lineRange(for: NSRange(location: nextLineStart, length: 0))
                            let targetPos = positionForColumn(blockInsertColumn, inLineAt: lr.location, in: currentNs)
                            textView.insertText(insertedText, replacementRange: NSRange(location: targetPos, length: 0))
                            let updatedNs = textView.string as NSString
                            let updatedLR = updatedNs.lineRange(for: NSRange(location: targetPos, length: 0))
                            nextLineStart = updatedLR.location + updatedLR.length
                        }
                    }
                    blockInsertStartPos = nil
                    wasInBlockMode = false
                    lastBlockRanges = []
                }

                let sel = textView.selectedRange()
                let newLength = (textView.string as NSString).length
                let pos = sel.location
                textView.setSelectedRange(NSRange(location: pos, length: 0))
                if pos > 0 && pos == newLength {
                    textView.setSelectedRange(NSRange(location: pos - 1, length: 0))
                }
                textView.updateCursorAppearance(isBlock: true)

            case .visualMode:
                clearBlockHighlights(in: textView)
                visualAnchor = cursorPos
                visualCursorPos = cursorPos
                textView.visualCursorOverride = cursorPos
                let selLen = min(1, length - cursorPos)
                textView.setSelectedRange(NSRange(location: cursorPos, length: selLen))

            case .visualLineMode:
                clearBlockHighlights(in: textView)
                visualAnchor = cursorPos
                visualCursorPos = cursorPos
                textView.visualCursorOverride = cursorPos
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                textView.setSelectedRange(lineRange)

            case .visualBlockMode:
                visualAnchor = cursorPos
                visualCursorPos = cursorPos
                textView.visualCursorOverride = cursorPos
                textView.setSelectedRange(NSRange(location: cursorPos, length: 0))
                updateBlockSelection(in: textView)

            case .commandMode:
                break

            case .replaceChar:
                break

            case .toggleCase(let count):
                // Toggle `count` chars from the cursor, bounded to the current
                // line's content (Vim's `~` stops at end-of-line, never wraps;
                // a count past the end must not thrash the last char).
                let lineRange = nsString.lineRange(for: NSRange(location: min(cursorPos, max(length - 1, 0)), length: 0))
                var lineContentEnd = lineRange.location + lineRange.length
                if lineContentEnd > lineRange.location, nsString.character(at: lineContentEnd - 1) == 0x0A {
                    lineContentEnd -= 1
                }
                let upTo = min(cursorPos + max(1, count), lineContentEnd)
                var pos = cursorPos
                while pos < upTo {
                    let charRange = NSRange(location: pos, length: 1)
                    let ch = nsString.substring(with: charRange)
                    let toggled = ch == ch.uppercased() ? ch.lowercased() : ch.uppercased()
                    // Caseless chars (digits, punctuation) toggle to themselves —
                    // skip the storage write instead of dirtying the document.
                    if toggled != ch {
                        textView.insertText(toggled, replacementRange: charRange)
                    }
                    pos += 1
                }
                // Rest on the char after the toggled run, clamped to the line's
                // last char (matching Vim).
                let rest = min(upTo, max(lineContentEnd - 1, lineRange.location))
                textView.setSelectedRange(NSRange(location: rest, length: 0))

            case .repeatLastChange:
                let savedActions = engine.lastChangeActions
                let savedInsertedText = engine.lastInsertedText
                guard !savedActions.isEmpty else { break }

                isReplayingDot = true

                let entersInsert = savedActions.contains { a in
                    switch a {
                    case .insertMode, .changeMotion, .changeLine, .changeLines, .changeToEnd, .changeTextObject:
                        return true
                    default:
                        return false
                    }
                }

                for a in savedActions {
                    if case .replaceChar = a {
                        let pos = textView.selectedRange().location
                        let ns = textView.string as NSString
                        if pos < ns.length && !engine.lastReplaceChar.isEmpty {
                            textView.setSelectedRange(NSRange(location: pos, length: 1))
                            textView.insertText(engine.lastReplaceChar, replacementRange: NSRange(location: pos, length: 1))
                            textView.setSelectedRange(NSRange(location: pos, length: 0))
                        }
                    } else {
                        executeAction(a, in: textView)
                    }
                }

                if entersInsert && !savedInsertedText.isEmpty {
                    textView.insertText(savedInsertedText, replacementRange: textView.selectedRange())
                }

                if entersInsert {
                    engine.mode = .normal
                    let pos = textView.selectedRange().location
                    let ns = textView.string as NSString
                    if pos > 0 && pos <= ns.length {
                        textView.setSelectedRange(NSRange(location: pos - 1, length: 0))
                    }
                    textView.updateCursorAppearance(isBlock: true)
                }

                isReplayingDot = false

            case .deleteChar:
                if cursorPos < length {
                    textView.setSelectedRange(NSRange(location: cursorPos, length: 1))
                    textView.delete(nil)
                }

            case .deleteCharBefore:
                if cursorPos > 0 {
                    textView.setSelectedRange(NSRange(location: cursorPos - 1, length: 1))
                    textView.delete(nil)
                }

            case .deleteLine:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                let lineText = nsString.substring(with: lineRange)
                parent.vimEngine.register = linewiseRegister(lineText)
                textView.setSelectedRange(linewiseDeletionRange(lineRange, in: nsString))
                textView.delete(nil)

            case .deleteLines(let count):
                let range = lineRangeForCount(from: cursorPos, count: max(1, count), in: nsString)
                if range.length > 0 {
                    parent.vimEngine.register = linewiseRegister(nsString.substring(with: range))
                    textView.setSelectedRange(linewiseDeletionRange(range, in: nsString))
                    textView.delete(nil)
                }

            case .deleteToEnd:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                let lineEnd = lineRange.location + lineRange.length
                let deleteEnd = lineEnd > 0 && nsString.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
                if cursorPos < deleteEnd {
                    let range = NSRange(location: cursorPos, length: deleteEnd - cursorPos)
                    parent.vimEngine.register = nsString.substring(with: range)
                    textView.setSelectedRange(range)
                    textView.delete(nil)
                }

            case .deleteMotion(let motion, let count):
                let target = resolveMotionNTimes(motion, count: count, in: textView)
                if motion.isLinewise {
                    let startLine = nsString.lineRange(for: NSRange(location: min(cursorPos, target), length: 0))
                    let endLine = nsString.lineRange(for: NSRange(location: max(cursorPos, target), length: 0))
                    let range = NSRange(location: startLine.location, length: NSMaxRange(endLine) - startLine.location)
                    if range.length > 0 {
                        parent.vimEngine.register = linewiseRegister(nsString.substring(with: range))
                        textView.setSelectedRange(linewiseDeletionRange(range, in: nsString))
                        textView.delete(nil)
                    }
                } else {
                    let start = min(cursorPos, target)
                    var end = max(cursorPos, target)
                    // Inclusive motions take the character under the target —
                    // but never a newline (e.g. $ on an empty line resolves to
                    // the line start, which holds the \n).
                    if motion.isInclusive && end < length && nsString.character(at: end) != 0x0A { end += 1 }
                    if start < end {
                        let range = NSRange(location: start, length: end - start)
                        parent.vimEngine.register = nsString.substring(with: range)
                        textView.setSelectedRange(range)
                        textView.delete(nil)
                    }
                }

            case .changeLine:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                var contentRange = lineRange
                if contentRange.length > 0 && nsString.character(at: contentRange.location + contentRange.length - 1) == 0x0A {
                    contentRange.length -= 1
                }
                parent.vimEngine.register = linewiseRegister(nsString.substring(with: contentRange))
                textView.setSelectedRange(contentRange)
                textView.delete(nil)
                textView.updateCursorAppearance(isBlock: false)
                if !isReplayingDot {
                    insertModeStartContent = textView.string
                    insertModeStartPos = textView.selectedRange().location
                }

            case .changeLines(let count):
                let range = lineRangeForCount(from: cursorPos, count: max(1, count), in: nsString, includeTrailingNewline: false)
                if range.length > 0 {
                    parent.vimEngine.register = linewiseRegister(nsString.substring(with: range))
                    textView.setSelectedRange(range)
                    textView.delete(nil)
                }
                textView.updateCursorAppearance(isBlock: false)
                if !isReplayingDot {
                    insertModeStartContent = textView.string
                    insertModeStartPos = textView.selectedRange().location
                }

            case .changeToEnd:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                let lineEnd = lineRange.location + lineRange.length
                let end = lineEnd > 0 && nsString.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
                if cursorPos < end {
                    let range = NSRange(location: cursorPos, length: end - cursorPos)
                    parent.vimEngine.register = nsString.substring(with: range)
                    textView.setSelectedRange(range)
                    textView.delete(nil)
                }
                textView.updateCursorAppearance(isBlock: false)
                if !isReplayingDot {
                    insertModeStartContent = textView.string
                    insertModeStartPos = textView.selectedRange().location
                }

            case .changeMotion(let motion, let count):
                let target = resolveMotionNTimes(motion, count: count, in: textView)
                if motion.isLinewise {
                    let startLine = nsString.lineRange(for: NSRange(location: min(cursorPos, target), length: 0))
                    let endLine = nsString.lineRange(for: NSRange(location: max(cursorPos, target), length: 0))
                    var rangeEnd = NSMaxRange(endLine)
                    if rangeEnd > startLine.location && nsString.character(at: rangeEnd - 1) == 0x0A {
                        rangeEnd -= 1
                    }
                    let range = NSRange(location: startLine.location, length: rangeEnd - startLine.location)
                    if range.length > 0 {
                        parent.vimEngine.register = linewiseRegister(nsString.substring(with: range))
                        textView.setSelectedRange(range)
                        textView.delete(nil)
                    }
                } else {
                    let start = min(cursorPos, target)
                    var end = max(cursorPos, target)
                    // Inclusive motions take the character under the target —
                    // but never a newline (e.g. $ on an empty line resolves to
                    // the line start, which holds the \n).
                    if motion.isInclusive && end < length && nsString.character(at: end) != 0x0A { end += 1 }
                    if start < end {
                        let range = NSRange(location: start, length: end - start)
                        parent.vimEngine.register = nsString.substring(with: range)
                        textView.setSelectedRange(range)
                        textView.delete(nil)
                    }
                }
                textView.updateCursorAppearance(isBlock: false)
                if !isReplayingDot {
                    insertModeStartContent = textView.string
                    insertModeStartPos = textView.selectedRange().location
                }

            case .yankLine:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                parent.vimEngine.register = linewiseRegister(nsString.substring(with: lineRange))
                parent.vimEngine.statusMessage = "1 line yanked"
                flashYankHighlight(range: lineRange, in: textView)

            case .yankLines(let count):
                let range = lineRangeForCount(from: cursorPos, count: max(1, count), in: nsString)
                if range.length > 0 {
                    parent.vimEngine.register = linewiseRegister(nsString.substring(with: range))
                    parent.vimEngine.statusMessage = "\(max(1, count)) line(s) yanked"
                    flashYankHighlight(range: range, in: textView)
                }

            case .yankMotion(let motion, let count):
                let target = resolveMotionNTimes(motion, count: count, in: textView)
                if motion.isLinewise {
                    let startLine = nsString.lineRange(for: NSRange(location: min(cursorPos, target), length: 0))
                    let endLine = nsString.lineRange(for: NSRange(location: max(cursorPos, target), length: 0))
                    let range = NSRange(location: startLine.location, length: NSMaxRange(endLine) - startLine.location)
                    if range.length > 0 {
                        parent.vimEngine.register = linewiseRegister(nsString.substring(with: range))
                        parent.vimEngine.statusMessage = "Yanked"
                        flashYankHighlight(range: range, in: textView)
                    }
                } else {
                    let start = min(cursorPos, target)
                    var end = max(cursorPos, target)
                    // Inclusive motions take the character under the target —
                    // but never a newline (e.g. $ on an empty line resolves to
                    // the line start, which holds the \n).
                    if motion.isInclusive && end < length && nsString.character(at: end) != 0x0A { end += 1 }
                    if start < end {
                        let range = NSRange(location: start, length: end - start)
                        parent.vimEngine.register = nsString.substring(with: range)
                        parent.vimEngine.statusMessage = "Yanked"
                        flashYankHighlight(range: range, in: textView)
                    }
                }

            case .pasteAfter:
                let reg = pasteContent()
                guard !reg.isEmpty else { break }
                if reg.hasSuffix("\n") {
                    let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                    let lineEnd = lineRange.location + lineRange.length
                    let lineHasNewline = lineEnd > 0 && nsString.character(at: lineEnd - 1) == 0x0A
                    if lineHasNewline {
                        textView.setSelectedRange(NSRange(location: lineEnd, length: 0))
                        textView.insertText(reg, replacementRange: NSRange(location: lineEnd, length: 0))
                        textView.setSelectedRange(NSRange(location: lineEnd, length: 0))
                    } else {
                        // Last line has no trailing newline of its own — open a new
                        // line below it instead of concatenating onto it (drop the
                        // register's trailing \n, prepend one to start the new line).
                        let body = String(reg.dropLast())
                        textView.setSelectedRange(NSRange(location: lineEnd, length: 0))
                        textView.insertText("\n" + body, replacementRange: NSRange(location: lineEnd, length: 0))
                        textView.setSelectedRange(NSRange(location: min(lineEnd + 1, (textView.string as NSString).length), length: 0))
                    }
                } else {
                    let insertPos = min(cursorPos + 1, length)
                    textView.setSelectedRange(NSRange(location: insertPos, length: 0))
                    textView.insertText(reg, replacementRange: NSRange(location: insertPos, length: 0))
                }

            case .pasteBefore:
                let reg = pasteContent()
                guard !reg.isEmpty else { break }
                if reg.hasSuffix("\n") {
                    let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                    textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                    textView.insertText(reg, replacementRange: NSRange(location: lineRange.location, length: 0))
                    textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                } else {
                    textView.insertText(reg, replacementRange: NSRange(location: cursorPos, length: 0))
                }

            case .joinLines:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                let lineEnd = lineRange.location + lineRange.length
                if lineEnd < length {
                    let nextLineRange = nsString.lineRange(for: NSRange(location: lineEnd, length: 0))
                    let nextLine = nsString.substring(with: nextLineRange)
                    let trimmed = nextLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    let joinEnd = lineEnd > 0 && nsString.character(at: lineEnd - 1) == 0x0A ? lineEnd - 1 : lineEnd
                    // Replace from just before this line's newline through the end
                    // of the next line's *content* (its own trailing newline, if
                    // any, must survive). Using nextLineRange.length directly is one
                    // short on the file's last line — which has no trailing newline
                    // — and strands its final character ("ab\ncd" → "ab cdd").
                    let nextLineEnd = nextLineRange.location + nextLineRange.length
                    let nextContentEnd = nextLineEnd > nextLineRange.location
                        && nsString.character(at: nextLineEnd - 1) == 0x0A ? nextLineEnd - 1 : nextLineEnd
                    let replaceRange = NSRange(location: joinEnd, length: nextContentEnd - joinEnd)
                    textView.setSelectedRange(replaceRange)
                    textView.insertText(" " + trimmed, replacementRange: replaceRange)
                }

            case .undo:
                textView.undoManager?.undo()

            case .redo:
                textView.undoManager?.redo()

            case .indent:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                textView.insertText("    ", replacementRange: NSRange(location: lineRange.location, length: 0))

            case .outdent:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                let lineText = nsString.substring(with: lineRange)
                var removeCount = 0
                for ch in lineText {
                    if ch == " " && removeCount < 4 {
                        removeCount += 1
                    } else if ch == "\t" && removeCount == 0 {
                        removeCount = 1
                        break
                    } else {
                        break
                    }
                }
                if removeCount > 0 {
                    let removeRange = NSRange(location: lineRange.location, length: removeCount)
                    textView.setSelectedRange(removeRange)
                    textView.delete(nil)
                }

            case .indentLines(let count):
                let range = lineRangeForCount(from: cursorPos, count: max(1, count), in: nsString)
                indentLineRange(range, in: textView)
                textView.setSelectedRange(NSRange(location: range.location, length: 0))

            case .outdentLines(let count):
                let range = lineRangeForCount(from: cursorPos, count: max(1, count), in: nsString)
                outdentLineRange(range, in: textView)
                textView.setSelectedRange(NSRange(location: range.location, length: 0))

            case .searchForward, .searchBackward:
                break

            case .searchExecute(let term, let forward):
                let matches = textView.highlightAllMatches(term: term)
                searchAndMoveCursor(term: term, forward: forward, matches: matches, in: textView)
                scheduleSearchHighlightClear(for: textView)

            case .nextMatch:
                let term = parent.vimEngine.searchTerm
                guard !term.isEmpty else { break }
                let matches = textView.highlightAllMatches(term: term)
                searchAndMoveCursor(term: term, forward: parent.vimEngine.searchForwardDirection, matches: matches, in: textView)
                parent.vimEngine.statusMessage = "/\(term)"
                scheduleSearchHighlightClear(for: textView)

            case .previousMatch:
                let term = parent.vimEngine.searchTerm
                guard !term.isEmpty else { break }
                let matches = textView.highlightAllMatches(term: term)
                searchAndMoveCursor(term: term, forward: !parent.vimEngine.searchForwardDirection, matches: matches, in: textView)
                parent.vimEngine.statusMessage = "?\(term)"
                scheduleSearchHighlightClear(for: textView)

            case .searchWordUnderCursor(let forward):
                guard let word = wordUnderCursor(in: textView), !word.isEmpty else {
                    parent.vimEngine.statusMessage = "No word under cursor"
                    break
                }
                // Seed the search register so n / N continue this search in
                // the same direction (n = forward after *, backward after #).
                parent.vimEngine.searchTerm = word
                parent.vimEngine.searchForwardDirection = forward
                let matches = textView.highlightAllMatches(term: word)
                searchAndMoveCursor(term: word, forward: forward, matches: matches, in: textView)
                parent.vimEngine.statusMessage = (forward ? "/" : "?") + word
                scheduleSearchHighlightClear(for: textView)

            case .goToLine(let line):
                let string = textView.string
                var lineCount = 0
                var currentIdx = string.startIndex

                while currentIdx < string.endIndex && lineCount < line - 1 {
                    let lineRange = string.lineRange(for: currentIdx..<currentIdx)
                    currentIdx = lineRange.upperBound
                    lineCount += 1
                }

                // Land on the line's first non-blank, like Vim's G/gg/:N.
                let target = MotionResolver.firstNonBlankOffset(ofLineAt: currentIdx.utf16Offset(in: string), in: nsString)
                if isVisual {
                    // Extend the active selection to the target instead of
                    // collapsing it to a caret (`V5G`, `v3G`, `v2gg`).
                    visualCursorPos = target
                    if engine.mode == .visualBlock {
                        updateBlockSelection(in: textView)
                    } else {
                        updateVisualSelection(cursorAt: target, in: textView)
                    }
                } else {
                    textView.setSelectedRange(NSRange(location: target, length: 0))
                }
                textView.scrollRangeToVisible(NSRange(location: target, length: 0))

            case .save:
                parent.onSave?()

            case .quit:
                break

            case .visualDelete:
                textView.visualCursorOverride = nil
                if wasInBlockMode && !lastBlockRanges.isEmpty {
                    let ranges = lastBlockRanges
                    clearBlockHighlights(in: textView)
                    var yanked = ""
                    var deletedOffset = 0
                    for range in ranges {
                        let adjusted = NSRange(location: range.location - deletedOffset, length: range.length)
                        let currentStr = textView.string as NSString
                        yanked += currentStr.substring(with: adjusted) + "\n"
                        textView.setSelectedRange(adjusted)
                        textView.delete(nil)
                        deletedOffset += range.length
                    }
                    parent.vimEngine.register = yanked
                    parent.vimEngine.statusMessage = "\(ranges.count) lines block deleted"
                    wasInBlockMode = false
                } else {
                    clearBlockHighlights(in: textView)
                    let sel = textView.selectedRange()
                    if sel.length > 0 {
                        parent.vimEngine.register = nsString.substring(with: sel)
                        textView.setSelectedRange(sel)
                        textView.delete(nil)
                        parent.vimEngine.statusMessage = "\(sel.length) chars deleted"
                    }
                }
                textView.updateCursorAppearance(isBlock: true)

            case .visualYank:
                textView.visualCursorOverride = nil
                if wasInBlockMode && !lastBlockRanges.isEmpty {
                    let ranges = lastBlockRanges
                    clearBlockHighlights(in: textView)
                    var yanked = ""
                    for range in ranges {
                        yanked += nsString.substring(with: range) + "\n"
                    }
                    parent.vimEngine.register = yanked
                    parent.vimEngine.statusMessage = "\(ranges.count) lines block yanked"
                    wasInBlockMode = false
                } else {
                    clearBlockHighlights(in: textView)
                    let sel = textView.selectedRange()
                    if sel.length > 0 {
                        parent.vimEngine.register = nsString.substring(with: sel)
                        parent.vimEngine.statusMessage = "\(sel.length) chars yanked"
                        flashYankHighlight(range: sel, in: textView)
                    }
                    textView.setSelectedRange(NSRange(location: sel.location, length: 0))
                }
                textView.updateCursorAppearance(isBlock: true)

            case .visualChange:
                textView.visualCursorOverride = nil
                if wasInBlockMode && !lastBlockRanges.isEmpty {
                    let ranges = lastBlockRanges
                    clearBlockHighlights(in: textView)
                    var yanked = ""
                    var deletedOffset = 0
                    for range in ranges {
                        let adjusted = NSRange(location: range.location - deletedOffset, length: range.length)
                        let currentStr = textView.string as NSString
                        yanked += currentStr.substring(with: adjusted) + "\n"
                        textView.setSelectedRange(adjusted)
                        textView.delete(nil)
                        deletedOffset += range.length
                    }
                    parent.vimEngine.register = yanked
                    wasInBlockMode = false
                } else {
                    clearBlockHighlights(in: textView)
                    let sel = textView.selectedRange()
                    if sel.length > 0 {
                        parent.vimEngine.register = nsString.substring(with: sel)
                        textView.setSelectedRange(sel)
                        textView.delete(nil)
                    }
                }
                textView.updateCursorAppearance(isBlock: false)

            case .visualPaste(let linewise):
                textView.visualCursorOverride = nil
                clearBlockHighlights(in: textView)
                wasInBlockMode = false
                let sel = textView.selectedRange()
                var reg = pasteContent()
                if !reg.isEmpty && sel.length > 0 {
                    if linewise {
                        // V-LINE selections include the trailing newline; keep
                        // the paste linewise so the replaced lines stay lines.
                        if !reg.hasSuffix("\n") { reg += "\n" }
                    } else if reg.hasSuffix("\n") {
                        // A linewise register pasted over a charwise selection
                        // is inserted inline (drop the register's newline).
                        reg.removeLast()
                    }
                    textView.insertText(reg, replacementRange: sel)
                    let ns = textView.string as NSString
                    textView.setSelectedRange(NSRange(location: min(sel.location, max(ns.length - 1, 0)), length: 0))
                } else {
                    textView.setSelectedRange(NSRange(location: sel.location, length: 0))
                }
                textView.updateCursorAppearance(isBlock: true)

            case .visualIndent:
                let sel = textView.selectedRange()
                let lineRange = nsString.lineRange(for: sel)
                var offset = 0
                var pos = lineRange.location
                while pos < lineRange.location + lineRange.length + offset {
                    let currentNsString = textView.string as NSString
                    let lr = currentNsString.lineRange(for: NSRange(location: pos, length: 0))
                    textView.insertText("    ", replacementRange: NSRange(location: lr.location, length: 0))
                    offset += 4
                    pos = lr.location + lr.length + 4
                }
                textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                textView.updateCursorAppearance(isBlock: true)

            case .visualOutdent:
                let sel = textView.selectedRange()
                let lineRange = nsString.lineRange(for: sel)
                var pos = lineRange.location
                while pos < NSMaxRange(lineRange) {
                    let currentNsString = textView.string as NSString
                    let lr = currentNsString.lineRange(for: NSRange(location: min(pos, currentNsString.length - 1), length: 0))
                    let lineText = currentNsString.substring(with: lr)
                    var removeCount = 0
                    for ch in lineText {
                        if ch == " " && removeCount < 4 { removeCount += 1 }
                        else if ch == "\t" && removeCount == 0 { removeCount = 1; break }
                        else { break }
                    }
                    if removeCount > 0 {
                        textView.setSelectedRange(NSRange(location: lr.location, length: removeCount))
                        textView.delete(nil)
                    }
                    let newNsString = textView.string as NSString
                    let newLr = newNsString.lineRange(for: NSRange(location: min(lr.location, newNsString.length - 1), length: 0))
                    pos = newLr.location + newLr.length
                }
                textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                textView.updateCursorAppearance(isBlock: true)

            case .visualBlockInsert:
                textView.visualCursorOverride = nil
                if !lastBlockRanges.isEmpty {
                    let firstRange = lastBlockRanges[0]
                    let ns = textView.string as NSString
                    blockInsertColumn = columnForPosition(firstRange.location, in: ns)
                    blockInsertFirstLineStart = ns.lineRange(for: NSRange(location: firstRange.location, length: 0)).location
                    blockInsertLineCount = lastBlockRanges.count
                    blockInsertStartPos = firstRange.location
                    blockInsertIsAppend = false
                    wasInBlockMode = true
                    textView.setSelectedRange(NSRange(location: firstRange.location, length: 0))
                }
                clearBlockHighlights(in: textView)
                textView.updateCursorAppearance(isBlock: false)

            case .visualBlockAppend:
                textView.visualCursorOverride = nil
                if !lastBlockRanges.isEmpty {
                    let firstRange = lastBlockRanges[0]
                    let ns = textView.string as NSString
                    blockInsertColumn = columnForPosition(firstRange.location + firstRange.length, in: ns)
                    blockInsertFirstLineStart = ns.lineRange(for: NSRange(location: firstRange.location, length: 0)).location
                    blockInsertLineCount = lastBlockRanges.count
                    let insertPos = firstRange.location + firstRange.length
                    blockInsertStartPos = insertPos
                    blockInsertIsAppend = true
                    wasInBlockMode = true
                    textView.setSelectedRange(NSRange(location: insertPos, length: 0))
                }
                clearBlockHighlights(in: textView)
                textView.updateCursorAppearance(isBlock: false)

            case .deleteTextObject(let textObj):
                let cursorPos = textView.selectedRange().location
                let nsStr = textView.string as NSString
                if let range = resolveTextObject(textObj, at: cursorPos, in: nsStr) {
                    parent.vimEngine.register = nsStr.substring(with: range)
                    textView.setSelectedRange(range)
                    textView.delete(nil)
                    let newPos = min(range.location, (textView.string as NSString).length - 1)
                    textView.setSelectedRange(NSRange(location: max(newPos, 0), length: 0))
                    textView.updateCursorAppearance(isBlock: true)
                }

            case .changeTextObject(let textObj):
                let cursorPos = textView.selectedRange().location
                let nsStr = textView.string as NSString
                if let range = resolveTextObject(textObj, at: cursorPos, in: nsStr) {
                    parent.vimEngine.register = nsStr.substring(with: range)
                    textView.setSelectedRange(range)
                    textView.delete(nil)
                    textView.updateCursorAppearance(isBlock: false)
                    if !isReplayingDot {
                        insertModeStartContent = textView.string
                        insertModeStartPos = textView.selectedRange().location
                    }
                }

            case .yankTextObject(let textObj):
                let cursorPos = textView.selectedRange().location
                let nsStr = textView.string as NSString
                if let range = resolveTextObject(textObj, at: cursorPos, in: nsStr) {
                    parent.vimEngine.register = nsStr.substring(with: range)
                    parent.vimEngine.statusMessage = "Yanked"
                    flashYankHighlight(range: range, in: textView)
                }

            case .visualSwapAnchor:
                let oldAnchor = visualAnchor
                let oldCursor = visualCursorPos
                visualAnchor = oldCursor
                visualCursorPos = oldAnchor
                textView.visualCursorOverride = visualCursorPos
                if engine.mode == .visualBlock {
                    updateBlockSelection(in: textView)
                } else {
                    updateVisualSelection(cursorAt: visualCursorPos, in: textView)
                }

            case .visualSelectTextObject(let textObj):
                let pos = isVisual ? visualCursorPos : textView.selectedRange().location
                let nsStr = textView.string as NSString
                if let range = resolveTextObject(textObj, at: pos, in: nsStr) {
                    visualAnchor = range.location
                    visualCursorPos = range.location + range.length - 1
                    textView.setSelectedRange(range)
                    textView.scrollRangeToVisible(range)
                }

            case .substitute(let pattern, let replacement, let isEntireDocument, let isGlobalReplace, let isCaseInsensitive):
                let string = textView.string
                let nsString = string as NSString
                let length = nsString.length
                
                let targetRange: NSRange
                if isEntireDocument {
                    targetRange = NSRange(location: 0, length: length)
                } else {
                    targetRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                }
                
                let targetText = nsString.substring(with: targetRange)
                
                var options: NSRegularExpression.Options = []
                if isCaseInsensitive {
                    options.insert(.caseInsensitive)
                }
                
                guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
                    parent.vimEngine.statusMessage = "Invalid regex pattern: \(pattern)"
                    break
                }
                
                let matches = regex.matches(in: targetText, options: [], range: NSRange(location: 0, length: (targetText as NSString).length))
                guard !matches.isEmpty else {
                    parent.vimEngine.statusMessage = "Pattern not found: \(pattern)"
                    break
                }
                
                var newText = targetText
                var offset = 0
                var replaceCount = 0
                
                for match in matches {
                    if !isGlobalReplace && replaceCount > 0 {
                        break
                    }
                    
                    let matchRange = NSRange(location: match.range.location + offset, length: match.range.length)
                    let matchResult = regex.replacementString(for: match, in: newText, offset: offset, template: replacement)
                    
                    let nsNewText = newText as NSString
                    newText = nsNewText.replacingCharacters(in: matchRange, with: matchResult)
                    
                    offset += (matchResult as NSString).length - matchRange.length
                    replaceCount += 1
                }
                
                textView.setSelectedRange(targetRange)
                textView.insertText(newText, replacementRange: targetRange)
                textView.setSelectedRange(NSRange(location: targetRange.location, length: 0))
                parent.vimEngine.statusMessage = "Replaced \(replaceCount) occurrence(s)"

            case .changeCaseMotion(let motion, let count, let upper):
                let target = resolveMotionNTimes(motion, count: count, in: textView)
                let range: NSRange
                if motion.isLinewise {
                    let startLine = nsString.lineRange(for: NSRange(location: min(cursorPos, target), length: 0))
                    let endLine = nsString.lineRange(for: NSRange(location: max(cursorPos, target), length: 0))
                    range = NSRange(location: startLine.location, length: NSMaxRange(endLine) - startLine.location)
                } else {
                    let start = min(cursorPos, target)
                    var end = max(cursorPos, target)
                    // Inclusive motions take the character under the target —
                    // but never a newline (e.g. $ on an empty line resolves to
                    // the line start, which holds the \n).
                    if motion.isInclusive && end < length && nsString.character(at: end) != 0x0A { end += 1 }
                    range = NSRange(location: start, length: end - start)
                }
                applyCaseChange(in: range, upper: upper, cursorTo: range.location, in: textView)

            case .changeCaseLines(let count, let upper):
                let range = lineRangeForCount(from: cursorPos, count: max(1, count), in: nsString)
                applyCaseChange(in: range, upper: upper, cursorTo: cursorPos, in: textView)

            case .visualChangeCase(let upper):
                textView.visualCursorOverride = nil
                clearBlockHighlights(in: textView)
                wasInBlockMode = false
                let sel = textView.selectedRange()
                if sel.length > 0 {
                    applyCaseChange(in: sel, upper: upper, cursorTo: sel.location, in: textView)
                } else {
                    textView.setSelectedRange(NSRange(location: sel.location, length: 0))
                }
                textView.updateCursorAppearance(isBlock: true)

            case .setMark(let ch):
                marks[ch] = cursorPos

            case .jumpToMark(let ch, let exact):
                guard let stored = marks[ch] else {
                    parent.vimEngine.statusMessage = "Mark `\(ch)` not set"
                    break
                }
                let clamped = min(stored, max(length - 1, 0))
                var target = clamped
                if !exact {
                    let lineRange = nsString.lineRange(for: NSRange(location: clamped, length: 0))
                    let lineText = nsString.substring(with: lineRange)
                    let indent = lineText.prefix(while: { $0 == " " || $0 == "\t" })
                    target = lineRange.location + indent.count
                }
                textView.setSelectedRange(NSRange(location: target, length: 0))
                textView.scrollRangeToVisible(NSRange(location: target, length: 0))

            case .clearSearchHighlight:
                searchHighlightTimer?.cancel()
                textView.clearSearchHighlights()

            case .openLinkUnderCursor:
                if let hit = textView.link(at: cursorPos) {
                    textView.openLink(hit.url)
                } else {
                    parent.vimEngine.statusMessage = "No link under cursor"
                }

            case .centerCursor(let alignment):
                scrollCursorToPosition(alignment: alignment, in: textView)
            }
        }

        /// Replaces `range` with its upper/lowercased text and parks the
        /// cursor at `cursorTo` (clamped). Uses `insertText` so the change is
        /// undoable, matching how `~` (toggleCase) is implemented.
        private func applyCaseChange(in range: NSRange, upper: Bool, cursorTo: Int, in textView: VimNSTextView) {
            let nsString = textView.string as NSString
            let safe = NSIntersectionRange(range, NSRange(location: 0, length: nsString.length))
            guard safe.length > 0 else { return }
            let text = nsString.substring(with: safe)
            let changed = upper ? text.uppercased() : text.lowercased()
            if changed != text {
                textView.insertText(changed, replacementRange: safe)
            }
            let newLength = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(cursorTo, max(newLength - 1, 0)), length: 0))
        }

        private func resolveTextObject(_ textObject: TextObject, at pos: Int, in nsString: NSString) -> NSRange? {
            let length = nsString.length
            guard pos < length else { return nil }

            switch textObject {
            case .inner(let type):
                return findTextObjectRange(type: type, at: pos, in: nsString, inner: true)
            case .around(let type):
                return findTextObjectRange(type: type, at: pos, in: nsString, inner: false)
            }
        }

        private func findTextObjectRange(type: TextObjectType, at pos: Int, in nsString: NSString, inner: Bool) -> NSRange? {
            let string = nsString as String

            switch type {
            case .doubleQuote:
                return findQuoteRange(quote: "\"", at: pos, in: nsString, inner: inner)
            case .singleQuote:
                return findQuoteRange(quote: "'", at: pos, in: nsString, inner: inner)
            case .backtick:
                return findQuoteRange(quote: "`", at: pos, in: nsString, inner: inner)
            case .paren:
                return findPairRange(open: "(", close: ")", at: pos, in: nsString, inner: inner)
            case .bracket:
                return findPairRange(open: "[", close: "]", at: pos, in: nsString, inner: inner)
            case .brace:
                return findPairRange(open: "{", close: "}", at: pos, in: nsString, inner: inner)
            case .angleBracket:
                return findPairRange(open: "<", close: ">", at: pos, in: nsString, inner: inner)
            case .word:
                return findWordObject(at: pos, in: string, inner: inner, bigWord: false)
            case .bigWord:
                return findWordObject(at: pos, in: string, inner: inner, bigWord: true)
            case .paragraph:
                return findParagraphObject(at: pos, in: nsString, inner: inner)
            case .tag:
                return nil
            }
        }

        private func findQuoteRange(quote: String, at pos: Int, in nsString: NSString, inner: Bool) -> NSRange? {
            let string = nsString as String
            guard pos < string.utf16.count else { return nil }
            let posIdx = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
            let lineRange = string.lineRange(for: posIdx..<posIdx)
            let quoteChar = quote.first!
            
            var quoteIndices: [String.Index] = []
            var i = lineRange.lowerBound
            while i < lineRange.upperBound {
                if string[i] == quoteChar {
                    if i > lineRange.lowerBound {
                        let prevIdx = string.index(before: i)
                        if string[prevIdx] == "\\" {
                            i = string.index(after: i)
                            continue
                        }
                    }
                    quoteIndices.append(i)
                }
                i = string.index(after: i)
            }
            
            guard quoteIndices.count >= 2 else { return nil }
            
            var openIdx: String.Index?
            var closeIdx: String.Index?
            
            for j in stride(from: 0, to: quoteIndices.count - 1, by: 2) {
                let open = quoteIndices[j]
                let close = quoteIndices[j + 1]
                if posIdx >= open && posIdx <= close {
                    openIdx = open
                    closeIdx = close
                    break
                }
            }
            
            if openIdx == nil {
                for j in stride(from: 0, to: quoteIndices.count - 1, by: 2) {
                    if quoteIndices[j] > posIdx {
                        openIdx = quoteIndices[j]
                        closeIdx = quoteIndices[j + 1]
                        break
                    }
                }
            }
            
            guard let open = openIdx, let close = closeIdx else { return nil }
            
            if inner {
                let start = string.index(after: open)
                return start < close ? NSRange(start..<close, in: string) : nil
            } else {
                let end = string.index(after: close)
                return NSRange(open..<end, in: string)
            }
        }

        private func findPairRange(open: String, close: String, at pos: Int, in nsString: NSString, inner: Bool) -> NSRange? {
            let string = nsString as String
            let length = string.utf16.count
            guard pos < length else { return nil }
            
            let openChar = open.first!
            let closeChar = close.first!
            let posIdx = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
            
            if string[posIdx] == openChar {
                if let closeIdx = findMatchingClose(openChar: openChar, closeChar: closeChar, from: posIdx, in: string) {
                    return makePairResult(open: posIdx, close: closeIdx, inner: inner, in: string)
                }
                return nil
            }
            
            if string[posIdx] == closeChar {
                if let openIdx = findMatchingOpen(openChar: openChar, closeChar: closeChar, from: posIdx, in: string) {
                    return makePairResult(open: openIdx, close: posIdx, inner: inner, in: string)
                }
                return nil
            }
            
            if let result = findEnclosingPair(openChar: openChar, closeChar: closeChar, at: posIdx, in: string, inner: inner) {
                return result
            }
            
            let lineRange = string.lineRange(for: posIdx..<posIdx)
            var searchIdx = string.index(after: posIdx)
            while searchIdx < lineRange.upperBound {
                if string[searchIdx] == openChar {
                    if let closeIdx = findMatchingClose(openChar: openChar, closeChar: closeChar, from: searchIdx, in: string) {
                        return makePairResult(open: searchIdx, close: closeIdx, inner: inner, in: string)
                    }
                    return nil
                }
                searchIdx = string.index(after: searchIdx)
            }
            
            return nil
        }

        private func findMatchingClose(openChar: Character, closeChar: Character, from openIdx: String.Index, in string: String) -> String.Index? {
            var depth = 1
            var i = string.index(after: openIdx)
            while i < string.endIndex {
                let c = string[i]
                if c == openChar { depth += 1 }
                if c == closeChar {
                    depth -= 1
                    if depth == 0 { return i }
                }
                i = string.index(after: i)
            }
            return nil
        }

        private func findMatchingOpen(openChar: Character, closeChar: Character, from closeIdx: String.Index, in string: String) -> String.Index? {
            var depth = 1
            var i = closeIdx
            while i > string.startIndex {
                i = string.index(before: i)
                let c = string[i]
                if c == closeChar { depth += 1 }
                if c == openChar {
                    depth -= 1
                    if depth == 0 { return i }
                }
            }
            return nil
        }

        private func findEnclosingPair(openChar: Character, closeChar: Character, at posIdx: String.Index, in string: String, inner: Bool) -> NSRange? {
            var depth = 0
            var i = posIdx
            while i > string.startIndex {
                i = string.index(before: i)
                let c = string[i]
                if c == closeChar { depth += 1 }
                if c == openChar {
                    if depth == 0 {
                        if let closeIdx = findMatchingClose(openChar: openChar, closeChar: closeChar, from: i, in: string) {
                            if closeIdx >= posIdx {
                                return makePairResult(open: i, close: closeIdx, inner: inner, in: string)
                            }
                        }
                        return nil
                    }
                    depth -= 1
                }
            }
            return nil
        }

        private func makePairResult(open: String.Index, close: String.Index, inner: Bool, in string: String) -> NSRange? {
            if inner {
                let start = string.index(after: open)
                return start <= close ? NSRange(start..<close, in: string) : nil
            } else {
                let end = string.index(after: close)
                return NSRange(open..<end, in: string)
            }
        }

        private func pasteContent() -> String {
            // The system clipboard is the source of truth: Vim yanks sync to it
            // (see VimEngine.register), and so do ⌘C and the code-block copy button.
            if let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty {
                return clip
            }
            return parent.vimEngine.register
        }

        private func findWordObject(at pos: Int, in string: String, inner: Bool, bigWord: Bool) -> NSRange? {
            guard pos < string.utf16.count else { return nil }
            let startIdx = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
            
            let isWordChar: (Character) -> Bool = bigWord
                ? { !$0.isWhitespace && !$0.isNewline }
                : { $0.isLetter || $0.isNumber || $0 == "_" }
                
            let onWord = isWordChar(string[startIdx])
            
            var start = startIdx
            while start > string.startIndex {
                let prev = string.index(before: start)
                if isWordChar(string[prev]) == onWord {
                    start = prev
                } else {
                    break
                }
            }
            
            var end = startIdx
            while end < string.endIndex {
                let next = string.index(after: end)
                if next < string.endIndex && isWordChar(string[next]) == onWord {
                    end = next
                } else {
                    break
                }
            }
            
            if !inner && onWord {
                var next = string.index(after: end)
                while next < string.endIndex && string[next].isWhitespace && !string[next].isNewline {
                    end = next
                    next = string.index(after: next)
                }
            }
            
            let startOffset = start.utf16Offset(in: string)
            let endOffset = end.utf16Offset(in: string)
            return NSRange(location: startOffset, length: endOffset - startOffset + 1)
        }

        private func findParagraphObject(at pos: Int, in nsString: NSString, inner: Bool) -> NSRange? {
            let length = nsString.length
            guard length > 0 else { return nil }

            var start = pos
            while start > 0 {
                if nsString.character(at: start - 1) == 0x0A {
                    if start >= 2 && nsString.character(at: start - 2) == 0x0A { break }
                    else if start == 1 { break }
                }
                start -= 1
            }

            var end = pos
            while end < length {
                if nsString.character(at: end) == 0x0A {
                    if end + 1 < length && nsString.character(at: end + 1) == 0x0A {
                        if !inner { end += 1 }
                        break
                    }
                }
                end += 1
            }
            if end >= length { end = length - 1 }

            return NSRange(location: start, length: end - start + 1)
        }

        private func scrollCursorToPosition(alignment: CenteringAlignment, in textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer,
                  let scrollView = textView.enclosingScrollView else { return }
            
            let cursorPos = textView.selectedRange().location
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: cursorPos, length: 0), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            
            let viewHeight = scrollView.contentSize.height
            let targetY: CGFloat
            
            switch alignment {
            case .center:
                targetY = rect.midY - (viewHeight / 2)
            case .top:
                targetY = rect.minY - 20
            case .bottom:
                targetY = rect.maxY - viewHeight + 20
            }
            
            let clampedY = max(0, min(targetY, textView.bounds.height - viewHeight))
            scrollView.contentView.bounds.origin.y = clampedY
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func flashYankHighlight(range: NSRange, in textView: VimNSTextView) {
            yankHighlightLayer?.removeFromSuperlayer()

            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

            var highlightRect = rect
            highlightRect.origin.x += textView.textContainerOrigin.x
            highlightRect.origin.y += textView.textContainerOrigin.y

            let layer = CALayer()
            layer.frame = highlightRect
            layer.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.35).cgColor
            layer.cornerRadius = 2

            textView.wantsLayer = true
            textView.layer?.addSublayer(layer)
            yankHighlightLayer = layer

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                layer.removeFromSuperlayer()
                if self?.yankHighlightLayer === layer {
                    self?.yankHighlightLayer = nil
                }
            }
        }

        private func scheduleSearchHighlightClear(for textView: VimNSTextView) {
            searchHighlightTimer?.cancel()
            let work = DispatchWorkItem { [weak textView] in
                textView?.clearSearchHighlights()
            }
            searchHighlightTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }

        /// The keyword under the cursor (letters/digits/underscore), used by
        /// `*` / `#`. If the cursor isn't on a keyword char, scans forward on
        /// the current line to the next one (matching Vim). Returns nil if no
        /// word is found before end-of-line.
        private func wordUnderCursor(in textView: VimNSTextView) -> String? {
            VimWordUnderCursor.word(in: textView.string as NSString, at: textView.selectedRange().location)
        }

        /// Moves the cursor to the next/previous match in `matches` (the ranges
        /// `highlightAllMatches` already found — document order), wrapping like
        /// Vim. Sharing the scan means an `n` press costs one pass over the
        /// match list instead of a second fold + scan of the whole document.
        private func searchAndMoveCursor(term: String, forward: Bool, matches: [NSRange], in textView: VimNSTextView) {
            guard !matches.isEmpty else {
                parent.vimEngine.statusMessage = "Pattern not found: \(term.searchFolded)"
                return
            }
            let cursorPos = textView.selectedRange().location
            let found: NSRange
            var wrapped = false
            if forward {
                if let next = matches.first(where: { $0.location > cursorPos }) {
                    found = next
                } else {
                    found = matches[0]
                    wrapped = true
                }
            } else {
                if let prev = matches.last(where: { $0.location < cursorPos }) {
                    found = prev
                } else {
                    found = matches[matches.count - 1]
                    wrapped = true
                }
            }
            textView.setSelectedRange(NSRange(location: found.location, length: 0))
            textView.scrollRangeToVisible(found)
            flashSearchHighlight(range: found, in: textView)
            if wrapped {
                parent.vimEngine.statusMessage = forward
                    ? "search hit BOTTOM, continuing at TOP"
                    : "search hit TOP, continuing at BOTTOM"
            }
        }

        private func flashSearchHighlight(range: NSRange, in textView: VimNSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)

            var highlightRect = rect
            highlightRect.origin.x += textView.textContainerOrigin.x
            highlightRect.origin.y += textView.textContainerOrigin.y

            let layer = CALayer()
            layer.frame = highlightRect
            layer.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.3).cgColor
            layer.cornerRadius = 2
            layer.borderWidth = 1
            layer.borderColor = NSColor.systemOrange.withAlphaComponent(0.6).cgColor

            textView.wantsLayer = true
            textView.layer?.addSublayer(layer)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                layer.removeFromSuperlayer()
            }
        }

        private func updateVisualSelection(cursorAt newPos: Int, in textView: VimNSTextView) {
            let nsString = textView.string as NSString
            let length = nsString.length
            let engine = parent.vimEngine

            textView.visualCursorOverride = newPos

            if engine.mode == .visualLine {
                let anchorLineRange = nsString.lineRange(for: NSRange(location: min(visualAnchor, length - 1), length: 0))
                let cursorLineRange = nsString.lineRange(for: NSRange(location: min(newPos, max(length - 1, 0)), length: 0))
                let selStart = min(anchorLineRange.location, cursorLineRange.location)
                let selEnd = max(NSMaxRange(anchorLineRange), NSMaxRange(cursorLineRange))
                textView.setSelectedRange(NSRange(location: selStart, length: selEnd - selStart))
            } else {
                let anchor = min(visualAnchor, length)
                let cursor = min(newPos, length)
                if cursor >= anchor {
                    let selLen = min(cursor - anchor + 1, length - anchor)
                    textView.setSelectedRange(NSRange(location: anchor, length: max(selLen, 1)))
                } else {
                    textView.setSelectedRange(NSRange(location: cursor, length: anchor - cursor + 1))
                }
            }
        }

        private func columnForPosition(_ pos: Int, in nsString: NSString) -> Int {
            let lineRange = nsString.lineRange(for: NSRange(location: pos, length: 0))
            return pos - lineRange.location
        }

        private func positionForColumn(_ col: Int, inLineAt lineStart: Int, in nsString: NSString) -> Int {
            let lineRange = nsString.lineRange(for: NSRange(location: lineStart, length: 0))
            var lineEnd = lineRange.location + lineRange.length
            if lineEnd > 0 && nsString.character(at: lineEnd - 1) == 0x0A {
                lineEnd -= 1
            }
            let lineLength = lineEnd - lineRange.location
            return lineRange.location + min(col, lineLength)
        }

        private func getBlockRanges(in textView: VimNSTextView) -> [NSRange] {
            return lastBlockRanges
        }

        private func updateBlockSelection(in textView: VimNSTextView) {
            let nsString = textView.string as NSString
            let length = nsString.length
            guard length > 0 else { return }

            let anchorCol = columnForPosition(min(visualAnchor, length - 1), in: nsString)
            let cursorCol = columnForPosition(min(visualCursorPos, length - 1), in: nsString)
            let anchorLineRange = nsString.lineRange(for: NSRange(location: min(visualAnchor, length - 1), length: 0))
            let cursorLineRange = nsString.lineRange(for: NSRange(location: min(visualCursorPos, length - 1), length: 0))

            let startLine = min(anchorLineRange.location, cursorLineRange.location)
            let endLine = max(anchorLineRange.location, cursorLineRange.location)
            let leftCol = min(anchorCol, cursorCol)
            let rightCol = max(anchorCol, cursorCol)

            clearBlockHighlights(in: textView)
            lastBlockRanges = []
            wasInBlockMode = true

            textView.wantsLayer = true
            textView.visualCursorOverride = visualCursorPos

            var lineStart = startLine
            while lineStart <= endLine {
                let lineRange = nsString.lineRange(for: NSRange(location: min(lineStart, length - 1), length: 0))
                var lineEnd = lineRange.location + lineRange.length
                if lineEnd > 0 && lineEnd <= length && nsString.character(at: lineEnd - 1) == 0x0A {
                    lineEnd -= 1
                }
                let lineLength = lineEnd - lineRange.location

                if leftCol < lineLength {
                    let blockStart = lineRange.location + leftCol
                    let blockEnd = lineRange.location + min(rightCol + 1, lineLength)
                    let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
                    lastBlockRanges.append(blockRange)

                    if let layoutManager = textView.layoutManager, let textContainer = textView.textContainer {
                        let glyphRange = layoutManager.glyphRange(forCharacterRange: blockRange, actualCharacterRange: nil)
                        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                        var highlightRect = rect
                        highlightRect.origin.x += textView.textContainerOrigin.x
                        highlightRect.origin.y += textView.textContainerOrigin.y

                        let layer = CALayer()
                        layer.frame = highlightRect
                        layer.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(0.5).cgColor
                        layer.name = "blockHighlight"
                        textView.layer?.addSublayer(layer)
                        blockHighlightLayers.append(layer)
                    }
                } else if leftCol <= lineLength {
                    let blockRange = NSRange(location: lineRange.location + leftCol, length: 0)
                    lastBlockRanges.append(blockRange)
                }

                lineStart = lineRange.location + lineRange.length
                if lineStart == lineRange.location { break }
            }

            textView.setSelectedRange(NSRange(location: visualCursorPos, length: 0))
        }

        private func clearBlockHighlights(in textView: VimNSTextView) {
            for layer in blockHighlightLayers {
                layer.removeFromSuperlayer()
            }
            blockHighlightLayers.removeAll()
        }

        private func handleInsertEntry(_ entry: InsertEntry, in textView: VimNSTextView) {
            let string = textView.string
            let nsString = string as NSString
            let cursorPos = textView.selectedRange().location
            let length = nsString.length

            switch entry {
            case .beforeCursor:
                break

            case .afterCursor:
                if cursorPos < length {
                    textView.setSelectedRange(NSRange(location: cursorPos + 1, length: 0))
                }

            case .lineStart:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                let lineText = nsString.substring(with: lineRange)
                let indent = lineText.prefix(while: { $0 == " " || $0 == "\t" })
                textView.setSelectedRange(NSRange(location: lineRange.location + indent.count, length: 0))

            case .lineEnd:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                var end = lineRange.location + lineRange.length
                if end > 0 && end <= length && nsString.character(at: end - 1) == 0x0A {
                    end -= 1
                }
                textView.setSelectedRange(NSRange(location: end, length: 0))

            case .newLineBelow:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                let lineEnd = lineRange.location + lineRange.length
                let lineText = nsString.substring(with: lineRange)
                let indent = String(lineText.prefix(while: { $0 == " " || $0 == "\t" }))
                let hasNewline = lineEnd > 0 && lineEnd <= length && lineRange.length > 0 && nsString.character(at: lineEnd - 1) == 0x0A
                if hasNewline {
                    let insertPos = lineEnd
                    let newText = indent + "\n"
                    textView.setSelectedRange(NSRange(location: insertPos, length: 0))
                    textView.insertText(newText, replacementRange: NSRange(location: insertPos, length: 0))
                    textView.setSelectedRange(NSRange(location: insertPos + indent.count, length: 0))
                } else {
                    let insertPos = lineEnd
                    let newText = "\n" + indent
                    textView.setSelectedRange(NSRange(location: insertPos, length: 0))
                    textView.insertText(newText, replacementRange: NSRange(location: insertPos, length: 0))
                }

            case .newLineAbove:
                let lineRange = nsString.lineRange(for: NSRange(location: cursorPos, length: 0))
                let lineText = nsString.substring(with: lineRange)
                let indent = String(lineText.prefix(while: { $0 == " " || $0 == "\t" }))
                let newText = indent + "\n"
                textView.setSelectedRange(NSRange(location: lineRange.location, length: 0))
                textView.insertText(newText, replacementRange: NSRange(location: lineRange.location, length: 0))
                textView.setSelectedRange(NSRange(location: lineRange.location + indent.count, length: 0))
            }
        }

        func resolveMotionNTimes(_ motion: Motion, count: Int, in textView: NSTextView) -> Int {
            let nsString = textView.string as NSString
            let cursorPos = textView.selectedRange().location
            if let resolved = MotionResolver.resolve(motion, count: count, from: cursorPos, in: nsString) {
                return resolved
            }
            // Viewport-relative motions (H/M/L) resolve against the live
            // layout and are idempotent under repetition, so a count
            // collapses to a single resolution.
            return resolveMotion(motion, in: textView)
        }

        /// Resolves a motion from the view's current cursor. Buffer motions
        /// delegate to the pure `MotionResolver` (headlessly testable);
        /// only the screen-relative ones read the live layout here.
        func resolveMotion(_ motion: Motion, in textView: NSTextView) -> Int {
            let nsString = textView.string as NSString
            let cursorPos = textView.selectedRange().location
            if let resolved = MotionResolver.resolve(motion, from: cursorPos, in: nsString) {
                return resolved
            }
            switch motion {
            case .screenTop:
                return screenLinePosition(.top, in: textView)
            case .screenMiddle:
                return screenLinePosition(.middle, in: textView)
            case .screenBottom:
                return screenLinePosition(.bottom, in: textView)
            default:
                // Unreachable: MotionResolver covers every buffer motion.
                return cursorPos
            }
        }

        private enum ScreenLine { case top, middle, bottom }

        /// Character offset of the first non-blank on the line at the top,
        /// middle, or bottom of the currently visible area (Vim H / M / L).
        private func screenLinePosition(_ which: ScreenLine, in textView: NSTextView) -> Int {
            let nsString = textView.string as NSString
            let length = nsString.length
            let cursorPos = textView.selectedRange().location
            guard length > 0,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return cursorPos }

            // visibleRect is in view coordinates; the layout manager works in
            // container coordinates, offset by textContainerOrigin.
            let visible = textView.visibleRect
            let origin = textView.textContainerOrigin
            let targetY: CGFloat
            switch which {
            case .top:    targetY = visible.minY + 1
            case .middle: targetY = visible.midY
            case .bottom: targetY = visible.maxY - 1
            }
            let point = CGPoint(x: 1, y: targetY - origin.y)

            let glyphIndex = layoutManager.glyphIndex(for: point, in: textContainer)
            let charIndex = min(max(layoutManager.characterIndexForGlyph(at: glyphIndex), 0), length - 1)

            let lineRange = nsString.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineText = nsString.substring(with: lineRange)
            let indent = lineText.prefix(while: { $0 == " " || $0 == "\t" })
            return min(lineRange.location + indent.count, max(lineRange.location, length - 1))
        }

    }
}
