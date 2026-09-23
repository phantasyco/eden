import AppKit
import SwiftUI

/// The composer's "+" menu: attach files, start with a skill, or check the
/// agent's MCP servers. A native menu with submenus, like Finder's "+" menus.
struct ComposerAddMenu: View {
    @Environment(AppModel.self) private var app
    let agent: AgentKind
    let repo: Repo?
    let attach: ([URL]) -> Void
    /// Puts a skill's "/name " at the start of the message.
    let insert: (String) -> Void
    /// Matches Send on the other side of the card, so both corners are concentric.
    var diameter: CGFloat = 28
    @State private var hovered = false

    var body: some View {
        Menu {
            Button("Attach Files…", systemImage: "paperclip") { chooseFiles() }
            if agent == .claude {
                Menu("Skills", systemImage: "book") {
                    let skills = self.skills
                    if skills.isEmpty {
                        Text("No Skills Found")
                    }
                    ForEach(skills, id: \.name) { skill in
                        Button {
                            insert("/\(skill.name) ")
                        } label: {
                            Text(skill.name)
                            Text(skill.detail.count > 80 ? skill.detail.prefix(79) + "…" : skill.detail)
                        }
                    }
                }
            }
            if agent.managesMCP {
                Menu("MCP Servers", systemImage: "server.rack") {
                    if let servers = app.mcpServers[agent] {
                        if servers.isEmpty { Text("No MCP Servers") }
                        ForEach(servers) { server in
                            Button {} label: {
                                Label {
                                    Text(server.name)
                                    Text(server.status)
                                } icon: {
                                    Image(systemName: server.isHealthy ? "checkmark.circle" : "exclamationmark.circle")
                                }
                            }
                        }
                    } else {
                        Text("Checking…")
                    }
                    Divider()
                    Button("Add MCP Server…", systemImage: "plus") { app.mcpSheetAgent = agent }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: diameter * 0.46, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        // A neutral circle: only Send is tinted, and nothing on the card has glass of its own.
        .frame(width: diameter, height: diameter)
        .background(Color.primary.opacity(hovered ? 0.12 : 0.08), in: Circle())
        .contentShape(Circle())
        .onHover { hovered = $0 }
        .help(agent.managesMCP ? "Attach files, use a skill, or check MCP servers" : "Attach files")
        .task(id: agent) { app.loadMCPServers(for: agent) }
    }

    /// Claude Code's skills in this repository. Before the first turn Eden
    /// can't tell skills from commands, so it lists them all.
    private var skills: [AgentCommand] {
        guard let repo else { return [] }
        let commands = app.agentCommands(for: repo, agent: agent)
        let names = ClaudeCommands.skillNames
        return names.isEmpty ? commands : commands.filter { names.contains($0.name) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        if panel.runModal() == .OK { attach(panel.urls) }
    }
}

/// Files waiting to go with the next message, each with a way to take it back.
struct AttachmentChips: View {
    @Binding var files: [URL]

    var body: some View {
        if !files.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(files, id: \.self) { file in
                    HStack(spacing: 5) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: file.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(file.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180, alignment: .leading)
                        Button {
                            files.removeAll { $0 == file }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Remove")
                    }
                    .font(.callout)
                    .padding(.leading, 6)
                    .padding(.trailing, 5)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

extension View {
    /// Dropping files anywhere on a composer attaches them.
    func acceptsAttachments(_ files: Binding<[URL]>) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let new = urls.filter { $0.isFileURL && !files.wrappedValue.contains($0) }
            files.wrappedValue += new
            return !new.isEmpty
        }
    }
}
