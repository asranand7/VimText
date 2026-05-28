import SwiftUI
import AppKit

class FindController: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var query: String = ""
    @Published var currentMatch: Int = 0
    @Published var totalMatches: Int = 0
    @Published var focusTrigger: Int = 0

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

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    static func paragraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 5
        style.paragraphSpacing = 0
        return style
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
        textView.textContainerInset = NSSize(width: 34, height: 20)
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

        textView.applyBaseFont(font)
        textView.restyleCodeBlocks(baseFont: font)

        let isInsert = vimEngine.mode.isEditing || startInInsertMode
        textView.updateCursorAppearance(isBlock: !isInsert)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? VimNSTextView else { return }
        context.coordinator.parent = self

        if !context.coordinator.isUpdatingFromTextView && textView.string != text {
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
            let safeLocation = min(selectedRange.location, textView.string.count)
            textView.setSelectedRange(NSRange(location: safeLocation, length: 0))
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
        }

        if context.coordinator.lastPaperStyle != paperStyle {
            context.coordinator.lastPaperStyle = paperStyle
            textView.paperStyle = paperStyle
            textView.needsDisplay = true
        }

        textView.smartLists = smartLists

        textView.updateCursorAppearance(isBlock: !vimEngine.mode.isEditing)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: VimTextView
        weak var textView: VimNSTextView?
        weak var scrollView: NSScrollView?
        var isUpdatingFromTextView = false
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
        var refocusObserver: Any?
        private var findMatchRanges: [NSRange] = []
        private var currentFindIndex: Int = -1

        init(_ parent: VimTextView) {
            self.parent = parent
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

        private func performFindInEditor(query: String) {
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
                searchRange.location = found.location + found.length
                searchRange.length = length - searchRange.location
            }

            textView.highlightAllMatches(term: query)

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
            guard let textView = notification.object as? NSTextView else { return }
            isUpdatingFromTextView = true
            parent.text = textView.string

            if let vimTextView = textView as? VimNSTextView {
                vimTextView.restyleCodeBlocks(baseFont: parent.font)
            }

            // Export RTF data to preserve rich text formatting
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                let range = NSRange(location: 0, length: textStorage.length)
                if let data = try? textStorage.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    parent.rtfData = data
                }
            } else {
                parent.rtfData = Data()
            }

            DispatchQueue.main.async {
                self.isUpdatingFromTextView = false
            }

            if parent.findController?.isVisible == true,
               let query = parent.findController?.query, !query.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.performFindInEditor(query: query)
                }
            }
        }

        func formattingDidChange() {
            guard let textView = textView else { return }
            isUpdatingFromTextView = true
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                let range = NSRange(location: 0, length: textStorage.length)
                if let data = try? textStorage.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
                    parent.rtfData = data
                }
            }
            DispatchQueue.main.async {
                self.isUpdatingFromTextView = false
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            return false
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            let string = textView.string
            let nsString = string as NSString
            let cursorPos = textView.selectedRange().location
            let length = nsString.length
            
            let lineRange = nsString.lineRange(for: NSRange(location: min(cursorPos, length), length: 0))
            let lineText = nsString.substring(with: NSRange(location: lineRange.location, length: min(cursorPos, length) - lineRange.location))
            let col = lineText.count + 1
            
            var lineNum = 1
            var pos = 0
            while pos < lineRange.location {
                let r = nsString.lineRange(for: NSRange(location: pos, length: 0))
                lineNum += 1
                pos = r.location + r.length
                if r.length == 0 { break }
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
                    case .insertMode, .deleteMotion, .deleteLine, .deleteToEnd, .deleteChar,
                         .deleteCharBefore, .changeMotion, .changeLine, .changeToEnd,
                         .deleteTextObject, .changeTextObject, .toggleCase, .joinLines,
                         .pasteAfter, .pasteBefore, .indent, .outdent, .replaceChar:
                        return true
                    default:
                        return false
                    }
                }
                let entersInsert = actions.contains { action in
                    switch action {
                    case .insertMode, .changeMotion, .changeLine, .changeToEnd, .changeTextObject:
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
                    case .insertMode, .changeMotion, .changeLine, .changeToEnd, .changeTextObject:
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
                return findWordForward(from: cursorPos, in: string)

            case .wordBackward:
                return findWordBackward(from: cursorPos, in: string)

            case .wordEnd:
                return findWordEnd(from: cursorPos, in: string)

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
            }
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

        private func findWordForward(from pos: Int, in string: String) -> Int {
            guard pos < string.utf16.count else { return pos }
            let startIndex = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
            var i = startIndex
            let startType = charType(string[i])
            
            while i < string.endIndex && charType(string[i]) == startType {
                i = string.index(after: i)
            }
            while i < string.endIndex && charType(string[i]) == .whitespace {
                i = string.index(after: i)
            }
            return i.utf16Offset(in: string)
        }

        private func findWordBackward(from pos: Int, in string: String) -> Int {
            guard pos > 0 else { return 0 }
            let startIndex = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
            var i = startIndex
            
            while i > string.startIndex {
                let prevIdx = string.index(before: i)
                if charType(string[prevIdx]) == .whitespace {
                    i = prevIdx
                } else {
                    break
                }
            }
            
            guard i > string.startIndex else { return 0 }
            let lastIdx = string.index(before: i)
            let targetType = charType(string[lastIdx])
            
            while i > string.startIndex {
                let prevIdx = string.index(before: i)
                if charType(string[prevIdx]) == targetType {
                    i = prevIdx
                } else {
                    break
                }
            }
            return i.utf16Offset(in: string)
        }

        private func findWordEnd(from pos: Int, in string: String) -> Int {
            guard pos < string.utf16.count else { return pos }
            let startIndex = string.utf16.index(string.utf16.startIndex, offsetBy: pos)
            var i = startIndex
            
            if i == string.endIndex || string.index(after: i) == string.endIndex {
                return pos
            }
            
            i = string.index(after: i)
            
            while i < string.endIndex && charType(string[i]) == .whitespace {
                i = string.index(after: i)
            }
            
            if i < string.endIndex {
                let targetType = charType(string[i])
                while i < string.endIndex {
                    let nextIdx = string.index(after: i)
                    if nextIdx < string.endIndex && charType(string[nextIdx]) == targetType {
                        i = nextIdx
                    } else {
                        break
                    }
                }
            }
            return min(i.utf16Offset(in: string), string.utf16.count - 1)
        }

        private enum CharType {
            case word, punctuation, whitespace
        }

        private func charType(_ char: Character) -> CharType {
            if char.isNewline || char.isWhitespace { return .whitespace }
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
    private var searchHighlightLayers: [CALayer] = []
    private var currentMatchLayer: CALayer?

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

    func highlightAllMatches(term: String) {
        clearSearchHighlights()
        guard !term.isEmpty else { return }
        let nsString = self.string as NSString
        let length = nsString.length
        guard length > 0 else { return }
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }

        self.wantsLayer = true
        var searchRange = NSRange(location: 0, length: length)
        while searchRange.location < length {
            let found = nsString.range(of: term, options: [.caseInsensitive], range: searchRange)
            if found.location == NSNotFound { break }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: found, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            var highlightRect = rect
            highlightRect.origin.x += self.textContainerOrigin.x
            highlightRect.origin.y += self.textContainerOrigin.y

            let layer = CALayer()
            layer.frame = highlightRect
            layer.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.3).cgColor
            layer.cornerRadius = 2
            layer.borderWidth = 0.5
            layer.borderColor = NSColor.systemYellow.withAlphaComponent(0.5).cgColor
            layer.name = "searchHighlight"
            self.layer?.addSublayer(layer)
            searchHighlightLayers.append(layer)

            searchRange.location = found.location + found.length
            searchRange.length = length - searchRange.location
        }
    }

    func clearSearchHighlights() {
        for layer in searchHighlightLayers {
            layer.removeFromSuperlayer()
        }
        searchHighlightLayers.removeAll()
        currentMatchLayer?.removeFromSuperlayer()
        currentMatchLayer = nil
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
        var inBlock = false
        var blockStart = 0
        var idx = 0
        while idx < len {
            let lineRange = ns.lineRange(for: NSRange(location: idx, length: 0))
            let trimmed = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            let isFence = trimmed.hasPrefix("```")
            if isFence {
                if inBlock {
                    let end = lineRange.location + lineRange.length
                    ranges.append(NSRange(location: blockStart, length: end - blockStart))
                    inBlock = false
                } else {
                    inBlock = true
                    blockStart = lineRange.location
                }
            }
            let next = lineRange.location + lineRange.length
            if next <= idx { break }
            idx = next
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

    override func keyDown(with event: NSEvent) {
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

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
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
        if let engine = vimEngine, !engine.mode.isEditing {
            DispatchQueue.main.async { [weak self] in
                self?.drawBlockCursor()
            }
        }
    }

    override func paste(_ sender: Any?) {
        super.paste(sender)
        if let font = self.font {
            applyBaseFont(font)
        }
        coordinator?.formattingDidChange()
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
        
        var lastLineY: CGFloat = textInset.height + font.ascender + 2.0 - (fontHeight + lineSpacing)
        var estimatedRowHeight = fontHeight + lineSpacing
        
        // 1. Draw lines/dots for existing lines using Layout Manager
        let glyphRange = layoutManager.glyphRange(for: textContainer)
        if glyphRange.length > 0 {
            layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, usedRect, container, range, stop in
                let lineRectY = rect.origin.y + textInset.height
                let y = lineRectY + font.ascender + 2.0
                
                if self.paperStyle == "dotted" {
                    let dotRadius: CGFloat = 0.8
                    let spacingX: CGFloat = 20
                    var x = startX
                    while x <= endX {
                        context.addArc(center: CGPoint(x: x, y: y), radius: dotRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                        context.fillPath()
                        x += spacingX
                    }
                } else if self.paperStyle == "lined" {
                    context.setLineWidth(0.8)
                    context.move(to: CGPoint(x: startX, y: y))
                    context.addLine(to: CGPoint(x: endX, y: y))
                    context.strokePath()
                }
                
                lastLineY = y
                estimatedRowHeight = rect.height
            }
        }
        
        // 2. Draw lines/dots for the empty area below the text
        var y = lastLineY + estimatedRowHeight
        while y < bounds.height {
            if paperStyle == "dotted" {
                let dotRadius: CGFloat = 0.8
                let spacingX: CGFloat = 20
                var x = startX
                while x <= endX {
                    context.addArc(center: CGPoint(x: x, y: y), radius: dotRadius, startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                    context.fillPath()
                    x += spacingX
                }
            } else if paperStyle == "lined" {
                context.setLineWidth(0.8)
                context.move(to: CGPoint(x: startX, y: y))
                context.addLine(to: CGPoint(x: endX, y: y))
                context.strokePath()
            }
            y += estimatedRowHeight
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
