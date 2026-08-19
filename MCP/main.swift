import Darwin
import Foundation
import MCPContract

// vimtext-mcp — the MCP stdio server MCP clients are pointed at.
//
// It holds no note logic of its own. Tools and their behaviour live in the
// running VimText app (which owns the notes in memory); this relays JSON-RPC
// between the client's stdio and the app's Unix socket. Keeping it a dumb pipe
// means updating VimText updates the tools, with no client reconfiguration and
// no second copy of the storage format to keep in sync.
//
// The exception is the part of the protocol that says what this server *is*
// rather than what the notes contain — handshake, tool list, ping. Those come
// from `MCPContract`, which the app compiles in too, and are answered here so
// that opening an agent session never launches a notes app. VimText is started
// on the first call that actually needs a note.
//
// No VimTextCore dependency: an MCP client spawns this on every session, so
// start-up time is a feature.

/// How long to wait for the app to answer one request before giving up. Every
/// call is a small local read or write, so this only ever fires when the app is
/// wedged — in which case an error the agent can report beats a hang with no
/// way out.
let replyTimeoutSeconds = 60

func log(_ message: String) {
    // stderr only. Anything on stdout would be parsed as a protocol message.
    FileHandle.standardError.write(Data("[vimtext-mcp] \(message)\n".utf8))
}

// MARK: - Socket

/// Connects to the app's socket, or returns nil if nothing is listening.
func connectToApp() -> Int32? {
    let socketPath = MCPContract.socketPath
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
    var timeout = timeval(tv_sec: replyTimeoutSeconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
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

var connection: Int32?

/// Anything buffered past a reply's newline is kept for the next call — replies
/// can arrive coalesced in one packet.
var socketBuffer = Data()

/// A connection to an app that is *already* running, or nil. Never launches.
func existingConnection() -> Int32? {
    if let connection { return connection }
    guard let fd = connectToApp() else { return nil }
    connection = fd
    return fd
}

/// The live connection, launching and waiting for VimText when it isn't up yet.
func ensureConnection() -> Int32? {
    if let fd = existingConnection() { return fd }

    log("VimText isn't running — starting it")
    launchApp()

    // Cold launch plus first-window setup; polling beats a fixed sleep because
    // a warm app answers almost immediately.
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if let fd = connectToApp() {
            connection = fd
            return fd
        }
        usleep(150_000)
    }
    log("gave up waiting for VimText to start")
    return nil
}

/// Drops the current socket so the next request reconnects (and relaunches)
/// rather than failing forever, and discards any half-read reply with it.
func dropConnection() {
    if let connection { close(connection) }
    connection = nil
    socketBuffer = Data()
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

enum ReplyOutcome {
    case reply(Data)
    /// The app is up but didn't answer in time (main thread wedged).
    case timedOut
    case disconnected
}

/// Reads one newline-terminated reply.
func readReply(_ fd: Int32) -> ReplyOutcome {
    var chunk = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        if let newline = socketBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = Data(socketBuffer[socketBuffer.startIndex..<newline])
            socketBuffer = Data(socketBuffer[socketBuffer.index(after: newline)...])
            return .reply(line)
        }
        let count = read(fd, &chunk, chunk.count)
        if count < 0 {
            if errno == EINTR { continue }
            // SO_RCVTIMEO expiry surfaces as EAGAIN.
            return errno == EAGAIN || errno == EWOULDBLOCK ? .timedOut : .disconnected
        }
        guard count > 0 else { return .disconnected } // app closed the connection
        socketBuffer.append(contentsOf: chunk[0..<count])
    }
}

// MARK: - Locally answered methods

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes]) else { return }
    FileHandle.standardOutput.write(data + Data([UInt8(ascii: "\n")]))
}

func successResponse(id: Any, result: [String: Any]) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "result": result]
}

func errorResponse(id: Any, message: String) -> [String: Any] {
    ["jsonrpc": "2.0", "id": id, "error": ["code": -32_000, "message": message]]
}

/// The reply to a method that describes the server rather than the notes, or
/// nil when the message has to go to the app.
///
/// `initialize` is answered here so a cold VimText launch can't overrun the
/// client's handshake timeout. `tools/list` is answered here only when the app
/// isn't already up: a client asks for it as soon as it connects, and launching
/// a notes app because someone opened a terminal is not what anyone wants —
/// but a running app is still the authority, and forwarding to it costs
/// nothing.
func localResponse(method: String?, id: Any, params: [String: Any]) -> [String: Any]? {
    switch method {
    case "initialize":
        return successResponse(id: id, result: MCPContract.initializeResult(
            requestedVersion: params["protocolVersion"] as? String
        ))
    case "server/discover":
        return successResponse(id: id, result: MCPContract.discoverResult())
    case "ping":
        return successResponse(id: id, result: [:])
    case "tools/list" where existingConnection() == nil:
        return successResponse(id: id, result: ["tools": MCPContract.toolDefinitions])
    default:
        return nil
    }
}

// MARK: - Relay loop

while let line = readLine(strippingNewline: true) {
    guard !line.isEmpty, let data = line.data(using: .utf8) else { continue }
    let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let method = message?["method"] as? String

    // Notifications carry no id and expect no reply. Dropping them here keeps
    // the relay strictly one-request-one-reply, so a reply can never be
    // misattributed to the wrong request.
    guard let id = message?["id"] else { continue }

    if let local = localResponse(method: method, id: id, params: message?["params"] as? [String: Any] ?? [:]) {
        emit(local)
        continue
    }

    guard var fd = ensureConnection() else {
        emit(errorResponse(id: id, message: "VimText could not be started, so notes aren't reachable. Open VimText and try again."))
        continue
    }

    // A failed write means the app went away since the last call — VimText was
    // quit, or rebuilt — and the request never landed: the app drops a partial
    // line when the connection closes. That is safe to retry on a fresh
    // connection, and beats spending the agent's turn on an error the very next
    // identical call wouldn't hit. (A failed *read* is not retried: the app may
    // already have applied the write, and a second create_note would duplicate
    // the note.)
    let payload = data + Data([UInt8(ascii: "\n")])
    if !writeAll(fd, payload) {
        dropConnection()
        guard let reconnected = ensureConnection(), writeAll(reconnected, payload) else {
            dropConnection()
            emit(errorResponse(id: id, message: "Lost the connection to VimText. Try that again."))
            continue
        }
        fd = reconnected
    }

    switch readReply(fd) {
    case .reply(let reply):
        FileHandle.standardOutput.write(reply + Data([UInt8(ascii: "\n")]))
    case .timedOut:
        // The answer may still turn up later on this socket, where it would be
        // read as the *next* request's reply, so the socket goes too.
        dropConnection()
        emit(errorResponse(id: id, message: "VimText didn't respond within \(replyTimeoutSeconds)s. It may be busy — try that again."))
    case .disconnected:
        dropConnection()
        emit(errorResponse(id: id, message: "Lost the connection to VimText. Try that again."))
    }
}

if let connection { close(connection) }
