import Foundation

struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var content: String
    var rtfData: Data?
    var folderId: UUID?
    var createdAt: Date
    var modifiedAt: Date
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String = "New Note",
        content: String = "",
        rtfData: Data? = nil,
        folderId: UUID? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.rtfData = rtfData
        self.folderId = folderId
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isPinned = isPinned
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Note" : trimmed
    }

    var preview: String {
        // Only the first 3 lines (capped to 120 chars) are ever shown, so
        // split just the head of the content. Splitting the whole string
        // allocates an array of every line — slow for very large notes that
        // are re-rendered on each list pass. `prefix(1000)` stops after 1000
        // chars (it does NOT walk the whole string the way `.count` would).
        let head = String(content.prefix(1000))
        let lines = head.components(separatedBy: .newlines)
        let previewLines = lines.prefix(3).joined(separator: " ")
        let trimmed = previewLines.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No additional text" : String(trimmed.prefix(120))
    }
}
