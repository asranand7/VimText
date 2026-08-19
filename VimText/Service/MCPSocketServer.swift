import AppKit
import Darwin
import Foundation
import MCPContract

/// Listens on a Unix domain socket and serves MCP requests out of the running
/// app, so an agent always sees the same notes the user does.
///
/// A Unix socket rather than a localhost port: a TCP listener makes macOS pop
/// the "accept incoming network connections?" firewall prompt on first launch,
/// which is a terrible first impression for a notes app. A socket file has no
/// port, raises no prompt, and — at mode 0600 inside the user's own Application
/// Support folder — is reachable only by the user, the same trust boundary the
/// notes files already sit behind.
///
/// Wire format is newline-delimited JSON-RPC: byte-identical to MCP's stdio
/// transport, which is what lets `vimtext-mcp` be a plain relay.
public final class MCPSocketServer {
    public static let shared = MCPSocketServer()

    public static let enabledDefaultsKey = "mcpServerEnabled"

    /// The server is always on: it starts with the app and has no UI switch,
    /// and `vimtext-mcp` launches the app when it isn't running, so an agent
    /// can always reach the user's notes. This key exists only as a support
    /// escape hatch (`defaults write com.vimtext.app mcpServerEnabled -bool false`).
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// Shared with the relay, which has to find this without configuration.
    public static var socketPath: String { MCPContract.socketPath }

    /// A request larger than this is a client gone wrong, not a note: the
    /// biggest legitimate one is a note body, and without a ceiling a peer that
    /// never sends a newline grows this process's memory until it dies.
    private static let maxRequestBytes = 16 * 1024 * 1024

    private let queue = DispatchQueue(label: "com.vimtext.mcp.listener")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    public private(set) var isRunning = false

    private init() {}

    // MARK: - Lifecycle

    /// Binds the socket and begins accepting. Safe to call more than once.
    public func start() {
        guard !isRunning, Self.isEnabled else { return }

        let path = Self.socketPath
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // sockaddr_un.sun_path is a fixed 104-byte buffer on Darwin; a longer
        // path would be silently truncated and bind somewhere unexpected.
        guard path.utf8.count < 104 else {
            NSLog("[VimText MCP] socket path too long (\(path.utf8.count) bytes): \(path)")
            return
        }

        // A socket file left behind by a crash would make bind() fail with
        // EADDRINUSE forever, so clear it first.
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[VimText MCP] socket() failed: \(String(cString: strerror(errno)))")
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &address.sun_path) { pathPointer in
            pathPointer.withMemoryRebound(to: CChar.self, capacity: 104) { destination in
                _ = strlcpy(destination, path, 104)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            NSLog("[VimText MCP] bind() failed: \(String(cString: strerror(errno)))")
            close(fd)
            return
        }

        // Owner-only: the socket is the door to every note.
        chmod(path, 0o600)

        guard listen(fd, 8) == 0 else {
            NSLog("[VimText MCP] listen() failed: \(String(cString: strerror(errno)))")
            close(fd)
            unlink(path)
            return
        }

        listenFD = fd
        isRunning = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPendingConnections() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    public func stop() {
        guard isRunning else { return }
        isRunning = false
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(Self.socketPath)
    }

    @objc private func applicationWillTerminate() {
        stop()
    }

    // MARK: - Connections

    private func acceptPendingConnections() {
        while true {
            let clientFD = accept(listenFD, nil, nil)
            guard clientFD >= 0 else {
                // A signal during accept() isn't the "no more pending
                // connections" answer (EAGAIN) that ends this pass.
                if errno == EINTR { continue }
                return
            }

            // Without SO_NOSIGPIPE, a client that goes away mid-write takes the
            // whole app down with SIGPIPE.
            var on: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

            // One serial queue per connection: requests on a connection are
            // answered in order, and separate clients don't block each other.
            DispatchQueue(label: "com.vimtext.mcp.connection").async { [weak self] in
                self?.serve(clientFD)
                close(clientFD)
            }
        }
    }

    private func serve(_ fd: Int32) {
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)

        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            guard count > 0 else { return } // peer closed
            pending.append(contentsOf: buffer[0..<count])

            while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                let line = pending[pending.startIndex..<newline]
                pending = pending[pending.index(after: newline)...]
                guard !line.isEmpty else { continue }

                // MCPProtocol reads and writes the note store, so it has to run
                // on the main actor. Blocking this connection's queue until it
                // returns is exactly the request/response semantics we want.
                let message = Data(line)
                let reply = DispatchQueue.main.sync {
                    MainActor.assumeIsolated { MCPProtocol.handle(message) }
                }
                if let reply, !write(fd, reply + Data([UInt8(ascii: "\n")])) {
                    return
                }
            }

            if pending.count > Self.maxRequestBytes {
                NSLog("[VimText MCP] dropping a connection that sent \(pending.count) bytes with no newline")
                return
            }
        }
    }

    /// Writes every byte, tolerating short writes and interrupted syscalls.
    /// Returns false once the peer is gone.
    private func write(_ fd: Int32, _ data: Data) -> Bool {
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
}
