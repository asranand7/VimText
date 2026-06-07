import AppKit

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
