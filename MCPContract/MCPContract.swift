import Foundation

/// Everything the two halves of the MCP integration must agree on: the
/// handshake, the tool definitions, and where the socket lives.
///
/// There are two binaries. `VimText.app` serves tools out of the running note
/// store (`MCPProtocol` → `NotesService`); `vimtext-mcp` is the stdio relay a
/// client actually spawns, and it answers the parts of the protocol that don't
/// need the notes — handshake, tool list, ping — itself, so starting an agent
/// session never has to launch a notes app. That only works if both sides
/// describe the same server, and when each kept its own copy they drifted: the
/// relay's instructions (the ones clients actually saw) claimed locked notes
/// were hidden, which was never how the service behaved. One module compiled
/// into both makes that class of bug impossible.
///
/// Foundation-only and dependency-free on purpose: an MCP client spawns the
/// relay on every session, so start-up time is a feature.
public enum MCPContract {
    public static let serverName = "vimtext"
    public static let serverVersion = "1.0.0"

    /// Protocol revisions we know how to speak. The negotiated version is the
    /// client's own when we recognise it, otherwise our default — which is what
    /// the spec asks for and what keeps older clients working.
    public static let supportedProtocolVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"
    ]
    public static let defaultProtocolVersion = "2025-06-18"

    public static func negotiatedVersion(requested: String?) -> String {
        guard let requested, supportedProtocolVersions.contains(requested) else {
            return defaultProtocolVersion
        }
        return requested
    }

    /// Fixed location, deliberately independent of the notes directory (which
    /// the user can move) so the relay can find it with no configuration.
    public static var socketPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("VimText/mcp.sock").path
    }

    // MARK: - Handshake

    /// What the model is told about these tools before it uses them. The locked
    /// note wording matters: locked notes read and search like any other (the
    /// app's own editor and search show them), and only writes are refused, so
    /// an agent that assumes it can't read them would be needlessly unhelpful.
    public static let instructions = """
    VimText is the user's personal notes app. Use these tools to search, read and edit \
    their notes. Note ids come from search_notes or list_notes — never invent one. \
    Prefer update_note with mode "append" over "replace" when adding to an existing \
    note, since replace discards the previous body. Notes marked isLocked can be \
    read and searched like any other, but never modified, moved or deleted — say so \
    rather than trying, and tell the user to unlock it in VimText first. You can \
    lock a note with lock_note, but nothing here can unlock one, so only lock a \
    note the user has asked you to protect.
    """

    public static func initializeResult(requestedVersion: String?) -> [String: Any] {
        [
            "protocolVersion": negotiatedVersion(requested: requestedVersion),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": serverName, "version": serverVersion],
            "instructions": instructions
        ]
    }

    /// The 2026-07-28 stateless flow probes this instead of `initialize`.
    public static func discoverResult() -> [String: Any] {
        [
            "protocolVersions": supportedProtocolVersions.sorted(),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": serverName, "version": serverVersion]
        ]
    }

    // MARK: - Tools

    private static func stringSchema(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private static func integerSchema(_ description: String, default defaultValue: Int) -> [String: Any] {
        ["type": "integer", "description": description, "default": defaultValue]
    }

    private static func tool(_ name: String, _ description: String, properties: [String: Any], required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required
            ] as [String: Any]
        ]
    }

    private static var folderProperty: [String: Any] {
        stringSchema("Folder name (as shown in the VimText sidebar). Omit for all notes / no folder.")
    }

    /// Ordered deliberately: the spec asks servers to return a stable ordering
    /// so clients can cache the list and prompt caches stay warm.
    ///
    /// Computed rather than stored so the dictionaries stay out of global
    /// mutable state — it is built once per `tools/list`, which is once per
    /// agent session.
    public static var toolDefinitions: [[String: Any]] {
        [
            tool(
                "search_notes",
                "Search the user's VimText notes by title and body text. Returns matching notes newest-first with a short preview, but not their full content — follow up with read_note.",
                properties: [
                    "query": stringSchema("What to search for. Matches note titles fuzzily and note bodies literally."),
                    "limit": integerSchema("Maximum notes to return.", default: 20),
                    "folder": folderProperty
                ],
                required: ["query"]
            ),
            tool(
                "list_notes",
                "List the user's VimText notes, most recently modified first. Use this to browse; use search_notes when you have a search term.",
                properties: [
                    "folder": folderProperty,
                    "limit": integerSchema("Maximum notes to return.", default: 50),
                    "offset": integerSchema("How many notes to skip, for paging.", default: 0)
                ],
                required: []
            ),
            tool(
                "read_note",
                "Read one note's full content. Identify it by id (from search_notes or list_notes) or by its exact title.",
                properties: [
                    "id": stringSchema("The note's id, as returned by search_notes or list_notes."),
                    "title": stringSchema("The note's exact title. Only used when id is omitted.")
                ],
                required: []
            ),
            tool(
                "create_note",
                "Create a new note in VimText. Content is Markdown-flavoured plain text.",
                properties: [
                    "content": stringSchema("The note body."),
                    "title": stringSchema("Title for the note. Defaults to the first line of the content."),
                    "folder": folderProperty
                ],
                required: ["content"]
            ),
            tool(
                "update_note",
                "Change an existing note's content or title. Use mode \"append\" to add to the note and \"replace\" only when the user wants the whole body rewritten — replace discards the existing content. Any hand-applied rich formatting (bold, italic) is lost on update; Markdown and embedded images survive.",
                properties: [
                    "id": stringSchema("The note's id, as returned by search_notes or list_notes."),
                    "content": stringSchema("The text to write."),
                    "mode": [
                        "type": "string",
                        "enum": ["replace", "append", "prepend"],
                        "description": "How to combine the text with what's already there.",
                        "default": "append"
                    ] as [String: Any],
                    "title": stringSchema("New title. Omit to leave the title unchanged.")
                ],
                required: ["id", "content"]
            ),
            tool(
                "delete_note",
                "Permanently delete a note. This cannot be undone, so confirm with the user before calling it.",
                properties: ["id": stringSchema("The note's id, as returned by search_notes or list_notes.")],
                required: ["id"]
            ),
            tool(
                "move_note",
                "Move a note into a folder, or out of every folder.",
                properties: [
                    "id": stringSchema("The note's id, as returned by search_notes or list_notes."),
                    "folder": stringSchema("Destination folder name. Omit or pass null to move the note to All Notes.")
                ],
                required: ["id"]
            ),
            tool(
                "lock_note",
                "Lock a note so it can't be edited, moved or deleted — including by you. Use it when the user asks to protect or finalise a note. There is no unlocking from here: the user unlocks a note in VimText itself, with the lock button in the editor header, so don't offer to undo this or lock a note you might need to change again.",
                properties: ["id": stringSchema("The note's id, as returned by search_notes or list_notes.")],
                required: ["id"]
            ),
            tool(
                "list_folders",
                "List the user's note folders and how many notes each contains.",
                properties: [:],
                required: []
            )
        ]
    }

    /// Tool names in definition order — the cheap check that both binaries and
    /// the dispatch switch are talking about the same set.
    public static var toolNames: [String] {
        toolDefinitions.compactMap { $0["name"] as? String }
    }
}
