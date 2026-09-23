import SwiftUI

/// Add Remote Project: a host from your SSH config and a folder on it. Eden
/// checks the folder is there before adding it.
struct RemoteProjectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var hosts = Machine.configuredHosts()
    @State private var host = ""
    @State private var path = ""
    @State private var adding = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Project on Another Machine").font(.headline)
                Text("Eden runs the agents, git, and the terminal there over SSH, with your SSH config and keys. The machine needs one of the agents installed and signed in there.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Form {
                if hosts.isEmpty {
                    TextField("Host", text: $host, prompt: Text("user@server"))
                } else {
                    Picker("Machine", selection: $host) {
                        ForEach(hosts, id: \.self) { Text($0).tag($0) }
                    }
                }
                TextField("Folder", text: $path, prompt: Text("~/code/project"))
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
                Button("Add Project", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(host.isEmpty || path.trimmingCharacters(in: .whitespaces).isEmpty || adding)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            if let preset = model.remoteProjectHost {
                if !hosts.contains(preset) { hosts.insert(preset, at: 0) }
                host = preset
                model.remoteProjectHost = nil
            }
            if host.isEmpty { host = hosts.first ?? "" }
        }
    }

    private func add() {
        adding = true
        error = nil
        Task {
            do {
                _ = try await model.addRemoteRepo(host: host, path: path.trimmingCharacters(in: .whitespaces))
                model.newChat(in: model.draftRepo)
                dismiss()
            } catch {
                self.error = "Couldn't open that folder on \(host).\n\(error.localizedDescription)"
            }
            adding = false
        }
    }
}
