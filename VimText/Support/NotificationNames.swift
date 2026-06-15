import Foundation

public extension Notification.Name {
    static let createNewNote = Notification.Name("createNewNote")
    static let duplicateCurrentNote = Notification.Name("duplicateCurrentNote")
    static let focusNoteSearch = Notification.Name("focusNoteSearch")
    /// Posted to hand keyboard focus to the sidebar note list so it can be
    /// driven with Vim keys (j/k/gg/G/Enter/dd). Toggling ⌘L re-posts this;
    /// the list itself decides whether to enter or leave navigation.
    static let focusNoteList = Notification.Name("focusNoteList")
    static let findInNote = Notification.Name("findInNote")
    static let openCommandPalette = Notification.Name("openCommandPalette")
    static let toggleSidebar = Notification.Name("toggleSidebar")
    static let openChangeLocationPanel = Notification.Name("openChangeLocationPanel")
    static let refocusEditor = Notification.Name("refocusEditor")
    /// Posted when a note is opened from somewhere other than the sidebar
    /// (e.g. the command palette) and the sidebar should scroll to reveal it.
    static let revealNoteInSidebar = Notification.Name("revealNoteInSidebar")
    /// Posted (synchronously) before the editor is torn down so the editor
    /// flushes its debounced code-block restyle + RTF serialization, keeping
    /// the persisted content and rich text in sync.
    static let commitEditorPendingWork = Notification.Name("commitEditorPendingWork")
}
