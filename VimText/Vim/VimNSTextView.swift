import SwiftUI
import AppKit

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
