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
    /// Locked notes are read-only and protected from deletion until unlocked.
    public var isLocked: Bool

    public init(
        id: UUID = UUID(),
        title: String = "New Note",
        content: String = "",
        rtfData: Data? = nil,
        folderId: UUID? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        isPinned: Bool = false,
        isLocked: Bool = false
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.rtfData = rtfData
        self.folderId = folderId
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isPinned = isPinned
        self.isLocked = isLocked
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        content = try c.decode(String.self, forKey: .content)
        rtfData = try c.decodeIfPresent(Data.self, forKey: .rtfData)
        folderId = try c.decodeIfPresent(UUID.self, forKey: .folderId)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        // Added after isPinned — notes saved by older versions lack the key.
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
    }

    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "New Note" : trimmed
    }

    public var preview: String { Self.makePreview(content: content) }

    /// Pure derivation of a sidebar/palette preview from raw note content.
    /// Exposed as a static so the view model can cache the result per note id
    /// (keyed off content changes) instead of re-deriving it in the render hot
    /// path — the non-lazy sidebar list builds every row on each filter change.
    public static func makePreview(content: String) -> String {
        // Only the first 3 lines after the title (capped to 120 chars) are
        // ever shown, so split just the head of the content. The first line
        // of `content` is also the source of `title`, so it's dropped here
        // to avoid showing the title twice in each sidebar row.
        let head = String(content.prefix(1000))
        let lines = head.components(separatedBy: .newlines).dropFirst()
        // List markers ("1.", "-", "•") read as noise when lines are joined
        // into one preview string, so they're stripped per line.
        let previewLines = lines.prefix(3)
            .map { Self.strippingListMarker(from: $0) }
            .joined(separator: " ")
        // Drop embedded-image Markdown so previews read as prose, not raw refs.
        let withoutImages = ImageMarkdown.strippingImageRefs(from: previewLines)
        // Tabs and runs of spaces (smart-list indentation, aligned columns)
        // render as ragged gaps in a one-line preview, so collapse them.
        let collapsed = withoutImages
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No additional text" : String(trimmed.prefix(120))
    }

    /// Removes a leading list marker (`- `, `* `, `+ `, `• `, `1. `, `2) `…)
    /// from a single line, for sidebar previews.
    static func strippingListMarker<S: StringProtocol>(from line: S) -> String {
        var rest = line[...]
        let indent = rest.prefix(while: { $0 == " " || $0 == "\t" })
        rest = rest.dropFirst(indent.count)

        if let first = rest.first, "-*+•".contains(first),
           let gap = rest.dropFirst().first, gap == " " || gap == "\t" {
            return String(rest.dropFirst(2))
        }
        let digits = rest.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3 {
            let afterDigits = rest.dropFirst(digits.count)
            if let sep = afterDigits.first, sep == "." || sep == ")",
               let gap = afterDigits.dropFirst().first, gap == " " || gap == "\t" {
                return afterDigits.dropFirst(2).trimmingCharacters(in: .whitespaces)
            }
        }
        return String(line)
    }
}
