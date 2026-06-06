import Foundation

public struct Note: Identifiable, Codable, Hashable {
    public let id: UUID
    public var title: String
    public var content: String
    public var rtfData: Data?
    public var folderId: UUID?
    public var createdAt: Date
    public var modifiedAt: Date
    public var isPinned: Bool

    public init(
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

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Note" : trimmed
    }

    public var preview: String {
        // Only the first 3 lines after the title (capped to 120 chars) are
        // ever shown, so split just the head of the content. The first line
        // of `content` is also the source of `title`, so it's dropped here
        // to avoid showing the title twice in each sidebar row.
        let head = String(content.prefix(1000))
        let lines = head.components(separatedBy: .newlines).dropFirst()
        let previewLines = lines.prefix(3).joined(separator: " ")
        let trimmed = previewLines.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No additional text" : String(trimmed.prefix(120))
    }
}
