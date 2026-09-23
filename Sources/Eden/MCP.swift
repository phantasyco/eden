import Foundation

/// An MCP server one of the agents has configured, as its CLI lists it.
struct MCPServer: Identifiable, Hashable {
    let name: String
    /// "Connected", "Failed to connect", "enabled", "disabled", as the CLI says it.
    let status: String

    var id: String { name }
    var isHealthy: Bool {
        let status = status.lowercased()
        return status.contains("connected") && !status.contains("fail") || status == "enabled"
    }
}

/// Lists and adds MCP servers through each CLI's own `mcp` commands. Eden
/// lists from your home folder, so it shows your own servers, not a
/// repository's project servers: listing those would start commands a freshly
/// cloned repository chose.
enum MCP {
    static func servers(for agent: AgentKind) async -> [MCPServer] {
        guard agent.managesMCP, let executable = Shell.which(agent.binary) else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let out = await Task.detached(operation: { try? Shell.run(executable, ["mcp", "list"], cwd: home) }).value else { return [] }
        let text = out.stdout + out.stderr
        return agent == .claude ? parseClaude(text) : parseCodex(text)
    }

    /// Adds a server by command (stdio) or URL (HTTP).
    static func add(to agent: AgentKind, name: String, target: String) async throws {
        guard let executable = Shell.which(agent.binary) else {
            throw EdenError(message: "\(agent.displayName) isn't installed.")
        }
        let isURL = target.hasPrefix("http://") || target.hasPrefix("https://")
        let words = target.split(separator: " ").map(String.init)
        let args: [String]
        switch (agent, isURL) {
        // User scope: Claude Code's default scope is the folder it runs in, and
        // threads run in worktrees, so a local server would never reach them.
        case (.claude, true): args = ["mcp", "add", "--scope", "user", "--transport", "http", name, target]
        case (.claude, false): args = ["mcp", "add", "--scope", "user", name, "--"] + words
        case (.codex, true): args = ["mcp", "add", name, "--url", target]
        case (.codex, false): args = ["mcp", "add", name, "--"] + words
        default: throw EdenError(message: "Add MCP servers to \(agent.displayName) in its own settings.")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let out = try await Task.detached { try Shell.run(executable, args, cwd: home) }.value
        guard out.status == 0 else {
            throw EdenError(message: (out.stderr.isEmpty ? out.stdout : out.stderr).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// "name: command-or-url - ✓ Connected", one per line after a header.
    /// Plugin servers have colons in their names ("plugin:x:y"), so the name
    /// ends at the first colon followed by a space.
    private static func parseClaude(_ text: String) -> [MCPServer] {
        text.split(separator: "\n").compactMap { line in
            guard let separator = line.range(of: ": "), let dash = line.range(of: " - ", options: .backwards),
                  separator.lowerBound < dash.lowerBound
            else { return nil }
            let name = line[..<separator.lowerBound].trimmingCharacters(in: .whitespaces)
            let status = line[dash.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: " ✓✔✗✘!⚠"))
            return name.isEmpty ? nil : MCPServer(name: name, status: status)
        }
    }

    /// Tables headed "Name ... Status ...": the name is the first column, and
    /// the status is whichever of enabled or disabled appears in the row.
    private static func parseCodex(_ text: String) -> [MCPServer] {
        text.split(separator: "\n").compactMap { line in
            let columns = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let name = columns.first, name != "Name",
                  let status = columns.first(where: { $0 == "enabled" || $0 == "disabled" })
            else { return nil }
            return MCPServer(name: name, status: status)
        }
    }
}
