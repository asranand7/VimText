import Foundation

public enum StorageError: LocalizedError, Equatable {
    case cannotCreateDirectory(String)
    case cannotWriteFile(String, String)
    case cannotEncodeMetadata(String)

    public var errorDescription: String? {
        switch self {
        case .cannotCreateDirectory(let path):
            return "Could not create notes directory at \(path)."
        case .cannotWriteFile(let path, let reason):
            return "Could not write \(path): \(reason)"
        case .cannotEncodeMetadata(let title):
            return "Could not encode metadata for \(title)."
        }
    }
}

public final class StorageManager {
    public static let shared = StorageManager()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let ioQueue = DispatchQueue(label: "com.vimtext.storage.io", qos: .utility)

    /// Maps each note's stable id to the file it currently lives in, so a title
    /// change (which changes the filename) can rename rather than orphan the file.
    private var urlsByID: [UUID: URL] = [:]
    private let lock = NSRecursiveLock()

    private static let customPathKey = "customNotesDirectoryPath"

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd-MM-yyyy-HH-mm-ss"
        return formatter
    }()

    public var customDirectoryPath: String? {
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

    /// Folder holding embedded note images, alongside the notes so the
    /// `assets/<file>` references in note content resolve relative to them and
    /// stay valid across note renames.
    private var assetsURL: URL {
        notesURL.appendingPathComponent("assets", isDirectory: true)
    }

    private var appSupportRoot: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("VimText", isDirectory: true)
    }

    private var recoveredURL: URL { appSupportRoot.appendingPathComponent("recovered", isDirectory: true) }
    private var backupsURL: URL { appSupportRoot.appendingPathComponent("backups", isDirectory: true) }

    private static let backupStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
        return formatter
    }()

    private init() {
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601
        ensureDirectoriesExist()
    }

    private func ensureDirectoriesExist() {
        try? fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)
    }

    /// Copies the on-disk version of a note (json + sidecars) into the
    /// recovered/ folder before it is overwritten. Used as a last-resort
    /// safety net so content can never be silently destroyed.
    private func stashForRecovery(_ jsonURL: URL) {
        let (etxt, _) = sidecars(for: jsonURL)
        var existingContent = ""
        if fileManager.fileExists(atPath: etxt.path) {
            existingContent = (try? String(contentsOf: etxt, encoding: .utf8)) ?? ""
        } else if let data = try? Data(contentsOf: jsonURL), let note = try? decoder.decode(Note.self, from: data) {
            existingContent = note.content
        }
        guard !existingContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        try? fileManager.createDirectory(at: recoveredURL, withIntermediateDirectories: true)
        let ts = Self.backupStampFormatter.string(from: Date())
        let (txt, rtf) = sidecars(for: jsonURL)
        for src in [jsonURL, txt, rtf] where fileManager.fileExists(atPath: src.path) {
            let dest = recoveredURL.appendingPathComponent("\(ts)-\(src.lastPathComponent)")
            try? fileManager.copyItem(at: src, to: dest)
        }
        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        if let items = try? fileManager.contentsOfDirectory(at: recoveredURL, includingPropertiesForKeys: [.creationDateKey]) {
            for item in items {
                if let created = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate, created < cutoff {
                    try? fileManager.removeItem(at: item)
                }
            }
        }
    }

    /// Snapshots the entire notes folder on launch (throttled to once per hour),
    /// keeping the most recent backups so any corruption is fully recoverable.
    func makeLaunchBackup() {
        DispatchQueue.global(qos: .utility).async { [self] in
            let src = notesURL
            guard fileManager.fileExists(atPath: src.path) else { return }
            try? fileManager.createDirectory(at: backupsURL, withIntermediateDirectories: true)
            if let items = try? fileManager.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: [.creationDateKey]) {
                let mostRecent = items.compactMap { try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate }.max()
                if let mostRecent, Date().timeIntervalSince(mostRecent) < 3600 { return }
            }
            let ts = Self.backupStampFormatter.string(from: Date())
            let dest = backupsURL.appendingPathComponent(ts, isDirectory: true)
            try? fileManager.copyItem(at: src, to: dest)
            if let dirs = try? fileManager.contentsOfDirectory(at: backupsURL, includingPropertiesForKeys: nil) {
                let sorted = dirs.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent > $1.lastPathComponent }
                for old in sorted.dropFirst(10) { try? fileManager.removeItem(at: old) }
            }
        }
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

    private func sidecars(for jsonURL: URL) -> (txt: URL, rtf: URL) {
        let base = jsonURL.deletingPathExtension()
        return (base.appendingPathExtension("txt"), base.appendingPathExtension("rtf"))
    }

    private struct NoteMetadata: Codable {
        let id: UUID
        var title: String
        var folderId: UUID?
        var createdAt: Date
        var modifiedAt: Date
        var isPinned: Bool
        // Optional so metadata written before the field existed still decodes
        // (a required Bool would make every old note fail to load).
        var isLocked: Bool?
        var rtfInSync: Bool
    }

    /// A `.json` URL for `base`, suffixed with `-2`, `-3`… if another note already
    /// owns that name (titles created in the same second can otherwise collide).
    private func uniqueURL(base: String, for id: UUID) -> URL {
        lock.lock()
        defer { lock.unlock() }
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

    /// A point-in-time read of all notes plus their on-disk locations.
    /// Returned by `readNotesSnapshot()` so the caller can apply the result
    /// on the main thread instead of having a background load mutate
    /// `urlsByID` concurrently with main-thread save/delete calls.
    struct NotesSnapshot {
        let notes: [Note]
        let urlsByID: [UUID: URL]
    }

    /// Reads notes from disk **without** mutating `urlsByID`. Safe to call
    /// off the main thread; pair with `apply(_:)` on the main thread.
    func readNotesSnapshot() -> NotesSnapshot {
        guard let files = try? fileManager.contentsOfDirectory(at: notesURL, includingPropertiesForKeys: nil) else {
            return NotesSnapshot(notes: [], urlsByID: [:])
        }

        var notes: [Note] = []
        var urlMap: [UUID: URL] = [:]
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url) else { continue }
            let (txtURL, rtfURL) = sidecars(for: url)
            if fileManager.fileExists(atPath: txtURL.path) {
                guard let meta = try? decoder.decode(NoteMetadata.self, from: data),
                      let content = try? String(contentsOf: txtURL, encoding: .utf8) else { continue }
                var rtf: Data? = nil
                if meta.rtfInSync, fileManager.fileExists(atPath: rtfURL.path) {
                    rtf = try? Data(contentsOf: rtfURL)
                }
                let note = Note(
                    id: meta.id,
                    title: meta.title,
                    content: content,
                    rtfData: rtf,
                    folderId: meta.folderId,
                    createdAt: meta.createdAt,
                    modifiedAt: meta.modifiedAt,
                    isPinned: meta.isPinned,
                    isLocked: meta.isLocked ?? false
                )
                urlMap[note.id] = url
                notes.append(note)
            } else if let note = try? decoder.decode(Note.self, from: data) {
                urlMap[note.id] = url
                notes.append(note)
            }
        }
        return NotesSnapshot(notes: notes, urlsByID: urlMap)
    }

    /// Applies a previously-read snapshot's url map. Must be called from the
    /// main thread (same isolation as all other `urlsByID` mutators).
    func apply(_ snapshot: NotesSnapshot) {
        lock.lock()
        defer { lock.unlock() }
        urlsByID = snapshot.urlsByID
    }

    public func loadNotes() -> [Note] {
        let snapshot = readNotesSnapshot()
        lock.lock()
        defer { lock.unlock() }
        urlsByID = snapshot.urlsByID
        return snapshot.notes
    }

    // MARK: - Image assets

    /// Resolves a relative `assets/<file>` reference to an absolute URL.
    public func assetURL(forRelativePath relativePath: String) -> URL {
        notesURL.appendingPathComponent(relativePath)
    }

    /// Writes image `data` into the assets folder under a fresh UUID name and
    /// returns the relative path (`assets/<uuid>.<ext>`) to embed in a note,
    /// or nil on failure.
    @discardableResult
    public func saveImageAsset(_ data: Data, fileExtension: String) -> String? {
        let ext = fileExtension.isEmpty ? "png" : fileExtension.lowercased()
        do {
            try fileManager.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let name = "\(UUID().uuidString).\(ext)"
        let url = assetsURL.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        return "assets/\(name)"
    }

    /// Removes any local image assets referenced by `content`, except those in
    /// `keeping`. Called when a note is deleted so its images don't linger.
    /// Duplicated notes share asset files (duplication copies the content's
    /// `assets/…` references verbatim), so the caller must pass the filenames
    /// still referenced by the surviving notes.
    private func removeAssets(referencedIn content: String, keeping: Set<String>) {
        for relativePath in ImageMarkdown.localAssetPaths(in: content) {
            guard !keeping.contains((relativePath as NSString).lastPathComponent) else { continue }
            try? fileManager.removeItem(at: assetURL(forRelativePath: relativePath))
        }
    }

    /// Deletes asset files no longer referenced by any note. Run at launch
    /// (when content is settled) rather than on every edit, so undoing an image
    /// deletion within a session never races a file removal.
    public func pruneOrphanAssets(referencedBy notes: [Note]) {
        guard fileManager.fileExists(atPath: assetsURL.path) else { return }
        let referenced = Set(
            notes.flatMap { ImageMarkdown.localAssetPaths(in: $0.content) }
                .map { ($0 as NSString).lastPathComponent }
        )
        guard let files = try? fileManager.contentsOfDirectory(at: assetsURL, includingPropertiesForKeys: nil) else { return }
        for file in files where !referenced.contains(file.lastPathComponent) {
            try? fileManager.removeItem(at: file)
        }
    }

    public func fileURL(for note: Note) -> URL {
        lock.lock()
        defer { lock.unlock() }
        return urlsByID[note.id] ?? uniqueURL(base: desiredBaseName(for: note), for: note.id)
    }

    @discardableResult
    public func saveNote(_ note: Note, rtfInSync: Bool = true) -> Result<Void, StorageError> {
        ioQueue.sync {
            performSaveNote(note, rtfInSync: rtfInSync)
        }
    }

    func saveNotesAsync(_ notes: [(note: Note, rtfInSync: Bool)], completion: @escaping ([UUID: Result<Void, StorageError>]) -> Void) {
        ioQueue.async { [self] in
            var results: [UUID: Result<Void, StorageError>] = [:]
            for item in notes {
                results[item.note.id] = performSaveNote(item.note, rtfInSync: item.rtfInSync)
            }
            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    func waitForPendingWrites() {
        ioQueue.sync {}
    }

    private func performSaveNote(_ note: Note, rtfInSync: Bool = true) -> Result<Void, StorageError> {
        do {
            try fileManager.createDirectory(at: notesURL, withIntermediateDirectories: true)
        } catch {
            return .failure(.cannotCreateDirectory(notesURL.path))
        }

        let target = uniqueURL(base: desiredBaseName(for: note), for: note.id)
        let (txtURL, rtfURL) = sidecars(for: target)
        lock.lock()
        let existing = urlsByID[note.id]
        lock.unlock()

        if note.content.isEmpty, let existing = existing {
            stashForRecovery(existing)
        }

        do {
            try Data(note.content.utf8).write(to: txtURL, options: .atomic)
        } catch {
            return .failure(.cannotWriteFile(txtURL.path, error.localizedDescription))
        }

        if let rtf = note.rtfData, !rtf.isEmpty {
            let existingSize = (try? fileManager.attributesOfItem(atPath: rtfURL.path))?[.size] as? NSNumber
            // A matching byte count does NOT guarantee identical content — e.g.
            // an image width changing 560→200 keeps the same length but is a
            // real change. Only then (rare) read the file to compare bytes.
            let needsWrite: Bool
            if existingSize?.intValue != rtf.count {
                needsWrite = true
            } else {
                needsWrite = (try? Data(contentsOf: rtfURL)) != rtf
            }
            if needsWrite {
                do {
                    try rtf.write(to: rtfURL, options: .atomic)
                } catch {
                    return .failure(.cannotWriteFile(rtfURL.path, error.localizedDescription))
                }
            }
        } else {
            try? fileManager.removeItem(at: rtfURL)
        }

        let meta = NoteMetadata(
            id: note.id,
            title: note.title,
            folderId: note.folderId,
            createdAt: note.createdAt,
            modifiedAt: note.modifiedAt,
            isPinned: note.isPinned,
            isLocked: note.isLocked,
            rtfInSync: rtfInSync && !(note.rtfData?.isEmpty ?? true)
        )
        guard let metaData = try? encoder.encode(meta) else {
            return .failure(.cannotEncodeMetadata(note.displayTitle))
        }
        do {
            try metaData.write(to: target, options: .atomic)
        } catch {
            return .failure(.cannotWriteFile(target.path, error.localizedDescription))
        }

        lock.lock()
        defer { lock.unlock() }
        if let existing = existing, existing != target {
            try? fileManager.removeItem(at: existing)
            let (oldTxt, oldRtf) = sidecars(for: existing)
            try? fileManager.removeItem(at: oldTxt)
            try? fileManager.removeItem(at: oldRtf)
        }
        urlsByID[note.id] = target
        return .success(())
    }

    /// Deletes a note's files. `remainingNotes` are the notes that survive the
    /// deletion; any asset they still reference is preserved (e.g. a duplicate
    /// of the deleted note shares its image files).
    func deleteNote(_ note: Note, remainingNotes: [Note]) {
        lock.lock()
        let url = urlsByID[note.id] ?? notesURL.appendingPathComponent("\(desiredBaseName(for: note)).json")
        urlsByID[note.id] = nil
        lock.unlock()
        let (txtURL, rtfURL) = sidecars(for: url)
        try? fileManager.removeItem(at: url)
        try? fileManager.removeItem(at: txtURL)
        try? fileManager.removeItem(at: rtfURL)
        let stillReferenced = Set(
            remainingNotes
                .flatMap { ImageMarkdown.localAssetPaths(in: $0.content) }
                .map { ($0 as NSString).lastPathComponent }
        )
        removeAssets(referencedIn: note.content, keeping: stillReferenced)
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
