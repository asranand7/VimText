import Foundation
import SwiftUI
import Combine
import AppKit

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var folders: [NoteFolder] = []
    @Published var selectedNoteId: UUID?
    @Published var selectedFolderId: UUID?
    @Published var searchText: String = ""
    @Published var showAllNotes: Bool = true

    /// Filtered + sorted notes for the sidebar. Maintained by a Combine
    /// pipeline (see init) so it's computed once whenever an input changes
    /// instead of being a computed property re-run several times per render.
    @Published private(set) var filteredNotes: [Note] = []

    private let storage = StorageManager.shared
    private var autoSaveTimer: Timer?
    private var pendingSaves: [UUID: Note] = [:]
    private var rtfInSyncByID: [UUID: Bool] = [:]
    private var cancellables = Set<AnyCancellable>()

    var selectedNote: Note? {
        get {
            guard let id = selectedNoteId else { return nil }
            return notes.first { $0.id == id }
        }
        set {
            if let note = newValue, let index = notes.firstIndex(where: { $0.id == note.id }) {
                notes[index] = note
                storage.saveNote(note)
            }
        }
    }

    /// Pure filter+sort used by the Combine pipeline. Kept static so the
    /// pipeline closure captures nothing.
    static func computeFilteredNotes(
        notes: [Note],
        showAllNotes: Bool,
        selectedFolderId: UUID?,
        searchText: String
    ) -> [Note] {
        var result = notes

        if !showAllNotes, let folderId = selectedFolderId {
            result = result.filter { $0.folderId == folderId }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.title.range(of: searchText, options: .caseInsensitive) != nil ||
                $0.content.range(of: searchText, options: .caseInsensitive) != nil
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
            .map { notes, showAll, folderId, search in
                Self.computeFilteredNotes(
                    notes: notes,
                    showAllNotes: showAll,
                    selectedFolderId: folderId,
                    searchText: search
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
        notes = snapshot.notes
        folders = loadedFolders
        if notes.isEmpty {
            createWelcomeNote()
        } else if selectedNoteId == nil || !notes.contains(where: { $0.id == selectedNoteId }) {
            selectedNoteId = filteredNotes.first?.id
        }
    }


    func load() {
        notes = storage.loadNotes()
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

        This editor has full Vim keybinding support.
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
        notes.insert(note, at: 0)
        storage.saveNote(note)
        selectedNoteId = note.id
    }

    func createNote() {
        let note = Note(
            title: "",
            content: "",
            folderId: showAllNotes ? nil : selectedFolderId
        )
        notes.insert(note, at: 0)
        storage.saveNote(note)
        selectedNoteId = note.id
    }

    func deleteNote(_ note: Note) {
        pendingSaves.removeValue(forKey: note.id)
        storage.deleteNote(note)
        notes.removeAll { $0.id == note.id }
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
        pendingSaves.removeAll()
        for note in notes {
            storage.deleteNote(note)
        }
        notes.removeAll()
        selectedNoteId = nil
    }

    func selectAllNoteIds() -> Set<UUID> {
        Set(filteredNotes.map { $0.id })
    }

    func deleteNotes(ids: Set<UUID>) {
        for id in ids {
            pendingSaves.removeValue(forKey: id)
        }
        let toDelete = notes.filter { ids.contains($0.id) }
        for note in toDelete {
            storage.deleteNote(note)
            notes.removeAll { $0.id == note.id }
        }
        if let sel = selectedNoteId, ids.contains(sel) {
            selectedNoteId = filteredNotes.first?.id
        }
    }

    func togglePin(_ note: Note) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
        pendingSaves.removeValue(forKey: note.id)
        notes[index].isPinned.toggle()
        notes[index].modifiedAt = Date()
        storage.saveNote(notes[index])
    }

    func updateNoteContent(id: UUID, title: String, content: String, rtfData: Data? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let contentChanged = notes[index].content != content
        let titleChanged = notes[index].title != title
        let rtfChanged = notes[index].rtfData != rtfData
        guard contentChanged || titleChanged || rtfChanged else { return }
        if rtfChanged {
            rtfInSyncByID[id] = true
        } else if contentChanged {
            rtfInSyncByID[id] = false
        }
        notes[index].title = title
        notes[index].content = content
        notes[index].rtfData = rtfData
        notes[index].modifiedAt = Date()
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

        Task.detached(priority: .utility) {
            for note in notesToSave {
                StorageManager.shared.saveNote(note, rtfInSync: flags[note.id] ?? true)
            }
        }
    }

    /// Writes every note with pending edits to disk synchronously. Used on
    /// critical events like folder switching, deinit, and app exit to ensure
    /// the process does not terminate before I/O completes.
    func flushPendingSavesSynchronously() {
        autoSaveTimer?.invalidate()
        autoSaveTimer = nil
        guard !pendingSaves.isEmpty else { return }
        
        for note in pendingSaves.values {
            storage.saveNote(note, rtfInSync: rtfInSyncByID[note.id] ?? true)
        }
        pendingSaves.removeAll()
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
        storage.saveNote(notes[index])
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
            storage.saveNote(notes[i])
        }
        folders.removeAll { $0.id == folder.id }
        storage.saveFolders(folders)
        if selectedFolderId == folder.id {
            showAllNotes = true
            selectedFolderId = nil
        }
    }
}
