import SwiftUI
import AppKit

class FindController: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var query: String = ""
    @Published var currentMatch: Int = 0
    @Published var totalMatches: Int = 0
    @Published var focusTrigger: Int = 0

    /// Mirrors whether the find text field has focus, so the key monitor only
    /// hijacks Shift+Return (previous match) while you're typing in find — not
    /// when you're editing the note with the find bar open.
    var isFieldFocused: Bool = false

    var performFind: ((String) -> Void)?
    var findNext: (() -> Void)?
    var findPrev: (() -> Void)?
    var dismiss: (() -> Void)?
    var refocusEditor: (() -> Void)?

    private var eventMonitor: Any?

    func installKeyMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command, event.charactersIgnoringModifiers == "f" {
                self.isVisible = true
                self.focusTrigger += 1
                return nil
            }
            if self.isVisible {
                if flags == .command, event.charactersIgnoringModifiers == "g" {
                    self.findNext?()
                    return nil
                }
                if flags == [.command, .shift], event.charactersIgnoringModifiers == "g" {
                    self.findPrev?()
                    return nil
                }
                // Shift+Return → previous match (Enter → next is the field's
                // onSubmit). keyCode 36 is Return.
                if event.keyCode == 36, flags == .shift, self.isFieldFocused {
                    self.findPrev?()
                    return nil
                }
                if event.keyCode == 53 {
                    self.isVisible = false
                    self.dismiss?()
                    self.query = ""
                    self.currentMatch = 0
                    self.totalMatches = 0
                    self.refocusEditor?()
                    return nil
                }
            }
            return event
        }
    }

    func removeKeyMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    deinit {
        removeKeyMonitor()
    }
}

// MARK: - VimTextView

struct VimTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var rtfData: Data
    @ObservedObject var vimEngine: VimEngine
    var findController: FindController?
    var onSave: (() -> Void)?
    var font: NSFont
    var startInInsertMode: Bool = false
    var backgroundColor: NSColor = .textBackgroundColor
    var textColor: NSColor = .labelColor
    var accentColor: NSColor = .systemOrange
    var paperStyle: String = "plain"
    var smartLists: Bool = true
    var showLineNumbers: Bool = false

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 0
        return style
    }

    private var textContainerInset: NSSize {
        NSSize(width: showLineNumbers ? 22 : 34, height: 20)
    }

    var themeKey: String {
        func component(_ color: NSColor) -> String {
            let c = color.usingColorSpace(.sRGB) ?? color
            return String(format: "%.3f,%.3f,%.3f", c.redComponent, c.greenComponent, c.blueComponent)
        }
        return [backgroundColor, textColor, accentColor].map(component).joined(separator: "|")
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // Overlay (floating) scroller — hides when idle, overlaps content
        scrollView.scrollerStyle = .overlay
        // Slim, soft knob — matches Apple Notes/Finder aesthetic
        scrollView.scrollerKnobStyle = .default
        // Right inset so the scroller floats 12pt from the panel edge
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.scrollerInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        // Vertical scroller subclass for slim capsule rendering
        scrollView.verticalScroller = PremiumScroller()
        // Preserve native momentum / physics
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .automatic

        let textView = VimNSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = true
        textView.backgroundColor = backgroundColor
        textView.drawsBackground = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.textContainerInset = textContainerInset
        textView.selectedTextAttributes = [
            .backgroundColor: accentColor.withAlphaComponent(0.28)
        ]

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true

        textView.insertionPointColor = accentColor
        textView.accentColor = accentColor

        // Set default typing attributes for rich text
        let defaultAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: Self.paragraphStyle()
        ]
        textView.typingAttributes = defaultAttrs

        textView.delegate = context.coordinator
        textView.vimEngine = vimEngine
        textView.coordinator = context.coordinator
        textView.paperStyle = paperStyle
        textView.smartLists = smartLists

        scrollView.documentView = textView
        scrollView.verticalRulerView = LineNumberRulerView(scrollView: scrollView, textView: textView)
        scrollView.hasVerticalRuler = showLineNumbers
        scrollView.rulersVisible = showLineNumbers

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.lastFontSize = font.pointSize
        context.coordinator.lastFontName = font.fontName
        context.coordinator.lastThemeKey = themeKey
        context.coordinator.setupFindController()
        context.coordinator.setupRefocusObserver(for: textView)

        // Load rich text content or fall back to plain text
        if !rtfData.isEmpty, let attrStr = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attrStr)
            textView.applyTextColor(textColor)
        } else {
            let attrStr = NSAttributedString(string: text, attributes: defaultAttrs)
            textView.textStorage?.setAttributedString(attrStr)
        }

        if !rtfData.isEmpty {
            textView.applyBaseFont(font)
        }
        textView.restyleCodeBlocks(baseFont: font)
        textView.renderImageAttachments()
        context.coordinator.lastAppliedText = text

        let isInsert = vimEngine.mode.isEditing || startInInsertMode
        textView.updateCursorAppearance(isBlock: !isInsert)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? VimNSTextView else { return }
        context.coordinator.parent = self

        if !context.coordinator.isUpdatingFromTextView && !context.coordinator.hasUnsyncedEdits && text != context.coordinator.lastAppliedText {
            let selectedRange = textView.selectedRange()
            let defaultAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: Self.paragraphStyle()
            ]
            if !rtfData.isEmpty, let attrStr = NSAttributedString(rtf: rtfData, documentAttributes: nil) {
                textView.textStorage?.setAttributedString(attrStr)
                textView.applyBaseFont(font)
                textView.applyTextColor(textColor)
            } else {
                let attrStr = NSAttributedString(string: text, attributes: defaultAttrs)
                textView.textStorage?.setAttributedString(attrStr)
            }
            textView.restyleCodeBlocks(baseFont: font)
            textView.renderImageAttachments()
            // Clamp against the NSString (UTF-16) length, not String.count
            // (grapheme count) — selectedRange.location is a UTF-16 offset,
            // so mixing the two misplaces the cursor in notes with emoji or
            // combining characters.
            let safeLocation = min(selectedRange.location, (textView.string as NSString).length)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
            context.coordinator.lastAppliedText = text

            // The note's text is now in the view. If a search is pending from a
            // ⌘K open, run it now — deterministically, the instant the content
            // is loaded (regardless of note size), instead of guessing a delay.
            // Deferred one runloop tick so we don't mutate published find state
            // mid view-update.
            if !context.coordinator.didInitialFindOnLoad,
               let fc = findController, fc.isVisible, !fc.query.isEmpty {
                context.coordinator.didInitialFindOnLoad = true
                let pendingQuery = fc.query
                let coordinator = context.coordinator
                DispatchQueue.main.async { coordinator.performFindInEditor(query: pendingQuery) }
            }
        }

        // Re-apply base font/size across the document when it changes (preserving bold/italic)
        if context.coordinator.lastFontSize != font.pointSize || context.coordinator.lastFontName != font.fontName {
            context.coordinator.lastFontSize = font.pointSize
            context.coordinator.lastFontName = font.fontName
            textView.applyBaseFont(font)
            textView.restyleCodeBlocks(baseFont: font)
            var attrs = textView.typingAttributes
            attrs[.font] = font
            textView.typingAttributes = attrs
            scrollView.verticalRulerView?.needsDisplay = true
        }

        if context.coordinator.lastThemeKey != themeKey {
            context.coordinator.lastThemeKey = themeKey
            textView.backgroundColor = backgroundColor
            textView.drawsBackground = (backgroundColor != .clear)
            textView.insertionPointColor = accentColor
            textView.accentColor = accentColor
            textView.selectedTextAttributes = [
                .backgroundColor: accentColor.withAlphaComponent(0.28)
            ]
            textView.applyTextColor(textColor)
            var attrs = textView.typingAttributes
            attrs[.foregroundColor] = textColor
            textView.typingAttributes = attrs
            textView.needsDisplay = true
            scrollView.verticalRulerView?.needsDisplay = true
        }

        if context.coordinator.lastPaperStyle != paperStyle {
            context.coordinator.lastPaperStyle = paperStyle
            textView.paperStyle = paperStyle
            textView.needsDisplay = true
        }

        textView.smartLists = smartLists
        textView.textContainerInset = textContainerInset
        scrollView.hasVerticalRuler = showLineNumbers
        scrollView.rulersVisible = showLineNumbers
        if let ruler = scrollView.verticalRulerView as? LineNumberRulerView {
            ruler.textView = textView
            ruler.needsDisplay = true
        } else {
            scrollView.verticalRulerView = LineNumberRulerView(scrollView: scrollView, textView: textView)
        }

        textView.updateCursorAppearance(isBlock: !vimEngine.mode.isEditing)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VimTextView
        weak var textView: VimNSTextView?
        weak var scrollView: NSScrollView?
        var isUpdatingFromTextView = false
        /// True when the user has typed into the NSTextView but we haven't
        /// yet synced that text back to the SwiftUI binding. While true,
        /// updateNSView must NOT replace the textView's content — the
        /// textView is the source of truth, not the (stale) SwiftUI state.
        var hasUnsyncedEdits = false
        /// Ensures a ⌘K-opened search runs exactly once, the moment the note's
        /// text finishes loading into the view (not on a guessed timer).
        var didInitialFindOnLoad = false
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

            let nsString = textView.string as NSString
            let length = nsString.length
            var searchRange = NSRange(location: 0, length: length)

            while searchRange.location < length {
                let found = nsString.range(of: query, options: [.caseInsensitive], range: searchRange)
                if found.location == NSNotFound { break }
                findMatchRanges.append(found)
                if findMatchRanges.count >= VimNSTextView.maxSearchMatches { break }
                searchRange.location = found.location + found.length
                searchRange.length = length - searchRange.location
            }

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
            // DO NOT update parent.text here. For a 2.9 MB file, copying the
            // entire NSString into a Swift String binding on every keystroke
            // costs ~5-10ms AND triggers a full SwiftUI body re-evaluation
            // (recreating VimTextView, calling updateNSView, diffing state).
            // The NSTextView is the authoritative source of truth while typing.
            // We sync the binding when typing pauses (500ms debounce) or on
            // teardown.
            hasUnsyncedEdits = true
            rtfStale = true
            isUpdatingFromTextView = true
            DispatchQueue.main.async {
                self.isUpdatingFromTextView = false
            }
            scheduleDeferredWork()
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

        private func serializeRTFIfStale() {
            guard rtfStale, let textView = textView else { return }
            isUpdatingFromTextView = true
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                let flattened = ImageAttachments.flattened(textStorage)
                let range = NSRange(location: 0, length: flattened.length)
                if let data = try? flattened.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    parent.rtfData = data
                }
            } else {
                parent.rtfData = Data()
            }
            rtfStale = false
            DispatchQueue.main.async {
                self.isUpdatingFromTextView = false
            }
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

            // Sync text binding — now that typing has paused, push the
            // current text to SwiftUI so onChange/save handlers see it.
            isUpdatingFromTextView = true
            hasUnsyncedEdits = false
            // Serialize image attachments back to portable `![](assets/…)`
            // Markdown so the on-disk content stays plain text.
            var synced = textView.textStorage.map { ImageAttachments.markdownString(from: $0) } ?? textView.string
            synced.makeContiguousUTF8()
            parent.text = synced
            lastAppliedText = synced

            textView.restyleCodeBlocks(baseFont: parent.font)

            DispatchQueue.main.async {
                self.isUpdatingFromTextView = false
            }

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
            guard let textView = textView, let storage = textView.textStorage else { return }
            isUpdatingFromTextView = true
            var synced = ImageAttachments.markdownString(from: storage)
            synced.makeContiguousUTF8()
            parent.text = synced
            lastAppliedText = synced
            if storage.length > 0 {
                let flattened = ImageAttachments.flattened(storage)
                let range = NSRange(location: 0, length: flattened.length)
                if let data = try? flattened.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    parent.rtfData = data
                }
            }
            rtfStale = false
            DispatchQueue.main.async { self.isUpdatingFromTextView = false }
        }

        func formattingDidChange() {
            // Formatting changes (bold/italic/underline toggle) are explicit
            // user actions — serialize RTF immediately so it persists.
            guard let textView = textView else { return }
            isUpdatingFromTextView = true
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                let flattened = ImageAttachments.flattened(textStorage)
                let range = NSRange(location: 0, length: flattened.length)
                if let data = try? flattened.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    parent.rtfData = data
                }
            }
            rtfStale = false
            DispatchQueue.main.async {
                self.isUpdatingFromTextView = false
            }
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

            if !isReplayingDot {
                let isChangeAction = actions.contains { action in
                    switch action {
                    case .insertMode, .deleteMotion, .deleteLine, .deleteLines, .deleteToEnd, .deleteChar,
                         .deleteCharBefore, .changeMotion, .changeLine, .changeLines, .changeToEnd,
                         .deleteTextObject, .changeTextObject, .toggleCase, .joinLines,
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

            for action in actions {
                executeAction(action, in: textView)
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
                handleInsertEntry(entry, in: textView)
                textView.updateCursorAppearance(isBlock: false)
                textView.clearSearchHighlights()
                if !isReplayingDot {
                    insertModeStartContent = textView.string
                    insertModeStartPos = textView.selectedRange().location
                }

            case .normalMode:
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

            case .toggleCase:
                if cursorPos < length {
                    let charRange = NSRange(location: cursorPos, length: 1)
                    let ch = nsString.substring(with: charRange)
                    let toggled = ch == ch.uppercased() ? ch.lowercased() : ch.uppercased()
                    textView.insertText(toggled, replacementRange: charRange)
                    let newPos = min(cursorPos + 1, length - 1)
                    textView.setSelectedRange(NSRange(location: max(newPos, 0), length: 0))
                }

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
                parent.vimEngine.register = lineText
                textView.setSelectedRange(lineRange)
                textView.delete(nil)

            case .deleteLines(let count):
                let range = lineRangeForCount(from: cursorPos, count: max(1, count), in: nsString)
                if range.length > 0 {
                    parent.vimEngine.register = nsString.substring(with: range)
                    textView.setSelectedRange(range)
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
                        parent.vimEngine.register = nsString.substring(with: range)
                        textView.setSelectedRange(range)
                        textView.delete(nil)
                    }
                } else {
                    let start = min(cursorPos, target)
                    var end = max(cursorPos, target)
                    if motion.isInclusive && end < length { end += 1 }
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
                parent.vimEngine.register = nsString.substring(with: contentRange)
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
                    parent.vimEngine.register = nsString.substring(with: range)
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
                        parent.vimEngine.register = nsString.substring(with: range)
                        textView.setSelectedRange(range)
                        textView.delete(nil)
                    }
                } else {
                    let start = min(cursorPos, target)
                    var end = max(cursorPos, target)
                    if motion.isInclusive && end < length { end += 1 }
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
                parent.vimEngine.register = nsString.substring(with: lineRange)
                parent.vimEngine.statusMessage = "1 line yanked"
                flashYankHighlight(range: lineRange, in: textView)

            case .yankLines(let count):
                let range = lineRangeForCount(from: cursorPos, count: max(1, count), in: nsString)
                if range.length > 0 {
                    parent.vimEngine.register = nsString.substring(with: range)
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
                        parent.vimEngine.register = nsString.substring(with: range)
                        parent.vimEngine.statusMessage = "Yanked"
                        flashYankHighlight(range: range, in: textView)
                    }
                } else {
                    let start = min(cursorPos, target)
                    var end = max(cursorPos, target)
                    if motion.isInclusive && end < length { end += 1 }
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
                    let insertPos = lineRange.location + lineRange.length
                    textView.setSelectedRange(NSRange(location: insertPos, length: 0))
                    textView.insertText(reg, replacementRange: NSRange(location: insertPos, length: 0))
                    textView.setSelectedRange(NSRange(location: insertPos, length: 0))
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
                    let replaceRange = NSRange(location: joinEnd, length: nextLineRange.length)
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
                textView.highlightAllMatches(term: term)
                searchAndMoveCursor(term: term, forward: forward, in: textView)
                scheduleSearchHighlightClear(for: textView)

            case .nextMatch:
                let term = parent.vimEngine.searchTerm
                guard !term.isEmpty else { break }
                textView.highlightAllMatches(term: term)
                searchAndMoveCursor(term: term, forward: parent.vimEngine.searchForwardDirection, in: textView)
                parent.vimEngine.statusMessage = "/\(term)"
                scheduleSearchHighlightClear(for: textView)

            case .previousMatch:
                let term = parent.vimEngine.searchTerm
                guard !term.isEmpty else { break }
                textView.highlightAllMatches(term: term)
                searchAndMoveCursor(term: term, forward: !parent.vimEngine.searchForwardDirection, in: textView)
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
                textView.highlightAllMatches(term: word)
                searchAndMoveCursor(term: word, forward: forward, in: textView)
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
                
                let offset = currentIdx.utf16Offset(in: string)
                textView.setSelectedRange(NSRange(location: offset, length: 0))
                textView.scrollRangeToVisible(NSRange(location: offset, length: 0))

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

            case .centerCursor(let alignment):
                scrollCursorToPosition(alignment: alignment, in: textView)
            }
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

        private func searchAndMoveCursor(term: String, forward: Bool, in textView: VimNSTextView) {
            let nsString = textView.string as NSString
            let length = nsString.length
            guard length > 0, !term.isEmpty else { return }

            let cursorPos = textView.selectedRange().location

            if forward {
                let searchStart = min(cursorPos + 1, length)
                if searchStart < length {
                    let searchRange = NSRange(location: searchStart, length: length - searchStart)
                    let found = nsString.range(of: term, options: [.caseInsensitive], range: searchRange)
                    if found.location != NSNotFound {
                        textView.setSelectedRange(NSRange(location: found.location, length: 0))
                        textView.scrollRangeToVisible(found)
                        flashSearchHighlight(range: found, in: textView)
                        return
                    }
                }
                let wrapRange = NSRange(location: 0, length: min(cursorPos + 1, length))
                let found = nsString.range(of: term, options: [.caseInsensitive], range: wrapRange)
                if found.location != NSNotFound {
                    textView.setSelectedRange(NSRange(location: found.location, length: 0))
                    textView.scrollRangeToVisible(found)
                    flashSearchHighlight(range: found, in: textView)
                    parent.vimEngine.statusMessage = "search hit BOTTOM, continuing at TOP"
                } else {
                    parent.vimEngine.statusMessage = "Pattern not found: \(term)"
                }
            } else {
                if cursorPos > 0 {
                    let searchRange = NSRange(location: 0, length: cursorPos)
                    let found = nsString.range(of: term, options: [.caseInsensitive, .backwards], range: searchRange)
                    if found.location != NSNotFound {
                        textView.setSelectedRange(NSRange(location: found.location, length: 0))
                        textView.scrollRangeToVisible(found)
                        flashSearchHighlight(range: found, in: textView)
                        return
                    }
                }
                let wrapRange = NSRange(location: cursorPos, length: length - cursorPos)
                let found = nsString.range(of: term, options: [.caseInsensitive, .backwards], range: wrapRange)
                if found.location != NSNotFound {
                    textView.setSelectedRange(NSRange(location: found.location, length: 0))
                    textView.scrollRangeToVisible(found)
                    flashSearchHighlight(range: found, in: textView)
                    parent.vimEngine.statusMessage = "search hit TOP, continuing at BOTTOM"
                } else {
                    parent.vimEngine.statusMessage = "Pattern not found: \(term)"
                }
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
            var pos = resolveMotion(motion, in: textView)
            if count > 1 {
                let savedRange = textView.selectedRange()
                for _ in 1..<count {
                    textView.setSelectedRange(NSRange(location: pos, length: 0))
                    pos = resolveMotion(motion, in: textView)
                }
                textView.setSelectedRange(savedRange)
            }
            return pos
        }

        func resolveMotion(_ motion: Motion, in textView: NSTextView) -> Int {
            let string = textView.string
            let nsString = string as NSString
            let cursorPos = textView.selectedRange().location
            let length = nsString.length

            guard length > 0 else { return 0 }

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
                return 0

            case .documentEnd:
                if length > 0 {
                    let lastLineRange = nsString.lineRange(for: NSRange(location: length - 1, length: 0))
                    return lastLineRange.location
                }
                return 0

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

            case .matchingBracket:
                return findMatchingBracket(from: cursorPos, in: nsString)

            case .screenTop:
                return screenLinePosition(.top, in: textView)
            case .screenMiddle:
                return screenLinePosition(.middle, in: textView)
            case .screenBottom:
                return screenLinePosition(.bottom, in: textView)
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

        private func moveVertically(from pos: Int, direction: Int, in nsString: NSString) -> Int {
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

        private func findWordForward(from pos: Int, in string: String, bigWord: Bool) -> Int {
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

        private func findWordBackward(from pos: Int, in string: String, bigWord: Bool) -> Int {
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

        private func findWordEnd(from pos: Int, in string: String, bigWord: Bool) -> Int {
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

        private func findWordEndBackward(from pos: Int, in string: String, bigWord: Bool) -> Int {
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

        private func charType(_ char: Character, bigWord: Bool = false) -> CharType {
            if char.isNewline || char.isWhitespace { return .whitespace }
            if bigWord { return .word }
            if char.isLetter || char.isNumber || char == "_" { return .word }
            return .punctuation
        }

        private func findCharInLine(_ ch: Character, forward: Bool, till: Bool, from pos: Int, in nsString: NSString) -> Int {
            let string = nsString as String
            guard pos < string.utf16.count else { return pos }
            let startIdx = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
            let lineRange = string.lineRange(for: startIdx..<startIdx)
            
            if forward {
                var i = startIdx
                if i < lineRange.upperBound {
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

        private func findMatchingBracket(from pos: Int, in nsString: NSString) -> Int {
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
}

extension NSAttributedString.Key {
    static let codeBlock = NSAttributedString.Key("vimTextCodeBlock")
}

final class LineNumberRulerView: NSRulerView {
    private static let minimumGutterWidth: CGFloat = 52

    weak var textView: NSTextView?

    init(scrollView: NSScrollView, textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = Self.minimumGutterWidth
        reservedThicknessForMarkers = 0
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        drawHashMarksAndLabels(in: dirtyRect)
    }

    @objc private func clipViewBoundsChanged(_ notification: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        NSColor.clear.setFill()
        rect.fill()

        let nsString = textView.string as NSString
        guard nsString.length > 0 else { return }

        let visibleRect = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        guard glyphRange.length > 0 else { return }

        let baseColor = textView.textColor ?? NSColor.secondaryLabelColor
        let fontSize = min(11, max(9, (textView.font?.pointSize ?? 16) * 0.62))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium),
            .foregroundColor: baseColor.withAlphaComponent(0.34),
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.alignment = .right
                return style
            }()
        ]

        var rows: [(lineStart: Int, y: CGFloat, height: CGFloat)] = []
        var seenLineStarts = Set<Int>()

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { _, usedRect, _, lineGlyphRange, _ in
            let charRange = layoutManager.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            guard charRange.location < nsString.length else { return }

            let lineRange = nsString.lineRange(for: NSRange(location: charRange.location, length: 0))
            if seenLineStarts.contains(lineRange.location) { return }
            seenLineStarts.insert(lineRange.location)

            let textViewY = usedRect.minY + textView.textContainerOrigin.y
            let y = textView.convert(NSPoint(x: 0, y: textViewY), to: self).y
            rows.append((lineRange.location, y, usedRect.height))
        }

        var numberedRows: [(number: Int, y: CGFloat, height: CGFloat)] = []
        var previousLineStart: Int?
        var currentLineNumber = 0
        for row in rows.sorted(by: { $0.lineStart < $1.lineStart }) {
            if let previousLineStart {
                currentLineNumber += newlineCount(in: NSRange(location: previousLineStart, length: row.lineStart - previousLineStart), in: nsString)
            } else {
                currentLineNumber = lineNumber(at: row.lineStart, in: nsString)
            }
            previousLineStart = row.lineStart
            numberedRows.append((currentLineNumber, row.y, row.height))
        }

        updateThickness(for: numberedRows.map(\.number), attributes: attrs)

        for row in numberedRows {
            let drawRect = NSRect(x: 1, y: row.y, width: ruleThickness - 9, height: row.height)
            NSString(string: "\(row.number)").draw(in: drawRect, withAttributes: attrs)
        }
    }

    private func updateThickness(for numbers: [Int], attributes attrs: [NSAttributedString.Key: Any]) {
        guard let maxDigits = numbers.map({ String($0).count }).max() else { return }
        let digitWidth = NSString(string: "8").size(withAttributes: attrs).width
        let desired = max(Self.minimumGutterWidth, ceil(CGFloat(maxDigits) * digitWidth + 18))
        guard abs(ruleThickness - desired) > 0.5 else { return }
        ruleThickness = desired
        scrollView?.tile()
    }

    private func newlineCount(in range: NSRange, in nsString: NSString) -> Int {
        guard range.length > 0 else { return 0 }
        let safeEnd = min(nsString.length, range.location + range.length)
        guard range.location < safeEnd else { return 0 }
        var count = 0
        for idx in range.location..<safeEnd {
            if nsString.character(at: idx) == 0x0A { count += 1 }
        }
        return count
    }

    private func lineNumber(at characterIndex: Int, in nsString: NSString) -> Int {
        guard characterIndex > 0 else { return 1 }
        var line = 1
        let safeEnd = min(characterIndex, nsString.length)
        var idx = 0
        while idx < safeEnd {
            if nsString.character(at: idx) == 0x0A { line += 1 }
            idx += 1
        }
        return line
    }
}

class VimNSTextView: NSTextView {
    var vimEngine: VimEngine?
    weak var coordinator: VimTextView.Coordinator?
    var accentColor: NSColor = .systemOrange
    var paperStyle: String = "plain"
    var smartLists: Bool = true
    var codeBlockRanges: [NSRange] = []
    private var copyButtons: [NSButton] = []
    private var blockCursorLayer: CALayer?
    var visualCursorOverride: Int? = nil
    /// The image currently showing its Google-Docs-style selection box/handles.
    weak var selectedImageAttachment: ImageTextAttachment?
    private var currentMatchLayer: CALayer?
    /// Upper bound on matches we find/highlight, as a safety valve against a
    /// pathological query (e.g. a single common letter in a multi-MB note).
    /// Far above any realistic search; effectively "all matches".
    static let maxSearchMatches = 50_000
    /// Whether temporary search-highlight attributes are currently applied,
    /// so clearing can skip an O(n) attribute sweep when there's nothing set.
    private var hasTemporarySearchHighlights = false

    func highlightCurrentMatch(range: NSRange) {
        currentMatchLayer?.removeFromSuperlayer()
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        var highlightRect = rect
        highlightRect.origin.x += self.textContainerOrigin.x
        highlightRect.origin.y += self.textContainerOrigin.y
        let layer = CALayer()
        layer.frame = highlightRect
        layer.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.4).cgColor
        layer.cornerRadius = 2
        layer.borderWidth = 1.5
        layer.borderColor = NSColor.systemOrange.withAlphaComponent(0.8).cgColor
        layer.name = "currentMatchHighlight"
        self.wantsLayer = true
        self.layer?.addSublayer(layer)
        currentMatchLayer = layer
    }

    /// Highlights every match by adding a temporary background-color attribute
    /// on the layout manager (not the text storage). The layout manager only
    /// draws the on-screen ones, so this is viewport-bound regardless of how
    /// many matches there are — no per-match layers, no 250 cap. Temporary
    /// attributes are display-only, so they're never serialized into the note.
    func applyMatchHighlights(_ ranges: [NSRange]) {
        clearSearchHighlights()
        guard let layoutManager = self.layoutManager else { return }
        let length = (self.string as NSString).length
        guard length > 0, !ranges.isEmpty else { return }

        let color = NSColor.systemYellow.withAlphaComponent(0.30)
        var applied = 0
        for r in ranges {
            let safe = NSIntersectionRange(r, NSRange(location: 0, length: length))
            guard safe.length > 0 else { continue }
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: safe)
            applied += 1
            if applied >= Self.maxSearchMatches { break }
        }
        hasTemporarySearchHighlights = applied > 0
    }

    /// Scans for `term` and highlights all matches. Used by the Vim `/` search.
    func highlightAllMatches(term: String) {
        guard !term.isEmpty else { clearSearchHighlights(); return }
        let nsString = self.string as NSString
        let length = nsString.length
        guard length > 0 else { clearSearchHighlights(); return }

        var ranges: [NSRange] = []
        var searchRange = NSRange(location: 0, length: length)
        while searchRange.location < length {
            let found = nsString.range(of: term, options: [.caseInsensitive], range: searchRange)
            if found.location == NSNotFound { break }
            ranges.append(found)
            if ranges.count >= Self.maxSearchMatches { break }
            searchRange.location = found.location + found.length
            searchRange.length = length - searchRange.location
        }
        applyMatchHighlights(ranges)
    }

    func clearSearchHighlights() {
        currentMatchLayer?.removeFromSuperlayer()
        currentMatchLayer = nil
        if hasTemporarySearchHighlights, let layoutManager = self.layoutManager {
            let fullRange = NSRange(location: 0, length: (self.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            hasTemporarySearchHighlights = false
        }
    }

    // MARK: - Rich Text Formatting

    func toggleBoldFormatting() {
        let fontManager = NSFontManager.shared
        let range = selectedRange()

        if range.length > 0 {
            guard let textStorage = textStorage else { return }
            textStorage.beginEditing()
            textStorage.enumerateAttribute(.font, in: range, options: []) { value, attrRange, _ in
                guard let currentFont = value as? NSFont else { return }
                let newFont: NSFont
                if fontManager.traits(of: currentFont).contains(.boldFontMask) {
                    newFont = fontManager.convert(currentFont, toNotHaveTrait: .boldFontMask)
                } else {
                    newFont = fontManager.convert(currentFont, toHaveTrait: .boldFontMask)
                }
                textStorage.addAttribute(.font, value: newFont, range: attrRange)
            }
            textStorage.endEditing()
        } else {
            var attrs = typingAttributes
            if let currentFont = attrs[.font] as? NSFont {
                let newFont: NSFont
                if fontManager.traits(of: currentFont).contains(.boldFontMask) {
                    newFont = fontManager.convert(currentFont, toNotHaveTrait: .boldFontMask)
                } else {
                    newFont = fontManager.convert(currentFont, toHaveTrait: .boldFontMask)
                }
                attrs[.font] = newFont
                typingAttributes = attrs
            }
        }
        coordinator?.formattingDidChange()
        vimEngine?.statusMessage = range.length > 0 ? "Bold toggled" : "Bold mode toggled"
    }

    func toggleItalicFormatting() {
        let fontManager = NSFontManager.shared
        let range = selectedRange()

        if range.length > 0 {
            guard let textStorage = textStorage else { return }
            textStorage.beginEditing()
            textStorage.enumerateAttribute(.font, in: range, options: []) { value, attrRange, _ in
                guard let currentFont = value as? NSFont else { return }
                let newFont: NSFont
                if fontManager.traits(of: currentFont).contains(.italicFontMask) {
                    newFont = fontManager.convert(currentFont, toNotHaveTrait: .italicFontMask)
                } else {
                    newFont = fontManager.convert(currentFont, toHaveTrait: .italicFontMask)
                }
                textStorage.addAttribute(.font, value: newFont, range: attrRange)
            }
            textStorage.endEditing()
        } else {
            var attrs = typingAttributes
            if let currentFont = attrs[.font] as? NSFont {
                let newFont: NSFont
                if fontManager.traits(of: currentFont).contains(.italicFontMask) {
                    newFont = fontManager.convert(currentFont, toNotHaveTrait: .italicFontMask)
                } else {
                    newFont = fontManager.convert(currentFont, toHaveTrait: .italicFontMask)
                }
                attrs[.font] = newFont
                typingAttributes = attrs
            }
        }
        coordinator?.formattingDidChange()
        vimEngine?.statusMessage = range.length > 0 ? "Italic toggled" : "Italic mode toggled"
    }

    func toggleUnderlineFormatting() {
        let range = selectedRange()

        if range.length > 0 {
            guard let textStorage = textStorage else { return }
            let currentVal = textStorage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
            let newVal = currentVal == 0 ? NSUnderlineStyle.single.rawValue : 0
            textStorage.beginEditing()
            textStorage.addAttribute(.underlineStyle, value: newVal, range: range)
            textStorage.endEditing()
        } else {
            var attrs = typingAttributes
            let currentVal = attrs[.underlineStyle] as? Int ?? 0
            attrs[.underlineStyle] = currentVal == 0 ? NSUnderlineStyle.single.rawValue : 0
            typingAttributes = attrs
        }
        coordinator?.formattingDidChange()
        vimEngine?.statusMessage = range.length > 0 ? "Underline toggled" : "Underline mode toggled"
    }

    func applyBaseFont(_ baseFont: NSFont) {
        guard let textStorage = textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }
        let fontManager = NSFontManager.shared
        textStorage.beginEditing()
        textStorage.addAttribute(.paragraphStyle, value: VimTextView.paragraphStyle(), range: fullRange)
        textStorage.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let existingTraits = (value as? NSFont).map { fontManager.traits(of: $0) } ?? NSFontTraitMask()
            var newFont = baseFont
            if existingTraits.contains(.boldFontMask) {
                newFont = fontManager.convert(newFont, toHaveTrait: .boldFontMask)
            }
            if existingTraits.contains(.italicFontMask) {
                newFont = fontManager.convert(newFont, toHaveTrait: .italicFontMask)
            }
            textStorage.addAttribute(.font, value: newFont, range: range)
        }
        textStorage.endEditing()
    }

    func applyTextColor(_ color: NSColor) {
        guard let textStorage = textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }
        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: color, range: fullRange)
        textStorage.endEditing()
    }

    /// Find ```-fenced regions in the plain text. Each returned range covers the
    /// opening fence line through the closing fence line (inclusive). Only closed
    /// blocks are styled — a lone opening fence stays plain text so it can never
    /// trap the cursor in an unbounded block.
    func computeCodeBlockRanges() -> [NSRange] {
        let ns = string as NSString
        let len = ns.length
        var ranges: [NSRange] = []
        
        var searchRange = NSRange(location: 0, length: len)
        var lastFenceIndex: Int? = nil
        
        while searchRange.location < len {
            let found = ns.range(of: "```", options: [], range: searchRange)
            if found.location == NSNotFound { break }
            
            let lineRange = ns.lineRange(for: NSRange(location: found.location, length: 0))
            let leadingRange = NSRange(location: lineRange.location, length: found.location - lineRange.location)
            let leadingStr = ns.substring(with: leadingRange).trimmingCharacters(in: .whitespaces)
            
            if leadingStr.isEmpty {
                if let start = lastFenceIndex {
                    let endOfLine = lineRange.location + lineRange.length
                    ranges.append(NSRange(location: start, length: endOfLine - start))
                    lastFenceIndex = nil
                } else {
                    lastFenceIndex = lineRange.location
                }
            }
            
            let nextIndex = lineRange.location + lineRange.length
            if nextIndex <= searchRange.location { break }
            searchRange.location = nextIndex
            searchRange.length = len - nextIndex
        }
        return ranges
    }

    func isLocationInCodeBlock(_ loc: Int) -> Bool {
        for r in codeBlockRanges where NSLocationInRange(loc, r) { return true }
        return false
    }

    /// Re-derive code-block styling from the fenced plain text: monospaced font
    /// inside fences (tagged with .codeBlock for background drawing), proportional
    /// font with preserved bold/italic elsewhere.
    func restyleCodeBlocks(baseFont: NSFont) {
        guard let textStorage = textStorage else { return }
        let len = textStorage.length
        let ranges = computeCodeBlockRanges()
        if ranges == codeBlockRanges {
            return
        }
        codeBlockRanges = ranges
        guard len > 0 else { needsDisplay = true; return }

        let fullRange = NSRange(location: 0, length: len)
        let monoFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        let fontManager = NSFontManager.shared

        let ns = string as NSString
        let baseParagraph = VimTextView.paragraphStyle()
        let blockGap: CGFloat = 12

        textStorage.beginEditing()
        textStorage.removeAttribute(.codeBlock, range: fullRange)
        // Reset paragraph style + font everywhere; blocks override below.
        textStorage.addAttribute(.paragraphStyle, value: baseParagraph, range: fullRange)
        textStorage.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
            let traits = (value as? NSFont).map { fontManager.traits(of: $0) } ?? NSFontTraitMask()
            var f = baseFont
            if traits.contains(.boldFontMask) { f = fontManager.convert(f, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { f = fontManager.convert(f, toHaveTrait: .italicFontMask) }
            textStorage.addAttribute(.font, value: f, range: range)
        }
        // Overlay monospaced font + tag on fenced ranges, and add a gap above the
        // opening fence and below the closing fence so the block stands apart.
        for r in ranges {
            let safe = NSIntersectionRange(r, fullRange)
            guard safe.length > 0 else { continue }
            textStorage.addAttribute(.font, value: monoFont, range: safe)
            textStorage.addAttribute(.codeBlock, value: true, range: safe)

            let firstLine = ns.lineRange(for: NSRange(location: safe.location, length: 0))
            let lastLine = ns.lineRange(for: NSRange(location: min(safe.location + safe.length - 1, ns.length), length: 0))

            let before = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
            before.paragraphSpacingBefore = blockGap
            let after = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
            after.paragraphSpacing = blockGap

            let firstSafe = NSIntersectionRange(firstLine, fullRange)
            if firstSafe.length > 0 {
                textStorage.addAttribute(.paragraphStyle, value: before, range: firstSafe)
            }
            let lastSafe = NSIntersectionRange(lastLine, fullRange)
            if lastSafe.length > 0 {
                textStorage.addAttribute(.paragraphStyle, value: after, range: lastSafe)
            }
        }
        textStorage.endEditing()
        needsDisplay = true
        updateCopyButtons()
    }

    func updateFontSize(_ newSize: CGFloat) {
        guard let textStorage = textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        if fullRange.length > 0 {
            textStorage.beginEditing()
            textStorage.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
                guard let currentFont = value as? NSFont else { return }
                let newFont = NSFont(descriptor: currentFont.fontDescriptor, size: newSize) ?? currentFont
                textStorage.addAttribute(.font, value: newFont, range: range)
            }
            textStorage.endEditing()
        }
        // Also update typing attributes
        var attrs = typingAttributes
        if let currentFont = attrs[.font] as? NSFont {
            attrs[.font] = NSFont(descriptor: currentFont.fontDescriptor, size: newSize) ?? currentFont
            typingAttributes = attrs
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            DispatchQueue.main.async { [weak self] in
                self?.window?.makeFirstResponder(self)
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            updateCursorAppearance(isBlock: vimEngine?.mode.isEditing == false)
        }
        return result
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.control) && event.charactersIgnoringModifiers == "v" {
            if let engine = vimEngine, !engine.mode.isEditing {
                return false
            }
        }
        if event.modifierFlags.contains(.command) {
            let hasShift = event.modifierFlags.contains(.shift)
            let hasOption = event.modifierFlags.contains(.option)
            if event.charactersIgnoringModifiers?.lowercased() == "b" && hasOption && !hasShift {
                NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                return true
            }
            if event.charactersIgnoringModifiers == "=" || event.characters == "+" {
                EditorPreferences.increaseFontSize()
                return true
            }
            if event.charactersIgnoringModifiers == "-" {
                EditorPreferences.decreaseFontSize()
                return true
            }
            if event.charactersIgnoringModifiers == "0" {
                EditorPreferences.resetFontSize()
                return true
            }
            if event.charactersIgnoringModifiers == "s" && !hasShift {
                coordinator?.parent.onSave?()
                vimEngine?.statusMessage = "Saved"
                return true
            }
            if event.charactersIgnoringModifiers == "f" && !hasShift {
                if let fc = coordinator?.parent.findController {
                    let sel = selectedRange()
                    if sel.length > 0 {
                        let nsString = string as NSString
                        fc.query = nsString.substring(with: sel)
                    }
                    fc.isVisible = true
                    fc.focusTrigger += 1
                    return true
                }
                return false
            }
            if event.charactersIgnoringModifiers == "f" && hasShift {
                return false
            }
            if event.charactersIgnoringModifiers == "g" {
                if let fc = coordinator?.parent.findController, fc.isVisible {
                    if hasShift {
                        fc.findPrev?()
                    } else {
                        fc.findNext?()
                    }
                    return true
                }
            }
            // Rich text formatting: Cmd+B (bold), Cmd+I (italic), Cmd+U (underline)
            if event.charactersIgnoringModifiers == "b" && !hasShift {
                toggleBoldFormatting()
                return true
            }
            if event.charactersIgnoringModifiers == "i" && !hasShift {
                toggleItalicFormatting()
                return true
            }
            if event.charactersIgnoringModifiers == "u" && !hasShift {
                toggleUnderlineFormatting()
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Vim Ctrl-D/U (half page) and Ctrl-F/B (full page) scrolling: move the
    /// cursor by a page worth of lines and scroll the view by the same amount,
    /// so the cursor keeps its position on screen. Works in normal and visual
    /// mode (visual extends the selection via the shared moveCursor path).
    private func performVimScroll(half: Bool, down: Bool, coordinator: VimTextView.Coordinator) {
        let f = font ?? NSFont.systemFont(ofSize: 16)
        let lineHeight = layoutManager?.defaultLineHeight(for: f) ?? max(1, f.pointSize * 1.3)
        guard lineHeight > 0 else { return }

        let visibleHeight = visibleRect.height
        let visibleLines = max(1, Int(visibleHeight / lineHeight))
        // Full page keeps a 2-line overlap, like Vim.
        let lineCount = max(1, half ? visibleLines / 2 : visibleLines - 2)

        let originBeforeY = enclosingScrollView?.contentView.bounds.origin.y ?? 0

        let motion: Motion = down ? .down : .up
        coordinator.executeActions(Array(repeating: .moveCursor(motion), count: lineCount))

        if let scrollView = enclosingScrollView {
            let clip = scrollView.contentView
            let maxY = max(0, bounds.height - visibleHeight)
            var origin = clip.bounds.origin
            origin.y = min(max(0, originBeforeY + CGFloat(lineCount) * lineHeight * (down ? 1 : -1)), maxY)
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Any keystroke dismisses the image selection box.
        deselectImage()
        guard let engine = vimEngine, let coordinator = coordinator else {
            super.keyDown(with: event)
            return
        }

        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }

        if modifiers.contains(.command) {
            super.keyDown(with: event)
            return
        }

        let isEsc = event.keyCode == 53
        let isReturn = event.keyCode == 36
        let isBackspace = event.keyCode == 51
        let isTab = event.keyCode == 48

        if engine.mode == .command {
            if isEsc {
                let actions = engine.processKey("escape")
                coordinator.executeActions(actions)
            } else if isReturn {
                if engine.isSearchMode {
                    let term = engine.commandLineText
                    let forward = engine.searchForwardDirection
                    engine.searchTerm = term
                    engine.mode = .normal
                    engine.showCommandLine = false
                    engine.isSearchMode = false
                    if !term.isEmpty {
                        coordinator.executeActions([.searchExecute(term, forward)])
                        engine.statusMessage = "/\(term)"
                    }
                } else {
                    let actions = engine.executeCommand(engine.commandLineText)
                    coordinator.executeActions(actions)
                }
            } else if isBackspace {
                if !engine.commandLineText.isEmpty {
                    engine.commandLineText.removeLast()
                }
            } else if let chars = event.characters {
                engine.commandLineText += chars
            }
            return
        }

        if engine.mode.isEditing {
            if isEsc {
                let actions = engine.processKey("escape")
                coordinator.executeActions(actions)
                return
            }

            if modifiers.contains(.control) && event.characters == "[" {
                let actions = engine.processKey("[", modifiers: modifiers)
                coordinator.executeActions(actions)
                return
            }

            if engine.mode == .replace {
                guard let chars = event.characters, !chars.isEmpty else { return }
                let pos = selectedRange().location
                let nsString = string as NSString
                let replacementRange = pos < nsString.length
                    ? NSRange(location: pos, length: 1)
                    : NSRange(location: pos, length: 0)
                insertText(chars, replacementRange: replacementRange)
                engine.recordNonInsertChange(actions: [.replaceChar])
                engine.lastReplaceChar = chars
                return
            }

            if isReturn && !modifiers.contains(.shift) && handleSmartListReturn() {
                return
            }

            if isTab && smartLists && handleSmartListTab(outdent: modifiers.contains(.shift)) {
                return
            }

            if event.characters == "`" && !modifiers.contains(.control) && handleBacktickAutoClose() {
                return
            }

            super.keyDown(with: event)
            return
        }

        if isEsc {
            let actions = engine.processKey("escape")
            coordinator.executeActions(actions)
            return
        }

        if modifiers.contains(.control) && event.charactersIgnoringModifiers == "v" {
            let actions = engine.processKey("v", modifiers: modifiers)
            coordinator.executeActions(actions)
            return
        }

        // Ctrl-D / Ctrl-U: half-page scroll. Ctrl-F / Ctrl-B: full-page scroll.
        if modifiers.contains(.control), let c = event.charactersIgnoringModifiers,
           c == "d" || c == "u" || c == "f" || c == "b" {
            let half = (c == "d" || c == "u")
            let down = (c == "d" || c == "f")
            performVimScroll(half: half, down: down, coordinator: coordinator)
            return
        }

        guard let chars = event.characters, !chars.isEmpty else { return }
        let key = chars

        if engine.keyBuffer == "r" && !isEsc {
            engine.resetBuffers()
            let pos = selectedRange().location
            let nsString = string as NSString
            if pos < nsString.length {
                setSelectedRange(NSRange(location: pos, length: 1))
                insertText(key, replacementRange: NSRange(location: pos, length: 1))
                setSelectedRange(NSRange(location: pos, length: 0))
                engine.recordNonInsertChange(actions: [.replaceChar])
                engine.lastReplaceChar = key
            }
            return
        }

        let actions = engine.processKey(key, modifiers: modifiers)
        coordinator.executeActions(actions)
    }

    private struct ListMarker {
        let indent: String       // leading whitespace of the line
        let body: String         // text after the marker
        let existingPrefix: String  // marker text already on the line (incl. trailing space)
        let nextPrefix: String   // marker to start the following line (incl. trailing space)
    }

    private func parseListMarker(_ line: String) -> ListMarker? {
        var s = Substring(line)
        if s.hasSuffix("\n") { s = s.dropLast() }
        let indent = s.prefix { $0 == " " || $0 == "\t" }
        let rest = s.dropFirst(indent.count)
        guard let first = rest.first else { return nil }

        // Unordered: - * + •
        if "-*+•".contains(first) {
            let afterMarker = rest.dropFirst()
            guard afterMarker.first == " " else { return nil }
            let prefix = "\(first) "
            return ListMarker(indent: String(indent),
                              body: String(afterMarker.dropFirst()),
                              existingPrefix: prefix,
                              nextPrefix: prefix)
        }

        // Ordered: digits followed by . or )
        let digits = rest.prefix { $0.isNumber }
        if !digits.isEmpty {
            let afterDigits = rest.dropFirst(digits.count)
            guard let sep = afterDigits.first, sep == "." || sep == ")" else { return nil }
            let afterSep = afterDigits.dropFirst()
            guard afterSep.first == " " else { return nil }
            let next = (Int(digits) ?? 0) + 1
            return ListMarker(indent: String(indent),
                              body: String(afterSep.dropFirst()),
                              existingPrefix: "\(digits)\(sep) ",
                              nextPrefix: "\(next)\(sep) ")
        }

        return nil
    }

    /// On Return in insert mode, continue or terminate a list item. Returns true if handled.
    private func handleSmartListReturn() -> Bool {
        guard smartLists else { return false }
        let sel = selectedRange()
        guard sel.length == 0 else { return false }

        guard !isLocationInCodeBlock(sel.location) else { return false }

        let ns = string as NSString
        let pos = sel.location
        let lineRange = ns.lineRange(for: NSRange(location: min(pos, ns.length), length: 0))
        let line = ns.substring(with: lineRange)
        guard let marker = parseListMarker(line) else { return false }

        // Only act when the cursor sits at the end of the line's content.
        var contentEnd = lineRange.location + lineRange.length
        if contentEnd > lineRange.location,
           ns.substring(with: NSRange(location: contentEnd - 1, length: 1)) == "\n" {
            contentEnd -= 1
        }
        guard pos == contentEnd else { return false }

        // Empty item → terminate the list by clearing the marker.
        if marker.body.trimmingCharacters(in: .whitespaces).isEmpty {
            let clearRange = NSRange(location: lineRange.location,
                                     length: contentEnd - lineRange.location)
            if shouldChangeText(in: clearRange, replacementString: "") {
                textStorage?.replaceCharacters(in: clearRange, with: "")
                didChangeText()
            }
            setSelectedRange(NSRange(location: lineRange.location, length: 0))
            return true
        }

        // Non-empty item → start the next item.
        insertText("\n" + marker.indent + marker.nextPrefix,
                   replacementRange: NSRange(location: pos, length: 0))
        return true
    }

    /// On Tab / Shift-Tab in insert mode, indent or outdent the current list item
    /// by one level (4 spaces). Returns true if handled.
    private func handleSmartListTab(outdent: Bool) -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        guard !isLocationInCodeBlock(sel.location) else { return false }

        let ns = string as NSString
        let pos = sel.location
        let lineRange = ns.lineRange(for: NSRange(location: min(pos, ns.length), length: 0))
        let line = ns.substring(with: lineRange)
        guard parseListMarker(line) != nil else { return false }

        let indentUnit = "    "

        if outdent {
            var removeLen = 0
            if line.hasPrefix("\t") {
                removeLen = 1
            } else {
                removeLen = min(indentUnit.count, line.prefix { $0 == " " }.count)
            }
            guard removeLen > 0 else { return true }
            let removeRange = NSRange(location: lineRange.location, length: removeLen)
            if shouldChangeText(in: removeRange, replacementString: "") {
                textStorage?.replaceCharacters(in: removeRange, with: "")
                didChangeText()
            }
            setSelectedRange(NSRange(location: max(lineRange.location, pos - removeLen), length: 0))
            return true
        }

        insertText(indentUnit, replacementRange: NSRange(location: lineRange.location, length: 0))
        setSelectedRange(NSRange(location: pos + indentUnit.count, length: 0))
        return true
    }

    /// When the third backtick completes a fence opener on its own line, auto-insert
    /// a blank line and a closing fence, leaving the cursor on the blank line.
    /// Returns true if handled (the typed backtick is inserted as part of this).
    private func handleBacktickAutoClose() -> Bool {
        let sel = selectedRange()
        guard sel.length == 0 else { return false }

        let ns = string as NSString
        let pos = sel.location
        let lineRange = ns.lineRange(for: NSRange(location: min(pos, ns.length), length: 0))
        var contentLen = lineRange.length
        if contentLen > 0,
           ns.substring(with: NSRange(location: lineRange.location + contentLen - 1, length: 1)) == "\n" {
            contentLen -= 1
        }
        let lineContent = ns.substring(with: NSRange(location: lineRange.location, length: contentLen))
        // The user is completing "``" → "```" at the end of an otherwise-empty line.
        guard lineContent == "``", pos == lineRange.location + contentLen else { return false }

        // Count fence lines before this one; odd means an opener is already waiting,
        // so this fence closes it — don't auto-insert another closer.
        var fenceCount = 0
        var idx = 0
        while idx < lineRange.location {
            let lr = ns.lineRange(for: NSRange(location: idx, length: 0))
            if ns.substring(with: lr).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```") {
                fenceCount += 1
            }
            let next = lr.location + lr.length
            if next <= idx { break }
            idx = next
        }
        guard fenceCount % 2 == 0 else { return false }

        insertText("`\n\n```", replacementRange: NSRange(location: pos, length: 0))
        setSelectedRange(NSRange(location: pos + 2, length: 0))
        return true
    }

    /// The eight selection handles around a selected image.
    enum ImageHandle { case nw, n, ne, e, se, s, sw, w }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // 1) Dragging a handle of the already-selected image resizes precisely.
        if let selected = selectedImageAttachment,
           let rect = rect(for: selected),
           let handle = imageHandle(at: point, in: rect) {
            resizeViaHandle(selected, imageRect: rect, handle: handle)
            return
        }

        // 2) Clicking an image selects it (showing the box), and dragging its
        //    body resizes it; a plain click just selects + places the caret.
        if let (attachment, rect) = imageAttachment(at: point) {
            selectImage(attachment)
            resizeViaBody(attachment, imageRect: rect, startPoint: point)
            return
        }

        // 3) Clicking elsewhere clears any image selection.
        deselectImage()
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
        if let engine = vimEngine, !engine.mode.isEditing {
            updateCursorAppearance(isBlock: true)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for (_, rect) in imageAttachmentRects() {
            addCursorRect(rect, cursor: .resizeLeftRight)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawImageSelectionChrome()
    }

    /// Draws the Google-Docs-style blue bounding box and eight square handles
    /// around the selected image.
    private func drawImageSelectionChrome() {
        guard let attachment = selectedImageAttachment, let rect = rect(for: attachment) else { return }

        let box = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        NSColor.systemBlue.setStroke()
        box.lineWidth = 1.5
        box.stroke()

        let handleSize: CGFloat = 8
        for (_, center) in imageHandleCenters(for: rect) {
            let r = NSRect(x: center.x - handleSize / 2,
                           y: center.y - handleSize / 2,
                           width: handleSize,
                           height: handleSize)
            let path = NSBezierPath(rect: r)
            NSColor.white.setFill()
            path.fill()
            NSColor.systemBlue.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// Layout rectangles (in view coordinates) of every embedded image.
    func imageAttachmentRects() -> [(attachment: ImageTextAttachment, rect: NSRect)] {
        guard let layoutManager = layoutManager, let textContainer = textContainer,
              let storage = textStorage else { return [] }
        let origin = textContainerOrigin
        var result: [(ImageTextAttachment, NSRect)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, range, _ in
            guard let attachment = value as? ImageTextAttachment else { return }
            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            result.append((attachment, rect))
        }
        return result
    }

    private func rect(for attachment: ImageTextAttachment) -> NSRect? {
        imageAttachmentRects().first { $0.attachment === attachment }?.rect
    }

    private func imageAttachment(at point: NSPoint) -> (ImageTextAttachment, NSRect)? {
        for entry in imageAttachmentRects() where entry.rect.contains(point) {
            return entry
        }
        return nil
    }

    /// Centre points of the eight handles for an image's `rect` (view coords).
    func imageHandleCenters(for rect: NSRect) -> [(ImageHandle, NSPoint)] {
        [
            (.nw, NSPoint(x: rect.minX, y: rect.minY)),
            (.n,  NSPoint(x: rect.midX, y: rect.minY)),
            (.ne, NSPoint(x: rect.maxX, y: rect.minY)),
            (.e,  NSPoint(x: rect.maxX, y: rect.midY)),
            (.se, NSPoint(x: rect.maxX, y: rect.maxY)),
            (.s,  NSPoint(x: rect.midX, y: rect.maxY)),
            (.sw, NSPoint(x: rect.minX, y: rect.maxY)),
            (.w,  NSPoint(x: rect.minX, y: rect.midY))
        ]
    }

    private func imageHandle(at point: NSPoint, in rect: NSRect) -> ImageHandle? {
        let tolerance: CGFloat = 10
        for (handle, center) in imageHandleCenters(for: rect) {
            if hypot(point.x - center.x, point.y - center.y) <= tolerance {
                return handle
            }
        }
        return nil
    }

    private func selectImage(_ attachment: ImageTextAttachment) {
        if selectedImageAttachment !== attachment {
            selectedImageAttachment = attachment
            needsDisplay = true
        }
        placeCaretAfter(attachment)
    }

    func deselectImage() {
        if selectedImageAttachment != nil {
            selectedImageAttachment = nil
            needsDisplay = true
        }
    }

    /// Resize by dragging a selection handle: the dragged edge/corner follows
    /// the pointer, with the opposite edge anchored (aspect locked).
    private func resizeViaHandle(_ attachment: ImageTextAttachment, imageRect: NSRect, handle: ImageHandle) {
        guard let window = window else { return }
        let aspect = attachment.nativeSize.height > 0 ? attachment.nativeSize.width / attachment.nativeSize.height : 1
        let maxWidth = availableImageWidth()
        NSCursor.crosshair.push()
        defer { NSCursor.pop() }
        while true {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { continue }
            if event.type == .leftMouseUp { break }
            let p = convert(event.locationInWindow, from: nil)
            var width: CGFloat
            switch handle {
            case .ne, .e, .se:          width = p.x - imageRect.minX          // left edge anchored
            case .nw, .w, .sw:          width = imageRect.maxX - p.x          // right edge anchored
            case .s:                    width = (p.y - imageRect.minY) * aspect
            case .n:                    width = (imageRect.maxY - p.y) * aspect
            }
            attachment.setDisplayWidth(min(max(48, width), maxWidth))
            invalidateLayout(for: attachment)
        }
        coordinator?.imageDidResize()
    }

    /// Resize by dragging the image body (width tracks the drag delta). A click
    /// without a drag leaves the image selected with the caret placed after it.
    private func resizeViaBody(_ attachment: ImageTextAttachment, imageRect: NSRect, startPoint: NSPoint) {
        guard let window = window else { return }
        let startWidth = attachment.bounds.width
        let maxWidth = availableImageWidth()
        var didResize = false
        while true {
            guard let event = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else { continue }
            if event.type == .leftMouseUp { break }
            let point = convert(event.locationInWindow, from: nil)
            if !didResize {
                if hypot(point.x - startPoint.x, point.y - startPoint.y) < 3 { continue }
                didResize = true
                NSCursor.resizeLeftRight.set()
            }
            attachment.setDisplayWidth(min(max(48, startWidth + (point.x - startPoint.x)), maxWidth))
            invalidateLayout(for: attachment)
        }
        if didResize { coordinator?.imageDidResize() }
    }

    /// Widest an image may be drawn — the text column minus insets.
    private func availableImageWidth() -> CGFloat {
        let inset = textContainerInset.width * 2
        let width = (textContainer?.size.width ?? bounds.width) - inset
        return max(120, width)
    }

    private func placeCaretAfter(_ attachment: ImageTextAttachment) {
        guard let storage = textStorage else { return }
        var caret: Int?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length), options: []) { value, range, stop in
            if value as AnyObject === attachment {
                caret = range.location + range.length
                stop.pointee = true
            }
        }
        if let caret {
            setSelectedRange(NSRange(location: caret, length: 0))
        }
        window?.makeFirstResponder(self)
        if let engine = vimEngine, !engine.mode.isEditing {
            updateCursorAppearance(isBlock: true)
        }
    }

    func updateCursorAppearance(isBlock: Bool) {
        if isBlock {
            insertionPointColor = .clear
            drawBlockCursor()
        } else {
            blockCursorLayer?.removeFromSuperlayer()
            blockCursorLayer = nil
            insertionPointColor = accentColor
            setNeedsDisplay(bounds)
        }
    }

    private func drawBlockCursor() {
        guard let layoutManager = layoutManager, let textContainer = textContainer else { return }

        let nsString = string as NSString
        let isVisual = vimEngine?.mode.isVisual == true
        let pos: Int
        if isVisual, let override = visualCursorOverride {
            pos = min(override, max(nsString.length - 1, 0))
        } else {
            pos = selectedRange().location
        }

        var glyphRange = NSRange(location: pos, length: 1)
        var rect: NSRect
        
        if pos >= nsString.length {
            if nsString.length > 0 {
                glyphRange = NSRange(location: nsString.length - 1, length: 1)
                let glyphIdx = layoutManager.glyphIndexForCharacter(at: glyphRange.location)
                rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: textContainer)
                rect.origin.x += textContainerOrigin.x
                rect.origin.y += textContainerOrigin.y
            } else {
                rect = NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y, width: 8, height: font?.pointSize ?? 15)
            }
        } else {
            let charIndex = glyphRange.location
            let glyphIdx = layoutManager.glyphIndexForCharacter(at: charIndex)
            rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIdx, length: 1), in: textContainer)
            rect.origin.x += textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            if rect.width < 2 {
                rect.size.width = 8
            }
        }

        // Size the cursor from the font actually at the cursor position — the
        // view's base `font` can lag behind a font-size change and make the
        // cursor too small. Real glyphs keep their true bounding-box height so
        // the cursor matches the text; only empty/newline positions (whose
        // glyph rect spans the whole line and carries paragraph spacing) get
        // collapsed to a single cell, otherwise they'd paint a fat bar.
        let cursorFont: NSFont = {
            if nsString.length > 0 {
                let idx = min(pos, nsString.length - 1)
                if let f = textStorage?.attribute(.font, at: idx, effectiveRange: nil) as? NSFont { return f }
            }
            return (typingAttributes[.font] as? NSFont) ?? font ?? NSFont.systemFont(ofSize: 15)
        }()
        let cellWidth = max(6, (" " as NSString).size(withAttributes: [.font: cursorFont]).width)
        let onNewline = pos < nsString.length &&
            (nsString.character(at: pos) == 0x0A || nsString.character(at: pos) == 0x0D)
        if onNewline || rect.width > cellWidth * 2 {
            rect.size.width = cellWidth
            rect.size.height = layoutManager.defaultLineHeight(for: cursorFont)
        }

        let cursorColor: NSColor = isVisual
            ? accentColor.withAlphaComponent(0.75)
            : accentColor.withAlphaComponent(0.45)

        self.wantsLayer = true
        
        if let existingLayer = blockCursorLayer, existingLayer.superlayer == self.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            existingLayer.frame = rect
            existingLayer.backgroundColor = cursorColor.cgColor
            CATransaction.commit()
        } else {
            blockCursorLayer?.removeFromSuperlayer()
            
            let layer = CALayer()
            layer.frame = rect
            layer.backgroundColor = cursorColor.cgColor
            layer.cornerRadius = 1.5
            self.layer?.addSublayer(layer)
            blockCursorLayer = layer
        }
    }

    override func setSelectedRange(_ charRange: NSRange) {
        super.setSelectedRange(charRange)
        if let engine = vimEngine, !engine.mode.isEditing {
            DispatchQueue.main.async { [weak self] in
                self?.drawBlockCursor()
            }
        }
    }

    override func didChangeText() {
        super.didChangeText()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
        if let engine = vimEngine, !engine.mode.isEditing {
            DispatchQueue.main.async { [weak self] in
                self?.drawBlockCursor()
            }
        }
    }

    override func paste(_ sender: Any?) {
        if insertPastedImage() { return }
        super.paste(sender)
        if let font = self.font {
            applyBaseFont(font)
        }
        coordinator?.formattingDidChange()
    }

    /// If the pasteboard holds an image (raw data, an NSImage, or image file
    /// URLs), save it to the assets folder, insert it as an inline attachment,
    /// and return true. Returns false so normal text paste proceeds otherwise.
    private func insertPastedImage() -> Bool {
        let pasteboard = NSPasteboard.general

        // 1) Image file(s) on the pasteboard (e.g. dragged from Finder/Photos).
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            let imageURLs = urls.filter { Self.imageFileExtensions.contains($0.pathExtension.lowercased()) }
            var insertedAny = false
            for url in imageURLs {
                if let data = try? Data(contentsOf: url),
                   insertImage(data: data, fileExtension: url.pathExtension.lowercased()) {
                    insertedAny = true
                }
            }
            if insertedAny { return true }
        }

        // 2) Raw PNG/TIFF bytes on the pasteboard.
        if let png = pasteboard.data(forType: .png) {
            return insertImage(data: png, fileExtension: "png")
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return insertImage(data: png, fileExtension: "png")
        }

        // 3) An NSImage object (some apps only offer this).
        if let image = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage])?.first,
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            return insertImage(data: png, fileExtension: "png")
        }

        return false
    }

    private static let imageFileExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif", "tiff", "tif", "bmp", "webp"
    ]

    private func insertImage(data: Data, fileExtension: String) -> Bool {
        guard let image = NSImage(data: data),
              let relativePath = StorageManager.shared.saveImageAsset(data, fileExtension: fileExtension) else {
            return false
        }
        let attachment = ImageTextAttachment(image: image,
                                             assetRelativePath: relativePath,
                                             displayWidth: nil)
        let attachmentString = NSAttributedString(attachment: attachment)
        let range = selectedRange()
        guard shouldChangeText(in: range, replacementString: "\u{FFFC}") else { return false }
        textStorage?.replaceCharacters(in: range, with: attachmentString)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + 1, length: 0))
        coordinator?.formattingDidChange()
        return true
    }

    /// Re-lays out the line holding `attachment` after its size changes (during
    /// a resize drag) so the surrounding text reflows immediately.
    func invalidateLayout(for attachment: ImageTextAttachment) {
        guard let storage = textStorage, let layoutManager = layoutManager else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.attachment, in: full, options: []) { value, range, stop in
            if value as AnyObject === attachment {
                layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
                layoutManager.invalidateDisplay(forCharacterRange: range)
                stop.pointee = true
            }
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// Replaces literal `![](assets/…)` Markdown references in the document
    /// with inline image attachments loaded from disk. Runs on load (after the
    /// text is set), analogous to `restyleCodeBlocks`. References whose asset
    /// file is missing are left as plain text so nothing is silently lost.
    func renderImageAttachments() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let references = ImageMarkdown.references(in: storage.string)
        guard !references.isEmpty else { return }

        // Attachments are about to be replaced; drop any stale selection.
        selectedImageAttachment = nil

        storage.beginEditing()
        // Replace back-to-front so earlier match ranges stay valid.
        for reference in references.reversed() {
            guard reference.path.hasPrefix("assets/") else { continue }
            let url = StorageManager.shared.assetURL(forRelativePath: reference.path)
            guard let image = NSImage(contentsOf: url) else { continue }
            let attachment = ImageTextAttachment(image: image,
                                                 assetRelativePath: reference.path,
                                                 displayWidth: reference.width)
            storage.replaceCharacters(in: reference.range, with: NSAttributedString(attachment: attachment))
        }
        storage.endEditing()
        window?.invalidateCursorRects(for: self)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        drawCodeBlockBackgrounds(in: rect)

        guard paperStyle != "plain" else { return }
        
        guard let context = NSGraphicsContext.current?.cgContext,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }
        
        context.saveGState()
        
        let font = self.font ?? NSFont.systemFont(ofSize: 16)
        let fontHeight = layoutManager.defaultLineHeight(for: font)
        
        var lineSpacing: CGFloat = 8
        if let paragraphStyle = typingAttributes[.paragraphStyle] as? NSParagraphStyle {
            lineSpacing = paragraphStyle.lineSpacing
        }
        
        let bounds = self.bounds
        let textInset = self.textContainerInset
        let startX = textInset.width
        let endX = bounds.width - textInset.width
        
        let baseColor = self.textColor ?? (self.typingAttributes[.foregroundColor] as? NSColor) ?? NSColor.labelColor
        let strokeColor = baseColor.withAlphaComponent(paperStyle == "dotted" ? 0.24 : 0.15).cgColor
        
        context.setStrokeColor(strokeColor)
        context.setFillColor(strokeColor)

        // Draws one grid row (a dotted or solid rule) at view-space baseline `y`.
        let dotRadius: CGFloat = 0.8
        let spacingX: CGFloat = 20
        let isDotted = (paperStyle == "dotted")
        let drawRow: (CGFloat) -> Void = { y in
            if isDotted {
                var x = startX
                while x <= endX {
                    context.addArc(center: CGPoint(x: x, y: y), radius: dotRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                    context.fillPath()
                    x += spacingX
                }
            } else {
                context.setLineWidth(0.8)
                context.move(to: CGPoint(x: startX, y: y))
                context.addLine(to: CGPoint(x: endX, y: y))
                context.strokePath()
            }
        }

        let rowHeight = fontHeight + lineSpacing

        // 1. Existing text lines — only the fragments overlapping the dirty
        //    rect, instead of walking every fragment in the document.
        let containerDirty = NSRect(x: rect.minX,
                                    y: rect.minY - textInset.height,
                                    width: rect.width,
                                    height: rect.height)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: containerDirty, in: textContainer)
        if visibleGlyphs.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: visibleGlyphs) { fragRect, _, _, _, _ in
                drawRow(fragRect.origin.y + textInset.height + font.ascender + 2.0)
            }
        }

        // 2. Empty area below the text. The text bottom comes from usedRect in
        //    O(1) (layout is already done for display), so we don't have to
        //    enumerate fragments to find it. Grid rows are kept on the same
        //    arithmetic baseline as the text lines so the pattern is seamless,
        //    and we only emit rows within the dirty vertical span.
        let firstBaseline = textInset.height + font.ascender + 2.0
        let textBottom = layoutManager.usedRect(for: textContainer).maxY + textInset.height
        let kBelowText = ((textBottom - firstBaseline) / rowHeight).rounded(.down) + 1
        let kInDirty = ((rect.minY - firstBaseline) / rowHeight).rounded(.up)
        let kStart = max(0, max(kBelowText, kInDirty))
        var y = firstBaseline + kStart * rowHeight
        let limit = min(rect.maxY, bounds.height)
        while y < limit {
            drawRow(y)
            y += rowHeight
        }

        context.restoreGState()
    }

    private func drawCodeBlockBackgrounds(in rect: NSRect) {
        guard !codeBlockRanges.isEmpty,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }

        _ = layoutManager
        _ = textContainer

        let baseColor = self.textColor ?? (typingAttributes[.foregroundColor] as? NSColor) ?? NSColor.labelColor
        let fillColor = baseColor.withAlphaComponent(0.05)
        let strokeColor = baseColor.withAlphaComponent(0.10)

        for range in codeBlockRanges {
            guard let blockRect = codeBlockBoxRect(for: range) else { continue }
            // Skip blocks scrolled out of the dirty rect — no need to build a
            // bezier path and fill/stroke something that won't be visible.
            guard blockRect.intersects(rect) else { continue }
            let path = NSBezierPath(roundedRect: blockRect, xRadius: 6, yRadius: 6)
            fillColor.setFill()
            path.fill()
            strokeColor.setStroke()
            path.lineWidth = 0.75
            path.stroke()
        }
    }

    /// The drawn rounded-rect box for a code block range, in view coordinates.
    private func codeBlockBoxRect(for range: NSRange) -> NSRect? {
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return nil }
        let ns = string as NSString
        var safe = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        guard safe.length > 0 else { return nil }
        // Exclude the closing fence's trailing newline so the box doesn't bleed
        // into the line below.
        if ns.substring(with: NSRange(location: safe.location + safe.length - 1, length: 1)) == "\n" {
            safe.length -= 1
        }
        guard safe.length > 0 else { return nil }

        let origin = self.textContainerOrigin
        let inset = self.textContainerInset
        let startX = inset.width - 8
        let width = bounds.width - 2 * inset.width + 16

        let glyphRange = layoutManager.glyphRange(forCharacterRange: safe, actualCharacterRange: nil)
        var bounding = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        bounding.origin.x += origin.x
        bounding.origin.y += origin.y
        return NSRect(x: startX, y: bounding.minY - 3, width: width, height: bounding.height + 6)
    }

    /// The text inside a code block, excluding the opening and closing ``` lines.
    private func innerCodeContent(for range: NSRange) -> String {
        let ns = string as NSString
        let safe = NSIntersectionRange(range, NSRange(location: 0, length: ns.length))
        guard safe.length > 0 else { return "" }
        let openerLine = ns.lineRange(for: NSRange(location: safe.location, length: 0))
        let closerLine = ns.lineRange(for: NSRange(location: min(safe.location + safe.length - 1, ns.length), length: 0))
        let innerStart = openerLine.location + openerLine.length
        let innerEnd = closerLine.location
        guard innerEnd > innerStart else { return "" }
        var inner = ns.substring(with: NSRange(location: innerStart, length: innerEnd - innerStart))
        while inner.hasSuffix("\n") || inner.hasSuffix("\r") { inner.removeLast() }
        return inner
    }

    private func makeCopyButton() -> NSButton {
        let button = NSButton()
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        button.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")?
            .withSymbolConfiguration(cfg)
        button.target = self
        button.action = #selector(copyButtonClicked(_:))
        button.toolTip = "Copy code"
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.layer?.backgroundColor = NSColor.textColor.withAlphaComponent(0.06).cgColor
        return button
    }

    /// Reconcile copy buttons with the current code blocks and position each at the
    /// top-right of its block.
    func updateCopyButtons() {
        while copyButtons.count > codeBlockRanges.count {
            copyButtons.removeLast().removeFromSuperview()
        }
        while copyButtons.count < codeBlockRanges.count {
            let button = makeCopyButton()
            addSubview(button)
            copyButtons.append(button)
        }
        let size: CGFloat = 22
        let pad: CGFloat = 5
        for (i, range) in codeBlockRanges.enumerated() {
            let button = copyButtons[i]
            guard let rect = codeBlockBoxRect(for: range) else { button.isHidden = true; continue }
            button.tag = i
            button.isHidden = false
            button.frame = NSRect(x: rect.maxX - size - pad, y: rect.minY + pad, width: size, height: size)
        }
    }

    @objc private func copyButtonClicked(_ sender: NSButton) {
        let idx = sender.tag
        guard idx >= 0, idx < codeBlockRanges.count else { return }
        let content = innerCodeContent(for: codeBlockRanges[idx])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(content, forType: .string)

        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        sender.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(cfg)
        sender.contentTintColor = .systemGreen
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak sender] in
            sender?.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Copy")?
                .withSymbolConfiguration(cfg)
            sender?.contentTintColor = .secondaryLabelColor
        }
    }

    override func layout() {
        super.layout()
        updateCopyButtons()
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

}

// MARK: - Premium Slim Overlay Scroller

/// A thin, capsule-shaped overlay scrollbar that matches the Apple Notes / Finder
/// aesthetic: ~7pt wide thumb, no visible track, soft opacity, native fade.
final class PremiumScroller: NSScroller {

    // Required so AppKit knows to use the overlay style for this instance.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    // Collapse the scroller's reserved layout width to zero so it truly overlays.
    override var frame: NSRect {
        get { super.frame }
        set {
            // Force the width to be the same as the standard overlay width (~15pt)
            // but we paint only a narrow thumb inside it.
            super.frame = newValue
        }
    }

    override func drawKnob() {
        let knobRect = rect(for: .knob)
        guard knobRect.height > 0 else { return }

        // Pin the 6pt thumb flush to the far-right edge of the knob rect.
        let thumbWidth: CGFloat = 6
        let edgeGap: CGFloat = 0
        let thumbX = knobRect.maxX - thumbWidth - edgeGap
        let thumbInsetY: CGFloat = 2
        let thumbRect = CGRect(
            x: thumbX,
            y: knobRect.minY + thumbInsetY,
            width: thumbWidth,
            height: max(knobRect.height - thumbInsetY * 2, thumbWidth)
        )

        let path = NSBezierPath(roundedRect: thumbRect, xRadius: thumbWidth / 2, yRadius: thumbWidth / 2)

        // Soft, semi-transparent fill — adapts to light and dark mode.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let fillColor = isDark
            ? NSColor.white.withAlphaComponent(0.30)
            : NSColor.black.withAlphaComponent(0.20)
        fillColor.setFill()
        path.fill()
    }

    // Draw nothing for the track — keep it completely transparent.
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
}
