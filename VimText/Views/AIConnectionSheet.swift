import AppKit
import SwiftUI

/// Connects an AI assistant to these notes in one click.
///
/// The server itself is always on (it starts with the app, and `vimtext-mcp`
/// launches VimText when an agent calls while it's closed), so there is nothing
/// to switch on here — only which assistants are wired up to it.
struct AIConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var statuses: [String: MCPClientInstaller.Status] = [:]
    @State private var errorMessage: String?
    @State private var copied = false

    private var detectedClients: [MCPClientInstaller.Client] {
        MCPClientInstaller.clients.filter(\.isClientInstalled)
    }

    private var undetectedClients: [MCPClientInstaller.Client] {
        MCPClientInstaller.clients.filter { !$0.isClientInstalled }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            if detectedClients.isEmpty {
                Text("No supported assistants found on this Mac. Install Claude Code, Claude Desktop, Gemini CLI or Cursor, or paste the config below into any MCP client.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(detectedClients.enumerated()), id: \.element.id) { index, client in
                        if index > 0 { Divider() }
                        row(for: client)
                    }
                }
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }

            if !undetectedClients.isEmpty {
                Text("Not installed: \(undetectedClients.map(\.name).joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button(copied ? "Copied" : "Copy Config for Another Client") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MCPClientInstaller.configSnippet, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear(perform: refreshStatuses)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect an AI Assistant")
                .font(.headline)
            Text("Lets an assistant search, read and write these notes. It can reach them whether or not VimText is open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(for client: MCPClientInstaller.Client) -> some View {
        let status = statuses[client.id] ?? .notConnected
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                    .font(.system(size: 13, weight: .medium))
                Text(caption(for: status, client: client))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch status {
            case .connected:
                Button("Disconnect") { apply(uninstall: true, to: client) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            case .needsUpdate:
                Button("Update") { apply(uninstall: false, to: client) }
            case .notConnected:
                Button("Connect") { apply(uninstall: false, to: client) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func caption(for status: MCPClientInstaller.Status, client: MCPClientInstaller.Client) -> String {
        switch status {
        case .connected: return "Connected. \(client.restartHint)"
        case .needsUpdate: return "Points at a different copy of VimText."
        case .notConnected: return "Not connected."
        }
    }

    private func apply(uninstall: Bool, to client: MCPClientInstaller.Client) {
        do {
            if uninstall {
                try MCPClientInstaller.uninstall(client)
            } else {
                try MCPClientInstaller.install(client)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshStatuses()
    }

    private func refreshStatuses() {
        statuses = MCPClientInstaller.clients.reduce(into: [:]) { result, client in
            result[client.id] = MCPClientInstaller.status(for: client)
        }
    }
}
