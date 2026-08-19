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
    /// Opens the command palette in commands-only mode (⌘P): every action the
    /// app can do, browsable and searchable, with no notes mixed in.
    static let openCommandList = Notification.Name("openCommandList")
    /// Asks the open editor to delete the current note via its (locked-aware)
    /// confirmation dialog — so a palette "Delete Note" is as safe as the
    /// header trash button.
    static let requestDeleteCurrentNote = Notification.Name("requestDeleteCurrentNote")
    static let toggleSidebar = Notification.Name("toggleSidebar")
    /// Opens the sheet for rebinding the global Quick Capture shortcut
    /// (posted by the ⌘P palette; NoteListView owns the sheet).
    static let openQuickCaptureShortcutSettings = Notification.Name("openQuickCaptureShortcutSettings")
    static let openChangeLocationPanel = Notification.Name("openChangeLocationPanel")
    /// Opens the sheet that connects an AI assistant to these notes over MCP
    /// (posted by the ⌘P palette; NoteListView owns the sheet).
    static let openAIConnectionPanel = Notification.Name("openAIConnectionPanel")
    static let refocusEditor = Notification.Name("refocusEditor")
    /// Posted when a note is opened from somewhere other than the sidebar
    /// (e.g. the command palette) and the sidebar should scroll to reveal it.
    static let revealNoteInSidebar = Notification.Name("revealNoteInSidebar")
    /// Posted (synchronously) before the editor is torn down so the editor
    /// flushes its debounced code-block restyle + RTF serialization, keeping
    /// the persisted content and rich text in sync.
    static let commitEditorPendingWork = Notification.Name("commitEditorPendingWork")
    /// Asks the open editor to move the caret to a `DeepLink.Target` (carried
    /// as the notification object) — a `vimtext://note/<id>?line=…` arriving
    /// from outside the app. The editor holds the text, so only it can resolve
    /// a line or heading into an offset.
    static let jumpToCaretTarget = Notification.Name("jumpToCaretTarget")
}
