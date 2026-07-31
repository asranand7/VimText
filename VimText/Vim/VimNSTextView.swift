import SwiftUI
import AppKit

class VimNSTextView: NSTextView, NSViewToolTipOwner {
    var vimEngine: VimEngine?
    weak var coordinator: VimTextView.Coordinator?
    var accentColor: NSColor = .systemOrange
    var paperStyle: String = "plain"
    var smartLists: Bool = true
    /// Read-only mode for locked notes — Vim mutations are rejected with a
    /// status hint (see Coordinator.executeActions and keyDown's `r` path).
    var isLockedNote: Bool = false
    var codeBlockRanges: [NSRange] = []
    /// Union of the character ranges edited since the last code-block restyle
    /// (post-edit coordinates, maintained by the text-storage delegate). Lets
    /// `restyleMarkdown` fix up just the edited region when the fence
    /// structure didn't change, instead of rewriting the whole document's
    /// attributes on every typing pause in a note that contains code blocks.
    private var editedRangeSinceRestyle: NSRange?
    /// Net document-length change across the edits accumulated in
    /// `editedRangeSinceRestyle`. Together they say "everything outside this
    /// region is unchanged, and everything after it moved by exactly this
    /// much" — which is what lets the fence scan be skipped (see
    /// `codeBlockRangesShiftedIfStructureIntact`).
    private var lengthDeltaSinceRestyle = 0
    /// The same accumulation on the heading cadence. Headings are refreshed per
    /// keystroke and code blocks only on the typing pause, so the two consume
    /// their edits at different times and can't share one accumulator.
    private var editedRangeSinceHeadingScan: NSRange?
    private var lengthDeltaSinceHeadingScan = 0
    /// Whether a full scan has ever established a baseline for each of the two.
    /// Until then the incremental paths have nothing trustworthy to shift — the
    /// storage can be filled before the delegate is wired, which is
    /// indistinguishable from "no edits since the last scan".
    private var hasScannedCodeBlocks = false
    private var hasScannedHeadings = false
    private var copyButtons: [NSButton] = []
    private var blockCursorLayer: CALayer?
    /// Set while a coalesced block-cursor redraw is already queued for this
    /// runloop turn, so several selection changes in one turn schedule just one.
    private var blockCursorRedrawScheduled = false
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
    /// Folded snapshot of the document for search (see `String.searchFolded`).
    /// Folding a multi-MB note is O(n), so it's cached across find-bar
    /// keystrokes and `n`/`N` presses and invalidated on edit — not recomputed
    /// per search.
    private var foldedSearchString: NSString?
    /// The last search scan (folded term → match ranges). Repeat `n`/`N`
    /// presses on the same term reuse it instead of rescanning the document.
    private var searchMatchCache: (term: String, ranges: [NSRange])?
    /// The folded term whose match highlights are currently painted, so a
    /// repeated `n` doesn't re-add thousands of temporary attributes.
    private var appliedHighlightTerm: String?

    /// Drops the folded-document and match caches. Called on every text
    /// mutation (`didChangeText` plus the load-time attachment rewrite).
    func invalidateSearchCaches() {
        foldedSearchString = nil
        searchMatchCache = nil
        appliedHighlightTerm = nil
    }

    /// All ranges of `term` in the document (searchFolded on both sides so
    /// straight quotes match smart quotes; folding is 1:1 in UTF-16, so the
    /// ranges are valid in the live text storage), in document order, capped
    /// at `maxSearchMatches`. Both the folded document snapshot and the
    /// per-term scan are cached until the next edit, so the Vim search and
    /// the find bar share one scan instead of re-folding the whole note.
    func searchMatches(for term: String) -> [NSRange] {
        let term = term.searchFolded
        guard !term.isEmpty else { return [] }
        if let cache = searchMatchCache, cache.term == term { return cache.ranges }

        let nsString: NSString
        if let cached = foldedSearchString {
            nsString = cached
        } else {
            nsString = self.string.searchFolded as NSString
            foldedSearchString = nsString
        }
        let length = nsString.length
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
        searchMatchCache = (term, ranges)
        return ranges
    }

    func highlightCurrentMatch(range: NSRange) {
        currentMatchLayer?.removeFromSuperlayer()
        currentMatchLayer = nil
        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }
        // Clip to the visible (unfolded) pieces of the match so a match that
        // falls inside a collapsed URL doesn't draw its box at the fold's
        // zero-width glyph position — see FoldingLayoutManager.visibleSubranges.
        let foldingLM = layoutManager as? FoldingLayoutManager
        let pieces = (foldingLM?.visibleSubranges(of: range) ?? [range]).filter { $0.length > 0 }
        guard var rect = pieces.first.map({
            layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: $0, actualCharacterRange: nil), in: textContainer)
        }) else { return }
        for piece in pieces.dropFirst() {
            let gr = layoutManager.glyphRange(forCharacterRange: piece, actualCharacterRange: nil)
            rect = rect.union(layoutManager.boundingRect(forGlyphRange: gr, in: textContainer))
        }
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
        // Clip each match to its visible (unfolded) pieces — a match that
        // falls inside a collapsed URL has no on-screen glyphs to paint over.
        let foldingLM = layoutManager as? FoldingLayoutManager
        var applied = 0
        for r in ranges {
            let safe = NSIntersectionRange(r, NSRange(location: 0, length: length))
            guard safe.length > 0 else { continue }
            for piece in foldingLM?.visibleSubranges(of: safe) ?? [safe] where piece.length > 0 {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: piece)
            }
            applied += 1
            if applied >= Self.maxSearchMatches { break }
        }
        hasTemporarySearchHighlights = applied > 0
    }

    /// Scans for `term` and highlights all matches. Used by the Vim `/` search.
    /// Returns the match ranges so callers (`n`/`N` navigation) can move the
    /// cursor without a second scan of the document. Re-applying the same
    /// term's highlights while they're still painted is skipped entirely.
    @discardableResult
    func highlightAllMatches(term: String) -> [NSRange] {
        guard !term.isEmpty else { clearSearchHighlights(); return [] }
        let ranges = searchMatches(for: term)
        guard !ranges.isEmpty else { clearSearchHighlights(); return [] }
        let folded = term.searchFolded
        if !hasTemporarySearchHighlights || appliedHighlightTerm != folded {
            applyMatchHighlights(ranges)
            appliedHighlightTerm = folded
        }
        return ranges
    }

    func clearSearchHighlights() {
        currentMatchLayer?.removeFromSuperlayer()
        currentMatchLayer = nil
        appliedHighlightTerm = nil
        if hasTemporarySearchHighlights, let layoutManager = self.layoutManager {
            let fullRange = NSRange(location: 0, length: (self.string as NSString).length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
            hasTemporarySearchHighlights = false
        }
    }

    // MARK: - Links

    /// Links currently detected in the document. Refreshed on load, on theme
    /// change, and when typing pauses (the deferred-work pass) — so between
    /// refreshes the ranges can briefly lag the text by one edit burst.
    private(set) var detectedLinks: [LinkDetection.Link] = []

    /// Detects URLs and styles them via temporary layout-manager attributes —
    /// the same display-only mechanism as search highlights, so link styling
    /// is never serialized into the note's content or RTF.
    func refreshLinkHighlights() {
        applyLinkHighlights(LinkDetection.links(in: self.string))
    }

    /// Documents at or below this UTF-16 length get the synchronous link scan
    /// (no chip pop-in); anything larger goes through the deferred scan so the
    /// NSDataDetector pass can't stall note-open or a theme switch.
    private static let syncLinkScanLimit = 64_000

    /// Sync link refresh for normal-sized notes, deferred for large ones.
    /// Use anywhere a full rescan happens on the main thread with the user
    /// waiting (note open, theme change).
    func refreshLinkHighlightsAdaptive() {
        if (self.string as NSString).length <= Self.syncLinkScanLimit {
            refreshLinkHighlights()
        } else {
            refreshLinkHighlightsDeferred()
        }
    }

    /// Re-detects links off the main thread, then applies the result back on
    /// it. NSDataDetector over a multi-MB note is too slow to run on the main
    /// thread on every typing pause, so the per-edit path uses this; the apply
    /// is skipped if the text length changed since the snapshot, so a stale
    /// scan never paints ranges that no longer line up. NSDataDetector (an
    /// NSRegularExpression subclass) is documented thread-safe for concurrent
    /// use, and the highlights are display-only temporary attributes, so doing
    /// the detection off-main is safe.
    func refreshLinkHighlightsDeferred() {
        let snapshot = self.string
        let length = (snapshot as NSString).length
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let links = LinkDetection.links(in: snapshot)
            DispatchQueue.main.async {
                guard let self, (self.string as NSString).length == length else { return }
                self.applyLinkHighlights(links)
            }
        }
    }

    /// Applies already-detected `links` as display-only temporary attributes,
    /// replacing whatever was applied before. Must run on the main thread.
    private func applyLinkHighlights(_ links: [LinkDetection.Link]) {
        guard let layoutManager = self.layoutManager else { return }
        let length = (self.string as NSString).length
        // Full-range removal is safe: links are the only temporary
        // foreground/underline users (search highlights use .backgroundColor).
        if !detectedLinks.isEmpty, length > 0 {
            let fullRange = NSRange(location: 0, length: length)
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            layoutManager.removeTemporaryAttribute(.underlineStyle, forCharacterRange: fullRange)
        }
        detectedLinks = links
        guard !detectedLinks.isEmpty else {
            window?.invalidateCursorRects(for: self)
            return
        }
        for link in detectedLinks {
            let safe = NSIntersectionRange(link.range, NSRange(location: 0, length: length))
            guard safe.length > 0 else { continue }
            // Modern link styling: accent color alone carries "this is a link".
            // We actively force underlineStyle = 0 (not just skip adding one):
            // browser-pasted URLs arrive as real `.link` attributes in the RTF
            // with a baked-in underline, which NSTextView renders from storage.
            // A temporary attribute overrides that for display without resaving,
            // so both typed and pasted links read as clean accent-colored text.
            layoutManager.addTemporaryAttribute(.foregroundColor, value: accentColor, forCharacterRange: safe)
            layoutManager.addTemporaryAttribute(.underlineStyle, value: 0, forCharacterRange: safe)
        }
        window?.invalidateCursorRects(for: self)
        updateLinkFolds()
    }

    /// The chip/marker text height for the editor's current base font. Reads
    /// the SwiftUI-side font first: NSTextView's `font` getter can lag behind
    /// `applyBaseFont` right after a font-size change, which would size chips
    /// for the previous font.
    private func chipTextHeightForCurrentFont() -> CGFloat {
        let baseFont = coordinator?.parent.font ?? font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        return layoutManager?.defaultLineHeight(for: baseFont) ?? 18
    }

    /// Recomputes which links collapse to a domain chip. The link the caret is
    /// currently on stays expanded so its full URL can be read and edited; every
    /// other link folds. Display-only — the document text is never modified.
    func updateLinkFolds() {
        guard let foldingLM = layoutManager as? FoldingLayoutManager else { return }
        foldingLM.chipFillColor = accentColor.withAlphaComponent(0.12)
        foldingLM.chipHoverFillColor = accentColor.withAlphaComponent(0.26)
        foldingLM.chipStrokeColor = accentColor.withAlphaComponent(0.24)
        foldingLM.chipIconColor = accentColor
        foldingLM.chipTextHeight = chipTextHeightForCurrentFont()

        guard !detectedLinks.isEmpty else {
            foldingLM.setFolds([])
            return
        }

        let sel = selectedRange()
        // A link is "active" (kept expanded) when the caret/selection touches it,
        // including the boundaries — so stepping onto a chip reveals it for
        // editing and the caret never lands inside hidden, zero-width glyphs.
        let active = detectedLinks.first { link in
            let start = link.range.location
            let end = link.range.location + link.range.length
            if sel.length == 0 {
                return sel.location >= start && sel.location <= end
            }
            return NSIntersectionRange(sel, link.range).length > 0
        }

        let folds = LinkFolding.computeFolds(
            links: detectedLinks,
            activeLinkRange: active?.range,
            in: self.string as NSString
        )
        foldingLM.setFolds(folds)
        needsDisplay = true
    }

    // MARK: - List markers (bullets / checkboxes)

    /// All list markers in the document, recomputed when content changes.
    private(set) var detectedMarkers: [ListMarkers.Marker] = []

    /// Re-detects bullet/checkbox markers from the current text, then applies
    /// them. Call on load and after edits — detection is cheap (a line scan).
    func refreshListMarkers() {
        detectedMarkers = ListMarkers.detect(in: self.string as NSString)
        applyListMarkers()
    }

    /// Pushes the active marker set to the layout manager. Bullets always render;
    /// a checkbox on the caret's line shows raw `- [ ]` so it can be edited (its
    /// hidden bracket glyphs would otherwise trap the caret).
    func applyListMarkers() {
        guard let foldingLM = layoutManager as? FoldingLayoutManager else { return }
        let base = (typingAttributes[.foregroundColor] as? NSColor) ?? .labelColor
        foldingLM.markerTextColor = base.withAlphaComponent(0.55)
        foldingLM.markerAccentColor = accentColor
        foldingLM.chipTextHeight = chipTextHeightForCurrentFont()

        guard !detectedMarkers.isEmpty else {
            foldingLM.setMarkers([])
            return
        }

        let sel = selectedRange()
        let active = detectedMarkers.filter { marker in
            guard case .checkbox = marker.kind else { return true } // bullets always render
            let start = marker.lineRange.location
            let end = marker.lineRange.location + marker.lineRange.length
            let caretOnLine = sel.length == 0
                ? (sel.location >= start && sel.location <= end)
                : NSIntersectionRange(sel, marker.lineRange).length > 0
            return !caretOnLine
        }
        foldingLM.setMarkers(active)
        needsDisplay = true
    }

    // MARK: - Heading prefixes (`## Heading` renders as `Heading`)

    /// One heading line's foldable `#` prefix.
    struct HeadingPrefix: Equatable {
        /// The line without its terminator — used to keep the caret's own line
        /// showing raw `## ` text.
        let lineRange: NSRange
        /// The hashes plus the whitespace separating them from the text.
        let prefixRange: NSRange
    }

    /// Heading prefixes in the document, recomputed when content changes.
    private(set) var detectedHeadings: [HeadingPrefix] = []

    /// Re-detects every `#{1,6} ` prefix in the document, then applies them.
    /// This is the authoritative pass — note open, font/theme change, and the
    /// deferred typing-pause pass — and it walks the whole document, so it must
    /// not run per keystroke (see `refreshHeadingFoldsForEdit`).
    func refreshHeadingFolds() {
        detectedHeadings = scanHeadings(in: NSRange(location: 0, length: (string as NSString).length))
        hasScannedHeadings = true
        editedRangeSinceHeadingScan = nil
        lengthDeltaSinceHeadingScan = 0
        applyHeadingFolds()
    }

    /// Per-keystroke heading maintenance. Heading-ness is a line-local property
    /// and the folds are plain character ranges, so an edit can only do two
    /// things: change the headings on the lines it touched, and move every
    /// heading after it by the edit's length delta. Both are derivable from the
    /// accumulated edit region — so this re-scans one paragraph and shifts an
    /// array, where a full `refreshHeadingFolds()` scanned the entire document
    /// on every keystroke (16 ms on a 2.5 MB note, i.e. slower than key repeat).
    /// The deferred pass still does the full scan, so any drift self-corrects
    /// on the next typing pause.
    func refreshHeadingFoldsForEdit() {
        guard hasScannedHeadings else { refreshHeadingFolds(); return }
        guard let edited = editedRangeSinceHeadingScan else {
            // No character edit since the last scan (an attribute-only pass):
            // the ranges still line up, only the caret may have moved.
            applyHeadingFolds()
            return
        }
        let delta = lengthDeltaSinceHeadingScan
        editedRangeSinceHeadingScan = nil
        lengthDeltaSinceHeadingScan = 0

        let ns = string as NSString
        let docRange = NSRange(location: 0, length: ns.length)
        // Re-scan whole paragraphs: a heading is defined by its line, so a line
        // the edit touched anywhere must be re-decided in full.
        let region = ns.paragraphRange(for: clamped(edited, to: docRange))
        // The same region in pre-edit coordinates. Text before it is untouched
        // (every accumulated edit starts at or after `region.location`), and
        // text after it moved by exactly `delta`.
        let oldStart = region.location
        let oldEnd = max(oldStart, NSMaxRange(region) - delta)

        var updated: [HeadingPrefix] = []
        updated.reserveCapacity(detectedHeadings.count + 1)
        for heading in detectedHeadings where NSMaxRange(heading.lineRange) <= oldStart {
            updated.append(heading)
        }
        updated.append(contentsOf: scanHeadings(in: region))
        for heading in detectedHeadings where heading.lineRange.location >= oldEnd {
            updated.append(HeadingPrefix(
                lineRange: NSRange(location: heading.lineRange.location + delta,
                                   length: heading.lineRange.length),
                prefixRange: NSRange(location: heading.prefixRange.location + delta,
                                     length: heading.prefixRange.length)
            ))
        }
        detectedHeadings = updated
        applyHeadingFolds()
    }

    /// Every heading prefix on a line starting inside `region`, in document
    /// order. Hops between `#` occurrences rather than walking every line, so a
    /// region without hashes costs one failed search.
    private func scanHeadings(in region: NSRange) -> [HeadingPrefix] {
        let ns = string as NSString
        let region = NSIntersectionRange(region, NSRange(location: 0, length: ns.length))
        let end = NSMaxRange(region)
        var found: [HeadingPrefix] = []
        var search = region
        while search.location < end {
            let hash = ns.range(of: "#", options: [], range: search)
            if hash.location == NSNotFound { break }
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: hash)
            // A heading `#` can only start a line, so one probe per line is
            // enough — skip to the next line either way.
            if lineStart == hash.location,
               let prefix = headingPrefix(in: ns, lineStart: lineStart, contentsEnd: contentsEnd),
               // codeBlockRanges can be up to one typing pause stale here; the
               // deferred restyle's refresh corrects any misfold.
               !isLocationInCodeBlock(lineStart) {
                found.append(HeadingPrefix(
                    lineRange: NSRange(location: lineStart, length: contentsEnd - lineStart),
                    prefixRange: prefix
                ))
            }
            let next = max(lineEnd, hash.location + 1)
            guard next < end else { break }
            search = NSRange(location: next, length: end - next)
        }
        return found
    }

    /// The `#`-and-whitespace range to hide on a heading line, or nil when the
    /// line isn't a heading or has no text after the prefix — hiding the whole
    /// of a bare `## ` line would leave an unexplained blank line.
    private func headingPrefix(in ns: NSString, lineStart: Int, contentsEnd: Int) -> NSRange? {
        let lineRange = NSRange(location: lineStart, length: contentsEnd - lineStart)
        guard let level = Self.headingLevel(in: ns, lineRange: lineRange) else { return nil }
        var i = lineStart + level
        while i < contentsEnd, ns.character(at: i) == 0x20 || ns.character(at: i) == 0x09 { i += 1 }
        guard i < contentsEnd else { return nil }
        return NSRange(location: lineStart, length: i - lineStart)
    }

    /// Pushes the hidden prefixes to the layout manager, leaving the caret's own
    /// line raw so the `#`s can be read and edited (and so the caret never has
    /// to sit among hidden, zero-width glyphs). A ranged selection keeps every
    /// prefix folded — unfolding each heading a visual-mode selection swept
    /// over would reflow the text under the selection.
    func applyHeadingFolds() {
        guard let foldingLM = layoutManager as? FoldingLayoutManager else { return }
        guard !detectedHeadings.isEmpty else {
            foldingLM.setHeadingPrefixes([])
            return
        }
        let sel = selectedRange()
        let hidden = detectedHeadings.compactMap { heading -> NSRange? in
            if sel.length == 0,
               sel.location >= heading.lineRange.location,
               sel.location <= NSMaxRange(heading.lineRange) { return nil }
            return heading.prefixRange
        }
        foldingLM.setHeadingPrefixes(hidden)
        needsDisplay = true
    }

    /// If `point` (view coordinates) lands on a rendered checkbox, toggles its
    /// `[ ]`↔`[x]` character in the text. Returns true when it handled the click.
    func toggleCheckboxIfClicked(at point: NSPoint) -> Bool {
        guard isEditable, !isLockedNote,
              let foldingLM = layoutManager as? FoldingLayoutManager else { return false }
        for marker in foldingLM.markers {
            guard case .checkbox = marker.kind,
                  let toggleIndex = marker.toggleCharIndex,
                  var box = foldingLM.checkboxBox(for: marker) else { continue }
            box.origin.x += textContainerOrigin.x
            box.origin.y += textContainerOrigin.y
            guard box.insetBy(dx: -5, dy: -5).contains(point) else { continue }
            toggleCheckbox(atCharIndex: toggleIndex)
            return true
        }
        return false
    }

    private func toggleCheckbox(atCharIndex index: Int) {
        guard let storage = textStorage, index < storage.length else { return }
        let ch = (storage.string as NSString).character(at: index)
        let replacement = (ch == 0x78 || ch == 0x58) ? " " : "x"
        let range = NSRange(location: index, length: 1)
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        refreshListMarkers()
    }

    /// The detected link containing `characterIndex`, if any.
    func link(at characterIndex: Int) -> LinkDetection.Link? {
        detectedLinks.first { NSLocationInRange(characterIndex, $0.range) }
    }

    private func link(atPoint point: NSPoint) -> LinkDetection.Link? {
        guard !detectedLinks.isEmpty else { return nil }
        let index = characterIndexForInsertion(at: point)
        // The insertion index sits between characters; check both neighbors so
        // clicks land anywhere on the link's glyphs.
        return link(at: index) ?? (index > 0 ? link(at: index - 1) : nil)
    }

    func openLink(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyLinkToPasteboard(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        vimEngine?.statusMessage = "Link copied"
    }

    @objc private func openLinkMenuItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { openLink(url) }
    }

    @objc private func copyLinkMenuItem(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { copyLinkToPasteboard(url) }
    }

    /// Right-clicking a link gets Open/Copy items on top of the normal menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = link(atPoint: point) else { return menu }
        let result = menu ?? NSMenu()
        let open = NSMenuItem(title: "Open Link", action: #selector(openLinkMenuItem(_:)), keyEquivalent: "")
        open.target = self
        open.representedObject = hit.url
        let copy = NSMenuItem(title: "Copy Link", action: #selector(copyLinkMenuItem(_:)), keyEquivalent: "")
        copy.target = self
        copy.representedObject = hit.url
        if result.items.isEmpty {
            result.addItem(open)
            result.addItem(copy)
        } else {
            result.insertItem(.separator(), at: 0)
            result.insertItem(copy, at: 0)
            result.insertItem(open, at: 0)
        }
        return result
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
        applyBaseFont(baseFont, in: NSRange(location: 0, length: textStorage.length))
    }

    /// Normalizes font (preserving bold/italic traits) and paragraph style over
    /// `range` only. Paste uses this scoped to the inserted text — rewriting
    /// attributes across the whole document made pasting into a large note
    /// O(document) instead of O(pasted text).
    func applyBaseFont(_ baseFont: NSFont, in range: NSRange) {
        guard let textStorage = textStorage else { return }
        let fullRange = NSIntersectionRange(range, NSRange(location: 0, length: textStorage.length))
        guard fullRange.length > 0 else { return }
        let fontManager = NSFontManager.shared
        // Cosmetic-only: don't pollute the undo stack with font attribute
        // changes — stale undo entries referencing deallocated fonts crash.
        undoManager?.disableUndoRegistration()
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
        undoManager?.enableUndoRegistration()
    }

    func applyTextColor(_ color: NSColor) {
        guard let textStorage = textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        guard fullRange.length > 0 else { return }
        // Cosmetic-only: don't register theme color changes on the undo stack.
        undoManager?.disableUndoRegistration()
        textStorage.beginEditing()
        textStorage.addAttribute(.foregroundColor, value: color, range: fullRange)
        textStorage.endEditing()
        undoManager?.enableUndoRegistration()
    }

    /// True if the document carries manual rich formatting that only RTF can
    /// preserve: bold/italic/underline/strikethrough runs. Theme foreground
    /// color, code-block monospacing, heading fonts, and image attachments are
    /// deliberately excluded — all are re-derived on load from the plain `.txt`
    /// (applyTextColor, restyleMarkdown, renderImageAttachments), and
    /// serializedRTF flattens attachments to their Markdown refs anyway, so a
    /// plain-prose, code-only, or image-only note needs no RTF sidecar.
    /// Enumerates with an early exit, so it's ~O(1) for a plain note (one run)
    /// and cheap for a rich one (stops at the first rich run) — far cheaper
    /// than the whole-document RTF encode it lets us skip.
    var hasRichTextFormatting: Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let fontManager = NSFontManager.shared
        var rich = false
        storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length), options: []) { attrs, _, stop in
            if (attrs[.underlineStyle] as? Int ?? 0) != 0
                || (attrs[.strikethroughStyle] as? Int ?? 0) != 0 {
                rich = true; stop.pointee = true; return
            }
            // Heading bold is derived from the `#` prefix, not user formatting.
            if attrs[.markdownHeading] != nil { return }
            if let font = attrs[.font] as? NSFont {
                let traits = fontManager.traits(of: font)
                if traits.contains(.boldFontMask) || traits.contains(.italicFontMask) {
                    rich = true; stop.pointee = true
                }
            }
        }
        return rich
    }

    /// Find ```-fenced regions in the plain text. Each returned range covers the
    /// opening fence line through the closing fence line (inclusive). Only closed
    /// blocks are styled — a lone opening fence stays plain text so it can never
    /// trap the cursor in an unbounded block.
    func computeCodeBlockRanges() -> [NSRange] {
        hasScannedCodeBlocks = true
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

    /// The current `codeBlockRanges` moved to account for `edited`, or nil when
    /// the edit could have changed which fences pair into blocks (in which case
    /// the caller must re-scan).
    ///
    /// A fence can only appear where a backtick was typed, and can only be
    /// destroyed by editing a line that is part of an existing block — a block's
    /// range spans its opening fence line through its closing fence line, so
    /// both are covered by the intersection test. The one fence that lives
    /// outside every block is the trailing unpaired one, and removing it leaves
    /// the earlier pairings (and therefore the block ranges) untouched.
    private func codeBlockRangesShiftedIfStructureIntact(edited: NSRange?, delta: Int) -> [NSRange]? {
        // Nothing to shift until a scan has established a baseline: content can
        // reach the storage before the delegate is wired (test rigs, and any
        // future load path), and an untracked load looks exactly like "no edits".
        guard hasScannedCodeBlocks else { return nil }
        // No character edit since the last scan: the fences can't have moved.
        guard let edited else { return codeBlockRanges }
        let ns = string as NSString
        let docRange = NSRange(location: 0, length: ns.length)
        let region = ns.paragraphRange(for: clamped(edited, to: docRange))
        // A new backtick anywhere in the edited text — re-scan.
        if region.length > 0,
           ns.range(of: "`", options: [], range: region).location != NSNotFound { return nil }
        // The edited region in pre-edit coordinates (see accumulateEdit).
        let oldStart = region.location
        let oldEnd = max(oldStart, NSMaxRange(region) - delta)
        // Every known block must lie entirely outside it, or its fences may
        // have been edited away.
        for block in codeBlockRanges {
            guard NSMaxRange(block) <= oldStart || block.location >= oldEnd else { return nil }
        }
        return codeBlockRanges.map { block in
            block.location >= oldEnd
                ? NSRange(location: block.location + delta, length: block.length)
                : block
        }
    }

    func isLocationInCodeBlock(_ loc: Int) -> Bool {
        for r in codeBlockRanges where NSLocationInRange(loc, r) { return true }
        return false
    }

    /// Re-derive Markdown-structural styling from the plain text: monospaced
    /// font inside ```-fences (tagged with .codeBlock for background drawing),
    /// scaled bold font on `#` heading lines (tagged with .markdownHeading),
    /// proportional base font with preserved bold/italic elsewhere.
    ///
    /// The full-document rewrite only runs when the fence *structure* changed.
    /// When blocks are unchanged or merely shifted by edits outside them (the
    /// common case: typing above a block), the attributes moved with the text,
    /// so only the edited region is normalized — previously every such pause
    /// rewrote the whole document's attributes and invalidated all its layout.
    /// Headings need no structure tracking of their own: heading-ness is a
    /// line-local property, so any line that gained or lost it lies inside the
    /// (paragraph-expanded) edited region the fast paths already normalize.
    /// Pass `force: true` to rewrite the whole document's styling even when
    /// the fence structure is unchanged — needed after a font-size change,
    /// which rewrites every font via `applyBaseFont` (wiping the mono and
    /// heading runs) without editing any text, so the edited-range fast paths
    /// below would otherwise leave them at the base font.
    func restyleMarkdown(baseFont: NSFont, force: Bool = false) {
        guard let textStorage = textStorage else { return }
        let edited = editedRangeSinceRestyle
        let delta = lengthDeltaSinceRestyle
        editedRangeSinceRestyle = nil
        lengthDeltaSinceRestyle = 0
        // Scanning the whole document for ``` costs ~16 ms on a 2.5 MB note and
        // ran on every typing pause even in notes with no fences at all. When
        // the edit provably can't have changed the fence structure, the current
        // ranges just move with the text instead.
        let ranges = (force ? nil : codeBlockRangesShiftedIfStructureIntact(edited: edited, delta: delta))
            ?? computeCodeBlockRanges()

        if force {
            codeBlockRanges = ranges
            guard textStorage.length > 0 else { needsDisplay = true; return }
            applyMarkdownStyling(in: NSRange(location: 0, length: textStorage.length), baseFont: baseFont)
            needsDisplay = true
            updateCopyButtons()
            return
        }

        if ranges == codeBlockRanges {
            // Structure and offsets untouched: normalize just the edited
            // region — text inserted at a block edge can't keep inherited mono
            // styling, and a line that gained or lost its `#` prefix restyles.
            // With no blocks, skip entirely unless the edit could involve a
            // heading (keeps the no-op typing path for plain notes).
            guard let edited else { return }
            if ranges.isEmpty && !regionMayInvolveHeadings(edited) { return }
            applyMarkdownStyling(in: edited, baseFont: baseFont)
            return
        }

        // Shift fast path: same block count and lengths, and every new range
        // still fully carries the .codeBlock tag — proof it's the same styled
        // text at new offsets (a restructure that coincidentally matches the
        // shape fails the tag check and takes the full rewrite below).
        // Heading runs shift along with the text too, so normalizing the
        // edited region covers them as well.
        if let edited,
           ranges.count == codeBlockRanges.count,
           zip(ranges, codeBlockRanges).allSatisfy({ $0.length == $1.length }),
           ranges.allSatisfy({ hasCodeBlockTag(spanning: $0) }) {
            codeBlockRanges = ranges
            applyMarkdownStyling(in: edited, baseFont: baseFont)
            needsDisplay = true // block background boxes moved with the text
            updateCopyButtons()
            return
        }

        codeBlockRanges = ranges
        guard textStorage.length > 0 else { needsDisplay = true; return }
        applyMarkdownStyling(in: NSRange(location: 0, length: textStorage.length), baseFont: baseFont)
        needsDisplay = true
        updateCopyButtons()
    }

    /// Cheap gate for the structure-unchanged fast path in a note with no code
    /// blocks: the edited region needs a styling pass only if it might contain
    /// a heading — its text has a `#` (possibly a new heading) or it carries a
    /// stale .markdownHeading tag (a heading whose `#` was just deleted).
    private func regionMayInvolveHeadings(_ edited: NSRange) -> Bool {
        guard let storage = textStorage else { return false }
        let ns = string as NSString
        let expanded = ns.paragraphRange(for: clamped(edited, to: NSRange(location: 0, length: ns.length)))
        guard expanded.length > 0 else { return false }
        if ns.range(of: "#", options: [], range: expanded).location != NSNotFound { return true }
        var tagged = false
        storage.enumerateAttribute(.markdownHeading, in: expanded, options: []) { value, _, stop in
            if value != nil { tagged = true; stop.pointee = true }
        }
        return tagged
    }

    /// Bounds-clamp that, unlike NSIntersectionRange, keeps a zero-length
    /// range's location (deletions report their edit as an empty range).
    private func clamped(_ range: NSRange, to bounds: NSRange) -> NSRange {
        let loc = min(max(range.location, bounds.location), NSMaxRange(bounds))
        let end = min(max(NSMaxRange(range), loc), NSMaxRange(bounds))
        return NSRange(location: loc, length: end - loc)
    }

    /// Instant heading feedback for the line being edited (called from
    /// didChangeText, i.e. per keystroke). The deferred restyleMarkdown pass
    /// on the typing pause is authoritative, but waiting ~500ms for a typed
    /// `# ` prefix to take effect — or for text typed after a heading's
    /// newline to shed the inherited big font — reads as lag. Aggressively
    /// gated: the caret line's desired heading level is compared against its
    /// current uniform .markdownHeading tagging and the line is only restyled
    /// on a mismatch, so steady typing pays one attribute walk of one line.
    private func liveRestyleHeadingAtCaret() {
        guard let textStorage = textStorage, textStorage.length > 0 else { return }
        let ns = string as NSString
        let caret = min(selectedRange().location, ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        // codeBlockRanges can be ~500ms stale here; worst case a keystroke's
        // live styling is skipped or briefly wrong and the deferred pass
        // corrects it.
        guard lineRange.length > 0, !isLocationInCodeBlock(lineRange.location) else { return }
        let desired = Self.headingLevel(in: ns, lineRange: lineRange)

        var current: Int? = nil
        var uniform = true
        var first = true
        textStorage.enumerateAttribute(.markdownHeading, in: lineRange, options: []) { value, _, stop in
            let level = value as? Int
            if first { current = level; first = false }
            else if level != current { uniform = false; stop.pointee = true }
        }
        if uniform && current == desired { return }

        let baseFont = coordinator?.parent.font ?? self.font ?? NSFont.systemFont(ofSize: 16)
        applyMarkdownStyling(in: lineRange, baseFont: baseFont)
    }

    /// True when the `.codeBlock` attribute covers every character of `range`.
    private func hasCodeBlockTag(spanning range: NSRange) -> Bool {
        guard let storage = textStorage, range.length > 0,
              NSMaxRange(range) <= storage.length else { return false }
        var effective = NSRange()
        guard storage.attribute(.codeBlock, at: range.location, longestEffectiveRange: &effective, in: range) != nil else {
            return false
        }
        return effective.length == range.length
    }

    /// Rewrites Markdown-structural styling over `target` only, deriving
    /// everything from the current `codeBlockRanges` and the target's line
    /// text: base font/paragraph (bold/italic kept) as the default, mono font
    /// + `.codeBlock` tag inside fences with the block-gap paragraph styles on
    /// each block's boundary lines, and a scaled bold font + `.markdownHeading`
    /// tag on `#` heading lines outside any fence. The full restyle passes
    /// the whole document; the fast paths pass just the edited region so the
    /// attribute churn — and the layout invalidation it causes — stays O(edit).
    private func applyMarkdownStyling(in target: NSRange, baseFont: NSFont) {
        guard let textStorage = textStorage, textStorage.length > 0 else { return }
        let ns = string as NSString
        let docRange = NSRange(location: 0, length: ns.length)
        // Clamp by hand: a pure deletion arrives as a zero-length edited
        // range, which NSIntersectionRange treats as "no intersection" and
        // relocates to 0. Paragraph-expanding before the emptiness guard keeps
        // deletions restyling their line (e.g. a heading losing its `#`).
        var target = clamped(target, to: docRange)
        // Paragraph styles only render correctly over whole paragraphs.
        target = ns.paragraphRange(for: target)
        guard target.length > 0 else { return }

        let monoFont = NSFont.monospacedSystemFont(ofSize: baseFont.pointSize, weight: .regular)
        let fontManager = NSFontManager.shared
        let baseParagraph = VimTextView.paragraphStyle()
        let blockGap: CGFloat = 12

        // Cosmetic-only: don't register the restyling on the undo stack.
        undoManager?.disableUndoRegistration()
        textStorage.beginEditing()
        textStorage.removeAttribute(.codeBlock, range: target)
        // Reset paragraph style + font in the target; blocks and headings
        // override below.
        textStorage.addAttribute(.paragraphStyle, value: baseParagraph, range: target)
        textStorage.enumerateAttributes(in: target, options: []) { attrs, range, _ in
            // A heading run's bold is derived from its `#` prefix, not manual
            // formatting — ignore its traits so a line that stopped being a
            // heading reverts to the plain base font.
            let traits = attrs[.markdownHeading] == nil
                ? ((attrs[.font] as? NSFont).map { fontManager.traits(of: $0) } ?? NSFontTraitMask())
                : NSFontTraitMask()
            var f = baseFont
            if traits.contains(.boldFontMask) { f = fontManager.convert(f, toHaveTrait: .boldFontMask) }
            if traits.contains(.italicFontMask) { f = fontManager.convert(f, toHaveTrait: .italicFontMask) }
            textStorage.addAttribute(.font, value: f, range: range)
        }
        textStorage.removeAttribute(.markdownHeading, range: target)
        // Overlay monospaced font + tag where blocks intersect the target, and
        // re-add the gap above the opening fence / below the closing fence for
        // any boundary line falling inside it.
        for r in codeBlockRanges {
            let safe = NSIntersectionRange(r, docRange)
            guard safe.length > 0 else { continue }
            let overlap = NSIntersectionRange(safe, target)

            let firstLine = ns.lineRange(for: NSRange(location: safe.location, length: 0))
            let lastLine = ns.lineRange(for: NSRange(location: min(safe.location + safe.length - 1, ns.length), length: 0))
            guard overlap.length > 0
                || NSIntersectionRange(firstLine, target).length > 0
                || NSIntersectionRange(lastLine, target).length > 0 else { continue }

            if overlap.length > 0 {
                textStorage.addAttribute(.font, value: monoFont, range: overlap)
                textStorage.addAttribute(.codeBlock, value: true, range: overlap)
            }

            if NSIntersectionRange(firstLine, target).length > 0 {
                let before = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
                before.paragraphSpacingBefore = blockGap
                textStorage.addAttribute(.paragraphStyle, value: before, range: NSIntersectionRange(firstLine, docRange))
            }
            if NSIntersectionRange(lastLine, target).length > 0 {
                let after = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
                after.paragraphSpacing = blockGap
                textStorage.addAttribute(.paragraphStyle, value: after, range: NSIntersectionRange(lastLine, docRange))
            }
        }
        // Heading overlay: `#{1,6} ` lines outside any fence get a scaled bold
        // font + level tag. The `#` marks stay visible ordinary characters, so
        // Vim offsets and the plain `.txt` on disk are untouched.
        var lineStart = target.location
        while lineStart < NSMaxRange(target) {
            let lineRange = ns.lineRange(for: NSRange(location: lineStart, length: 0))
            if !isLocationInCodeBlock(lineRange.location),
               let level = Self.headingLevel(in: ns, lineRange: lineRange) {
                textStorage.addAttribute(.font, value: Self.headingFont(level: level, baseFont: baseFont), range: lineRange)
                textStorage.addAttribute(.markdownHeading, value: level, range: lineRange)
                let para = baseParagraph.mutableCopy() as! NSMutableParagraphStyle
                para.paragraphSpacingBefore = 10
                para.paragraphSpacing = 3
                textStorage.addAttribute(.paragraphStyle, value: para, range: lineRange)
            }
            let next = NSMaxRange(lineRange)
            if next <= lineStart { break }
            lineStart = next
        }
        textStorage.endEditing()
        undoManager?.enableUndoRegistration()
    }

    /// Level (1–6) of the ATX heading on the line at `lineRange`, or nil: one
    /// to six `#` characters at the line start followed by a space or tab.
    /// `#hashtag`, `#!/bin/sh`, and 7+ hashes stay plain text.
    static func headingLevel(in ns: NSString, lineRange: NSRange) -> Int? {
        let end = NSMaxRange(lineRange)
        var i = lineRange.location
        var hashes = 0
        while i < end, ns.character(at: i) == 0x23 /* # */ {
            hashes += 1
            if hashes > 6 { return nil }
            i += 1
        }
        guard hashes > 0, i < end else { return nil }
        let next = ns.character(at: i)
        return (next == 0x20 || next == 0x09) ? hashes : nil
    }

    /// Heading display font: the base font's family, scaled by level and bold.
    static func headingFont(level: Int, baseFont: NSFont) -> NSFont {
        let scale: CGFloat
        switch level {
        case 1: scale = 1.5
        case 2: scale = 1.3
        case 3: scale = 1.15
        default: scale = 1.0
        }
        let size = (baseFont.pointSize * scale).rounded()
        let resized = NSFont(descriptor: baseFont.fontDescriptor, size: size) ?? baseFont
        return NSFontManager.shared.convert(resized, toHaveTrait: .boldFontMask)
    }

    /// Fast scan used at note-open to decide whether the initial restyle must
    /// force a full pass (a plain note keeps its zero-cost open otherwise).
    /// Over-approximates: doesn't exclude fenced code, which only means an
    /// unnecessary full restyle for a note whose sole `#` lines sit in fences.
    static func containsHeadingLine(_ text: String) -> Bool {
        let ns = text as NSString
        let len = ns.length
        var search = NSRange(location: 0, length: len)
        while search.location < len {
            let found = ns.range(of: "#", options: [], range: search)
            if found.location == NSNotFound { return false }
            let lineRange = ns.lineRange(for: NSRange(location: found.location, length: 0))
            if lineRange.location == found.location,
               headingLevel(in: ns, lineRange: lineRange) != nil {
                return true
            }
            // A heading `#` can only start a line — skip to the next one.
            let next = max(NSMaxRange(lineRange), found.location + 1)
            search = NSRange(location: next, length: len - next)
        }
        return false
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
        let isReturn = event.keyCode == 36 || event.keyCode == 76 // Return / keypad Enter
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
                // Arrow/function keys carry invisible F700-range characters
                // that would silently corrupt the search term — drop them.
                let printable = chars.unicodeScalars.filter {
                    !(0xF700...0xF8FF).contains(Int($0.value)) && $0 != "\u{7F}"
                }
                engine.commandLineText += String(String.UnicodeScalarView(printable))
            }
            return
        }

        if engine.mode.isEditing {
            if isEsc {
                let actions = engine.processKey("escape")
                coordinator.executeActions(actions)
                return
            }

            if modifiers.contains(.control) && event.charactersIgnoringModifiers == "[" {
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

            if isBackspace && handleSmartListBackspace() {
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

        // Control combos arrive in `event.characters` as raw ASCII control
        // codes (Ctrl-R = U+0012, Ctrl-O = U+000F, …), which never match the
        // engine's key strings — so redo, and the Ctrl-O/Ctrl-I jump list,
        // silently died on real keyboards. Read the base key from
        // charactersIgnoringModifiers whenever Control is held (the Ctrl-D/U/F/B
        // and Ctrl-V branches above already do). Shift is still honored there.
        let key: String
        if modifiers.contains(.control), let base = event.charactersIgnoringModifiers, !base.isEmpty {
            key = base
        } else {
            guard let chars = event.characters, !chars.isEmpty else { return }
            key = chars
        }

        if engine.keyBuffer == "r" && !isEsc {
            engine.resetBuffers()
            if isLockedNote {
                engine.statusMessage = "Note is locked — unlock to edit"
                return
            }
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

    /// Replaces `range` with `text` through the undo-aware editing path.
    @discardableResult
    private func replaceForSmartList(_ range: NSRange, with text: String) -> Bool {
        guard shouldChangeText(in: range, replacementString: text) else { return false }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        return true
    }

    /// Renumbers the ordered list block around `location`, keeping the caret
    /// where the user left it. Called after any edit that can change an item's
    /// position or level.
    func renumberLists(around location: Int) {
        guard smartLists else { return }
        let edits = SmartList.renumberEdits(in: string as NSString, around: location)
        guard !edits.isEmpty else { return }
        var caret = selectedRange().location
        // Back to front so earlier ranges stay valid.
        for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
            guard replaceForSmartList(edit.range, with: edit.replacement) else { continue }
            let delta = (edit.replacement as NSString).length - edit.range.length
            if edit.range.location + edit.range.length <= caret { caret += delta }
        }
        let length = (string as NSString).length
        setSelectedRange(NSRange(location: min(max(caret, 0), length), length: 0))
    }

    /// Removes one indent level from the line at `lineStart`, returning how many
    /// characters went away.
    private func outdentLine(at lineStart: Int, line: String) -> Int {
        let removeLength: Int
        if line.hasPrefix("\t") {
            removeLength = 1
        } else {
            removeLength = min(SmartList.indentUnit.count, line.prefix { $0 == " " }.count)
        }
        guard removeLength > 0 else { return 0 }
        return replaceForSmartList(NSRange(location: lineStart, length: removeLength), with: "") ? removeLength : 0
    }

    /// On Return in insert mode, continue, split or terminate a list item.
    /// Returns true if handled.
    private func handleSmartListReturn() -> Bool {
        guard smartLists else { return false }
        let sel = selectedRange()
        guard sel.length == 0 else { return false }
        guard !isLocationInCodeBlock(sel.location) else { return false }

        let ns = string as NSString
        let pos = sel.location
        guard let (item, lineRange, contentEnd) = SmartList.item(in: ns, at: pos) else { return false }

        // Inside the marker itself (or before it) Return is just a Return.
        let bodyStart = lineRange.location + item.prefixLength
        guard pos >= bodyStart else { return false }

        // Empty item → step out one level, or end the list at the top level.
        if item.isEmpty {
            if !item.indent.isEmpty {
                let line = ns.substring(with: NSRange(location: lineRange.location,
                                                      length: contentEnd - lineRange.location))
                let removed = outdentLine(at: lineRange.location, line: line)
                setSelectedRange(NSRange(location: max(lineRange.location, contentEnd - removed), length: 0))
                renumberLists(around: lineRange.location)
            } else {
                replaceForSmartList(NSRange(location: lineRange.location,
                                            length: contentEnd - lineRange.location), with: "")
                setSelectedRange(NSRange(location: lineRange.location, length: 0))
            }
            return true
        }

        // Otherwise start a new item — text right of the caret moves down with
        // it, so Return in the middle of an item splits it in two.
        let sibling = SmartList.previousSibling(in: ns, beforeLineAt: lineRange.location,
                                                indentWidth: item.indentWidth)
        let marker = item.nextMarkerText(previousSibling: sibling)
        insertText("\n" + item.indent + marker, replacementRange: NSRange(location: pos, length: 0))
        renumberLists(around: selectedRange().location)
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
        guard let (_, lineRange, contentEnd) = SmartList.item(in: ns, at: pos) else { return false }
        let line = ns.substring(with: NSRange(location: lineRange.location,
                                              length: contentEnd - lineRange.location))

        if outdent {
            let removed = outdentLine(at: lineRange.location, line: line)
            guard removed > 0 else { return true }
            setSelectedRange(NSRange(location: max(lineRange.location, pos - removed), length: 0))
            renumberLists(around: lineRange.location)
            return true
        }

        insertText(SmartList.indentUnit, replacementRange: NSRange(location: lineRange.location, length: 0))
        setSelectedRange(NSRange(location: pos + SmartList.indentUnit.count, length: 0))
        renumberLists(around: selectedRange().location)
        return true
    }

    /// Backspace at the very start of a list item's text removes the whole
    /// marker (or steps out one level first) instead of nibbling at it.
    /// Returns true if handled.
    private func handleSmartListBackspace() -> Bool {
        guard smartLists else { return false }
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0 else { return false }
        guard !isLocationInCodeBlock(sel.location) else { return false }

        let ns = string as NSString
        let pos = sel.location
        guard let (item, lineRange, contentEnd) = SmartList.item(in: ns, at: pos) else { return false }
        guard pos == lineRange.location + item.prefixLength else { return false }

        if !item.indent.isEmpty {
            let line = ns.substring(with: NSRange(location: lineRange.location,
                                                  length: contentEnd - lineRange.location))
            let removed = outdentLine(at: lineRange.location, line: line)
            guard removed > 0 else { return false }
            setSelectedRange(NSRange(location: pos - removed, length: 0))
        } else {
            let markerRange = NSRange(location: lineRange.location, length: item.prefixLength)
            guard replaceForSmartList(markerRange, with: "") else { return false }
            setSelectedRange(NSRange(location: lineRange.location, length: 0))
        }
        renumberLists(around: lineRange.location)
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

        // 0) ⌘-click on a link opens it (plain click just moves the cursor,
        //    as a Vim editor should).
        if event.modifierFlags.contains(.command), let hit = link(atPoint: point) {
            openLink(hit.url)
            return
        }

        // 0b) A plain click on a rendered checkbox toggles it (without moving
        //     the caret), the way a notes app should.
        if event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
           toggleCheckboxIfClicked(at: point) {
            return
        }

        // 0c) Double-clicking an image opens it large in the full-window
        //     lightbox viewer (single click is reserved for select/resize).
        if event.clickCount == 2, let (attachment, _) = imageAttachment(at: point) {
            presentImageLightbox(startingAt: attachment)
            return
        }

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
        // Pointing hand + full-URL tooltip over links — restricted to the
        // visible character range so this never forces layout of a huge note's
        // tail. Tooltips are rebuilt here (rather than in their own pass) so
        // they refresh on the same triggers as the cursor rects: scrolling,
        // fold changes, and link re-detection.
        removeAllToolTips()
        guard !detectedLinks.isEmpty, let layoutManager, let textContainer else { return }
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        for link in detectedLinks where NSIntersectionRange(link.range, visibleChars).length > 0 {
            let glyphRange = layoutManager.glyphRange(forCharacterRange: link.range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
            addCursorRect(rect, cursor: .pointingHand)
            addToolTip(rect, owner: self, userData: nil)
        }
    }

    /// Full URL shown when hovering a folded chip (or any link) — restores the
    /// destination that folding hides from view.
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        link(atPoint: point)?.url.absoluteString ?? ""
    }

    // MARK: - Link chip hover

    private var linkHoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area = linkHoverTrackingArea { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        linkHoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        setHoveredLink(link(atPoint: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoveredLink(nil)
    }

    /// Reports the link under the pointer: darkens its chip (layout manager) and
    /// surfaces its full URL instantly in the status bar — no waiting on the slow
    /// native tooltip. Redraws only the affected chip rects when the hovered link
    /// actually changes, so this stays snappy even on a large note.
    private func setHoveredLink(_ link: LinkDetection.Link?) {
        guard let foldingLM = layoutManager as? FoldingLayoutManager else { return }
        let newRange = link?.range
        let changed: Bool
        switch (foldingLM.hoveredLinkRange, newRange) {
        case let (current?, new?): changed = !NSEqualRanges(current, new)
        case (nil, nil): changed = false
        default: changed = true
        }
        guard changed else { return }

        let previous = foldingLM.hoveredLinkRange
        foldingLM.hoveredLinkRange = newRange
        vimEngine?.hoveredLinkURL = link?.url.absoluteString
        // Repaint just the chips whose hover state flipped — not the whole view.
        invalidateLinkChip(previous)
        invalidateLinkChip(newRange)
    }

    private func invalidateLinkChip(_ range: NSRange?) {
        guard let range, let layoutManager, let textContainer else { return }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            .offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
        setNeedsDisplay(rect.insetBy(dx: -10, dy: -4))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPlaceholderIfNeeded()
        drawImageSelectionChrome()
    }

    /// Faint prompt shown in an empty, editable note so a blank canvas doesn't
    /// look broken. Drawn where the first typed character would land; clears
    /// itself the moment any text exists (the guard fails and the redraw on
    /// textDidChange repaints).
    private func drawPlaceholderIfNeeded() {
        guard isEditable, (string as NSString).length == 0 else { return }
        let baseColor = (typingAttributes[.foregroundColor] as? NSColor) ?? .labelColor
        let placeholderFont = (typingAttributes[.font] as? NSFont)
            ?? font
            ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: placeholderFont,
            .foregroundColor: baseColor.withAlphaComponent(0.3)
        ]
        let origin = textContainerOrigin
        let pad = textContainer?.lineFragmentPadding ?? 5
        ("Start writing…" as NSString).draw(
            at: NSPoint(x: origin.x + pad, y: origin.y),
            withAttributes: attrs
        )
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

    /// Opens the full-window image viewer starting on `attachment`, with every
    /// image in the note (document order) available via the arrow keys.
    func presentImageLightbox(startingAt attachment: ImageTextAttachment) {
        deselectImage()
        var images: [NSImage] = []
        var startIndex = 0
        for entry in imageAttachmentRects() {
            if entry.attachment === attachment { startIndex = images.count }
            // The attachment's backing image is decoded at display size, so the
            // lightbox loads the full-resolution original from the asset file
            // (NSImage(contentsOf:) decodes lazily, at first draw per image).
            let url = StorageManager.shared.assetURL(forRelativePath: entry.attachment.assetRelativePath)
            if entry.attachment.assetRelativePath.hasPrefix("assets/"), let full = NSImage(contentsOf: url) {
                images.append(full)
            } else if let image = entry.attachment.image {
                images.append(image)
            }
        }
        ImageLightboxView.present(images: images, startIndex: startIndex, over: self)
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
        refreshBackingImageIfEnlarged(attachment)
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
        if didResize {
            refreshBackingImageIfEnlarged(attachment)
            coordinator?.imageDidResize()
        }
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

        // Keep the block cursor clearly visible — at 0.45 it read as a faint
        // smudge on light themes and was hard to locate at a glance.
        let cursorColor: NSColor = isVisual
            ? accentColor.withAlphaComponent(0.85)
            : accentColor.withAlphaComponent(0.70)

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

    /// Coalesces block-cursor redraws. A single Vim command can call
    /// `setSelectedRange` several times in one runloop turn, and each redraw
    /// runs glyph layout; this collapses them into one redraw of the final
    /// state (the only state the user ever sees).
    private func scheduleBlockCursorRedraw() {
        guard !blockCursorRedrawScheduled else { return }
        blockCursorRedrawScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.blockCursorRedrawScheduled = false
            self.drawBlockCursor()
        }
    }

    override func setSelectedRange(_ charRange: NSRange) {
        super.setSelectedRange(charRange)
        if let engine = vimEngine, !engine.mode.isEditing {
            scheduleBlockCursorRedraw()
        }
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateSearchCaches()
        liveRestyleHeadingAtCaret()
        refreshHeadingFoldsForEdit()
        // The gutter's line-count anchor was already narrowed (or kept) by the
        // storage delegate for this edit — here it just needs a repaint.
        if let ruler = enclosingScrollView?.verticalRulerView as? LineNumberRulerView {
            ruler.needsDisplay = true
        }
        if let engine = vimEngine, !engine.mode.isEditing {
            scheduleBlockCursorRedraw()
        }
    }

    override func paste(_ sender: Any?) {
        if insertPastedImage() { return }
        let pasteStart = selectedRange().location
        // Strip rich formatting only when the clipboard actually holds text.
        // Source apps (IntelliJ, browsers, Xcode) put an RTF flavor on the
        // pasteboard with their own theme baked in — fonts, syntax colors, and
        // a background color on every character — which super.paste() would
        // import wholesale; pasteAsPlainText drops all of it (links are
        // re-detected from the plain string anyway). But pasteAsPlainText also
        // drops images, so for a non-text pasteboard (e.g. a screenshot that
        // insertPastedImage couldn't handle) fall back to super.paste so the
        // image is still inserted rather than silently discarded.
        if NSPasteboard.general.string(forType: .string) != nil {
            pasteAsPlainText(sender)
        } else {
            super.paste(sender)
        }
        // Use the coordinator's parent font — the live, user-configured font
        // from EditorPreferences — instead of self.font which is the stale
        // NSTextView-level property and may carry an outdated size.
        let baseFont = coordinator?.parent.font ?? self.font ?? NSFont.systemFont(ofSize: 16)
        // Normalize only the pasted range (the caret sits at its end after the
        // paste) — the rest of the document already carries the base font, and
        // touching it wholesale also clobbered code-block monospacing.
        let pasteEnd = selectedRange().location
        if pasteEnd > pasteStart {
            applyBaseFont(baseFont, in: NSRange(location: pasteStart, length: pasteEnd - pasteStart))
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
        // Header probe only — the display-sized bitmap is decoded off-main so a
        // multi-megapixel screenshot paste doesn't stall the keystroke.
        guard let probe = ImageDecoder.probe(.data(data)),
              let relativePath = StorageManager.shared.saveImageAsset(data, fileExtension: fileExtension) else {
            return false
        }
        let attachment = ImageTextAttachment(image: nil,
                                             nativeSize: probe.pointSize,
                                             nativePixelWidth: probe.pixelSize.width,
                                             assetRelativePath: relativePath,
                                             displayWidth: nil)
        loadAttachmentImageAsync(attachment, from: .data(data))
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
    /// text is set), analogous to `restyleMarkdown`. References whose asset
    /// file is missing are left as plain text so nothing is silently lost.
    func renderImageAttachments() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let references = ImageMarkdown.references(in: storage.string)
        guard !references.isEmpty else { return }

        // Attachments are about to be replaced; drop any stale selection.
        selectedImageAttachment = nil

        storage.beginEditing()
        // Replace back-to-front so earlier match ranges stay valid. Only the
        // image header is read here (dimensions for layout) — pixel decoding
        // happens off-main below, at display size rather than full resolution,
        // so opening an image-heavy note doesn't block on decodes.
        for reference in references.reversed() {
            guard reference.path.hasPrefix("assets/") else { continue }
            let url = StorageManager.shared.assetURL(forRelativePath: reference.path)
            guard let probe = ImageDecoder.probe(.url(url)) else { continue }
            let attachment = ImageTextAttachment(image: nil,
                                                 nativeSize: probe.pointSize,
                                                 nativePixelWidth: probe.pixelSize.width,
                                                 assetRelativePath: reference.path,
                                                 displayWidth: reference.width)
            storage.replaceCharacters(in: reference.range, with: NSAttributedString(attachment: attachment))
            loadAttachmentImageAsync(attachment, from: .url(url))
        }
        storage.endEditing()
        // This mutates the storage without going through didChangeText — the
        // markdown refs collapse to single attachment chars, shifting every
        // later offset — so the search/line caches must be dropped by hand.
        invalidateSearchCaches()
        (enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?.invalidateLineCache()
        window?.invalidateCursorRects(for: self)
    }

    /// Pixel density to decode note images at. The view may not be in a window
    /// yet when attachments load, so fall back to the sharpest attached screen.
    private var imageBackingScale: CGFloat {
        window?.backingScaleFactor
            ?? NSScreen.screens.map(\.backingScaleFactor).max()
            ?? 2
    }

    /// Decodes `attachment`'s bitmap at its display width off the main thread,
    /// then swaps it in and repaints its line. The attachment already has its
    /// final bounds (from the metadata probe), so nothing reflows on arrival.
    private func loadAttachmentImageAsync(_ attachment: ImageTextAttachment, from source: ImageDecoder.Source) {
        let pointWidth = attachment.bounds.width
        let scale = imageBackingScale
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak attachment] in
            guard let decoded = ImageDecoder.downsampledImage(from: source, targetPointWidth: pointWidth, scale: scale) else { return }
            DispatchQueue.main.async {
                guard let attachment else { return }
                attachment.setBackingImage(decoded.image, decodedPixelWidth: decoded.pixelWidth)
                // No-op if the attachment left the document while decoding.
                self?.invalidateLayout(for: attachment)
            }
        }
    }

    /// After a resize: if the image was enlarged past the resolution it was
    /// decoded at (and the source file has more pixels to give), re-decode a
    /// sharper bitmap in the background.
    private func refreshBackingImageIfEnlarged(_ attachment: ImageTextAttachment) {
        let wantedPixels = attachment.bounds.width * imageBackingScale
        guard wantedPixels > attachment.decodedPixelWidth + 1,
              attachment.decodedPixelWidth < attachment.nativePixelWidth,
              attachment.assetRelativePath.hasPrefix("assets/") else { return }
        let url = StorageManager.shared.assetURL(forRelativePath: attachment.assetRelativePath)
        loadAttachmentImageAsync(attachment, from: .url(url))
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        drawCodeBlockBackgrounds(in: rect)

        guard paperStyle != "plain" else { return }
        
        guard let context = NSGraphicsContext.current?.cgContext,
              let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }
        
        context.saveGState()
        
        let font = coordinator?.parent.font ?? self.font ?? NSFont.systemFont(ofSize: 16)
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

// MARK: - NSTextStorageDelegate — edited-range tracking for scoped restyles

extension VimNSTextView: NSTextStorageDelegate {
    /// Accumulates the union of character edits (and the net length change)
    /// since the last code-block restyle and the last heading scan (wired as
    /// the storage's delegate in makeNSView). Attribute-only edits
    /// (theme/color/font passes, including the restyles themselves) don't carry
    /// `.editedCharacters` and are ignored.
    ///
    /// Also lets the line-number gutter keep its line-count anchor when the
    /// edit landed after it — the anchor counts newlines *before* its offset,
    /// so text changed at or after that offset can't invalidate it, and
    /// dropping it outright made every keystroke re-count the document from 0.
    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        (editedRangeSinceRestyle, lengthDeltaSinceRestyle) = Self.accumulateEdit(
            union: editedRangeSinceRestyle, netDelta: lengthDeltaSinceRestyle,
            edit: editedRange, delta: delta
        )
        (editedRangeSinceHeadingScan, lengthDeltaSinceHeadingScan) = Self.accumulateEdit(
            union: editedRangeSinceHeadingScan, netDelta: lengthDeltaSinceHeadingScan,
            edit: editedRange, delta: delta
        )
        (enclosingScrollView?.verticalRulerView as? LineNumberRulerView)?
            .invalidateLineCache(after: editedRange.location)
    }

    /// Folds one more edit into an accumulated (union, net delta) pair, keeping
    /// the union in *current* document coordinates: an edit before it shifts it
    /// along, an edit inside it grows or shrinks it, an edit after it leaves it
    /// alone. The result is always a superset of the changed text, which is what
    /// callers rely on — they re-derive everything inside the union and shift
    /// everything after it by the net delta.
    static func accumulateEdit(union: NSRange?, netDelta: Int,
                               edit: NSRange, delta: Int) -> (NSRange, Int) {
        guard var current = union else { return (edit, delta) }
        if edit.location <= current.location {
            current.location = max(0, current.location + delta)
        } else if edit.location < NSMaxRange(current) {
            current.length = max(0, current.length + delta)
        }
        return (NSUnionRange(current, edit), netDelta + delta)
    }
}
