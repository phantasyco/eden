import SwiftUI

/// Add MCP Server: a name, and a command (stdio) or URL (HTTP), added through
/// the agent's own `mcp add`.
struct MCPServerSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let agent: AgentKind
    @State private var name = ""
    @State private var target = ""
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add MCP Server").font(.headline)
                Text("For \(Providers.name(of: agent)) models. Eden adds it with \(agent.displayName)'s own `mcp add`, so every session picks it up.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Name", text: $name, prompt: Text("sentry"))
                TextField("Command or URL", text: $target, prompt: Text("https://mcp.sentry.dev/mcp or npx my-server"))
                    .font(.body.monospaced())
            }
            .formStyle(.columns)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if adding { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || target.trimmingCharacters(in: .whitespaces).isEmpty || adding)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func add() {
        adding = true
        error = nil
        Task {
            do {
                try await MCP.add(to: agent, name: name.trimmingCharacters(in: .whitespaces), target: target.trimmingCharacters(in: .whitespaces))
                app.loadMCPServers(for: agent, force: true)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            adding = false
        }
    }
}
