import Foundation
import SwiftUI
import Combine
import AppKit

enum NoteSaveState: Equatable {
    case saved
    case saving
    case error(String)

    var displayText: String {
        switch self {
        case .saved: return "Saved"
        case .saving: return "Saving"
        case .error: return "Save failed"
        }
    }
}

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var folders: [NoteFolder] = []
    @Published var selectedNoteId: UUID? {
        didSet {
            if let id = selectedNoteId, id != oldValue { recordRecentNote(id) }
        }
    }

    /// Most-recently-opened note ids, newest first. Drives the command
    /// palette's empty-query ordering. Persisted so recents survive relaunch.
    private(set) var recentNoteIds: [UUID] = NotesViewModel.loadRecentNoteIds()

    private static let recentNoteIdsKey = "recentNoteIds"
    private static let recentNoteLimit = 15

    private static func loadRecentNoteIds() -> [UUID] {
        (UserDefaults.standard.stringArray(forKey: recentNoteIdsKey) ?? [])
            .compactMap(UUID.init(uuidString:))
    }

    private func recordRecentNote(_ id: UUID) {
        recentNoteIds.removeAll { $0 == id }
        recentNoteIds.insert(id, at: 0)
        if recentNoteIds.count > Self.recentNoteLimit {
            recentNoteIds.removeLast(recentNoteIds.count - Self.recentNoteLimit)
        }
        UserDefaults.standard.set(recentNoteIds.map(\.uuidString), forKey: Self.recentNoteIdsKey)
    }
    @Published var selectedFolderId: UUID?
    @Published var pendingSearchHighlight: String?
    @Published var searchText: String = ""
    @Published var showAllNotes: Bool = true
    @Published var saveState: NoteSaveState = .saved

    /// Filtered + sorted notes for the sidebar. Maintained by a Combine
    /// pipeline (see init) so it's computed once whenever an input changes
    /// instead of being a computed property re-run several times per render.
    @Published private(set) var filteredNotes: [Note] = []

    private let storage = StorageManager.shared
    private var autoSaveTimer: Timer?
    private var pendingSaves: [UUID: Note] = [:]
    private var rtfInSyncByID: [UUID: Bool] = [:]
    private var cancellables = Set<AnyCancellable>()

    /// Per-note folded search haystack (`title\ncontent`, run through
    /// `searchFolded`), keyed by note id. Lets the sidebar filter test a note
    /// without re-folding its full content on every keystroke — the fold is
    /// done once here and refreshed only when the note's title/content changes.
    /// `computeFilteredNotes` reads it; the create/update/delete/load paths keep
    /// it in lockstep with `notes`.
    private var searchIndex: [UUID: String] = [:]

    var selectedNote: Note? {
        get {
            guard let id = selectedNoteId else { return nil }
            return notes.first { $0.id == id }
        }
        set {
            if let note = newValue, let index = notes.firstIndex(where: { $0.id == note.id }) {
                searchIndex[note.id] = Self.searchHaystack(for: note)
                notes[index] = note
                applySaveResult(storage.saveNote(note))
            }
        }
    }

    /// The folded search haystack for a note: title and content joined (so one
    /// scan covers both fields) and run through `searchFolded` (so a
    /// straight-quote query matches smart-quote text). Folding maps scalars 1:1,
    /// so folding the join equals joining the folds — this matches exactly the
    /// queries the old per-field `title`/`content` `searchFolded` checks did.
    static func searchHaystack(title: String, content: String) -> String {
        (title + "\n" + content).searchFolded
    }

    static func searchHaystack(for note: Note) -> String {
        searchHaystack(title: note.title, content: note.content)
    }

    private static func buildSearchIndex(_ notes: [Note]) -> [UUID: String] {
        notes.reduce(into: [UUID: String](minimumCapacity: notes.count)) {
            $0[$1.id] = searchHaystack(for: $1)
        }
    }

    /// Pure filter+sort used by the Combine pipeline. `searchIndex` supplies the
    /// precomputed folded haystack per note id; when an entry is missing (direct
    /// callers, e.g. tests) it falls back to folding the note inline, so the
    /// result is identical either way — only cheaper when the cache is warm.
    static func computeFilteredNotes(
        notes: [Note],
        showAllNotes: Bool,
        selectedFolderId: UUID?,
        searchText: String,
        searchIndex: [UUID: String] = [:]
    ) -> [Note] {
        var result = notes

        if !showAllNotes, let folderId = selectedFolderId {
            result = result.filter { $0.folderId == folderId }
        }

        if !searchText.isEmpty {
            // Folded so a straight-quote query matches smart-quote note text.
            let query = searchText.searchFolded
            result = result.filter { note in
                let haystack = searchIndex[note.id] ?? searchHaystack(for: note)
                return haystack.range(of: query, options: .caseInsensitive) != nil
            }
        }

        let pinned = result.filter { $0.isPinned }.sorted { $0.createdAt > $1.createdAt }
        let unpinned = result.filter { !$0.isPinned }.sorted { $0.createdAt > $1.createdAt }
        return pinned + unpinned
    }

    var allNotesCount: Int { notes.count }

    func notesCount(for folderId: UUID) -> Int {
        notes.filter { $0.folderId == folderId }.count
    }

    init() {
        // Recompute filteredNotes whenever any input changes.
        Publishers.CombineLatest4($notes, $showAllNotes, $selectedFolderId, $searchText)
            .map { [weak self] notes, showAll, folderId, search in
                Self.computeFilteredNotes(
                    notes: notes,
                    showAllNotes: showAll,
                    selectedFolderId: folderId,
                    searchText: search,
                    searchIndex: self?.searchIndex ?? [:]
                )
            }
            .assign(to: &$filteredNotes)

        // Safety net: flush any debounced edits synchronously before the
        // app quits or loses focus (onDisappear isn't guaranteed to fire).
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                self?.flushPendingSavesSynchronously()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)
            .sink { [weak self] _ in
                self?.flushPendingSavesSynchronously()
            }
            .store(in: &cancellables)

        Task { await loadAsync() }
    }

    deinit {
        // Flush any unsaved changes synchronously to protect user data on window close
        for note in pendingSaves.values {
            StorageManager.shared.saveNote(note)
        }
        StorageManager.shared.waitForPendingWrites()
    }

    private func loadAsync() async {
        // Read from disk on a background thread, but do NOT touch
        // StorageManager.urlsByID there — that map is also written by
        // saveNote/deleteNote on the main thread, and a concurrent write
        // can corrupt the dictionary (manifesting as lost row clicks).
        let (snapshot, loadedFolders) = await Task.detached(priority: .userInitiated) {
            (StorageManager.shared.readNotesSnapshot(), StorageManager.shared.loadFolders())
        }.value
        storage.apply(snapshot)
        searchIndex = Self.buildSearchIndex(snapshot.notes)
        notes = snapshot.notes
        folders = loadedFolders
        storage.makeLaunchBackup()
        let loadedNotes = snapshot.notes
        Task.detached(priority: .utility) {
            StorageManager.shared.pruneOrphanAssets(referencedBy: loadedNotes)
        }
        if notes.isEmpty {
            createWelcomeNote()
        } else if selectedNoteId == nil || !notes.contains(where: { $0.id == selectedNoteId }) {
            selectedNoteId = filteredNotes.first?.id
        }
    }


    func load() {
        let loaded = storage.loadNotes()
        searchIndex = Self.buildSearchIndex(loaded)
        notes = loaded
        folders = storage.loadFolders()
        if notes.isEmpty {
            createWelcomeNote()
        } else {
            if selectedNoteId == nil || !notes.contains(where: { $0.id == selectedNoteId }) {
                selectedNoteId = filteredNotes.first?.id
            }
        }
    }

    private func createWelcomeNote() {
        let welcomeContent = """
        Welcome to VimText!

        This editor has broad Vim keybinding support for common writing and editing flows.
        You are currently in INSERT mode — start typing!

        Quick Reference:
          Esc       → Normal mode
          i         → Insert mode (before cursor)
          a         → Insert mode (after cursor)
          o         → New line below & insert
          h j k l   → Move left/down/up/right
          w b       → Word forward/backward
          dd        → Delete line
          yy        → Yank (copy) line
          p         → Paste
          u         → Undo
          :w        → Save
          ⌘S        → Save
          ⌘N        → New note

        Happy writing!
        """
        let note = Note(
            title: "Welcome to VimText",
            content: welcomeContent
        )
        searchIndex[note.id] = Self.searchHaystack(for: note)
        notes.insert(note, at: 0)
        applySaveResult(storage.saveNote(note))
        selectedNoteId = note.id
    }

    func createNote() {
        let note = Note(
            title: "",
            content: "",
            folderId: showAllNotes ? nil : selectedFolderId
        )
        searchIndex[note.id] = Self.searchHaystack(for: note)
        notes.insert(note, at: 0)
        applySaveResult(storage.saveNote(note))
        selectedNoteId = note.id
    }

    /// Creates a copy of `note` (new id/timestamps, unpinned) directly above it
    /// and selects it. Returns the new note's id.
    @discardableResult
    func duplicateNote(_ note: Note) -> UUID? {
        guard notes.contains(where: { $0.id == note.id }) else { return nil }
        let copy = Note(
            title: note.title,
            content: note.content,
            rtfData: note.rtfData,
            folderId: note.folderId
        )
        let insertIndex = notes.firstIndex(where: { $0.id == note.id }).map { $0 + 1 } ?? 0
        searchIndex[copy.id] = Self.searchHaystack(for: copy)
        notes.insert(copy, at: insertIndex)
        applySaveResult(storage.saveNote(copy))
        selectedNoteId = copy.id
        return copy.id
    }

    func deleteNote(_ note: Note) {
        // Locked notes can't be deleted — every UI path hides/blocks this,
        // but guard here too so no future caller can bypass the lock.
        guard !note.isLocked else { return }
        pendingSaves.removeValue(forKey: note.id)
        storage.deleteNote(note, remainingNotes: notes.filter { $0.id != note.id })
        notes.removeAll { $0.id == note.id }
        searchIndex[note.id] = nil
        if selectedNoteId == note.id {
            selectedNoteId = filteredNotes.first?.id
        }
    }

    func deleteNotes(at offsets: IndexSet) {
        let notesToDelete = offsets.map { filteredNotes[$0] }
        for note in notesToDelete {
            deleteNote(note)
        }
    }

    func deleteAllNotes() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        let locked = notes.filter { $0.isLocked }
        pendingSaves = pendingSaves.filter { id, _ in locked.contains { $0.id == id } }
        for note in notes where !note.isLocked {
            storage.deleteNote(note, remainingNotes: locked)
        }
        searchIndex = Self.buildSearchIndex(locked)
        notes = locked
        selectedNoteId = filteredNotes.first?.id
    }

    func selectAllNoteIds() -> Set<UUID> {
        Set(filteredNotes.map { $0.id })
    }

    func deleteNotes(ids: Set<UUID>) {
        // Locked notes survive bulk deletion.
        let ids = Set(notes.filter { ids.contains($0.id) && !$0.isLocked }.map(\.id))
        for id in ids {
            pendingSaves.removeValue(forKey: id)
        }
        let toDelete = notes.filter { ids.contains($0.id) }
        let remaining = notes.filter { !ids.contains($0.id) }
        for note in toDelete {
            storage.deleteNote(note, remainingNotes: remaining)
            notes.removeAll { $0.id == note.id }
            searchIndex[note.id] = nil
        }
        if let sel = selectedNoteId, ids.contains(sel) {
            selectedNoteId = filteredNotes.first?.id
        }
    }

    func toggleLock(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        // Flush any in-flight edit first so locking can't race a pending save.
        flushPendingSavesSynchronously()
        notes[index].isLocked.toggle()
        applySaveResult(storage.saveNote(notes[index]))
    }

    func togglePin(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        pendingSaves.removeValue(forKey: note.id)
        notes[index].isPinned.toggle()
        notes[index].modifiedAt = Date()
        applySaveResult(storage.saveNote(notes[index]))
    }

    func updateNoteContent(id: UUID, title: String, content: String, rtfData: Data? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        // Backstop: the editor is read-only for locked notes, but never let a
        // stray callback overwrite locked content either.
        guard !notes[index].isLocked else { return }
        let contentChanged = notes[index].content != content
        let titleChanged = notes[index].title != title
        let rtfChanged = notes[index].rtfData != rtfData
        guard contentChanged || titleChanged || rtfChanged else { return }
        if rtfChanged {
            rtfInSyncByID[id] = true
        } else if contentChanged {
            rtfInSyncByID[id] = false
        }
        // Refresh the cached search haystack before mutating `notes` — the
        // mutation re-fires the filter pipeline, which must see the new text.
        if titleChanged || contentChanged {
            searchIndex[id] = Self.searchHaystack(title: title, content: content)
        }
        notes[index].title = title
        notes[index].content = content
        notes[index].rtfData = rtfData
        notes[index].modifiedAt = Date()
        saveState = .saving
        // Debounce the disk write. The in-memory note (and the whole UI) is
        // already up to date; only the expensive encode+write is deferred so
        // that holding a key down doesn't write the full note to disk on
        // every character.
        scheduleSave(note: notes[index])
    }

    /// Marks a note as needing a save and (re)arms the debounce timer.
    private func scheduleSave(note: Note) {
        pendingSaves[note.id] = note
        autoSaveTimer?.invalidate()
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.flushPendingSaves() }
        }
    }

    /// Writes every note with pending edits to disk immediately on a background thread.
    func flushPendingSaves() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        guard !pendingSaves.isEmpty else { return }

        let notesToSave = Array(pendingSaves.values)
        let flags = notesToSave.reduce(into: [UUID: Bool]()) { $0[$1.id] = rtfInSyncByID[$1.id] ?? true }
        pendingSaves.removeAll()

        saveState = .saving
        let batch = notesToSave.map { (note: $0, rtfInSync: flags[$0.id] ?? true) }
        storage.saveNotesAsync(batch) { [weak self] results in
            guard let self else { return }
            var firstError: StorageError?
            for note in notesToSave {
                if case .failure(let error) = results[note.id] {
                    firstError = firstError ?? error
                    if self.pendingSaves[note.id] == nil {
                        self.pendingSaves[note.id] = note
                    }
                }
            }

            if let firstError {
                self.saveState = .error(firstError.localizedDescription)
            } else if self.pendingSaves.isEmpty {
                self.saveState = .saved
            }
        }
    }

    /// Writes every note with pending edits to disk synchronously. Used on
    /// critical events like folder switching, deinit, and app exit to ensure
    /// the process does not terminate before I/O completes.
    func flushPendingSavesSynchronously() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        guard !pendingSaves.isEmpty else {
            storage.waitForPendingWrites()
            if saveState == .saving {
                saveState = .saved
            }
            return
        }

        saveState = .saving
        let notesToSave = Array(pendingSaves.values)
        pendingSaves.removeAll()
        var firstError: StorageError?

        for note in notesToSave {
            let result = storage.saveNote(note, rtfInSync: rtfInSyncByID[note.id] ?? true)
            if case .failure(let error) = result {
                firstError = firstError ?? error
                pendingSaves[note.id] = note
            }
        }

        if let firstError {
            saveState = .error(firstError.localizedDescription)
        } else {
            storage.waitForPendingWrites()
            saveState = .saved
        }
    }

    /// Flushes any pending changes to the old folder before switching directory paths.
    func changeDirectoryPath(to path: String?) {
        flushPendingSavesSynchronously()
        storage.customDirectoryPath = path
        load()
    }

    func moveNote(_ note: Note, to folderId: UUID?) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        pendingSaves.removeValue(forKey: note.id)
        notes[index].folderId = folderId
        notes[index].modifiedAt = Date()
        applySaveResult(storage.saveNote(notes[index]))
    }

    func createFolder(name: String) {
        let folder = NoteFolder(name: name)
        folders.append(folder)
        storage.saveFolders(folders)
    }

    func renameFolder(_ folder: NoteFolder, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index].name = name
        storage.saveFolders(folders)
    }

    func deleteFolder(_ folder: NoteFolder) {
        for i in notes.indices where notes[i].folderId == folder.id {
            notes[i].folderId = nil
            applySaveResult(storage.saveNote(notes[i]))
        }
        folders.removeAll { $0.id == folder.id }
        storage.saveFolders(folders)
        if selectedFolderId == folder.id {
            showAllNotes = true
            selectedFolderId = nil
        }
    }

    private func applySaveResult(_ result: Result<Void, StorageError>) {
        switch result {
        case .success:
            saveState = .saved
        case .failure(let error):
            saveState = .error(error.localizedDescription)
        }
    }
}
