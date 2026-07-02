import SwiftUI
import AppKit


// MARK: - VimTextView

struct VimTextView: NSViewRepresentable {
    /// Content the editor is created with. The NSTextStorage is the source of
    /// truth from then on — SwiftUI never pushes content back into the view.
    /// The editor is recreated per note (`.id(noteId)`), so initial-only is
    /// sufficient.
    var initialText: String
    var initialRTFData: Data
    /// Called (debounced, and on flush) with the latest serialized content
    /// (Markdown text + RTF) whenever the user edits the note.
    var onContentChange: ((String, Data) -> Void)?
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
    /// Locked notes are read-only: typing is disabled and Vim mutations are
    /// rejected with a status hint. Navigation/search still work.
    var isLocked: Bool = false

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
        // Swap in the folding layout manager so long URLs render as domain
        // chips. Done before content loads so the first layout pass already
        // reflects the folds. Temporary attributes (links/search) live on the
        // layout manager, so they're (re)applied after this via refresh* calls.
        if let container = textView.textContainer {
            container.replaceLayoutManager(FoldingLayoutManager())
        }
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
        // Render stored `.link` runs (e.g. browser-pasted URLs) as clean
        // accent-colored text with no underline — the dated default.
        textView.linkTextAttributes = [
            .foregroundColor: accentColor,
            .underlineStyle: 0,
            .cursor: NSCursor.pointingHand
        ]
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
        textView.isLockedNote = isLocked
        textView.isEditable = !isLocked

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

        // Load rich text content or fall back to plain text. From here on the
        // text storage is authoritative; content flows out via onContentChange.
        if !initialRTFData.isEmpty, let attrStr = NSAttributedString(rtf: initialRTFData, documentAttributes: nil) {
            textView.textStorage?.setAttributedString(attrStr)
            textView.applyTextColor(textColor)
            textView.applyBaseFont(font)
        } else {
            let attrStr = NSAttributedString(string: initialText, attributes: defaultAttrs)
            textView.textStorage?.setAttributedString(attrStr)
        }
        textView.restyleCodeBlocks(baseFont: font)
        textView.renderImageAttachments()
        textView.refreshLinkHighlights()
        textView.refreshListMarkers()
        context.coordinator.latestText = initialText
        context.coordinator.latestRTF = initialRTFData

        let isInsert = vimEngine.mode.isEditing || startInInsertMode
        textView.updateCursorAppearance(isBlock: !isInsert)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? VimNSTextView else { return }
        context.coordinator.parent = self

        // Note content is never pushed from SwiftUI after creation — the text
        // storage is the source of truth and the editor is recreated per note.
        // Only presentation inputs (font, theme, paper, rulers) sync below.

        // Re-apply base font/size across the document when it changes (preserving bold/italic)
        if context.coordinator.lastFontSize != font.pointSize || context.coordinator.lastFontName != font.fontName {
            context.coordinator.lastFontSize = font.pointSize
            context.coordinator.lastFontName = font.fontName
            textView.applyBaseFont(font)
            textView.restyleCodeBlocks(baseFont: font)
            var attrs = textView.typingAttributes
            attrs[.font] = font
            textView.typingAttributes = attrs
            // Chips and list markers size themselves from the font's line
            // height — refold so they re-reserve their slots at the new size.
            textView.updateLinkFolds()
            textView.applyListMarkers()
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
            textView.linkTextAttributes = [
                .foregroundColor: accentColor,
                .underlineStyle: 0,
                .cursor: NSCursor.pointingHand
            ]
            textView.applyTextColor(textColor)
            textView.refreshLinkHighlights()
            textView.refreshListMarkers()
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
        textView.isLockedNote = isLocked
        textView.isEditable = !isLocked
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

}



