import AppKit

/// Full-window overlay that shows a note's images at large size, Twitter-style:
/// double-click an image to open it here, ←/→ (or h/l) to move between the
/// note's images, Esc / q / click-outside to close. Presented by adding itself
/// over the window's content view; on close it removes itself and hands first
/// responder back to the editor.
final class ImageLightboxView: NSView {
    private let images: [NSImage]
    private var index: Int
    var onClose: (() -> Void)?

    // Hit regions, recomputed on every draw.
    private var imageRect: NSRect = .zero
    private var closeRect: NSRect = .zero
    private var prevRect: NSRect = .zero
    private var nextRect: NSRect = .zero

    private init(images: [NSImage], startIndex: Int) {
        self.images = images
        self.index = min(max(0, startIndex), max(0, images.count - 1))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.9).cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    /// Builds the overlay over `host`'s window, wires close to restore the
    /// editor's focus, and fades it in. No-op if there are no images.
    static func present(images: [NSImage], startIndex: Int, over host: NSView) {
        guard !images.isEmpty, let content = host.window?.contentView else { return }
        let box = ImageLightboxView(images: images, startIndex: startIndex)
        box.frame = content.bounds
        box.autoresizingMask = [.width, .height]
        box.onClose = { [weak box, weak host] in
            box?.removeFromSuperview()
            if let host { host.window?.makeFirstResponder(host) }
        }
        content.addSubview(box)
        host.window?.makeFirstResponder(box)
        box.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            box.animator().alphaValue = 1
        }
    }

    private func close() { onClose?() }

    private func step(_ delta: Int) {
        guard images.count > 1 else { return }
        index = (index + delta + images.count) % images.count
        needsDisplay = true
    }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        if !handleNavigationKey(event) { super.keyDown(with: event) }
    }

    /// AppKit calls this for every key-down as it walks the view hierarchy,
    /// *before* dispatching `keyDown` to the first responder. Claiming the
    /// navigation keys here makes them work even if focus is still on the
    /// editor behind the overlay (arrow keys would otherwise move its caret).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        handleNavigationKey(event) || super.performKeyEquivalent(with: event)
    }

    /// Returns true if `event` was a viewer navigation/close key we consumed.
    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53: close(); return true          // esc
        case 123: step(-1); return true        // left arrow
        case 124: step(1); return true         // right arrow
        default:
            switch event.charactersIgnoringModifiers {
            case "h": step(-1); return true
            case "l", " ": step(1); return true
            case "q": close(); return true
            default: return false
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if closeRect.contains(p) { close(); return }
        if images.count > 1 {
            if prevRect.contains(p) { step(-1); return }
            if nextRect.contains(p) { step(1); return }
        }
        // Click on the dimmed backdrop (not the image itself) dismisses.
        if !imageRect.contains(p) { close() }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(closeRect, cursor: .pointingHand)
        if images.count > 1 {
            addCursorRect(prevRect, cursor: .pointingHand)
            addCursorRect(nextRect, cursor: .pointingHand)
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard !images.isEmpty else { return }
        let image = images[index]

        let sideInset: CGFloat = images.count > 1 ? 96 : 48
        let available = bounds.insetBy(dx: sideInset, dy: 64)
        imageRect = Self.aspectFit(image.size, in: available)
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1)

        // Close button (top-right).
        closeRect = NSRect(x: bounds.maxX - 56, y: bounds.maxY - 56, width: 34, height: 34)
        drawGlyphCircle(in: closeRect) { r in
            let path = NSBezierPath()
            let i = r.insetBy(dx: r.width * 0.32, dy: r.height * 0.32)
            path.move(to: NSPoint(x: i.minX, y: i.minY))
            path.line(to: NSPoint(x: i.maxX, y: i.maxY))
            path.move(to: NSPoint(x: i.minX, y: i.maxY))
            path.line(to: NSPoint(x: i.maxX, y: i.minY))
            return path
        }

        guard images.count > 1 else { return }

        // Left / right navigation chevrons, vertically centered.
        let chevronY = bounds.midY - 21
        prevRect = NSRect(x: 26, y: chevronY, width: 42, height: 42)
        nextRect = NSRect(x: bounds.maxX - 68, y: chevronY, width: 42, height: 42)
        drawGlyphCircle(in: prevRect) { r in Self.chevron(in: r, pointingLeft: true) }
        drawGlyphCircle(in: nextRect) { r in Self.chevron(in: r, pointingLeft: false) }

        // "index / count" counter, centered near the bottom.
        let counter = "\(index + 1) / \(images.count)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let size = counter.size(withAttributes: attrs)
        counter.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: 26), withAttributes: attrs)
    }

    /// Draws a translucent circular button and strokes `glyph(bounds)` on top.
    private func drawGlyphCircle(in rect: NSRect, glyph: (NSRect) -> NSBezierPath) {
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(ovalIn: rect).fill()
        NSColor.white.withAlphaComponent(0.9).setStroke()
        let path = glyph(rect)
        path.lineWidth = 2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func chevron(in rect: NSRect, pointingLeft: Bool) -> NSBezierPath {
        let r = rect.insetBy(dx: rect.width * 0.34, dy: rect.height * 0.28)
        let path = NSBezierPath()
        if pointingLeft {
            path.move(to: NSPoint(x: r.maxX, y: r.maxY))
            path.line(to: NSPoint(x: r.minX, y: r.midY))
            path.line(to: NSPoint(x: r.maxX, y: r.minY))
        } else {
            path.move(to: NSPoint(x: r.minX, y: r.maxY))
            path.line(to: NSPoint(x: r.maxX, y: r.midY))
            path.line(to: NSPoint(x: r.minX, y: r.minY))
        }
        return path
    }

    /// Largest rect with `size`'s aspect ratio that fits centered in `container`.
    /// Never upscales past the image's native size.
    private static func aspectFit(_ size: NSSize, in container: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return container }
        let scale = min(container.width / size.width, container.height / size.height, 1)
        let w = size.width * scale
        let h = size.height * scale
        return NSRect(x: container.midX - w / 2, y: container.midY - h / 2, width: w, height: h)
    }
}
