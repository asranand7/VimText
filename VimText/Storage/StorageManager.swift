import Foundation

final class StorageManager {
    static let shared = StorageManager()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var baseURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VimText", isDirectory: true)
    }

    private var notesURL: URL {
        baseURL.appendingPathComponent("notes", isDirectory: true)
    }

    private var foldersURL: URL {
        baseURL.appendingPathComponent("folders.json")
    }

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        ensureDirectoriesExist()
    }

    private func ensureDirectoriesExist() {
        try? fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)
    }

    func loadNotes() -> [Note] {
        guard let files = try? fileManager.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: nil) else {
            return []
        }

        return files.compactMap { url -> Note? in
            guard url.pathExtension == "json" else { return nil }
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(Note.self, from: data)
        }
    }

    func fileURL(for note: Note) -> URL {
        notesURL.appendingPathComponent("\(note.id.uuidString).json")
    }

    func saveNote(_ note: Note) {
        let url = notesURL.appendingPathComponent("\(note.id.uuidString).json")
        guard let data = try? encoder.encode(note) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func deleteNote(_ note: Note) {
        let url = notesURL.appendingPathComponent("\(note.id.uuidString).json")
        try? fileManager.removeItem(at: url)
    }

    func loadFolders() -> [NoteFolder] {
        guard let data = try? Data(contentsOf: foldersURL) else { return [] }
        return (try? decoder.decode([NoteFolder].self, from: data)) ?? []
    }

    func saveFolders(_ folders: [NoteFolder]) {
        guard let data = try? encoder.encode(folders) else { return }
        try? data.write(to: foldersURL, options: .atomic)
    }
}
