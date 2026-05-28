import Foundation

final class StorageManager {
    static let shared = StorageManager()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Maps each note's stable id to the file it currently lives in, so a title
    /// change (which changes the filename) can rename rather than orphan the file.
    private var urlsByID: [UUID: URL] = [:]

    private static let customPathKey = "customNotesDirectoryPath"

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM-yyyy-HH-mm-ss"
        return formatter
    }()

    var customDirectoryPath: String? {
        get { UserDefaults.standard.string(forKey: Self.customPathKey) }
        set {
            if let path = newValue {
                UserDefaults.standard.set(path, forKey: Self.customPathKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.customPathKey)
            }
            ensureDirectoriesExist()
        }
    }

    private var baseURL: URL {
        if let customPath = customDirectoryPath {
            return URL(fileURLWithPath: customPath)
        }
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

    // MARK: - File naming

    /// Turn a note title into a filesystem-safe slug: letters/numbers kept,
    /// everything else collapsed to single dashes, capped in length.
    private func slug(_ title: String) -> String {
        var out = ""
        var pendingDash = false
        for ch in title.trimmingCharacters(in: .whitespacesAndNewlines) {
            if ch.isLetter || ch.isNumber {
                if pendingDash && !out.isEmpty { out.append("-") }
                out.append(ch)
                pendingDash = false
            } else {
                pendingDash = true
            }
        }
        if out.count > 40 {
            out = String(out.prefix(40))
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "untitled" : out
    }

    private func desiredBaseName(for note: Note) -> String {
        "\(slug(note.title))-\(Self.stampFormatter.string(from: note.createdAt))"
    }

    /// A `.json` URL for `base`, suffixed with `-2`, `-3`… if another note already
    /// owns that name (titles created in the same second can otherwise collide).
    private func uniqueURL(base: String, for id: UUID) -> URL {
        let ownURL = urlsByID[id]
        var candidate = notesURL.appendingPathComponent("\(base).json")
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) && candidate != ownURL {
            candidate = notesURL.appendingPathComponent("\(base)-\(n).json")
            n += 1
        }
        return candidate
    }

    // MARK: - Notes

    func loadNotes() -> [Note] {
        urlsByID.removeAll()
        guard let files = try? fileManager.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: nil) else {
            return []
        }

        var result: [Note] = []
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let note = try? decoder.decode(Note.self, from: data) else { continue }
            urlsByID[note.id] = url
            result.append(note)
        }
        return result
    }

    func fileURL(for note: Note) -> URL {
        urlsByID[note.id] ?? uniqueURL(base: desiredBaseName(for: note), for: note.id)
    }

    func saveNote(_ note: Note) {
        guard let data = try? encoder.encode(note) else { return }
        let target = uniqueURL(base: desiredBaseName(for: note), for: note.id)
        let existing = urlsByID[note.id]
        do {
            try data.write(to: target, options: .atomic)
        } catch {
            return
        }
        if let existing = existing, existing != target {
            try? fileManager.removeItem(at: existing)
        }
        urlsByID[note.id] = target
    }

    func deleteNote(_ note: Note) {
        let url = urlsByID[note.id] ?? notesURL.appendingPathComponent("\(desiredBaseName(for: note)).json")
        try? fileManager.removeItem(at: url)
        urlsByID[note.id] = nil
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
