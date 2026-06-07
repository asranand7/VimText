import SwiftUI
import AppKit

class FindController: ObservableObject {
    @Published var isVisible: Bool = false
    @Published var query: String = ""
    @Published var currentMatch: Int = 0
    @Published var totalMatches: Int = 0
    @Published var focusTrigger: Int = 0

    /// Mirrors whether the find text field has focus, so the key monitor only
    /// hijacks Shift+Return (previous match) while you're typing in find — not
    /// when you're editing the note with the find bar open.
    var isFieldFocused: Bool = false

    /// True when the find bar was opened from ⌘K to jump to a match. In this
    /// mode only Enter (next) / Shift+Enter (previous) cycle matches; pressing
    /// any other key dismisses the bar, exactly like Escape.
    var navigationMode: Bool = false

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
                self.navigationMode = false
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
                // Shift+Return → previous match (Enter → next is the field's
                // onSubmit). keyCode 36 is Return.
                if event.keyCode == 36, flags == .shift, self.isFieldFocused {
                    self.findPrev?()
                    return nil
                }
                if event.keyCode == 53 {
                    self.closeFromMonitor()
                    return nil
                }
                // ⌘K navigation mode: only Enter (passes through to onSubmit →
                // next) and Shift+Return (handled above) operate; every other
                // key dismisses, just like Escape.
                if self.navigationMode, self.isFieldFocused {
                    if event.keyCode == 36 { return event }
                    self.closeFromMonitor()
                    return nil
                }
            }
            return event
        }
    }

    /// Closes the find bar and returns focus to the editor (the shared
    /// Escape / navigation-dismiss path).
    private func closeFromMonitor() {
        isVisible = false
        navigationMode = false
        dismiss?()
        query = ""
        currentMatch = 0
        totalMatches = 0
        refocusEditor?()
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
