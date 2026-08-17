import Foundation

/// Adds and removes VimText's entry in an MCP client's config file, so
/// connecting an assistant is one button rather than a documentation page.
///
/// Every supported client uses the same shape — a top-level `mcpServers` object
/// keyed by server name — so one installer covers all of them; only the file
/// path differs. Config files belong to other apps and carry the user's other
/// servers, so writes are always read-modify-write with a backup, never a
/// wholesale overwrite.
public enum MCPClientInstaller {
    /// The key VimText registers itself under.
    public static let serverKey = "vimtext"

    /// How a client's registration is written.
    public enum Strategy: Hashable {
        /// Merge into the client's JSON config file. Correct for clients that
        /// only read their config at startup.
        case configFile
        /// Shell out to the client's own CLI.
        ///
        /// Required for Claude Code: `~/.claude.json` is not a config file it
        /// merely reads, it's live state a running Claude Code keeps in memory
        /// and rewrites wholesale (caches, per-project history). An external
        /// read-modify-write is therefore silently reverted the next time it
        /// saves — the entry lands on disk, works until restart, and vanishes.
        /// Going through `claude mcp add` makes it do the merge itself.
        case cli(executable: String)
    }

    public struct Client: Identifiable, Hashable {
        public let id: String
        public let name: String
        /// The config file the entry ends up in. Written directly under
        /// `.configFile`; under `.cli` it is only read, to report status.
        public let configPath: String
        /// The file or folder whose existence means the client is installed.
        public let detectionPath: String
        /// Where the user finds the setting, for the "restart it" hint.
        public let restartHint: String
        public let strategy: Strategy

        public var isClientInstalled: Bool {
            FileManager.default.fileExists(atPath: detectionPath)
        }
    }

    public enum Status: Equatable {
        /// Connected and pointing at this copy of VimText.
        case connected
        /// Registered, but pointing at a different (moved or older) binary.
        case needsUpdate
        case notConnected
    }

    public enum InstallError: LocalizedError {
        case unreadableConfig(String)
        case malformedConfig(String)
        case writeFailed(String)
        case cliNotFound(String, String)
        case cliFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case .unreadableConfig(let name): return "Could not read \(name)'s config file."
            case .malformedConfig(let name): return "\(name)'s config file isn't valid JSON, so it wasn't changed. Fix it and try again."
            case .writeFailed(let detail): return "Could not save the config file: \(detail)"
            case .cliNotFound(let name, let executable):
                return "Couldn't find the `\(executable)` command, so \(name) can't be configured automatically. Use “Copy Config” and add it yourself."
            case .cliFailed(let name, let detail):
                return "\(name) refused the change: \(detail.isEmpty ? "unknown error" : detail)"
            }
        }
    }

    private static var home: String { NSHomeDirectory() }

    public static let clients: [Client] = [
        Client(
            id: "claude-code",
            name: "Claude Code",
            configPath: "\(home)/.claude.json",
            detectionPath: "\(home)/.claude",
            restartHint: "Restart Claude Code to pick it up.",
            strategy: .cli(executable: "claude")
        ),
        Client(
            id: "claude-desktop",
            name: "Claude Desktop",
            configPath: "\(home)/Library/Application Support/Claude/claude_desktop_config.json",
            detectionPath: "\(home)/Library/Application Support/Claude",
            restartHint: "Fully quit Claude (⌘Q) and reopen it to pick it up.",
            strategy: .configFile
        ),
        Client(
            id: "gemini-cli",
            name: "Gemini CLI",
            configPath: "\(home)/.gemini/settings.json",
            detectionPath: "\(home)/.gemini",
            restartHint: "Restart the Gemini CLI to pick it up.",
            strategy: .configFile
        ),
        Client(
            id: "cursor",
            name: "Cursor",
            configPath: "\(home)/.cursor/mcp.json",
            detectionPath: "\(home)/.cursor",
            restartHint: "Restart Cursor to pick it up.",
            strategy: .configFile
        )
    ]

    /// Path to the relay binary that ships beside the app executable.
    ///
    /// When VimText runs from a `.app`, that bundle's copy is used, so a build
    /// installed anywhere registers itself correctly. Outside a bundle (a
    /// `swift run` dev build) there is nothing worth registering, so this falls
    /// back to the installed location.
    public static var serverBinaryPath: String {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            return bundle.appendingPathComponent("Contents/MacOS/vimtext-mcp").path
        }
        return "/Applications/VimText.app/Contents/MacOS/vimtext-mcp"
    }

    /// The snippet to paste into any client not listed above.
    public static var configSnippet: String {
        let object: [String: Any] = [
            "mcpServers": [serverKey: ["command": serverBinaryPath]]
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{\"mcpServers\":{\"\(serverKey)\":{\"command\":\"\(serverBinaryPath)\"}}}"
        }
        return text
    }

    // MARK: - Status

    public static func status(for client: Client) -> Status {
        guard let config = try? readConfig(client),
              let servers = config["mcpServers"] as? [String: Any],
              let entry = servers[serverKey] as? [String: Any],
              let command = entry["command"] as? String else {
            return .notConnected
        }
        return command == serverBinaryPath ? .connected : .needsUpdate
    }

    // MARK: - Mutations

    public static func install(_ client: Client) throws {
        if case .cli(let executable) = client.strategy {
            // Remove first: `mcp add` errors on an existing name, and a stale
            // entry pointing at a moved binary is exactly when reinstalling is
            // wanted. A missing entry makes remove fail harmlessly.
            _ = try? runCLI(client, executable, ["mcp", "remove", "--scope", "user", serverKey])
            try runCLI(client, executable, ["mcp", "add", "--scope", "user", serverKey, "--", serverBinaryPath])
            return
        }
        var config = try readConfig(client) ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverKey] = ["command": serverBinaryPath]
        config["mcpServers"] = servers
        try writeConfig(config, to: client)
    }

    public static func uninstall(_ client: Client) throws {
        if case .cli(let executable) = client.strategy {
            try runCLI(client, executable, ["mcp", "remove", "--scope", "user", serverKey])
            return
        }
        guard var config = try readConfig(client) else { return }
        guard var servers = config["mcpServers"] as? [String: Any] else { return }
        servers.removeValue(forKey: serverKey)
        config["mcpServers"] = servers
        try writeConfig(config, to: client)
    }

    // MARK: - CLI delegation

    /// Locations a client CLI is commonly installed to. A GUI app inherits a
    /// bare `PATH` from launchd — not the user's shell — so `/usr/bin/env foo`
    /// finds nothing and the search has to be explicit.
    private static func locateExecutable(_ name: String) -> String? {
        let candidates = [
            "\(home)/.claude/local/\(name)",
            "\(home)/.local/bin/\(name)",
            "\(home)/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)"
        ]
        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }
        // Last resort: ask a login shell, which sources the user's profile and
        // so knows about version managers (nvm, mise, asdf) and custom paths.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? capture(shell, ["-lc", "command -v \(name)"]) else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func runCLI(_ client: Client, _ executable: String, _ arguments: [String]) throws {
        guard let tool = locateExecutable(executable) else {
            throw InstallError.cliNotFound(client.name, executable)
        }
        let output: String
        do {
            output = try capture(tool, arguments)
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
        guard lastExitCode == 0 else {
            throw InstallError.cliFailed(client.name, output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private nonisolated(unsafe) static var lastExitCode: Int32 = 0

    /// Runs `tool` and returns stdout+stderr, recording the exit status.
    private static func capture(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lastExitCode = process.terminationStatus
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Config file I/O

    /// Returns nil when the file doesn't exist yet (a client that has never had
    /// an MCP server configured), which is a normal state, not an error.
    private static func readConfig(_ client: Client) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: client.configPath) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: client.configPath)) else {
            throw InstallError.unreadableConfig(client.name)
        }
        // An empty file is equivalent to "no config yet".
        guard !data.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InstallError.malformedConfig(client.name)
        }
        return object
    }

    private static func writeConfig(_ config: [String: Any], to client: Client) throws {
        let url = URL(fileURLWithPath: client.configPath)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Keep the last known-good copy next to the original: these files
            // hold the user's other MCP servers and, for Claude Code, a lot more
            // besides.
            if FileManager.default.fileExists(atPath: client.configPath) {
                let backup = url.appendingPathExtension("vimtext-backup")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            let data = try JSONSerialization.data(
                withJSONObject: config,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: url, options: .atomic)
        } catch let error as InstallError {
            throw error
        } catch {
            throw InstallError.writeFailed(error.localizedDescription)
        }
    }
}
