import Foundation
import SwiftUI
import Combine

@MainActor
final class NotesViewModel: ObservableObject {
    @Published var notes: [Note] = []
    @Published var folders: [NoteFolder] = []
    @Published var selectedNoteId: UUID?
    @Published var selectedFolderId: UUID?
    @Published var searchText: String = ""
    @Published var showAllNotes: Bool = true

    private let storage = StorageManager.shared
    private var autoSaveTimer: Timer?
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

    var filteredNotes: [Note] {
        var result = notes

        if !showAllNotes, let folderId = selectedFolderId {
            result = result.filter { $0.folderId == folderId }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.title.lowercased().contains(query) ||
                $0.content.lowercased().contains(query)
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
        Task { await loadAsync() }
    }

    private func loadAsync() async {
        let (loadedNotes, loadedFolders) = await Task.detached(priority: .userInitiated) {
            (StorageManager.shared.loadNotes(), StorageManager.shared.loadFolders())
        }.value
        notes = loadedNotes
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
        notes[index].title = title
        notes[index].content = content
        notes[index].rtfData = rtfData
        notes[index].modifiedAt = Date()
        storage.saveNote(notes[index])
    }

    func moveNote(_ note: Note, to folderId: UUID?) {
        guard let index = notes.firstIndex(where: { $0.id == note.id }) else { return }
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
