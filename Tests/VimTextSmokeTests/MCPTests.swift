import Foundation
import MCPContract
@testable import VimTextCore

// Coverage for the agent-facing surface: the JSON-RPC envelope, the tool
// dispatch, and `NotesService` itself. Everything here runs headless, so
// `NotesViewModel.current` is nil and the service takes its
// StorageManager-backed path — the same one used when the app is running with
// no window open.

// MARK: - Harness

@MainActor
private func mcpHandle(_ message: [String: Any]) throws -> [String: Any]? {
    let data = try JSONSerialization.data(withJSONObject: message)
    guard let reply = MCPProtocol.handle(data) else { return nil }
    guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
        throw SmokeTestFailure.failed("MCP reply was not a JSON object")
    }
    return object
}

@MainActor
private func mcpResult(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
    let reply = try mcpHandle(["jsonrpc": "2.0", "id": 1, "method": method, "params": params])
    guard let result = reply?["result"] as? [String: Any] else {
        throw SmokeTestFailure.failed("\(method) returned no result: \(String(describing: reply))")
    }
    return result
}

/// Calls a tool and returns its text payload plus the `isError` flag — a failed
/// tool call is a *result* in MCP, not a JSON-RPC error.
@MainActor
private func mcpTool(_ name: String, _ arguments: [String: Any] = [:]) throws -> (text: String, isError: Bool) {
    let result = try mcpResult("tools/call", ["name": name, "arguments": arguments])
    let text = (result["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
    return (text, result["isError"] as? Bool ?? false)
}

private func decodeSummaries(_ json: String) throws -> [NotesService.NoteSummary] {
    guard let data = json.data(using: .utf8),
          let summaries = try? JSONDecoder().decode([NotesService.NoteSummary].self, from: data) else {
        throw SmokeTestFailure.failed("expected a note list, got: \(json)")
    }
    return summaries
}

/// Runs `body` and returns the `ServiceError` it threw, failing if it didn't.
@MainActor
private func expectServiceError<T>(_ message: String, _ body: () throws -> T) throws -> NotesService.ServiceError {
    do {
        _ = try body()
    } catch let error as NotesService.ServiceError {
        return error
    } catch {
        throw SmokeTestFailure.failed("\(message): threw \(error) instead of a ServiceError")
    }
    throw SmokeTestFailure.failed("\(message): did not throw")
}

// MARK: - Protocol envelope

func testMCPHandshakeAndEnvelope() throws {
    try MainActor.assumeIsolated {
        // A version we speak is echoed back; one we don't falls back to ours.
        let known = try mcpResult("initialize", ["protocolVersion": "2024-11-05"])
        try expectEqual(known["protocolVersion"] as? String, "2024-11-05", "a supported protocol version should be echoed")
        let unknown = try mcpResult("initialize", ["protocolVersion": "1999-01-01"])
        try expectEqual(
            unknown["protocolVersion"] as? String,
            MCPContract.defaultProtocolVersion,
            "an unknown protocol version should fall back to the default"
        )

        // `vimtext-mcp` answers initialize itself, so the instructions a client
        // actually sees are the contract's. The app must not carry its own copy
        // — they drifted once, and the relay's said locked notes were hidden.
        try expectEqual(known["instructions"] as? String, MCPContract.instructions, "the app must serve the shared instructions")
        try expect(
            MCPContract.instructions.contains("read and searched like any other"),
            "instructions must say locked notes are readable — read_note returns their content"
        )

        // Notifications (no id) get no reply at all.
        let notification = try mcpHandle(["jsonrpc": "2.0", "method": "notifications/initialized"])
        try expect(notification == nil, "a notification must not be answered")

        let unknownMethod = try mcpHandle(["jsonrpc": "2.0", "id": 7, "method": "notes/teleport"])
        let methodError = unknownMethod?["error"] as? [String: Any]
        try expectEqual(methodError?["code"] as? Int, -32601, "an unknown method should be a method-not-found error")

        guard let garbage = MCPProtocol.handle(Data("not json".utf8)),
              let parsed = try JSONSerialization.jsonObject(with: garbage) as? [String: Any],
              let parseError = parsed["error"] as? [String: Any] else {
            throw SmokeTestFailure.failed("malformed input should produce a parse error")
        }
        try expectEqual(parseError["code"] as? Int, -32700, "malformed input should be a parse error")

        let ping = try mcpResult("ping")
        try expect(ping.isEmpty, "ping should return an empty result")
    }
}

func testMCPToolListMatchesDispatch() throws {
    try withTemporaryStorage { _, _ in
        try MainActor.assumeIsolated {
            let tools = try mcpResult("tools/list")["tools"] as? [[String: Any]] ?? []
            try expectEqual(tools.compactMap { $0["name"] as? String }, MCPContract.toolNames, "tools/list should serve the contract's tools in order")

            for tool in tools {
                let name = tool["name"] as? String ?? "?"
                let schema = tool["inputSchema"] as? [String: Any]
                let properties = schema?["properties"] as? [String: Any] ?? [:]
                let required = schema?["required"] as? [String] ?? []
                try expect(!(tool["description"] as? String ?? "").isEmpty, "\(name) needs a description")
                try expectEqual(schema?["type"] as? String, "object", "\(name)'s input schema should be an object")
                for key in required {
                    try expect(properties[key] != nil, "\(name) requires \"\(key)\" but doesn't define it")
                }
            }

            // Every advertised tool must be reachable: called with no arguments
            // a tool may complain about what's missing, but "Unknown tool"
            // means it was defined and never wired into the dispatch switch.
            for name in MCPContract.toolNames {
                let call = try mcpTool(name)
                try expect(!call.text.hasPrefix("Unknown tool"), "\(name) is advertised but not dispatched")
            }

            let bogus = try mcpTool("summon_note")
            try expect(bogus.isError, "an unknown tool should come back as a tool error")
            try expect(bogus.text.contains("search_notes"), "an unknown tool should list the ones that do exist")
        }
    }
}

// MARK: - Argument handling

func testMCPArgumentsAreClampedAndCoerced() throws {
    try withTemporaryStorage { _, _ in
        try MainActor.assumeIsolated {
            let service = NotesService.shared
            for title in ["Alpha", "Beta", "Gamma"] {
                _ = try service.create(content: "\(title)\nbody", title: title, folder: nil)
            }

            // A negative offset used to index the slice out of bounds, which in
            // a tool call running on the main actor took the whole app with it.
            let negativeOffset = try decodeSummaries(try mcpTool("list_notes", ["offset": -5]).text)
            try expectEqual(negativeOffset.count, 3, "a negative offset should clamp to the start of the list")

            let pastEnd = try decodeSummaries(try mcpTool("list_notes", ["offset": 99]).text)
            try expect(pastEnd.isEmpty, "an offset past the end should return nothing, not fail")

            let negativeLimit = try decodeSummaries(try mcpTool("list_notes", ["limit": -1]).text)
            try expectEqual(negativeLimit.count, 1, "a negative limit should clamp to one note")

            // Models write numbers as strings often enough that the strict cast
            // silently falling back to the default is a real papercut.
            let stringLimit = try decodeSummaries(try mcpTool("list_notes", ["limit": "2"]).text)
            try expectEqual(stringLimit.count, 2, "a numeric string limit should be honoured")

            let paged = try decodeSummaries(try mcpTool("list_notes", ["offset": 1, "limit": 1]).text)
            try expectEqual(paged.count, 1, "paging should return one note")

            let badMode = try mcpTool("update_note", ["id": UUID().uuidString, "content": "x", "mode": "smoosh"])
            try expect(badMode.isError, "an unknown update mode should be a tool error")
            try expect(badMode.text.contains("prepend"), "an unknown mode should name the modes that work")

            let missing = try mcpTool("create_note")
            try expect(missing.isError, "create_note without content should be a tool error")
        }
    }
}

// MARK: - Service behaviour

func testNotesServiceLifecycle() throws {
    try withTemporaryStorage { storage, _ in
        try MainActor.assumeIsolated {
            let service = NotesService.shared

            // No title given → first line, the same rule the app uses.
            let created = try service.create(content: "Shopping\nmilk", title: nil, folder: nil)
            try expectEqual(created.title, "Shopping", "an untitled note should take its title from the first line")

            let appended = try service.update(id: created.id, content: "eggs", mode: .append, title: nil)
            try expectEqual(appended.content, "Shopping\nmilk\neggs", "append should add a line, not run text together")

            let prepended = try service.update(id: created.id, content: "TODO", mode: .prepend, title: nil)
            try expectEqual(prepended.content, "TODO\nShopping\nmilk\neggs", "prepend should go above the existing body")

            let replaced = try service.update(id: created.id, content: "just this", mode: .replace, title: "Renamed")
            try expectEqual(replaced.content, "just this", "replace should discard the old body")
            try expectEqual(replaced.title, "Renamed", "a supplied title should be applied")

            let read = try service.read(id: created.id, title: nil)
            try expectEqual(read.content, "just this", "the note should read back as it was written")

            // Titles fuzzy-match, bodies match literally.
            try expectEqual(try service.search(query: "Renam").map(\.id), [created.id], "search should match a title fuzzily")
            try expectEqual(try service.search(query: "just this").map(\.id), [created.id], "search should match body text")
            let miss = try service.search(query: "nothing here at all")
            try expect(miss.isEmpty, "a miss should return no notes")
            _ = try expectServiceError("an empty query", { try service.search(query: "   ") })

            // Folders resolve by name, case-insensitively, and nil is a real
            // destination (All Notes) rather than a missing argument.
            storage.saveFolders([NoteFolder(name: "Work")])
            try expectEqual(try service.move(id: created.id, folder: "work").folder, "Work", "a folder should resolve by name, ignoring case")
            try expectEqual(service.folders().first?.noteCount, 1, "the folder should report the note it now holds")
            let unfiled = try service.move(id: created.id, folder: nil)
            try expect(unfiled.folder == nil, "a nil folder should move the note to All Notes")
            _ = try expectServiceError("a folder that doesn't exist", { try service.move(id: created.id, folder: "Nowhere") })

            let deleted = try service.delete(id: created.id)
            try expectEqual(deleted.title, "Renamed", "delete should report what it removed")
            _ = try expectServiceError("reading a deleted note", { try service.read(id: created.id, title: nil) })
        }
    }
}

func testMCPLockIsOneWay() throws {
    try withTemporaryStorage { storage, _ in
        try MainActor.assumeIsolated {
            let service = NotesService.shared
            let note = try service.create(content: "recovery codes", title: "Codes", folder: nil)

            let locked = try service.lock(id: note.id)
            try expect(locked.isLocked, "lock should report the note as locked")
            try expect(
                storage.loadNotes().first { $0.id.uuidString == note.id }?.isLocked == true,
                "the lock should survive to disk"
            )

            // Locking is what every other write checks for, so the tools that
            // change a note must now refuse it.
            let edit = try mcpTool("update_note", ["id": note.id, "content": "more"])
            try expect(edit.isError, "a locked note should refuse an edit")
            try expect(edit.text.contains("locked"), "the refusal should say the note is locked")
            let removal = try mcpTool("delete_note", ["id": note.id])
            try expect(removal.isError, "a locked note should refuse deletion")

            // Re-locking is a no-op rather than an error: a model retrying has
            // already got what it asked for.
            let again = try mcpTool("lock_note", ["id": note.id])
            try expect(!again.isError, "locking an already-locked note should succeed quietly")

            // There is deliberately no way to unlock from MCP — an unlock
            // argument here would undo every guard above.
            let schema = try mcpResult("tools/list")["tools"] as? [[String: Any]] ?? []
            let lockTool = schema.first { $0["name"] as? String == "lock_note" }
            let properties = (lockTool?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
            try expectEqual(properties.keys.sorted(), ["id"], "lock_note should take an id and nothing else")

            // Locking saves the whole note, and a save that forgets the RTF
            // deletes the sidecar with the user's formatting in it.
            let rtf = try NSAttributedString(string: "styled").data(
                from: NSRange(location: 0, length: 6),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            let rich = Note(title: "Rich", content: "styled", rtfData: rtf)
            try expectSuccess(storage.saveNote(rich), "saving the rich fixture")
            _ = try service.lock(id: rich.id.uuidString)
            let reloaded = storage.loadNotes().first { $0.id == rich.id }
            try expectEqual(reloaded?.rtfData, rtf, "locking must not drop the note's RTF sidecar")
            try expect(reloaded?.isLocked == true, "the rich note should be locked")
        }
    }
}

func testNotesServiceRejectsBadReferencesAndLockedWrites() throws {
    try withTemporaryStorage { storage, _ in
        try MainActor.assumeIsolated {
            let service = NotesService.shared

            let malformedId = try expectServiceError("a malformed id", { try service.read(id: "note-42", title: nil) })
            guard case .invalidArgument = malformedId else {
                throw SmokeTestFailure.failed("a malformed id should be an invalid-argument error, not a missing note")
            }
            let unknownId = try expectServiceError("an unknown id", { try service.read(id: UUID().uuidString, title: nil) })
            guard case .noteNotFound = unknownId else {
                throw SmokeTestFailure.failed("an id that parses but matches nothing should be note-not-found")
            }
            _ = try expectServiceError("neither id nor title", { try service.read(id: nil, title: nil) })

            // Two notes can legitimately share a title, so a title lookup has to
            // hand back the ids rather than guess.
            _ = try service.create(content: "one", title: "Twin", folder: nil)
            _ = try service.create(content: "two", title: "Twin", folder: nil)
            let duplicate = try expectServiceError("a duplicated title", { try service.read(id: nil, title: "twin") })
            guard case .ambiguousTitle(_, let ids) = duplicate else {
                throw SmokeTestFailure.failed("a duplicated title should be an ambiguous-title error")
            }
            try expectEqual(ids.count, 2, "an ambiguous title should list both candidates")

            // Locked notes: readable and searchable (the app's own editor and
            // search show them), but every write is refused.
            let locked = Note(title: "Passport", content: "number 123", isLocked: true)
            try expectSuccess(storage.saveNote(locked), "saving the locked fixture")

            let detail = try service.read(id: locked.id.uuidString, title: nil)
            try expectEqual(detail.content, "number 123", "a locked note should still read")
            try expect(detail.isLocked, "a locked note should be flagged as locked")
            try expectEqual(try service.search(query: "number 123").map(\.id), [locked.id.uuidString], "a locked note should still be searchable")

            for write in ["update", "move", "delete"] {
                let error = try expectServiceError("a \(write) on a locked note", {
                    switch write {
                    case "update": _ = try service.update(id: locked.id.uuidString, content: "x", mode: .append, title: nil)
                    case "move": _ = try service.move(id: locked.id.uuidString, folder: nil)
                    default: _ = try service.delete(id: locked.id.uuidString)
                    }
                })
                guard case .noteLocked = error else {
                    throw SmokeTestFailure.failed("\(write) on a locked note should be refused as locked, got \(error)")
                }
            }
            try expect(
                storage.loadNotes().contains { $0.id == locked.id && $0.content == "number 123" },
                "a locked note must survive the refused writes untouched"
            )
        }
    }
}
