import AppKit

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
        // Bulk-copy characters and scan the buffer: one getCharacters call per
        // chunk instead of an objc_msgSend per character, which dominated the
        // gutter's draw time on large notes.
        var count = 0
        var location = range.location
        let chunkSize = 64 * 1024
        var buffer = [unichar](repeating: 0, count: min(chunkSize, safeEnd - location))
        while location < safeEnd {
            let chunkLen = min(chunkSize, safeEnd - location)
            buffer.withUnsafeMutableBufferPointer { buf in
                nsString.getCharacters(buf.baseAddress!, range: NSRange(location: location, length: chunkLen))
            }
            for i in 0..<chunkLen where buffer[i] == 0x0A { count += 1 }
            location += chunkLen
        }
        return count
    }

    /// The last (character index, line number) pair resolved by `lineNumber`.
    /// Scrolling redraws the gutter every frame; counting newlines only over
    /// the delta since the previous draw keeps that O(scroll distance) instead
    /// of O(document) per frame. Edits shift offsets, so `invalidateLineCache`
    /// (called from `VimNSTextView.didChangeText`) must drop it.
    private var lineAnchor: (charIndex: Int, line: Int)?

    func invalidateLineCache() {
        lineAnchor = nil
    }

    private func lineNumber(at characterIndex: Int, in nsString: NSString) -> Int {
        let target = min(max(characterIndex, 0), nsString.length)
        guard target > 0 else { return 1 }
        let line: Int
        // Count from the cached anchor when that's the shorter walk (an
        // invariant, not an optimization guess: line(T) = 1 + newlines[0,T)
        // = anchorLine ± newlines between anchor and T).
        if let anchor = lineAnchor, anchor.charIndex <= nsString.length,
           abs(anchor.charIndex - target) < target {
            if target >= anchor.charIndex {
                line = anchor.line + newlineCount(in: NSRange(location: anchor.charIndex, length: target - anchor.charIndex), in: nsString)
            } else {
                line = anchor.line - newlineCount(in: NSRange(location: target, length: anchor.charIndex - target), in: nsString)
            }
        } else {
            line = 1 + newlineCount(in: NSRange(location: 0, length: target), in: nsString)
        }
        lineAnchor = (target, line)
        return line
    }
}
