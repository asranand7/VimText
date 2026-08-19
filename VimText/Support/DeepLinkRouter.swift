import AppKit
import Foundation

/// Turns a parsed `DeepLink` into app state.
///
/// Split from `DeepLink` so the parsing stays pure and headlessly testable;
/// this half is the one that needs a running app.
///
/// The awkward part is timing. macOS delivers a URL as soon as the app is
/// launched to open it, which on a cold start is before SwiftUI has built the
/// window — so `NotesViewModel.current` is nil and the notes aren't loaded yet.
/// Rather than guess a delay, an unroutable link is retried on a short tick
/// until the view model appears or the budget runs out.
@MainActor
public final class DeepLinkRouter {
    public static let shared = DeepLinkRouter()

    private init() {}

    /// A cold launch has to build the window, the view model *and* finish the
    /// asynchronous note load before a link can be routed — measured at over
    /// three seconds on a first launch after install, so the budget is generous.
    /// It is still bounded: a link that can never be routed has to stop rather
    /// than fire into whatever the user opened in the meantime.
    private static let retryInterval: TimeInterval = 0.15
    private static let retryBudget: TimeInterval = 10
    private static var maxAttempts: Int { Int(retryBudget / retryInterval) }

    public func handle(_ urls: [URL]) {
        for url in urls {
            guard let link = DeepLink.parse(url) else { continue }
            route(link, attempt: 0)
        }
    }

    private func route(_ link: DeepLink, attempt: Int) {
        NSApp.activate(ignoringOtherApps: true)

        switch link {
        case .capture(let text):
            // No view model needed: the capture panel writes through
            // NotesViewModel when a window exists and straight to storage when
            // it doesn't, exactly as the global hotkey does.
            QuickCapturePanelController.shared.show(prefill: text)

        case .search(let query):
            guard let viewModel = NotesViewModel.current else {
                return retry(link, attempt: attempt)
            }
            viewModel.searchText = query
            NotificationCenter.default.post(name: .focusNoteSearch, object: nil)

        case .note(let id, let target):
            guard let viewModel = NotesViewModel.current else {
                return retry(link, attempt: attempt)
            }
            guard viewModel.notes.contains(where: { $0.id == id }) else {
                // Notes arrive asynchronously (`NotesViewModel.loadAsync`), so
                // an empty list means "not loaded yet", not "not there" — keep
                // waiting. A populated list without the id is a real answer.
                if viewModel.notes.isEmpty { return retry(link, attempt: attempt) }
                reportMissingNote()
                return
            }
            // Set before the selection: switching notes rebuilds the editor,
            // and its onAppear is what consumes the target — the same order
            // the ⌘K palette uses for pendingSearchHighlight.
            viewModel.pendingCaretTarget = target
            viewModel.selectedNoteId = id
            NotificationCenter.default.post(name: .revealNoteInSidebar, object: id)
        }
    }

    /// The one case worth interrupting for. A deep link's whole promise is
    /// "click this and land there"; when the note has since been deleted, the
    /// app comes to the front showing something else entirely and silence reads
    /// as success.
    private func reportMissingNote() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "That note no longer exists"
        alert.informativeText = "The link points to a note that has been deleted."
        alert.runModal()
    }

    private func retry(_ link: DeepLink, attempt: Int) {
        guard attempt < Self.maxAttempts else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.retryInterval) { [weak self] in
            self?.route(link, attempt: attempt + 1)
        }
    }
}
