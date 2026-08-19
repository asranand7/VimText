import Foundation

/// The stable, transport-agnostic API over a user's notes.
///
/// Everything outside the app (today: the MCP server) talks to this type and
/// never to `StorageManager` or the on-disk layout — so changing how notes are
/// persisted stays invisible to integrations. The DTOs below are deliberately
/// *not* `Note`: ids are strings, dates are ISO-8601, and no storage-only field
/// (rtfData, sidecar sync flags) is exposed.
///
/// Two execution paths, mirroring Quick Capture (`QuickCapturePanel.save`):
/// when a main window exists, everything routes through `NotesViewModel` so the
/// UI updates live; when it doesn't (window closed, app still running), the
/// service reads and writes `StorageManager` directly.
@MainActor
public final class NotesService {
    public static let shared = NotesService()

    /// Bumped on breaking DTO changes so clients can detect a mismatch. Adding
    /// an optional field is not breaking and does not bump this.
    public static let apiVersion = 1

    private init() {}

    // MARK: - DTOs

    public struct NoteSummary: Codable {
        public let id: String
        public let title: String
        public let preview: String
        public let folder: String?
        public let createdAt: String
        public let modifiedAt: String
        public let isPinned: Bool
        public let isLocked: Bool
        public let characterCount: Int
        /// `vimtext://` link that opens this note. Included so an agent's answer
        /// can end in something the user clicks, instead of a title they have to
        /// go and find.
        public let url: String
    }

    public struct NoteDetail: Codable {
        public let id: String
        public let title: String
        public let content: String
        public let folder: String?
        public let createdAt: String
        public let modifiedAt: String
        public let isPinned: Bool
        public let isLocked: Bool
        public let characterCount: Int
        public let url: String
    }

    public struct FolderInfo: Codable {
        public let id: String
        public let name: String
        public let noteCount: Int
    }

    public enum UpdateMode: String, Codable {
        case replace, append, prepend
    }

    public enum ServiceError: LocalizedError, Equatable {
        case noteNotFound(String)
        case ambiguousTitle(String, [String])
        case noteLocked(String)
        case folderNotFound(String)
        case invalidArgument(String)
        case saveFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noteNotFound(let ref):
                return "No note matches \(ref)."
            case .ambiguousTitle(let title, let ids):
                return "Several notes are titled \"\(title)\". Call read_note again with one of these ids: \(ids.joined(separator: ", "))."
            case .noteLocked(let title):
                return "\"\(title)\" is locked. Unlock it in VimText to allow changes."
            case .folderNotFound(let name):
                return "No folder named \"\(name)\"."
            case .invalidArgument(let detail):
                return detail
            case .saveFailed(let detail):
                return "Could not save: \(detail)"
            }
        }
    }

    // MARK: - Reads

    public func search(query: String, limit: Int = 20, folder: String? = nil) throws -> [NoteSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServiceError.invalidArgument("query must not be empty; use list_notes to browse.")
        }
        let folderId = try resolveFolderFilter(folder)
        let candidates = notes().filter { folder == nil || $0.folderId == folderId }

        // Title matches rank above body matches, using the same fuzzy matcher
        // as the ⌘K palette so agent search and in-app search agree.
        let scored: [(note: Note, score: Int)] = candidates.compactMap { note in
            let titleScore = FuzzySearch.match(trimmed, in: note.displayTitle).map { $0.score * 2 }
            // Locked bodies are searched like any other: the lock protects a
            // note from being *edited*, not from being found. The app's own
            // search matches locked notes too.
            let bodyScore: Int? = note.content.searchNormalized.range(of: trimmed.searchNormalized) != nil ? 40 : nil
            guard let best = [titleScore, bodyScore].compactMap({ $0 }).max() else { return nil }
            return (note, best)
        }

        return scored
            .sorted { $0.score == $1.score ? $0.note.modifiedAt > $1.note.modifiedAt : $0.score > $1.score }
            .prefix(max(1, limit))
            .map(\.note)
            .map(summary(for:))
    }

    public func list(folder: String? = nil, limit: Int = 50, offset: Int = 0) throws -> [NoteSummary] {
        let folderId = try resolveFolderFilter(folder)
        let filtered = notes()
            .filter { folder == nil || $0.folderId == folderId }
            .sorted { $0.modifiedAt > $1.modifiedAt }
        // Clamped rather than rejected: paging arguments come straight out of a
        // model, and a negative offset would trap on the slice below — taking
        // the whole app down over a bad tool call.
        let start = min(max(0, offset), filtered.count)
        return filtered[start...].prefix(max(1, limit)).map(summary(for:))
    }

    public func read(id: String?, title: String?) throws -> NoteDetail {
        let note = try resolve(id: id, title: title)
        return detail(for: note)
    }

    public func folders() -> [FolderInfo] {
        let all = notes()
        return folderList().map { folder in
            FolderInfo(
                id: folder.id.uuidString,
                name: folder.name,
                noteCount: all.filter { $0.folderId == folder.id }.count
            )
        }
    }

    // MARK: - Writes

    public func create(content: String, title: String?, folder: String?) throws -> NoteDetail {
        let folderId = try resolveFolder(folder)
        // Falling back to the first line matches how a note titled in the app
        // gets its name, so agent-made notes look native in the sidebar.
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? QuickCapture.title(from: content).nilIfEmpty
            ?? "Untitled"

        if let viewModel = NotesViewModel.current {
            let note = viewModel.createExternalNote(title: resolvedTitle, content: content, folderId: folderId)
            viewModel.flushPendingSavesSynchronously()
            return detail(for: note)
        }
        let note = Note(title: resolvedTitle, content: content, folderId: folderId)
        if case .failure(let error) = StorageManager.shared.saveNote(note) {
            throw ServiceError.saveFailed(error.localizedDescription)
        }
        invalidateCachedNotes()
        return detail(for: note)
    }

    public func update(id: String, content: String, mode: UpdateMode, title: String?) throws -> NoteDetail {
        let note = try resolve(id: id, title: nil)
        guard !note.isLocked else { throw ServiceError.noteLocked(note.displayTitle) }

        let newContent = merged(existing: note.content, incoming: content, mode: mode)
        let newTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? note.title

        if let viewModel = NotesViewModel.current {
            guard let updated = viewModel.applyExternalEdit(id: note.id, title: newTitle, content: newContent) else {
                throw ServiceError.noteNotFound(id)
            }
            return detail(for: updated)
        }

        var copy = note
        copy.title = newTitle
        copy.content = newContent
        // The `.rtf` sidecar still holds the pre-edit text and wins over the
        // `.txt` when the editor loads a note, so it has to go — same as the
        // app's own plain-content edit path (`updateNoteContent`).
        copy.rtfData = nil
        copy.modifiedAt = Date()
        if case .failure(let error) = StorageManager.shared.saveNote(copy, rtfInSync: false) {
            throw ServiceError.saveFailed(error.localizedDescription)
        }
        invalidateCachedNotes()
        return detail(for: copy)
    }

    public func delete(id: String) throws -> NoteSummary {
        let note = try resolve(id: id, title: nil)
        // Belt and braces: NotesViewModel.deleteNote refuses locked notes too,
        // but the headless path below goes straight to StorageManager, which
        // knows nothing about locking. This guard is the only one there.
        guard !note.isLocked else { throw ServiceError.noteLocked(note.displayTitle) }
        let deleted = summary(for: note)

        if let viewModel = NotesViewModel.current {
            viewModel.deleteNote(note)
        } else {
            let remaining = notes().filter { $0.id != note.id }
            StorageManager.shared.deleteNote(note, remainingNotes: remaining)
            invalidateCachedNotes()
        }
        return deleted
    }

    /// Locks a note, so nothing can change it until the user unlocks it in
    /// VimText.
    ///
    /// One-way on purpose. Every other write here refuses a locked note, and an
    /// unlock tool would hand a model the obvious way round that — unlock,
    /// edit, lock again. The lock exists to stop edits nobody asked for, which
    /// is exactly the mistake an agent is most likely to make, so removing it
    /// stays a human action: one click on the lock in the editor header. (To
    /// allow it anyway, this is the method to extend, along with the
    /// `lock_note` schema and the instructions in `MCPContract`.)
    @discardableResult
    public func lock(id: String) throws -> NoteSummary {
        let note = try resolve(id: id, title: nil)
        // Idempotent: a model re-locking a locked note has got what it wanted.
        guard !note.isLocked else { return summary(for: note) }

        if let viewModel = NotesViewModel.current {
            // The editor may still be holding keystrokes it hasn't serialized;
            // once the note is locked, `updateNoteContent`'s locked guard would
            // drop them. Same reasoning as `applyExternalEdit`.
            NotificationCenter.default.post(name: .commitEditorPendingWork, object: nil)
            // toggleLock flushes pending saves and hydrates the RTF sidecar
            // before saving, which is why this doesn't set the flag itself.
            viewModel.toggleLock(note)
            let locked = viewModel.notes.first { $0.id == note.id } ?? note
            return summary(for: locked)
        }

        var copy = note
        copy.isLocked = true
        // Locking isn't a content edit, so `modifiedAt` stays put — the same
        // choice the app's own lock button makes, and it keeps a lock from
        // reordering the sidebar. The note came from the eager headless read,
        // so it still carries its RTF and saving won't drop the sidecar.
        if case .failure(let error) = StorageManager.shared.saveNote(copy) {
            throw ServiceError.saveFailed(error.localizedDescription)
        }
        invalidateCachedNotes()
        return summary(for: copy)
    }

    public func move(id: String, folder: String?) throws -> NoteSummary {
        let note = try resolve(id: id, title: nil)
        guard !note.isLocked else { throw ServiceError.noteLocked(note.displayTitle) }
        let folderId = try resolveFolder(folder)

        if let viewModel = NotesViewModel.current {
            viewModel.moveNote(note, to: folderId)
            viewModel.flushPendingSavesSynchronously()
            let moved = viewModel.notes.first { $0.id == note.id } ?? note
            return summary(for: moved)
        }
        var copy = note
        copy.folderId = folderId
        copy.modifiedAt = Date()
        if case .failure(let error) = StorageManager.shared.saveNote(copy) {
            throw ServiceError.saveFailed(error.localizedDescription)
        }
        invalidateCachedNotes()
        return summary(for: copy)
    }

    // MARK: - Backing state

    private var cachedNotes: [Note]?
    private var cachedFolders: [NoteFolder]?
    private var requestDepth = 0

    /// Runs one request against a single read of the store.
    ///
    /// With a window open the backing state is already in memory, but the
    /// headless path goes to disk on every access, and the call graph touches
    /// it a lot: `list` alone re-read `folders.json` once *per row* just to name
    /// each note's folder, on top of reloading every note. Caching for the span
    /// of one request makes that one read each. Writes clear the cache, so
    /// nothing later in the same request can see a note it just changed.
    func withRequestScope<T>(_ body: () throws -> T) rethrows -> T {
        requestDepth += 1
        defer {
            requestDepth -= 1
            if requestDepth == 0 { invalidateCache() }
        }
        return try body()
    }

    private func invalidateCache() {
        cachedNotes = nil
        cachedFolders = nil
    }

    /// After a note write. The folder list is untouched by one, so it stays.
    private func invalidateCachedNotes() {
        cachedNotes = nil
    }

    /// The live notes when a window is open, otherwise a fresh read from disk.
    ///
    /// The headless read is deliberately eager (`loadNotes`, which loads `.rtf`)
    /// rather than the lazy snapshot: a note whose `rtfData` is nil would have
    /// its sidecar deleted by the next `saveNote`, silently dropping the user's
    /// formatting and images.
    private func notes() -> [Note] {
        if let viewModel = NotesViewModel.current { return viewModel.notes }
        if let cachedNotes { return cachedNotes }
        let loaded = StorageManager.shared.loadNotes()
        if requestDepth > 0 { cachedNotes = loaded }
        return loaded
    }

    private func folderList() -> [NoteFolder] {
        if let viewModel = NotesViewModel.current { return viewModel.folders }
        if let cachedFolders { return cachedFolders }
        let loaded = StorageManager.shared.loadFolders()
        if requestDepth > 0 { cachedFolders = loaded }
        return loaded
    }

    private func resolve(id: String?, title: String?) throws -> Note {
        if let id = id?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            guard let uuid = UUID(uuidString: id) else {
                throw ServiceError.invalidArgument("\"\(id)\" is not a valid note id. Ids come from search_notes or list_notes.")
            }
            guard let note = notes().first(where: { $0.id == uuid }) else {
                throw ServiceError.noteNotFound(id)
            }
            return note
        }
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw ServiceError.invalidArgument("Pass either id or title.")
        }
        let matches = notes().filter { $0.displayTitle.caseInsensitiveCompare(title) == .orderedSame }
        switch matches.count {
        case 0: throw ServiceError.noteNotFound("title \"\(title)\"")
        case 1: return matches[0]
        default: throw ServiceError.ambiguousTitle(title, matches.map(\.id.uuidString))
        }
    }

    /// Resolves a folder reference (name or id) for assignment. `nil` means
    /// "All Notes" and is a valid destination, so this returns an optional
    /// rather than throwing on nil.
    private func resolveFolder(_ reference: String?) throws -> UUID? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }
        if let uuid = UUID(uuidString: reference), folderList().contains(where: { $0.id == uuid }) {
            return uuid
        }
        guard let match = folderList().first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) else {
            throw ServiceError.folderNotFound(reference)
        }
        return match.id
    }

    /// Same resolution, for filtering reads. Distinguished only for clarity at
    /// the call sites, where `nil` means "don't filter" rather than "no folder".
    private func resolveFolderFilter(_ reference: String?) throws -> UUID? {
        try resolveFolder(reference)
    }

    private func merged(existing: String, incoming: String, mode: UpdateMode) -> String {
        switch mode {
        case .replace:
            return incoming
        case .append:
            guard !existing.isEmpty else { return incoming }
            return existing.hasSuffix("\n") ? existing + incoming : existing + "\n" + incoming
        case .prepend:
            guard !existing.isEmpty else { return incoming }
            return incoming.hasSuffix("\n") ? incoming + existing : incoming + "\n" + existing
        }
    }

    // MARK: - DTO mapping

    private func folderName(for id: UUID?) -> String? {
        guard let id else { return nil }
        return folderList().first { $0.id == id }?.name
    }

    private func summary(for note: Note) -> NoteSummary {
        NoteSummary(
            id: note.id.uuidString,
            title: note.displayTitle,
            preview: NotesViewModel.current?.preview(for: note.id) ?? note.preview,
            folder: folderName(for: note.folderId),
            createdAt: ISO8601DateFormatter.vimTextService.string(from: note.createdAt),
            modifiedAt: ISO8601DateFormatter.vimTextService.string(from: note.modifiedAt),
            isPinned: note.isPinned,
            isLocked: note.isLocked,
            characterCount: note.content.count,
            url: DeepLink.url(forNoteId: note.id)
        )
    }

    private func detail(for note: Note) -> NoteDetail {
        NoteDetail(
            id: note.id.uuidString,
            title: note.displayTitle,
            // Locked notes read normally — the editor shows their content too.
            // `isLocked` below tells the agent it must not attempt a write; the
            // write methods refuse one regardless.
            content: note.content,
            folder: folderName(for: note.folderId),
            createdAt: ISO8601DateFormatter.vimTextService.string(from: note.createdAt),
            modifiedAt: ISO8601DateFormatter.vimTextService.string(from: note.modifiedAt),
            isPinned: note.isPinned,
            isLocked: note.isLocked,
            characterCount: note.content.count,
            url: DeepLink.url(forNoteId: note.id)
        )
    }
}

extension ISO8601DateFormatter {
    /// Shared formatter for service DTOs — `ISO8601DateFormatter` is expensive
    /// to build and every note in a list response needs two.
    static let vimTextService = ISO8601DateFormatter()
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
