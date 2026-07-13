import AppKit

/// Pure helpers for Quick Capture, kept separate from the AppKit panel so the
/// headless smoke tests can exercise them.
public enum QuickCapture {
    /// Title rule matching the editor's: first non-empty line that isn't just
    /// an embedded image, capped at 100 characters.
    public static func title(from text: String) -> String {
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || ImageMarkdown.isImageOnly(line) { continue }
            return String(line.prefix(100))
        }
        return ""
    }
}

/// Borderless panel that can take keyboard focus without activating the app
/// (Spotlight-style), so capture works over whatever app is frontmost.
private final class QuickCaptureWindow: NSPanel {
    var onCommandReturn: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == UInt16(kVK_Return) {
            onCommandReturn?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // Clicking away dismisses, Spotlight-style. The buffer is kept (see
    // controller) so a stray click doesn't lose the thought.
    override func resignKey() {
        super.resignKey()
        orderOut(nil)
    }
}

private let kVK_Return = 0x24

/// Floating capture window summoned anywhere by the global hotkey. Type,
/// ⌘↩ saves the text as a new note, Esc (or clicking away) dismisses. The
/// text survives a dismiss — only a successful save clears it.
@MainActor
public final class QuickCapturePanelController: NSObject, NSTextViewDelegate {
    public static let shared = QuickCapturePanelController()

    private var panel: QuickCaptureWindow?
    private var textView: NSTextView?
    private var placeholderLabel: NSTextField?
    private var hintLabel: NSTextField?
    private var containerView: NSView?

    private static let panelSize = NSSize(width: 560, height: 190)
    private static let contentInset: CGFloat = 18
    private static let hintBarHeight: CGFloat = 30

    public func toggle() {
        if let panel, panel.isVisible {
            dismiss()
        } else {
            show()
        }
    }

    public func show() {
        let panel = self.panel ?? buildPanel()
        guard let textView else { return }
        applyTheme(to: panel)
        updatePlaceholderVisibility()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
    }

    /// Same face as the note editor: theme paper, theme text, editor font.
    /// Re-applied on every show so theme/font changes are always reflected.
    private func applyTheme(to panel: QuickCaptureWindow) {
        let theme = AppTheme.current
        let font = Self.editorFont()

        panel.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        containerView?.layer?.backgroundColor = theme.editorBackgroundNS.cgColor
        containerView?.layer?.borderColor = theme.separatorNS.cgColor
        containerView?.layer?.borderWidth = 1

        textView?.font = font
        textView?.textColor = theme.textNS
        textView?.insertionPointColor = theme.accentNS
        textView?.selectedTextAttributes = [
            .backgroundColor: theme.accentNS.withAlphaComponent(0.28)
        ]

        placeholderLabel?.font = font
        placeholderLabel?.textColor = theme.secondaryTextNS.withAlphaComponent(0.8)
        hintLabel?.textColor = theme.secondaryTextNS.withAlphaComponent(0.75)
    }

    /// Mirrors NoteEditorView's font rule (Inter, or the monospaced toggle).
    private static func editorFont() -> NSFont {
        let size = CGFloat(EditorPreferences.fontSize())
        if UserDefaults.standard.bool(forKey: "useMonospacedFont") {
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont(name: "Inter-Regular", size: size)
            ?? NSFont(name: "Inter", size: size)
            ?? .systemFont(ofSize: size)
    }

    public func dismiss() {
        panel?.orderOut(nil)
    }

    private func saveAndDismiss() {
        guard let textView else { return }
        let text = textView.string
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            persistCapturedText(text)
            textView.string = ""
            updatePlaceholderVisibility()
        }
        dismiss()
    }

    private func persistCapturedText(_ text: String) {
        if let viewModel = NotesViewModel.current {
            viewModel.createQuickCapturedNote(text)
        } else {
            // Main window (and its view model) is gone — write straight to
            // disk; the next window/launch loads it. Safe without RTF
            // hydration because a brand-new note has no .rtf sidecar.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = QuickCapture.title(from: trimmed)
            let note = Note(title: title.isEmpty ? "Untitled" : title, content: trimmed)
            StorageManager.shared.saveNote(note)
        }
    }

    // MARK: - NSTextViewDelegate

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Esc reaches NSTextView as cancelOperation: (or complete: on some
        // configurations) — both mean dismiss here.
        if commandSelector == #selector(NSResponder.cancelOperation(_:))
            || commandSelector == #selector(NSTextView.complete(_:)) {
            dismiss()
            return true
        }
        return false
    }

    public func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
    }

    private func updatePlaceholderVisibility() {
        placeholderLabel?.isHidden = !(textView?.string.isEmpty ?? true)
    }

    // MARK: - Panel construction

    private func position(_ panel: NSPanel) {
        // Spotlight-like: centered on whichever screen holds the mouse, in
        // the upper third.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + visible.height * 0.62
        ))
    }

    private func buildPanel() -> QuickCaptureWindow {
        let size = Self.panelSize
        let panel = QuickCaptureWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.onCommandReturn = { [weak self] in self?.saveAndDismiss() }

        // Solid theme paper (colored in applyTheme), not a system material —
        // the panel should look like a small floating piece of the editor.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = 14
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        panel.contentView = container

        let inset = Self.contentInset
        let scrollFrame = NSRect(
            x: inset,
            y: Self.hintBarHeight,
            width: size.width - inset * 2,
            height: size.height - Self.hintBarHeight - inset
        )
        let scroll = NSScrollView(frame: scrollFrame)
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]

        let textView = NSTextView(frame: NSRect(origin: .zero, size: scrollFrame.size))
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollFrame.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        scroll.documentView = textView
        container.addSubview(scroll)

        let placeholder = NSTextField(labelWithString: "Type your note…")
        placeholder.font = Self.editorFont()
        placeholder.frame = NSRect(
            x: inset + 5,
            y: scrollFrame.maxY - placeholder.intrinsicContentSize.height - 6,
            width: scrollFrame.width - 10,
            height: placeholder.intrinsicContentSize.height
        )
        placeholder.autoresizingMask = [.width, .minYMargin]
        container.addSubview(placeholder)

        let hint = NSTextField(labelWithString: "↩ new line    ⌘↩ save to VimText    esc dismiss")
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .right
        hint.frame = NSRect(x: inset, y: 9, width: size.width - inset * 2, height: 14)
        hint.autoresizingMask = [.width, .maxYMargin]
        container.addSubview(hint)

        self.panel = panel
        self.textView = textView
        self.placeholderLabel = placeholder
        self.hintLabel = hint
        self.containerView = container
        return panel
    }
}
