import Darwin
import Foundation

// vimtext-mcp — the MCP stdio server MCP clients are pointed at.
//
// It holds no note logic of its own. Tools and their behaviour live in the
// running VimText app (which owns the notes in memory); this relays JSON-RPC
// between the client's stdio and the app's Unix socket. Keeping it a dumb pipe
// means updating VimText updates the tools, with no client reconfiguration and
// no second copy of the storage format to keep in sync.
//
// Foundation only, no VimTextCore: an MCP client spawns this on every session,
// so start-up time is a feature.

let socketPath: String = {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return appSupport.appendingPathComponent("VimText/mcp.sock").path
}()

func log(_ message: String) {
    // stderr only. Anything on stdout would be parsed as a protocol message.
    FileHandle.standardError.write(Data("[vimtext-mcp] \(message)\n".utf8))
}

// MARK: - Socket

/// Connects to the app's socket, or returns nil if nothing is listening.
func connectToApp() -> Int32? {
    guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
        pathPointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
            _ = strlcpy(destination, socketPath, 104)
        }
    }

    let connected = withUnsafePointer(to: &address) { addressPointer in
        addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else {
        close(fd)
        return nil
    }

    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    return fd
}

/// The VimText.app this binary lives inside, so the relay launches the copy it
/// shipped with rather than whatever else is on the machine.
func containingAppBundle() -> String? {
    guard let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
    // …/VimText.app/Contents/MacOS/vimtext-mcp → …/VimText.app
    let bundle = executable
        .deletingLastPathComponent()  // MacOS
        .deletingLastPathComponent()  // Contents
        .deletingLastPathComponent()  // VimText.app
    guard bundle.pathExtension == "app", FileManager.default.fileExists(atPath: bundle.path) else { return nil }
    return bundle.path
}

/// Launches VimText without bringing it to the front, so an agent's tool call
/// never steals focus from what the user is doing.
func launchApp() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    if let bundle = containingAppBundle() {
        process.arguments = ["-g", bundle]
    } else {
        // Not running from inside the bundle (dev build, moved binary) — let
        // LaunchServices find the app by its identifier.
        process.arguments = ["-g", "-b", "com.vimtext.app"]
    }
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        log("could not launch VimText: \(error.localizedDescription)")
    }
}

/// The live connection, launching and waiting for VimText when it isn't up yet.
func ensureConnection(_ existing: Int32?) -> Int32? {
    if let existing { return existing }
    if let fd = connectToApp() { return fd }

    log("VimText isn't running — starting it")
    launchApp()

    // Cold launch plus first-window setup; polling beats a fixed sleep because
    // a warm app answers almost immediately.
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if let fd = connectToApp() { return fd }
        usleep(150_000)
    }
    log("gave up waiting for VimText to start")
    return nil
}

func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    var remaining = data
    while !remaining.isEmpty {
        let written = remaining.withUnsafeBytes { raw in
            Darwin.write(fd, raw.baseAddress, raw.count)
        }
        if written < 0 {
            if errno == EINTR { continue }
            return false
        }
        remaining = remaining.dropFirst(written)
    }
    return true
}

/// Reads one newline-terminated reply. Anything buffered past the newline is
/// kept for the next call — replies can arrive coalesced in one packet.
var socketBuffer = Data()

func readReply(_ fd: Int32) -> Data? {
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        if let newline = socketBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(socketBuffer[socketBuffer.startIndex..<newline])
            socketBuffer = Data(socketBuffer[socketBuffer.index(after: newline)...])
            return line
        }
        let count = read(fd, &chunk, chunk.count)
        if count < 0 {
            if errno == EINTR { continue }
            return nil
        }
        guard count > 0 else { return nil } // app closed the connection
        socketBuffer.append(contentsOf: chunk[0..<count])
    }
}

// MARK: - Local handshake

/// Kept in step with `MCPProtocol.supportedProtocolVersions` in the app.
let supportedProtocolVersions: Set<String> = [
    "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"
]

/// `initialize` is answered here rather than forwarded so a cold VimText launch
/// can't overrun the client's handshake timeout. The app is started on the
/// first real request instead. The response has to match the app's own — see
/// `MCPProtocol.initializeResult`.
func localInitializeResponse(id: Any, params: [String: Any]) -> [String: Any] {
    let requested = params["protocolVersion"] as? String
    let version = supportedProtocolVersions.contains(requested ?? "") ? requested! : "2025-06-18"
    return [
        "jsonrpc": "2.0",
        "id": id,
        "result": [
            "protocolVersion": version,
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "vimtext", "version": "1.0.0"],
            "instructions": """
            VimText is the user's personal notes app. Use these tools to search, read and edit \
            their notes. Note ids come from search_notes or list_notes — never invent one. \
            Prefer update_note with mode "append" over "replace" when adding to an existing \
            note, since replace discards the previous body. Locked notes are read-only and \
            their contents are hidden.
            """
        ] as [String: Any]
    ]
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data + Data([UInt8(ascii: "\n")]))
}

func errorResponse(id: Any, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": -32_000, "message": message]]
}

// MARK: - Relay loop

var connection: Int32?

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
    let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let method = message?["method"] as? String

    // Notifications carry no id and expect no reply. Dropping them here keeps
    // the relay strictly one-request-one-reply, so a reply can never be
    // misattributed to the wrong request.
    guard let id = message?["id"] else { continue }

    if method == "initialize" {
        emit(localInitializeResponse(id: id, params: message?["params"] as? [String: Any] ?? [:]))
        continue
    }

    guard let fd = ensureConnection(connection) else {
        emit(errorResponse(id: id, message: "VimText could not be started, so notes aren't reachable. Open VimText and try again."))
        continue
    }
    connection = fd

    guard writeAll(fd, data + Data([UInt8(ascii: "\n")])), let reply = readReply(fd) else {
        // The app quit mid-session. Drop the dead socket so the next request
        // reconnects (and relaunches) instead of failing forever.
        close(fd)
        connection = nil
        socketBuffer = Data()
        emit(errorResponse(id: id, message: "Lost the connection to VimText. Try that again."))
        continue
    }

    FileHandle.standardOutput.write(reply + Data([UInt8(ascii: "\n")]))
}

if let connection { close(connection) }
