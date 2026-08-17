import Foundation

/// The MCP (Model Context Protocol) surface: JSON-RPC 2.0 request handling and
/// the tool definitions that map onto `NotesService`.
///
/// Hand-rolled rather than taken from a package because the surface an MCP
/// *server* needs is small — `initialize`, `tools/list`, `tools/call` — and the
/// app ships with no external dependencies (see ARCHITECTURE.md).
///
/// Transport-agnostic on purpose: this takes one JSON-RPC message and returns
/// one reply (or nil for notifications, which per spec get no response). The
/// socket server owns framing; adding an HTTP transport later means writing a
/// new caller, not touching this file.
@MainActor
public enum MCPProtocol {
    public static let serverName = "vimtext"
    public static let serverVersion = "1.0.0"

    /// Protocol revisions we know how to speak. The negotiated version is the
    /// client's own when we recognise it, otherwise our default — which is what
    /// the spec asks for and what keeps older clients working.
    static let supportedProtocolVersions: Set<String> = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"
    ]
    static let defaultProtocolVersion = "2025-06-18"

    // MARK: - Entry point

    /// Handles one JSON-RPC message. Returns the encoded reply, or nil when the
    /// message was a notification (no `id`) and therefore takes no response.
    public static func handle(_ data: Data) -> Data? {
        guard let parsed = try? JSONSerialization.jsonObject(with: data),
              let message = parsed as? [String: Any],
              let method = message["method"] as? String else {
            return encode(errorResponse(id: nil, code: -32700, message: "Parse error: expected a JSON-RPC object with a method."))
        }

        // Notifications carry no id and must not be answered.
        guard let id = message["id"] else {
            return nil
        }
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            return encode(successResponse(id: id, result: initializeResult(params: params)))
        case "server/discover":
            return encode(successResponse(id: id, result: discoverResult()))
        case "tools/list":
            return encode(successResponse(id: id, result: ["tools": toolDefinitions]))
        case "tools/call":
            return encode(successResponse(id: id, result: callTool(params: params)))
        case "ping":
            return encode(successResponse(id: id, result: [:]))
        default:
            return encode(errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: - Handshake

    static func negotiatedVersion(requested: String?) -> String {
        guard let requested, supportedProtocolVersions.contains(requested) else {
            return defaultProtocolVersion
        }
        return requested
    }

    private static func initializeResult(params: [String: Any]) -> [String: Any] {
        [
            "protocolVersion": negotiatedVersion(requested: params["protocolVersion"] as? String),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": serverName, "version": serverVersion],
            "instructions": """
            VimText is the user's personal notes app. Use these tools to search, read and edit \
            their notes. Note ids come from search_notes or list_notes — never invent one. \
            Prefer update_note with mode "append" over "replace" when adding to an existing \
            note, since replace discards the previous body. Notes marked isLocked can be \
            read and searched like any other, but never modified, moved or deleted — say so \
            rather than trying, and tell the user to unlock it in VimText first.
            """
        ]
    }

    /// The 2026-07-28 stateless flow probes this instead of `initialize`.
    private static func discoverResult() -> [String: Any] {
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

    private static let folderProperty = stringSchema("Folder name (as shown in the VimText sidebar). Omit for all notes / no folder.")

    /// Ordered deliberately: the spec asks servers to return a stable ordering
    /// so clients can cache the list and prompt caches stay warm.
    static let toolDefinitions: [[String: Any]] = [
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
            "list_folders",
            "List the user's note folders and how many notes each contains.",
            properties: [:],
            required: []
        )
    ]

    // MARK: - Dispatch

    private static func callTool(params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return toolError("tools/call requires a tool name.")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let service = NotesService.shared

        do {
            switch name {
            case "search_notes":
                return toolResult(try service.search(
                    query: arguments["query"] as? String ?? "",
                    limit: arguments["limit"] as? Int ?? 20,
                    folder: arguments["folder"] as? String
                ))
            case "list_notes":
                return toolResult(try service.list(
                    folder: arguments["folder"] as? String,
                    limit: arguments["limit"] as? Int ?? 50,
                    offset: arguments["offset"] as? Int ?? 0
                ))
            case "read_note":
                return toolResult(try service.read(
                    id: arguments["id"] as? String,
                    title: arguments["title"] as? String
                ))
            case "create_note":
                guard let content = arguments["content"] as? String else {
                    return toolError("create_note requires content.")
                }
                return toolResult(try service.create(
                    content: content,
                    title: arguments["title"] as? String,
                    folder: arguments["folder"] as? String
                ))
            case "update_note":
                guard let id = arguments["id"] as? String, let content = arguments["content"] as? String else {
                    return toolError("update_note requires id and content.")
                }
                let rawMode = arguments["mode"] as? String ?? "append"
                guard let mode = NotesService.UpdateMode(rawValue: rawMode) else {
                    return toolError("Unknown mode \"\(rawMode)\". Use replace, append or prepend.")
                }
                return toolResult(try service.update(
                    id: id,
                    content: content,
                    mode: mode,
                    title: arguments["title"] as? String
                ))
            case "delete_note":
                guard let id = arguments["id"] as? String else {
                    return toolError("delete_note requires id.")
                }
                return toolResult(try service.delete(id: id))
            case "move_note":
                guard let id = arguments["id"] as? String else {
                    return toolError("move_note requires id.")
                }
                return toolResult(try service.move(id: id, folder: arguments["folder"] as? String))
            case "list_folders":
                return toolResult(service.folders())
            default:
                return toolError("Unknown tool \"\(name)\".")
            }
        } catch {
            // Tool failures come back as a result with isError, not a JSON-RPC
            // error: the model is meant to see them and adjust (wrong id, locked
            // note, missing folder) rather than have the call fail outright.
            return toolError(error.localizedDescription)
        }
    }

    // MARK: - Result shaping

    private static func toolResult<T: Encodable>(_ value: T) -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let text = (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
            ?? "Could not encode the result."
        return ["content": [["type": "text", "text": text]], "isError": false]
    }

    private static func toolError(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    // MARK: - JSON-RPC envelopes

    private static func successResponse(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        [
            "jsonrpc": "2.0",
            "id": id ?? NSNull(),
            "error": ["code": code, "message": message]
        ]
    }

    /// Encodes one message for a newline-delimited transport, so the payload
    /// must stay on a single line — hence no `.prettyPrinted` here (the tool
    /// text inside it is pretty-printed, and its newlines are JSON-escaped).
    private static func encode(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
    }
}
