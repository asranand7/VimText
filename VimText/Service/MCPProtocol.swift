import Foundation
import MCPContract

/// The MCP (Model Context Protocol) surface: JSON-RPC 2.0 request handling and
/// the dispatch from tool calls onto `NotesService`.
///
/// Hand-rolled rather than taken from a package because the surface an MCP
/// *server* needs is small — `initialize`, `tools/list`, `tools/call` — and the
/// app ships with no external dependencies (see ARCHITECTURE.md). What the
/// server *says* it is (handshake, tool schemas) lives in `MCPContract`, which
/// the `vimtext-mcp` relay compiles in too; this file is the half that needs
/// the running note store.
///
/// Transport-agnostic on purpose: this takes one JSON-RPC message and returns
/// one reply (or nil for notifications, which per spec get no response). The
/// socket server owns framing; adding an HTTP transport later means writing a
/// new caller, not touching this file.
@MainActor
public enum MCPProtocol {
    public static var serverName: String { MCPContract.serverName }
    public static var serverVersion: String { MCPContract.serverVersion }

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
            return encode(successResponse(id: id, result: MCPContract.initializeResult(
                requestedVersion: params["protocolVersion"] as? String
            )))
        case "server/discover":
            return encode(successResponse(id: id, result: MCPContract.discoverResult()))
        case "tools/list":
            return encode(successResponse(id: id, result: ["tools": MCPContract.toolDefinitions]))
        case "tools/call":
            return encode(successResponse(id: id, result: callTool(params: params)))
        case "ping":
            return encode(successResponse(id: id, result: [:]))
        default:
            return encode(errorResponse(id: id, code: -32601, message: "Method not found: \(method)"))
        }
    }

    // MARK: - Dispatch

    private static func callTool(params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return toolError("tools/call requires a tool name.")
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]

        do {
            // One request, one read of the store: see `withRequestScope`.
            return try NotesService.shared.withRequestScope {
                try invoke(name, arguments: arguments, service: NotesService.shared)
            }
        } catch {
            // Tool failures come back as a result with isError, not a JSON-RPC
            // error: the model is meant to see them and adjust (wrong id, locked
            // note, missing folder) rather than have the call fail outright.
            return toolError(error.localizedDescription)
        }
    }

    private static func invoke(_ name: String, arguments: [String: Any], service: NotesService) throws -> [String: Any] {
        switch name {
        case "search_notes":
            return toolResult(try service.search(
                query: string(arguments, "query") ?? "",
                limit: integer(arguments, "limit", default: 20),
                folder: string(arguments, "folder")
            ))
        case "list_notes":
            return toolResult(try service.list(
                folder: string(arguments, "folder"),
                limit: integer(arguments, "limit", default: 50),
                offset: integer(arguments, "offset", default: 0)
            ))
        case "read_note":
            return toolResult(try service.read(
                id: string(arguments, "id"),
                title: string(arguments, "title")
            ))
        case "create_note":
            guard let content = string(arguments, "content") else {
                throw NotesService.ServiceError.invalidArgument("create_note requires content.")
            }
            return toolResult(try service.create(
                content: content,
                title: string(arguments, "title"),
                folder: string(arguments, "folder")
            ))
        case "update_note":
            guard let id = string(arguments, "id"), let content = string(arguments, "content") else {
                throw NotesService.ServiceError.invalidArgument("update_note requires id and content.")
            }
            let rawMode = string(arguments, "mode") ?? "append"
            guard let mode = NotesService.UpdateMode(rawValue: rawMode.lowercased()) else {
                throw NotesService.ServiceError.invalidArgument("Unknown mode \"\(rawMode)\". Use replace, append or prepend.")
            }
            return toolResult(try service.update(
                id: id,
                content: content,
                mode: mode,
                title: string(arguments, "title")
            ))
        case "delete_note":
            guard let id = string(arguments, "id") else {
                throw NotesService.ServiceError.invalidArgument("delete_note requires id.")
            }
            return toolResult(try service.delete(id: id))
        case "move_note":
            guard let id = string(arguments, "id") else {
                throw NotesService.ServiceError.invalidArgument("move_note requires id.")
            }
            return toolResult(try service.move(id: id, folder: string(arguments, "folder")))
        case "lock_note":
            guard let id = string(arguments, "id") else {
                throw NotesService.ServiceError.invalidArgument("lock_note requires id.")
            }
            return toolResult(try service.lock(id: id))
        case "list_folders":
            return toolResult(service.folders())
        default:
            throw NotesService.ServiceError.invalidArgument(
                "Unknown tool \"\(name)\". This server offers: \(MCPContract.toolNames.joined(separator: ", "))."
            )
        }
    }

    // MARK: - Argument reading

    /// Arguments arrive as whatever the model produced, so a value of the wrong
    /// JSON type is a routine event rather than a client bug. A number written
    /// as a string still means that number; anything else falls back to the
    /// schema default rather than failing the call.
    private static func integer(_ arguments: [String: Any], _ key: String, default fallback: Int) -> Int {
        switch arguments[key] {
        case let value as Int: return value
        case let value as NSNumber: return value.intValue
        case let value as String: return Int(value.trimmingCharacters(in: .whitespaces)) ?? fallback
        default: return fallback
        }
    }

    /// Treats an explicit null or an all-whitespace string as "not supplied",
    /// so `{"folder": null}` and `{"folder": "  "}` both mean "no folder"
    /// instead of a lookup for a folder named "  ".
    private static func string(_ arguments: [String: Any], _ key: String) -> String? {
        guard let value = arguments[key] as? String else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
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
