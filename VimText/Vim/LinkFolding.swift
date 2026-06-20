import AppKit

/// Computes which parts of each detected link to hide so a long URL collapses
/// to just its domain (e.g. `https://www.amazon.in/TIMEX…/dp/B0FVFYTHS2` shows
/// as `amazon.in`). This is pure range math over the document string — it never
/// mutates storage, so the full URL stays the source of truth for Vim motions,
/// find, copy, and RTF saving. The actual hiding/drawing happens in
/// `FoldingLayoutManager`.
enum LinkFolding {
    /// One link rendered as a collapsed chip.
    struct Fold: Equatable {
        /// The full link range in the document (the real URL text).
        let linkRange: NSRange
        /// The contiguous sub-range that stays visible (the domain).
        let visibleRange: NSRange
        /// The ranges hidden on either side of the domain (scheme/`www.`, path).
        let hiddenRanges: [NSRange]
        /// The hidden character (the last of the scheme prefix) repurposed as a
        /// fixed-width control glyph that reserves on-screen room for the link
        /// icon just before the domain. nil when the URL has no prefix to hide.
        let iconSlotIndex: Int?
        /// True when the link directly abuts a non-space character (e.g. `panda
        /// :https://…`). The chip then reserves extra leading width so it never
        /// visually hugs the preceding `:`/word.
        let precededByNonSpace: Bool
    }

    /// Builds the fold list for `links`, leaving `activeLinkRange` (the link the
    /// caret is currently on) fully expanded so it can be read and edited.
    static func computeFolds(
        links: [LinkDetection.Link],
        activeLinkRange: NSRange?,
        in text: NSString
    ) -> [Fold] {
        let docLength = text.length
        var folds: [Fold] = []
        for link in links {
            // Skip the link being edited — show its full URL.
            if let active = activeLinkRange, NSEqualRanges(active, link.range) { continue }
            let safe = NSIntersectionRange(link.range, NSRange(location: 0, length: docLength))
            guard safe.length > 0 else { continue }
            guard let fold = fold(for: link, safeRange: safe, in: text) else { continue }
            folds.append(fold)
        }
        return folds
    }

    /// Locates the domain inside the URL text and returns the fold, or nil when
    /// there's nothing worth collapsing (the domain isn't found, or the URL is
    /// already just the domain with no scheme/path to hide).
    private static func fold(for link: LinkDetection.Link, safeRange: NSRange, in text: NSString) -> Fold? {
        let urlText = text.substring(with: safeRange)
        guard let domain = displayDomain(for: link.url) else { return nil }

        let found = (urlText as NSString).range(of: domain, options: [.caseInsensitive])
        guard found.location != NSNotFound, found.length > 0 else { return nil }

        let visibleStart = safeRange.location + found.location
        let visibleRange = NSRange(location: visibleStart, length: found.length)
        let visibleEnd = visibleStart + found.length
        let linkEnd = safeRange.location + safeRange.length

        var hidden: [NSRange] = []
        var iconSlot: Int? = nil
        if visibleStart > safeRange.location {
            hidden.append(NSRange(location: safeRange.location, length: visibleStart - safeRange.location))
            // The character immediately before the domain becomes the icon slot.
            iconSlot = visibleStart - 1
        }
        if linkEnd > visibleEnd {
            hidden.append(NSRange(location: visibleEnd, length: linkEnd - visibleEnd))
        }
        // Nothing to hide → it's already a bare domain; don't draw a chip.
        guard !hidden.isEmpty else { return nil }

        // Does a non-space character sit immediately before the link?
        let before = safeRange.location - 1
        var precededByNonSpace = false
        if before >= 0 {
            let ch = text.character(at: before)
            precededByNonSpace = !(ch == 0x20 || ch == 0x09 || ch == 0x0A || ch == 0x0D)
        }

        return Fold(
            linkRange: safeRange,
            visibleRange: visibleRange,
            hiddenRanges: hidden,
            iconSlotIndex: iconSlot,
            precededByNonSpace: precededByNonSpace
        )
    }

    /// The host shown in the chip: the URL host minus a leading `www.`. Returns
    /// nil for schemes without a host (e.g. `mailto:`), which stay expanded.
    private static func displayDomain(for url: URL) -> String? {
        guard var host = url.host, !host.isEmpty else { return nil }
        if host.lowercased().hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        return host.isEmpty ? nil : host
    }
}

/// A layout manager that renders `LinkFolding.Fold`s by giving the hidden URL
/// glyphs zero-width null glyphs and drawing a rounded "chip" behind the
/// visible domain. Display-only: the text storage is untouched.
final class FoldingLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    /// Current folds. Setting recomputes the hidden-glyph lookup and invalidates
    /// only the affected ranges so glyph generation re-runs.
    private(set) var folds: [LinkFolding.Fold] = []
    /// Flattened, sorted hidden ranges for O(log n) membership tests during the
    /// hot glyph-generation callback.
    private var hiddenStarts: [Int] = []
    private var hiddenEnds: [Int] = []

    var chipFillColor: NSColor = NSColor.systemBlue.withAlphaComponent(0.12)
    var chipStrokeColor: NSColor = NSColor.systemBlue.withAlphaComponent(0.22)
    var chipIconColor: NSColor = NSColor.systemBlue
    /// Text line height used to size the chip so it hugs the domain rather than
    /// filling the full (line-spaced) line fragment.
    var chipTextHeight: CGFloat = 18

    /// Line-leading list markers (bullets / checkboxes) currently rendered.
    private(set) var markers: [ListMarkers.Marker] = []
    var markerTextColor: NSColor = .secondaryLabelColor
    var markerAccentColor: NSColor = NSColor.systemBlue

    /// Character indexes reserved as fixed-width control glyphs holding a drawn
    /// decoration (the link icon, a bullet dot, or a checkbox).
    private var controlSlots: Set<Int> = []
    private var cachedIcon: NSImage?
    private var cachedIconKey: String = ""

    private var iconSize: CGFloat { (chipTextHeight * 0.6).rounded() }
    private var iconGap: CGFloat { 5 }
    /// On-screen width reserved before the domain: the icon plus a small gap.
    private var iconBoxWidth: CGFloat { iconSize + iconGap }
    /// Extra leading width when the chip directly follows a non-space character,
    /// so it doesn't visually hug the preceding `:`/word.
    private var chipLeadingGap: CGFloat { 7 }
    private var bulletSlotWidth: CGFloat { (chipTextHeight * 0.62).rounded() }
    private var checkboxSize: CGFloat { (chipTextHeight * 0.78).rounded() }
    private var checkboxSlotWidth: CGFloat { checkboxSize + 4 }
    /// Per-slot reserved width (icon box / bullet / checkbox).
    private var slotWidths: [Int: CGFloat] = [:]

    override init() {
        super.init()
        delegate = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        delegate = self
    }

    /// Replaces the fold set. No-ops when unchanged so routine selection moves
    /// don't churn layout. Invalidates the union of old+new link ranges.
    func setFolds(_ newFolds: [LinkFolding.Fold]) {
        guard newFolds != folds else { return }
        let affected = unionRange(folds.map(\.linkRange) + newFolds.map(\.linkRange))
        folds = newFolds
        rebuildIndices()
        invalidate(affected)
    }

    /// Replaces the list markers. Same no-op-when-unchanged contract as folds.
    func setMarkers(_ newMarkers: [ListMarkers.Marker]) {
        guard newMarkers != markers else { return }
        let affected = unionRange(markers.map(\.lineRange) + newMarkers.map(\.lineRange))
        markers = newMarkers
        rebuildIndices()
        invalidate(affected)
    }

    /// Rebuilds the hidden-range index and control-slot widths from both folds
    /// and markers — the single source the glyph/layout callbacks read.
    private func rebuildIndices() {
        var ranges: [NSRange] = []
        var slots: [Int: CGFloat] = [:]

        for fold in folds {
            ranges.append(contentsOf: fold.hiddenRanges)
            if let slot = fold.iconSlotIndex {
                slots[slot] = iconBoxWidth + (fold.precededByNonSpace ? chipLeadingGap : 0)
            }
        }
        for marker in markers {
            if let hidden = marker.hiddenRange { ranges.append(hidden) }
            switch marker.kind {
            case .bullet: slots[marker.slotIndex] = bulletSlotWidth
            case .checkbox: slots[marker.slotIndex] = checkboxSlotWidth
            }
        }

        ranges.sort { $0.location < $1.location }
        hiddenStarts = ranges.map { $0.location }
        hiddenEnds = ranges.map { $0.location + $0.length }
        controlSlots = Set(slots.keys)
        slotWidths = slots
    }

    private func invalidate(_ affected: NSRange?) {
        guard let affected, affected.length > 0 else { return }
        let docLength = textStorage?.length ?? 0
        let target = NSIntersectionRange(affected, NSRange(location: 0, length: docLength))
        guard target.length > 0 else { return }
        invalidateGlyphs(forCharacterRange: target, changeInLength: 0, actualCharacterRange: nil)
        invalidateLayout(forCharacterRange: target, actualCharacterRange: nil)
    }

    private func unionRange(_ ranges: [NSRange]) -> NSRange? {
        guard !ranges.isEmpty else { return nil }
        var minLoc = Int.max
        var maxEnd = 0
        for r in ranges {
            minLoc = min(minLoc, r.location)
            maxEnd = max(maxEnd, r.location + r.length)
        }
        return NSRange(location: minLoc, length: maxEnd - minLoc)
    }

    private func isHidden(_ charIndex: Int) -> Bool {
        guard !hiddenStarts.isEmpty else { return false }
        // Binary search for the last range starting at or before charIndex.
        var lo = 0, hi = hiddenStarts.count - 1, candidate = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if hiddenStarts[mid] <= charIndex {
                candidate = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        guard candidate >= 0 else { return false }
        return charIndex < hiddenEnds[candidate]
    }

    // MARK: NSLayoutManagerDelegate — hide the folded glyphs

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes charIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard !hiddenStarts.isEmpty else { return 0 } // 0 → use props unchanged

        let count = glyphRange.length
        let newProps = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
        defer { newProps.deallocate() }
        newProps.update(from: props, count: count)

        var changed = false
        for i in 0..<count {
            let ci = charIndexes[i]
            if controlSlots.contains(ci) {
                // Reserved decoration slot: a control glyph so the control-
                // character delegate can give it a fixed width (see boundingBox).
                newProps[i] = .controlCharacter
                changed = true
            } else if isHidden(ci) {
                newProps[i] = .null
                changed = true
            }
        }
        guard changed else { return 0 }

        layoutManager.setGlyphs(glyphs, properties: newProps, characterIndexes: charIndexes, font: font, forGlyphRange: glyphRange)
        return count
    }

    // MARK: NSLayoutManagerDelegate — reserve width for the icon slot

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldUse action: NSLayoutManager.ControlCharacterAction,
        forControlCharacterAt charIndex: Int
    ) -> NSLayoutManager.ControlCharacterAction {
        controlSlots.contains(charIndex) ? .whitespace : action
    }

    func layoutManager(
        _ layoutManager: NSLayoutManager,
        boundingBoxForControlGlyphAt glyphIndex: Int,
        for textContainer: NSTextContainer,
        proposedLineFragment proposedRect: NSRect,
        glyphPosition: NSPoint,
        characterIndex charIndex: Int
    ) -> NSRect {
        NSRect(x: glyphPosition.x, y: proposedRect.minY, width: slotWidths[charIndex] ?? iconBoxWidth, height: proposedRect.height)
    }

    // MARK: Chip background drawing

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let container = textContainers.first, !folds.isEmpty || !markers.isEmpty else { return }

        drawMarkers(glyphsToShow: glyphsToShow, at: origin, in: container)

        for fold in folds {
            let glyphRange = self.glyphRange(forCharacterRange: fold.visibleRange, actualCharacterRange: nil)
            guard glyphRange.length > 0,
                  NSIntersectionRange(glyphRange, glyphsToShow).length > 0 else { continue }

            var rect = boundingRect(forGlyphRange: glyphRange, in: container)
            rect = rect.offsetBy(dx: origin.x, dy: origin.y)

            // Hug the domain text. The paragraph style adds line spacing *below*
            // each line, so glyphs sit at the TOP of the fragment — centering on
            // the fragment's midY would push the chip down. Center on the text's
            // own vertical span (minY + textHeight/2) instead.
            let chipHeight = chipTextHeight + 4
            let textCenterY = rect.minY + chipTextHeight / 2

            // When this fold has an icon slot, the layout reserved `iconBoxWidth`
            // of blank space just before the domain — extend the pill over it and
            // paint the icon there. Otherwise the pill just hugs the domain.
            let hasIcon = fold.iconSlotIndex != nil
            let pillLeft = hasIcon ? (rect.minX - iconBoxWidth - 4) : (rect.minX - 4)
            let pill = NSRect(
                x: pillLeft,
                y: textCenterY - chipHeight / 2,
                width: rect.maxX + 6 - pillLeft,
                height: chipHeight
            )
            let path = NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5)
            chipFillColor.setFill()
            path.fill()
            chipStrokeColor.setStroke()
            path.lineWidth = 0.75
            path.stroke()

            if hasIcon, let icon = linkIcon() {
                let iconRect = NSRect(
                    x: rect.minX - iconBoxWidth,
                    y: textCenterY - iconSize / 2,
                    width: iconSize,
                    height: iconSize
                )
                icon.draw(in: iconRect)
            }
        }
    }

    /// Draws bullet dots and checkboxes in their reserved slots.
    private func drawMarkers(glyphsToShow: NSRange, at origin: NSPoint, in container: NSTextContainer) {
        for marker in markers {
            let gr = glyphRange(forCharacterRange: NSRange(location: marker.slotIndex, length: 1), actualCharacterRange: nil)
            guard gr.length > 0, NSIntersectionRange(gr, glyphsToShow).length > 0 else { continue }
            let rect = boundingRect(forGlyphRange: gr, in: container).offsetBy(dx: origin.x, dy: origin.y)
            let textCenterY = rect.minY + chipTextHeight / 2

            switch marker.kind {
            case .bullet:
                let d = (chipTextHeight * 0.26).rounded()
                let dot = NSRect(x: rect.minX + (rect.width - d) / 2, y: textCenterY - d / 2, width: d, height: d)
                markerTextColor.setFill()
                NSBezierPath(ovalIn: dot).fill()

            case .checkbox(let checked):
                let box = NSRect(x: rect.minX, y: textCenterY - checkboxSize / 2, width: checkboxSize, height: checkboxSize)
                let path = NSBezierPath(roundedRect: box.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
                if checked {
                    markerAccentColor.setFill()
                    path.fill()
                    drawCheckmark(in: box, color: .white)
                } else {
                    path.lineWidth = 1.5
                    markerTextColor.withAlphaComponent(0.55).setStroke()
                    path.stroke()
                }
            }
        }
    }

    /// A checkmark inside `box`. Coordinates are in the text view's flipped space
    /// (y increases downward), so the dip of the check is the largest y.
    private func drawCheckmark(in box: NSRect, color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: box.minX + box.width * 0.26, y: box.minY + box.height * 0.52))
        path.line(to: NSPoint(x: box.minX + box.width * 0.44, y: box.minY + box.height * 0.70))
        path.line(to: NSPoint(x: box.minX + box.width * 0.76, y: box.minY + box.height * 0.32))
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// The on-screen box for a checkbox marker in container coordinates (add the
    /// text view's `textContainerOrigin` for view coordinates). For hit-testing.
    func checkboxBox(for marker: ListMarkers.Marker) -> NSRect? {
        guard case .checkbox = marker.kind, let container = textContainers.first else { return nil }
        let gr = glyphRange(forCharacterRange: NSRange(location: marker.slotIndex, length: 1), actualCharacterRange: nil)
        guard gr.length > 0 else { return nil }
        let rect = boundingRect(forGlyphRange: gr, in: container)
        let textCenterY = rect.minY + chipTextHeight / 2
        return NSRect(x: rect.minX, y: textCenterY - checkboxSize / 2, width: checkboxSize, height: checkboxSize)
    }

    /// The tinted link glyph, cached until its color or size changes.
    private func linkIcon() -> NSImage? {
        let key = "\(chipIconColor)-\(iconSize)"
        if let cachedIcon, cachedIconKey == key { return cachedIcon }
        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: chipIconColor))
        let image = NSImage(systemSymbolName: "link", accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        cachedIcon = image
        cachedIconKey = key
        return image
    }
}
