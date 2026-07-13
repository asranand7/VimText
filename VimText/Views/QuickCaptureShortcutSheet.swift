import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Sheet for rebinding the global Quick Capture shortcut. Records any
/// combination of ⌃⌥⇧⌘ plus a key — all four modifiers at once included —
/// applies it immediately, and surfaces the Carbon rejection when another
/// app owns the combo system-wide.
struct QuickCaptureShortcutSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var display = QuickCaptureHotKey.shared.shortcutDescription
    @State private var message: String?

    var body: some View {
        VStack(spacing: 16) {
            Text("Quick Capture Shortcut")
                .font(.headline)
            Text("Press the new shortcut — any mix of ⌃ ⌥ ⇧ ⌘ plus a key.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.6))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.tertiary, lineWidth: 1)
                Text(display)
                    .font(.title3.weight(.medium))
                ShortcutRecorderField(
                    onCapture: { keyCode, modifiers in
                        applyShortcut(keyCode: keyCode, carbonModifiers: modifiers)
                    },
                    onCancel: { dismiss() }
                )
            }
            .frame(width: 260, height: 44)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Reset to Default (⌃⌥Space)") {
                    applyShortcut(
                        keyCode: QuickCaptureHotKey.defaultKeyCode,
                        carbonModifiers: QuickCaptureHotKey.defaultModifiers
                    )
                }
                Spacer()
                Button("Done") { dismiss() }
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func applyShortcut(keyCode: UInt32, carbonModifiers: UInt32) {
        guard QuickCaptureHotKey.isValidShortcut(keyCode: keyCode, carbonModifiers: carbonModifiers) else {
            message = "Include at least one of ⌃ ⌥ ⌘ (F-keys work alone)."
            return
        }
        if QuickCaptureHotKey.shared.apply(keyCode: keyCode, carbonModifiers: carbonModifiers) {
            message = nil
        } else {
            message = "That shortcut is already taken by another app — VimText couldn't register it."
        }
        display = QuickCaptureHotKey.shared.shortcutDescription
    }
}

/// Invisible key-catcher that grabs focus and reports the next keystroke as
/// (virtual key code, Carbon modifier mask). Plain Esc cancels instead of
/// being recorded, so the sheet stays dismissable from the keyboard.
private struct ShortcutRecorderField: NSViewRepresentable {
    var onCapture: (UInt32, UInt32) -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onCapture = onCapture
        view.onCancel = onCancel
    }

    final class RecorderView: NSView {
        var onCapture: ((UInt32, UInt32) -> Void)?
        var onCancel: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The sheet's field should be recording the moment it appears.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        private func handle(_ event: NSEvent) -> Bool {
            let modifiers = QuickCaptureHotKey.carbonModifiers(from: event.modifierFlags)
            if event.keyCode == UInt16(kVK_Escape), modifiers == 0 {
                onCancel?()
                return true
            }
            onCapture?(UInt32(event.keyCode), modifiers)
            return true
        }

        override func keyDown(with event: NSEvent) {
            _ = handle(event)
        }

        // ⌘-combos arrive as key equivalents, not keyDown — claim them here
        // so the shortcut being recorded doesn't fire an app menu item.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.type == .keyDown, window?.firstResponder === self else {
                return super.performKeyEquivalent(with: event)
            }
            return handle(event)
        }
    }
}
